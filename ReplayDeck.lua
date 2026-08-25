-- =====================================================================================
-- DCS Replay Deck -- in-sim agent
-- =====================================================================================
-- Install as:  <Saved Games>\DCS\Scripts\Hooks\ReplayDeck.lua
--
-- Broadcasts replay state to the deck on UDP 31490 and takes commands on 31491.
--
-- WHAT LIVES HERE AND WHAT LIVES IN THE DECK
--
-- There is no Lua API for time acceleration -- iCommandAccelerate is an INPUT command, not
-- a function -- so the deck drives speed by synthesising LCtrl+Z / LAlt+Z / LShift+Z into
-- the DCS window. Everything that needs to be exact lives here instead:
--
--   * DCS.setPause / DCS.restartMission        -- real API calls, flight-confirmed
--   * arrival detection for a seek             -- see ARMSTOP below
--
-- ARMSTOP is the reason this file exists rather than the deck simply watching the clock.
-- A UDP round trip costs upward of 100 ms, and at 24x that is 2.4 seconds of model time
-- sailed past -- for a tool whose entire selling point is landing on an exact second. So
-- the deck sends a TARGET and this file watches every frame and pauses the instant the
-- clock crosses it. Worst case is one frame of overshoot.
--
-- MEASURED, NOT ASSUMED
--
-- Sim speed is derived from getModelTime/getRealTime, never from counting our own
-- keystrokes. DCS displayed 3400x on SYNTAX's machine while delivering 16x, and a dropped
-- keypress would desynchronise a counting approach permanently and silently. See
-- docs/FINDINGS.md sections 2a-2c.
--
-- SAFETY
--
-- This runs in DCS's menu state. A throw at file scope kills the chunk before
-- DCS.setUserCallbacks and takes the whole hook with it, silently. Every call is wrapped,
-- the sockets open once and lazily, and nothing at all happens outside a mission -- two
-- testers once got a DCS that reached the menu and hung because a hook polled there.
-- =====================================================================================

local TAG = "REPLAYDECK"

local HOST       = "127.0.0.1"
local STATE_PORT = 31490   -- hook -> deck
local CMD_PORT   = 31491   -- deck -> hook

local STOPPED = 0.004      -- below this the sim is stopped, not slow. 1/64 is 0.015625;
                           -- a threshold of 0.02 reported the deepest slow-motion rung as
                           -- PAUSED, caught by test/hysteresis_test.lua before it ever flew.

local function say(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    pcall(log.write, TAG, log.INFO, ok and msg or tostring(fmt))
end

-- =====================================================================================
-- state
-- =====================================================================================
-- `seek` deliberately sits OUTSIDE the per-mission state. DCS.restartMission() tears the
-- mission down and builds it again, firing onMissionLoadEnd -- so a rewind target stored
-- in mission state would be wiped by the very call that starts the rewind.
local seek = {
    active  = false,  -- a seek is in flight
    target  = nil,    -- model time to stop at
    armed   = false,  -- watching every frame for the target
    -- Target set, but NOT yet watching: arm when the next mission finishes loading.
    --
    -- THIS IS WHY REWINDS DID NOTHING. The deck arms and then restarts, so for a moment the
    -- target is set while the sim is still at the OLD time -- past it. The arrival check saw
    -- `194 >= 140`, declared arrival, paused the sim and disarmed, all before restartMission
    -- had done anything. The deck got an ARRIVED it had not earned, stopped driving, and the
    -- replay restarted with nothing watching. SYNTAX saw "it restarted and did not advance".
    pending = false,
}

local st = {
    in_mission = false,
    frames     = 0,
    m_prev     = nil,
    r_prev     = nil,
    speed      = nil,   -- last CONFIRMED measured rate
    pending    = nil,   -- previous sample, awaiting agreement
    -- The FIRST model time seen after a load. This is the track's true floor, and the deck
    -- must get it from here rather than from a .trk on disk.
    --
    -- The deck used to read absoluteTime0 out of the newest file in the Tracks folder, and
    -- that file is wrong: DCS RECORDS A NEW TRACK WHILE REPLAYING ONE, so the newest .trk
    -- is always the live recording, never the thing being played. SYNTAX's deck showed
    -- "LastMissionTrack.trk, 8s" while the replay sat at 00:03:48, then refused a rewind
    -- with "already at the start of the track" because it was clamping against the wrong
    -- file's start time. The sim itself is the only reliable source.
    start_time = nil,
}

local sock = { tried = false, tx = nil, rx = nil, dead = false }

-- =====================================================================================
-- sockets
-- =====================================================================================
-- Rules taken from an earlier overlay hook of mine, each of which was paid for:
--   * a bare require("socket") is the Rebel9 bug -- package.path only carries LuaSocket
--     once some other script has primed it, so prime it before giving up.
--   * settimeout(0) BEFORE the socket is pointed anywhere it could block on.
--   * never assert() or socket.try(); they raise, and raising here breaks DCS's menus.
local function open_sockets()
    sock.tried = true

    local ok, s = pcall(require, "socket")
    if not ok then
        local root = "."
        local okd, d = pcall(function() return lfs.currentdir() end)
        if okd and type(d) == "string" and #d > 0 then root = d end
        for _, base in ipairs({ root, "." }) do
            package.path  = package.path  .. ";" .. base .. "\\LuaSocket\\?.lua"
            package.cpath = package.cpath .. ";" .. base .. "\\LuaSocket\\?.dll"
        end
        ok, s = pcall(require, "socket")
    end
    if not ok or type(s) ~= "table" or type(s.udp) ~= "function" then
        sock.dead = true
        say("LuaSocket unreachable even after priming package.path (%s) -- deck link disabled",
            tostring(s))
        return
    end

    local okt, tx = pcall(s.udp)
    if okt and tx then
        pcall(function() tx:settimeout(0) end)
        if pcall(function() tx:setpeername(HOST, STATE_PORT) end) then sock.tx = tx end
    end

    local okr, rx = pcall(s.udp)
    if okr and rx then
        local t = pcall(function() rx:settimeout(0) end)
        local b = pcall(function() return rx:setsockname(HOST, CMD_PORT) end)
        if t and b then sock.rx = rx end
    end

    say("link: state->%d %s, commands<-%d %s",
        STATE_PORT, sock.tx and "open" or "FAILED",
        CMD_PORT,   sock.rx and "open" or "FAILED")
end

local function send(msg)
    -- TEST SEAM. Nothing in DCS ever sets this global, so in the sim this is one nil lookup and
    -- nothing else. It lets test/kills_test.lua observe what the REAL detection code emits,
    -- rather than a copy of that code pasted into the test -- which is how a test quietly stops
    -- protecting the thing it was written for.
    local sink = _G.REPLAYDECK_TEST_SINK
    if sink then sink(msg) end
    if not sock.tx then return end
    pcall(function() sock.tx:send(msg) end)
end

-- =====================================================================================
-- live world-watcher  (real-time events)
-- =====================================================================================
-- Where the timeline's events come from now.
--
-- DCS only writes Logs\debrief.log when a replay PASS ENDS -- which is exactly why events
-- used to appear only after a restart or a seek, never as you watched. The camera probe
-- proved the Export world API is reachable from this hook state during a replay, so instead
-- of waiting for the debrief we watch the world ourselves: poll every object a few times a
-- second, and when a weapon APPEARS that is a shot, when a unit VANISHES that is a kill.
-- Each one streams to the deck the instant it happens, at the model time it happened.
--
-- FIRST RUN IS SELF-DOCUMENTING. LoGetWorldObjects' exact shape is not a thing to guess at
-- (two callback names each cost a sortie on this project). So the first few objects are
-- dumped in full and every emitted event is logged, capped, under REPLAYDECK -- one replay's
-- log says exactly what the objects look like and whether the shot/kill split is right.
-- Expect the first flight to be a little noisy (chaff and flares may read as "shot" until the
-- log tells us their type names); that run is the calibration.
local WORLD_POLL_FRAMES = 20    -- ~0.13s at 150 fps; a missile in flight lasts far longer
local WORLD_LOG_CAP     = 80

-- THE PHANTOM-KILL GUARD. The watcher decides a unit died by diffing this poll against the
-- previous one -- which is only meaningful if the two polls are ADJACENT MOMENTS of the same
-- pass. They are not, twice over:
--
--   * polling is suspended for the whole of a seek (see the pump: `not seek.active`), so the
--     poll after an arrival diffs against a snapshot from wherever the replay was BEFORE it,
--     often a thousand model seconds away;
--   * a rewind calls DCS.restartMission, so the next poll diffs a brand-new pass against the
--     dying breath of the old one.
--
-- Every unit present then and absent now is reported dead. On SYNTAX's Caucasus track that
-- produced 67 "kills" on one frame at t=288.13 -- the exact model time of the multiplayer
-- track's client init -- and had one human player killed four separate times
-- before taking off at t=2195. Roughly half the kills in the event list were fiction.
--
-- So: when model time jumps, do not diff. Re-baseline and emit nothing. A missed event costs
-- a mark on the timeline; an invented one sends the user to a moment where nothing happened.
local WORLD_MAX_GAP = 30.0      -- model seconds between polls before we distrust the diff.
                                -- 20 frames at 16x on a 20 fps machine is ~16s, so this has
                                -- headroom over the worst legitimate gap; a seek jumps by
                                -- hundreds and is caught every time.
local WORLD_CONFIRM = 3         -- consecutive polls a unit must stay missing before it is dead

local world = {
    prev = nil, polls = 0, logged = 0, dump_n = 0, newdump = 0, dumped = false, warned = false,
    last_t = nil,       -- model time of the previous poll
    rebase = false,     -- set when a seek starts; consumed by the first poll afterwards
    rebased = 0,        -- how many times we declined to diff (logged, capped)
    gone = {},          -- id -> disappearance awaiting confirmation; see the vanish loop
    dead = {},          -- unit NAME -> already reported dead this pass. A unit dies once.
    shot = {},          -- id -> weapon type already announced, so set churn cannot re-fire it
    returns = 0,        -- units that came back before confirming (logged, capped)
}

local function resolve_world()
    if type(_G.LoGetWorldObjects) == "function" then return _G.LoGetWorldObjects end
    if type(_G.Export) == "table" and type(_G.Export.LoGetWorldObjects) == "function" then
        return _G.Export.LoGetWorldObjects
    end
    return nil
end

-- A unit carries a UnitName; a weapon does not. This is the v1 discriminator; the schema dump
-- below is what confirms or corrects it.
local function obj_is_unit(o)
    return type(o.UnitName) == "string" and #o.UnitName > 0
end

-- Clean a free-text field down to what the space-separated wire format allows. NO length cap:
-- the debrief's labels carry a weapon and both pilots ("Vikhr_M_ATGM_9M127_extra_PILOTNAME")
-- and a 32-char cut amputates the half that says who was hit.
local function clean(s)
    return (tostring(s):gsub("%s+", "_"):gsub("[^%w_%-%.]", ""))
end

-- A single short token -- a unit name used as a lookup key, where length is not information.
local function clean_token(s)
    local t = clean(s)
    if #t > 32 then t = t:sub(1, 32) end
    return t
end

-- The object's TYPE name (AGM_88, M-1_Abrams), or nil if it has none. This is the signal that
-- separates a real weapon from the nameless burst objects -- chaff, flares and gun rounds --
-- that flooded the first run as "shot obj".
local function obj_name(o)
    if type(o.Name) == "string" and #o.Name > 0 then return clean(o.Name) end
    return nil
end

-- The unit's own name/callsign (BIGWILD, BLUE_LINE_SENAKI-1), or nil. Units carry one; weapons
-- and noise objects do not.
local function obj_unitname(o)
    -- clean_token, matching emit_poi's unit= field and the SNAP command exactly. If these three
    -- disagreed by so much as a truncation, a long unit name would be sent one way and looked up
    -- another, and the target would read as "absent" forever.
    if type(o.UnitName) == "string" and #o.UnitName > 0 then return clean_token(o.UnitName) end
    return nil
end

local function obj_side(o)
    return tonumber(o.CoalitionID) or tonumber(o.Coalition) or 0
end

-- `unit` is the name of the thing the camera could point at (the unit that died, for a kill),
-- or nil when there is no single subject -- a launch names a weapon, not a place to look. The
-- deck has parsed this field since 1.3.0 and treats "-" as absent, so emitting it is backward
-- compatible in both directions: an older deck ignores the extra key, a newer hook feeds a
-- newer deck. Keep the value through clean(): the wire format is space-separated.
local function emit_poi(t, kind, side, label, unit)
    side = tonumber(side) or 0
    t = tonumber(t) or 0
    -- Clean HERE, not in each caller: three separate producers feed this, and the wire format
    -- is space-separated, so one stray space from any of them corrupts every field after it.
    label = (label and #tostring(label) > 0) and clean(label) or tostring(kind)
    unit  = (unit and #tostring(unit) > 0) and clean_token(unit) or "-"
    send(string.format("POI t=%.3f kind=%s side=%d unit=%s label=%s", t, kind, side, unit, label))
    if world.logged < WORLD_LOG_CAP then
        world.logged = world.logged + 1
        say("world POI #%d: t=%.2f kind=%s side=%d unit=%s label=%s",
            world.logged, t, kind, side, unit, label)
    end
end

-- One-level field dump, so the real schema of an object is on record after a single replay --
-- including subtables like Type (the category), Position and Flags.
local function dump_object(id, o)
    local bits = {}
    pcall(function()
        for k, v in pairs(o) do
            local tv = type(v)
            if tv ~= "table" and tv ~= "function" then
                bits[#bits + 1] = tostring(k) .. "=" .. tostring(v)
            elseif tv == "table" then
                local sub = {}
                pcall(function()
                    for sk, sv in pairs(v) do
                        if type(sv) ~= "table" and type(sv) ~= "function" then
                            sub[#sub + 1] = tostring(sk) .. "=" .. tostring(sv)
                        end
                        if #sub >= 8 then break end
                    end
                end)
                bits[#bits + 1] = tostring(k) .. "={" .. table.concat(sub, ",") .. "}"
            end
        end
    end)
    say("world OBJ %s: %s", tostring(id), table.concat(bits, "  "))
end

local function poll_world(now)
    if type(now) ~= "number" then return end
    local get = resolve_world()
    if not get then
        if not world.warned then
            world.warned = true
            say("world: no LoGetWorldObjects reachable here -- live events off")
        end
        return
    end

    local ok, objs = pcall(get)
    if not ok or type(objs) ~= "table" then
        if not world.warned then
            world.warned = true
            say("world: LoGetWorldObjects failed (ok=%s type=%s) -- live events off",
                tostring(ok), type(objs))
        end
        return
    end

    local cur, names, count = {}, {}, 0
    for id, o in pairs(objs) do
        if type(o) == "table" then
            count = count + 1
            local prev = world.prev and world.prev[id]
            local un   = obj_unitname(o)
            -- Present-by-NAME as well as by id. DCS hands the same unit a new runtime id when it
            -- respawns or changes slot, so an id-keyed test alone reports a returning player as
            -- permanently gone -- which is exactly how a live human was recorded dead four times.
            if un then names[un] = true end
            cur[id] = {
                unit  = obj_is_unit(o),
                name  = obj_name(o),        -- type name, or nil
                uname = un,                 -- unit name, or nil
                side  = obj_side(o),
                seen  = (prev and prev.seen or 0) + 1,   -- consecutive polls present
            }
            if not world.dumped and world.dump_n < 4 then
                world.dump_n = world.dump_n + 1
                dump_object(id, o)
            end
        end
    end
    if not world.dumped then
        world.dumped = true
        say("world: first poll saw %d objects", count)
    end

    world.polls = world.polls + 1

    -- Is this poll adjacent to the last one, or did the replay jump? See WORLD_MAX_GAP above.
    -- A negative step is a rewind; an oversized one is a seek, a restart or the user holding
    -- the acceleration keys. In every case the two snapshots describe different moments and the
    -- difference between them is not a list of deaths.
    -- A FIXED ceiling, deliberately. An earlier version widened this by the last accepted gap
    -- ("adapt to the current speed") and that quietly destroyed the guard: each accepted poll
    -- raised the next allowance fourfold, so walking up the speed ladder ratcheted the ceiling
    -- from 30s to a thousand, and a genuine seek-sized discontinuity sailed through as a diff.
    -- A gap this large is untrustworthy no matter how fast the replay is running.
    local dt = (world.last_t and (now - world.last_t)) or 0
    local jumped = world.rebase
        or (world.last_t ~= nil and (dt < -0.001 or dt > WORLD_MAX_GAP))

    if jumped then
        if world.rebased < 12 then
            world.rebased = world.rebased + 1
            say("world: %s (%.1f -> %.1f, %+.1fs) -- re-baselined, no events from this poll",
                world.rebase and "seek/restart" or "time jump",
                world.last_t or now, now, dt)
        end
        world.rebase = false
        -- A presence streak belongs to a timeline. `cur` counted itself against the PRE-jump
        -- snapshot, so an id spanning the discontinuity would drag a ready-made streak into the
        -- baseline we are about to adopt and be eligible to "die" on the very next poll.
        for _, info in pairs(cur) do info.seen = 1 end
        world.prev   = cur
        world.last_t = now
        world.gone   = {}       -- pending disappearances belong to the abandoned timeline
        -- The rebase poll has already stored a complete baseline, so only ONE further poll of
        -- warm-up is owed. Zeroing this cost two poll intervals of blindness, and a real kill
        -- inside them was dropped for good.
        world.polls  = 1
        return
    end

    -- The vanish loop stamps a death with the moment the unit was LAST SEEN -- by definition the
    -- PREVIOUS poll, since it is absent from this one. Latch that before the assignment below
    -- destroys it, or every kill lands up to one poll interval late and the deck's 10-second
    -- lead-in is spent covering our own measurement error.
    local prev_t = world.last_t or now
    world.last_t = now

    -- Diff against the previous snapshot. Warm up for two polls so the initial population
    -- settles, and require the clock to have actually MOVED: a paused sim reports the same model
    -- time every frame, so dt is 0 and the guard above cannot see anything wrong -- yet the
    -- object set still churns while paused (every seek arrival sits paused). Diffing a frozen
    -- clock stamps that churn as a burst of kills at one instant.
    if world.prev and world.polls > 2 and dt > 0 then
        -- New weapons -> shots. A real weapon carries a type Name; the nameless burst objects
        -- (chaff, flares, gun rounds) are dropped. The first few nameless newcomers are dumped
        -- so the log shows exactly what they are, in case a real weapon ever lacks a name.
        -- `seen == 1` means "absent from the previous poll", which is true both for a genuinely
        -- new weapon AND for one that merely dropped out of this client-scoped set and came back
        -- -- the same churn that invented the kills. So each object announces a shot ONCE, and
        -- the note is keyed by id AND type name, so a recycled id carrying a different weapon
        -- still reports.
        for id, info in pairs(cur) do
            if info.seen == 1 and not info.unit then
                if not info.name and world.newdump < 8 then
                    world.newdump = world.newdump + 1
                    dump_object("NEW-nameless " .. tostring(id), objs[id])
                end
                if info.name and world.shot[id] ~= info.name then
                    world.shot[id] = info.name
                    emit_poi(now, "shot", info.side, info.name)
                end
            end
        end
        -- Vanished units -> kills, but ABSENCE IS NOT DEATH until it has been confirmed.
        --
        -- The set this diffs is small and client-scoped -- one poll saw 24 objects on a mission
        -- of 129 units -- and things drop out of it for reasons that have nothing to do with
        -- dying. SYNTAX's own log has one human player "killed" at t=1330.63 and
        -- again at t=1982.87 in ONE continuous stretch with no seek between them: he left the
        -- set and came back. A single missing poll is the weakest possible evidence of a death,
        -- and it is exactly what the old code acted on.
        --
        -- Two defences, because one is not enough:
        --
        --  1. HOLD. A disappearance is parked and only becomes a kill after WORLD_CONFIRM
        --     consecutive polls still missing. This catches the brief flicker.
        --  2. ONCE PER PASS, BY NAME. A unit dies once. That player was absent for hundreds of
        --     model seconds and returned, so no practical hold would have caught him -- but the
        --     SECOND and later "deaths" of a name are refutable on their own terms. The latch is
        --     keyed by unit NAME, not runtime id, precisely because DCS reissues the id on a
        --     respawn: an id-keyed latch would not recognise the returning unit as the same one.
        --
        -- Cancellation is also by name for the same reason: if any object now carries that name,
        -- the unit is present, whatever handle it arrived under.
        for id, info in pairs(world.prev) do
            if not cur[id] and info.unit and info.uname
               and (info.seen or 0) >= WORLD_CONFIRM
               and not world.dead[info.uname] and not world.gone[id] then
                world.gone[id] = {
                    uname = info.uname, side = info.side,
                    t = prev_t,             -- last seen at the PREVIOUS poll, not this one
                    seen = info.seen,       -- carried so a flicker cannot reset the streak
                    misses = 0,
                }
            end
        end

        for id, g in pairs(world.gone) do
            if cur[id] or names[g.uname] then
                -- Present again, under this handle or another. It was never a death.
                --
                -- Restore the presence streak HERE, while the record still exists: coming back
                -- restarted the count at 1 (it is read from world.prev, which had dropped this
                -- id), and a unit stuck below WORLD_CONFIRM can never have its REAL death
                -- reported. A flicker must not cost the unit its history.
                if cur[id] and (g.seen or 0) > (cur[id].seen or 0) then
                    cur[id].seen = g.seen
                end
                world.gone[id] = nil
                if world.returns < 12 then
                    world.returns = world.returns + 1
                    say("world: %s reappeared after %d missed poll(s) -- not a kill",
                        tostring(g.uname), g.misses)
                end
            else
                g.misses = g.misses + 1
                if g.misses >= WORLD_CONFIRM then
                    world.gone[id] = nil
                    world.dead[g.uname] = true
                    emit_poi(g.t, "kill", g.side, g.uname, g.uname)
                end
            end
        end
    end


    world.prev = cur
end

-- =====================================================================================
-- camera capability probe  (v1.4.0 groundwork -- measures, never guesses)
-- =====================================================================================
-- WHY THIS EXISTS. A camera-snap was built once on the belief that LoSetCameraPosition drives
-- the view from this Lua state. That belief was never tested: the probe written to prove it was
-- never installed, and REPLAYDECK-CAM appears zero times in every log on the machine. Worse, the
-- probe only ever drove POSITION -- its own comment says "Orientation is left as it was" -- so
-- even a success would have said nothing about AIMING, which is the entire feature.
--
-- Three unknowns decide whether a follow-cam is possible at all, and no amount of reading source
-- settles them. So ask the sim, once, and write the answers down:
--
--   1. Does writing a camera POSITION take effect?
--   2. Does writing an ORIENTATION take effect, or does DCS recompute it from its own view?
--   3. Does either work while the sim is PAUSED -- the only state a seek arrival is ever in?
--
-- The probe nudges the camera for two frames and puts it back exactly where it found it. It runs
-- once per DCS session, only when the user asks to jump to an event, and everything is pcall'd:
-- a probe that breaks the deck would cost more than the answer is worth.
local cam = {
    ran = false, phase = 0, base = nil, want = nil, fov = nil, unit = nil, threw = false,
}

local function cam_api()
    local E = (type(_G.Export) == "table") and _G.Export or _G
    local get = E.LoGetCameraPosition or _G.LoGetCameraPosition
    local set = E.LoSetCameraPosition or _G.LoSetCameraPosition
    if type(get) ~= "function" or type(set) ~= "function" then return nil, nil end
    return get, set
end

local function v3(t)
    if type(t) ~= "table" then return nil end
    return { x = tonumber(t.x) or 0, y = tonumber(t.y) or 0, z = tonumber(t.z) or 0 }
end

local function pose_copy(p)
    if type(p) ~= "table" then return nil end
    local c = { p = v3(p.p), x = v3(p.x), y = v3(p.y), z = v3(p.z) }
    if not c.p then return nil end
    return c
end

local function near(a, b, tol)
    if not a or not b then return false end
    return math.abs(a.x - b.x) < tol and math.abs(a.y - b.y) < tol and math.abs(a.z - b.z) < tol
end

-- Describe a pose in one line: the three orts plus the position, so the log carries the raw
-- numbers rather than a conclusion. Which ort is "forward" is exactly what we cannot yet assume.
local function pose_str(p)
    if not p then return "nil" end
    local function s(v) return v and string.format("(%.3f,%.3f,%.3f)", v.x, v.y, v.z) or "nil" end
    return string.format("p=(%.1f,%.1f,%.1f) x=%s y=%s z=%s", p.p.x, p.p.y, p.p.z,
                         s(p.x), s(p.y), s(p.z))
end

local function cam_probe_step()
    local get, set = cam_api()
    if not get or not set then
        if not cam.ran then
            cam.ran = true
            say("CAMPROBE: no LoGetCameraPosition/LoSetCameraPosition in this state -- a "
                .. "follow-cam is not possible from the hook. Feature stops here.")
            send("CAMPROBE result=absent")
        end
        return
    end

    local paused = select(2, pcall(function() return DCS.getPause() end))

    if cam.phase == 0 then
        local ok, pose = pcall(get)
        local base = ok and pose_copy(pose) or nil
        if not base then
            cam.ran, cam.phase = true, -1
            say("CAMPROBE: LoGetCameraPosition returned nothing usable (ok=%s) -- stopping",
                tostring(ok))
            send("CAMPROBE result=noget")
            return
        end
        cam.base = base
        cam.fov  = select(2, pcall(function() return DCS.getCurrentFOV() end))
        say("CAMPROBE frame 1: paused=%s fov=%s BASE %s",
            tostring(paused), tostring(cam.fov), pose_str(base))

        -- pose_copy only insists on a position, so a differently-shaped pose would reach the
        -- orientation maths below and throw on indexing a nil ort. Answer instead of throwing.
        if not (base.x and base.y and base.z) then
            cam.ran, cam.phase = true, -1
            say("CAMPROBE: the pose carries no orientation vectors -- aim cannot be tested this "
                .. "way; camera untouched")
            send("CAMPROBE result=noorts")
            return
        end

        -- Ask for something unmistakable: 250 m straight up, and the orientation rolled a
        -- quarter turn. Swap two orts AND NEGATE ONE. Swapping alone flips the determinant to
        -- -1, which is a mirror rather than a rotation -- not a pose any camera can hold, so a
        -- sim that validates its input would refuse the whole write and the read-back would
        -- report "aim ignored". That is the one answer that would wrongly kill this feature, so
        -- it must not be produced by handing DCS an impossible matrix. Negating restores det=+1.
        local want = pose_copy(base)
        want.p.y = want.p.y + 250.0
        want.x = v3(base.y)
        want.y = { x = -base.x.x, y = -base.x.y, z = -base.x.z }
        want.z = v3(base.z)
        cam.want = want
        -- NO WRITE. Driving the camera from here is settled: DCS reverts the pose on the next
        -- frame, and a large move crashes the sim outright (see snap_hold). The pose is still
        -- logged because the numbers are what taught us the axis convention, but nothing is set.
        say("CAMPROBE frame 1: would have written %s (not sent -- camera writes are disabled)",
            pose_str(want))
        cam.ran, cam.phase = true, 3
        send("CAMPROBE result=disabled")
        return
    end

    if cam.phase == 1 then
        local ok, pose = pcall(get)
        local got = ok and pose_copy(pose) or nil
        if not got then
            say("CAMPROBE frame 2: read-back failed -- inconclusive")
            send("CAMPROBE result=noreadback")
        else
            local pos_took = near(got.p, cam.want.p, 5.0)
            local pos_base = near(got.p, cam.base.p, 5.0)
            -- Orientation has three outcomes, and they are NOT the same answer. "Ignored"
            -- (handed back what was there before) means DCS owns the aim and a look-at
            -- follow-cam is impossible without another mechanism; "different from both" means
            -- something else is fighting us.
            local ori_took = near(got.x, cam.want.x, 0.01) and near(got.y, cam.want.y, 0.01)
            local ori_base = near(got.x, cam.base.x, 0.01) and near(got.y, cam.base.y, 0.01)
            local ori = ori_took and "TOOK" or (ori_base and "IGNORED(kept its own)" or "DIFFERENT")
            say("CAMPROBE frame 2: paused=%s POSITION %s ORIENTATION %s", tostring(paused),
                pos_took and "TOOK" or (pos_base and "IGNORED" or "MOVED-ELSEWHERE"), ori)
            say("CAMPROBE frame 2: GOT %s", pose_str(got))
            send(string.format("CAMPROBE result=ok pos=%s ori=%s paused=%s",
                pos_took and "took" or "ignored",
                ori_took and "took" or (ori_base and "ignored" or "different"),
                tostring(paused)))
        end
        cam.phase = 2
        return
    end

    if cam.phase == 2 then
        cam.ran, cam.phase = true, 3
        say("CAMPROBE: camera restored; probe complete")
    end
end

-- What can the sim actually see right now, and is the unit we care about among it? This is the
-- other half of the question: the last attempt failed to find its target and we still do not
-- know whether that is scoping, timing, or the unit simply not existing at that moment.
local function cam_report_world(uname)
    local get = resolve_world()
    if not get then return end
    local ok, objs = pcall(get)
    if not ok or type(objs) ~= "table" then return end
    local total, units, found, id_found = 0, 0, false, nil
    for id, o in pairs(objs) do
        if type(o) == "table" then
            total = total + 1
            local un = obj_unitname(o)
            if un then
                units = units + 1
                if uname and un == uname then found, id_found = true, id end
            end
        end
    end
    say("CAMPROBE world: %d objects, %d named units; target %q %s%s",
        total, units, tostring(uname or "-"),
        found and "PRESENT" or "ABSENT",
        found and (" (id " .. tostring(id_found) .. ")") or "")
    send(string.format("SNAPINFO objects=%d units=%d target=%s", total, units,
                       found and "present" or "absent"))
end

-- =====================================================================================
-- camera follow  (the actual snap: hold the view on a named unit, every frame)
-- =====================================================================================
-- Built on measurements, not assumptions. From a real pose DCS handed back (dcs.log,
-- "CAMPROBE frame 1: BASE"):
--
--   x=(0.878,-0.469,-0.092)  y=(0.467,0.883,-0.049)  z=(0.105,0.000,0.995)
--
-- z has a zero altitude component (horizontal), y is mostly +altitude, and x carries the
-- downward tilt of a camera looking at a jet below it. x cross y = (0.104,0.000,0.994) = z.
-- So the pose is RIGHT-HANDED with  x = FORWARD, y = UP, z = RIGHT, and forward x up = right.
-- That also matches how an existing flight-proven overlay on this machine reads the same table.
--
-- The world objects carry Position{x,y,z} AND Heading/Pitch/Bank, so the camera can sit behind
-- the target rather than at an arbitrary bearing. DCS world axes: x = north, z = east, y = up.
local CAM_BACK = 38.0       -- metres behind the target
local CAM_UP   = 11.0       -- metres above it
local SNAP_MISS_LIMIT = 240 -- frames the target may be missing before the hold gives up

local snap = {
    on = false, uname = nil, misses = 0, frames = 0,
    wrote = nil,        -- the pose we asked for last frame, to see whether it survived
    verdict = false,    -- whether the hold-vs-override question has been answered and logged
    threw = false,
}

local function v_norm(v)
    local m = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if not (m > 1e-6) then return nil end
    return { x = v.x / m, y = v.y / m, z = v.z / m }
end

local function v_cross(a, b)
    return { x = a.y * b.z - a.z * b.y,
             y = a.z * b.x - a.x * b.z,
             z = a.x * b.y - a.y * b.x }
end

-- The named unit's position and heading, or nil if the sim cannot currently see it.
local function find_unit(uname)
    local get = resolve_world()
    if not get then return nil end
    local ok, objs = pcall(get)
    if not ok or type(objs) ~= "table" then return nil end
    for id, o in pairs(objs) do
        if type(o) == "table" and type(o.Position) == "table" and obj_unitname(o) == uname then
            return {
                id = id,
                x = tonumber(o.Position.x) or 0,
                y = tonumber(o.Position.y) or 0,
                z = tonumber(o.Position.z) or 0,
                heading = tonumber(o.Heading) or 0,
            }
        end
    end
    return nil
end

-- A chase pose: eye behind and above the target, aimed at it.
local function chase_pose(t)
    local hx, hz = math.cos(t.heading), math.sin(t.heading)
    local eye = { x = t.x - hx * CAM_BACK, y = t.y + CAM_UP, z = t.z - hz * CAM_BACK }

    local f = v_norm({ x = t.x - eye.x, y = t.y - eye.y, z = t.z - eye.z })
    if not f then return nil end
    -- right = forward x worldUp, then up = right x forward. This is the ordering that
    -- reproduces the measured identity forward x up = right; getting it backwards mirrors the
    -- image, which is a pose no camera can hold.
    local r = v_norm(v_cross(f, { x = 0, y = 1, z = 0 }))
    if not r then return nil end          -- looking straight up or down; no stable roll
    local u = v_cross(r, f)
    return { x = f, y = u, z = r, p = eye }
end

-- Called every frame while a snap is active. DCS's own view controller writes the camera each
-- frame too, so this must re-assert rather than set once -- a single write is simply replaced,
-- which is what the one-shot probe measured.
-- DISABLED BY MEASUREMENT, NOT BY OPINION. This used to drive the camera onto the followed
-- unit every frame. On SYNTAX's Caucasus track it CRASHED DCS:
--
--   snap: following <a unit ~40 km away> at (-246134,2187,663100)
--   snap: re-assert check -- last frame's pose was OVERWRITTEN by DCS (drift 58529.0 m)
--   [DCS died 0.8s later]
--
-- Two findings, both fatal to the approach:
--
--  1. The target was ~40 km from the camera. Writing that pose asks DCS to move its viewpoint
--     40 km between two frames, which makes the engine stream a whole new terrain region on the
--     spot. That is what killed it.
--  2. It would not have worked even without the crash. The read-back one frame later showed the
--     camera back where DCS wanted it, 58 km from the pose we set -- the view controller simply
--     reverts an outside write. Re-asserting every frame does not win that fight; it just loses
--     it 150 times a second.
--
-- So the hook no longer moves the camera at all. It still REPORTS what it can see, which is what
-- makes the deck's view choice honest -- and no report is worth crashing the sim for.
local function snap_hold()
    local t = find_unit(snap.uname)
    if not t then
        snap.misses = snap.misses + 1
        if snap.misses > SNAP_MISS_LIMIT then
            snap.on = false
            send("SNAPOFF reason=lost")
        end
        return
    end
    if snap.frames == 0 then
        snap.frames = 1
        say("snap: %s is present (id %s) -- reporting only; the camera is left to DCS",
            tostring(snap.uname), tostring(t.id))
    end
end

local function snap_stop(reason)
    if not snap.on then return end
    snap.on, snap.uname, snap.wrote = false, nil, nil
    snap.misses, snap.frames = 0, 0
    send("SNAPOFF reason=" .. tostring(reason or "released"))
end

-- =====================================================================================
-- commands
-- =====================================================================================
local function do_restart()
    -- Flight-confirmed: this restarts a TRACK from the beginning, landing on the briefing
    -- screen with the sim paused. That pause is not a nuisance -- it is exactly what we
    -- want, because it means the seek starts from a known standstill at model time zero.
    if type(DCS.restartMission) ~= "function" then
        say("restart: DCS.restartMission missing")
        send("ERR restart unavailable")
        return false
    end
    local ok = pcall(function() DCS.restartMission() end)
    -- Say whether a stop is still armed. This one line is what would have shown, in the
    -- first dcs.log after the bug, that the target was being wiped by the restart.
    say("restart: %s (armed target: %s)", ok and "issued" or "FAILED",
        seek.armed and string.format("%.2f", seek.target or -1) or "none")
    return ok
end

-- Should an ARMSTOP start watching immediately, or wait for the track to reload?
--
-- Immediately only when the target is genuinely AHEAD of the playhead. A target behind us
-- means a rewind is on its way, and arming now makes the arrival check fire on this very
-- frame -- which is precisely what broke every rewind: `194 >= 140` counted as arriving,
-- paused the sim, disarmed, and left the restart with nothing watching.
--
-- The 0.5s margin keeps a target we are sitting exactly on from arming and instantly firing.
local function should_arm_now(target, now)
    if type(now) ~= "number" then return true end   -- no clock: nothing to be wrong about
    return target > now + 0.5
end

local function handle(line)
    line = tostring(line):gsub("%s+$", "")

    if line == "PING" then
        send("PONG")

    elseif line == "PAUSE" then
        pcall(function() DCS.setPause(true) end)

    elseif line == "RESUME" then
        -- Also the briefing-screen dismissal. DCS's own Esc handler (GameGUI.lua
        -- onSimulationEsc) hides BriefingDialog by calling exactly this, so a restart
        -- followed by RESUME walks straight past the FLY button with no click.
        pcall(function() DCS.setPause(false) end)

    elseif line == "RESTART" then
        -- DOES NOT TOUCH THE ARMED TARGET, and that is the whole point.
        --
        -- It used to clear seek.active/armed/target here, which silently destroyed every
        -- rewind: the deck arms a stop and then restarts, in that order, so RESTART wiped
        -- the target a few milliseconds after it was set. Nothing was left watching, and
        -- the replay sailed straight past the mark every time.
        --
        -- No command may silently undo another. DISARM is the one and only way to cancel a
        -- pending stop, so the order the deck sends things in cannot matter.
        --
        -- Record that THIS seek is entitled to cross a mission load, so onMissionLoadEnd can
        -- tell a rewind waiting for its own restart from a forward seek that has simply been
        -- orphaned by a pass ending. Judging that by `seek.pending` alone would drop a genuine
        -- rewind whenever the clock read failed at arm time and it was stamped armed instead.
        seek.restarting = seek.active or false
        do_restart()

    elseif line:sub(1, 8) == "ARMSTOP " then
        -- The precision half of a seek. Deck says where; we watch every frame and stop
        -- there. Survives the mission reload because `seek` is not per-mission state.
        local t = tonumber(line:sub(9))
        if t then
            local okn, now = pcall(function() return DCS.getModelTime() end)
            local ahead = should_arm_now(t, okn and now or nil)

            seek.target  = t
            seek.active  = true
            seek.armed   = ahead
            seek.pending = not ahead
            seek.loads      = 0     -- mission loads this seek has survived; see onMissionLoadEnd
            seek.restarting = false  -- set true only if a RESTART follows, entitling it to one

            -- Polling stops for the duration of a seek, so whenever it resumes the world will
            -- have moved on wholesale. Mark the baseline stale NOW: the flag outlives the seek
            -- and is consumed by the first poll after it, whether that seek ended at its target,
            -- at a DISARM, or in a restart. Without this the arrival poll invents a kill for
            -- every unit that is not in view at the destination.
            world.rebase = true
            snap_stop("seek")      -- a new seek owns the view; do not fight the F10 map

            say("armstop: target %.2f, now %s -> %s", t, tostring(now),
                ahead and "armed" or "pending until the track reloads")
            send(string.format("ARMED %.3f", t))
        end

    elseif line == "DISARM" then
        seek.active, seek.armed, seek.target, seek.pending = false, false, nil, false
        send("DISARMED")

    elseif line:sub(1, 5) == "SNAP " then
        -- v1.4.0 groundwork. The deck sends this on arrival when the event names a unit. For
        -- now it MEASURES rather than moves: report what the sim can see, and run the one-shot
        -- camera capability probe. Building the follow-cam on top of this is the next step, and
        -- it will be built on these log lines instead of on an assumption.
        local u = clean_token(line:sub(6))     -- same normalisation as obj_unitname / emit_poi
        cam.unit = (#u > 0) and u or nil
        pcall(cam_report_world, cam.unit)

        -- Start the follow. F2 and F6 are only keystrokes: they cannot be pointed at a NAMED
        -- unit, which is why jumping to a kill landed on the player's own aircraft whenever the
        -- weapon view had nothing to show. This can.
        if cam.unit then
            snap.on, snap.uname = true, cam.unit
            snap.misses, snap.frames, snap.wrote = 0, 0, nil
            say("snap: asked to follow %s", tostring(cam.unit))
        else
            snap_stop("nounit")
        end

    elseif line == "UNSNAP" then
        -- Nothing holds the camera yet; accepted so the deck's release path is never an error.
        -- Commands are drained BEFORE the probe steps, so an UNSNAP can land between the probe's
        -- write and its restore. Clearing cam.unit alone would freeze it there -- 250 m up and
        -- rolled -- because the driver is gated on cam.unit. Put the camera back first.
        cam.unit = nil
        snap_stop("released")
        cam.phase, cam.base, cam.want = 0, nil, nil
        send("SNAPOFF")

    elseif line == "REWIND" then
        -- Alias for RESTART, kept because older decks send it.
        do_restart()
    end
end

-- =====================================================================================
-- per-frame
-- =====================================================================================
local function measure(m, r)
    if not (st.m_prev and st.r_prev) then return end
    local dr = r - st.r_prev
    -- Guard the divide. A zero or backwards real-time delta is a worthless sample, not a
    -- stopped sim -- discard rather than publish 0x or infinity.
    if dr <= 0.05 then return end

    local ratio = (m - st.m_prev) / dr
    if ratio < STOPPED then
        st.speed, st.pending = 0, nil
        return
    end

    -- Believe a reading when two consecutive samples AGREE WITH EACH OTHER -- never when
    -- it matches a list of expected values. An earlier version gated on membership of a
    -- speed ladder that stopped at 128, and silently discarded everything above it; the
    -- probe reported a 1x ceiling while SYNTAX watched 1600x on screen.
    local prev = st.pending
    if prev and math.abs(ratio - prev) <= prev * 0.15 then
        st.speed = (ratio + prev) / 2
    end
    st.pending = ratio
end

local function pump()
    if not st.in_mission then return end
    if not sock.tried then open_sockets() end
    if sock.dead then return end

    if sock.rx then
        -- Drain, but never let a flooded socket own the frame.
        for _ = 1, 8 do
            local ok, data = pcall(function() return sock.rx:receive() end)
            if not ok or not data then break end
            pcall(handle, data)
        end
    end

    local okm, m = pcall(function() return DCS.getModelTime() end)
    if not (okm and type(m) == "number") then return end

    -- Latch the floor on the first reading of a new mission, and keep latching downward:
    -- a restart can deliver its first frame slightly after t0, and taking the lowest value
    -- we ever see costs nothing and cannot drift high.
    if st.start_time == nil or m < st.start_time then st.start_time = m end

    -- ARRIVAL CHECK RUNS EVERY FRAME, BEFORE ANY THROTTLING BELOW. This is the whole
    -- reason the hook owns the stop instead of the deck: at 24x a frame is 0.4s of model
    -- time, so checking here costs at most one frame of overshoot, where a UDP round trip
    -- would cost several seconds.
    if seek.armed and seek.target and m >= seek.target then
        seek.armed, seek.active, seek.pending = false, false, false
        pcall(function() DCS.setPause(true) end)
        say("armstop: reached %.2f (target %.2f), paused", m, seek.target)
        send(string.format("ARRIVED %.3f", m))
    end

    local okr, r = pcall(function() return DCS.getRealTime() end)
    if okr and type(r) == "number" then
        -- Measure on a ~0.4s cadence (60 frames at SYNTAX's ~150 fps). Long enough for a
        -- meaningful ratio, short enough to track a human on the speed keys.
        st.frames = st.frames + 1
        if st.frames % 60 == 0 then
            measure(m, r)
            st.m_prev, st.r_prev = m, r
        end
    end

    -- Live world-watcher: real-time events straight from the sim (see the section above).
    -- Only during a replay, and not mid-seek -- a fast-forward would flood, and the deck is
    -- looking at the F10 map then anyway. isTrackPlaying is only asked once per poll interval.
    if st.frames % WORLD_POLL_FRAMES == 0 and not seek.active then
        local playing = select(2, pcall(function() return DCS.isTrackPlaying() end))
        if playing then pcall(poll_world, m) end
    end

    -- The camera probe, once a SNAP has asked for it. Runs on consecutive frames (write, then
    -- read back, then restore) because a read-back on the SAME frame would only echo our own
    -- write. The error is captured rather than swallowed: a silent dead probe is precisely the
    -- failure mode that cost this feature two test flights already.
    if cam.unit and not cam.ran then
        local ok, err = pcall(cam_probe_step)
        if not ok and not cam.threw then
            cam.threw, cam.ran = true, true
            say("CAMPROBE: threw (%s) -- probe abandoned, camera left alone", tostring(err))
        end
    end

    -- Hold the camera on the followed unit. EVERY frame, because DCS's own view controller
    -- writes the camera every frame too; a single write is simply replaced. Only once the probe
    -- has finished, so the two never fight over the same frames.
    if snap.on and cam.ran then
        local ok, err = pcall(snap_hold)
        if not ok and not snap.threw then
            snap.threw = true
            say("snap: hold threw (%s) -- released, camera left to DCS", tostring(err))
            snap_stop("error")
        end
    end

    -- Publish at ~10 Hz. The deck interpolates the clock between packets, so this is
    -- plenty for a smooth readout and keeps the menu state's per-frame cost near zero.
    if st.frames % 6 ~= 0 then return end
    local paused = select(2, pcall(function() return DCS.getPause() end))
    local track  = select(2, pcall(function() return DCS.isTrackPlaying() end))
    -- `mission` goes LAST. It is the only field whose value came from user data, so if the
    -- sanitising above ever lets something through, it corrupts nothing after it.
    send(string.format(
        "STATE t=%.3f speed=%.4f paused=%s track=%s seeking=%s target=%.3f start=%.3f mission=%s",
        m, st.speed or 0, tostring(paused), tostring(track),
        tostring(seek.active), seek.target or -1, st.start_time or m,
        st.mission or "unknown"))
end

-- =====================================================================================
-- briefing dismissal
-- =====================================================================================
-- Takes down the briefing screen that restartMission leaves up.
--
-- The dialog is created in the GUI Lua state (Scripts/UI/BriefingDialog.lua, driven from
-- MissionEditor/GameGUI.lua), which is NOT this state -- probe run 2 proved the hooks state
-- has no START_PARAMS, no mmw and no Gui.doQuit. net.dostring_in is the documented bridge
-- between states, but the name of the target state is not something we can look up, so this
-- tries the plausible ones and records which succeeded.
--
-- Everything is wrapped: this runs inside onMissionLoadEnd, where a throw would break the
-- menu and take the rest of the hook with it.
local briefing_state = nil   -- remembered once something works

local function dismiss_briefing()
    -- The direct call first. Harmless, and it may be enough on some builds.
    pcall(function() DCS.onShowDialog(false) end)

    if type(net) ~= "table" or type(net.dostring_in) ~= "function" then
        say("briefing: net.dostring_in unavailable -- cannot reach the GUI state")
        return
    end

    -- Hide the dialog AND clear the pause it was holding, mirroring what DCS's own Esc
    -- handler does in GameGUI.lua onSimulationEsc.
    local code = [[
        local ok, B = pcall(require, 'BriefingDialog')
        if ok and B and B.hide then B.hide() end
        if DCS and DCS.setPause then DCS.setPause(false) end
        return 'ok'
    ]]

    local candidates = briefing_state and { briefing_state } or { "gui", "mission", "server", "userinterface" }

    for _, state in ipairs(candidates) do
        local ok, res = pcall(function() return net.dostring_in(state, code) end)
        if ok and res then
            if briefing_state ~= state then
                briefing_state = state
                say("briefing: dismissed via net.dostring_in(%q) -> %s", state, tostring(res))
            end
            return
        end
    end

    say("briefing: no state accepted dostring_in; the FLY button may need a click")
end

-- =====================================================================================
-- mission fingerprint
-- =====================================================================================
-- A short, stable id for the mission being replayed, safe to put in a filename and in a
-- space-separated wire packet.
--
-- Built from the mission table rather than its name, because the name is always
-- "tempMission" during a replay. Counting groups is what separates two missions that share
-- a theatre and a start time -- a very common pair among training tracks flown on the same
-- map at the same hour.
local function fingerprint_mission()
    local ok, m = pcall(function() return DCS.getCurrentMission() end)
    if not ok or type(m) ~= "table" or type(m.mission) ~= "table" then
        return "unknown"
    end

    local mis = m.mission
    local theatre = tostring(mis.theatre or "?")
    local start   = tonumber(mis.start_time) or 0

    local date = ""
    if type(mis.date) == "table" then
        date = string.format("%04d%02d%02d",
            tonumber(mis.date.Year) or 0, tonumber(mis.date.Month) or 0,
            tonumber(mis.date.Day) or 0)
    end

    -- Walk the order of battle for a cheap structural signature. Guarded throughout: a
    -- malformed mission table must not throw in the menu state.
    local groups, units = 0, 0
    pcall(function()
        for _, coal in pairs(mis.coalition or {}) do
            for _, country in pairs(type(coal) == "table" and coal.country or {}) do
                for _, cat in ipairs({ "plane", "helicopter", "ship", "vehicle", "static" }) do
                    local t = type(country) == "table" and country[cat]
                    local gs = type(t) == "table" and t.group
                    if type(gs) == "table" then
                        for _, g in pairs(gs) do
                            groups = groups + 1
                            local us = type(g) == "table" and g.units
                            if type(us) == "table" then
                                for _ in pairs(us) do units = units + 1 end
                            end
                        end
                    end
                end
            end
        end
    end)

    local id = string.format("%s-%s-%d-g%d-u%d", theatre, date, start, groups, units)
    return (id:gsub("%s+", "_"):gsub("[^%w_%-%.]", ""))
end

-- =====================================================================================
-- event-source probe  (temporary)
-- =====================================================================================
-- Which callback actually carries a missile launch during a replay?
--
-- onDebriefingEvent was the obvious candidate -- it is declared in GameGUI.lua and it is
-- where Logs\debrief.log gets its entries, which we KNOW carry exactly what a timeline
-- marker needs (type="shot", t=88.16, weapon="AIM-120C"). It produced nothing at all on
-- SYNTAX's Persian Gulf replay, so either it does not reach user hooks or it only fires at
-- mission end.
--
-- Two names have already cost a sortie each on this project by being guessed at. So instead
-- of trying a third, this logs EVERY event callback DCS offers, with its arguments, and one
-- replay names the right one for good.
--
-- Capped hard: a busy multiplayer track fires thousands of these and dcs.log is not a
-- flight recorder.
local seen_events = {}
local event_lines = 0
local EVENT_LOG_CAP = 120

local function probe_event(source, ...)
    local n = select("#", ...)
    local bits = {}
    for i = 1, math.min(n, 8) do
        local v = select(i, ...)
        if type(v) == "table" then
            -- Tables are the interesting case: that is where a debriefing event's fields
            -- live. Flatten one level so the shape is visible.
            local fields = {}
            local okf = pcall(function()
                for k, val in pairs(v) do
                    if type(val) ~= "table" and type(val) ~= "function" then
                        fields[#fields + 1] = tostring(k) .. "=" .. tostring(val)
                    end
                    if #fields >= 10 then break end
                end
            end)
            bits[#bits + 1] = "{" .. (okf and table.concat(fields, " ") or "?") .. "}"
        else
            bits[#bits + 1] = tostring(v)
        end
    end

    -- Always log the FIRST sighting of each source, however full the log is: knowing a
    -- callback fires at all is the answer we came for.
    local first = not seen_events[source]
    seen_events[source] = true

    if first or event_lines < EVENT_LOG_CAP then
        event_lines = event_lines + 1
        say("EVENTPROBE %s(%d): %s", source, n, table.concat(bits, " | "))
        if event_lines == EVENT_LOG_CAP then
            say("EVENTPROBE capped at %d lines; sources seen so far are above", EVENT_LOG_CAP)
        end
    end
end

-- =====================================================================================
-- points of interest
-- =====================================================================================
-- Captures the events a content creator actually wants to find again -- missile launches,
-- hits, kills -- and streams them to the deck with their model time, so the timeline fills
-- itself in as the replay runs.
--
-- WHY NOT TACVIEW. DCS already has this. Every entry that ends up in Logs\debrief.log
-- carries exactly what a timeline marker needs:
--
--     type = "shot", t = 88.16, weapon = "AIM-120C",
--     initiatorPilotName = "SYNTAX", initiator_unit_type = "F/A-18C"
--
-- onDebriefingEvent is the LIVE feed those entries come from (declared in
-- MissionEditor/GameGUI.lua). Reading it here means no export step, no .acmi parsing, no
-- Tacview version drift, and it works on every track already on disk. It also fires during
-- a fast-forward, so the first seek through a track populates the whole timeline for free.
--
-- Tacview import stays worth doing later as an OPTIONAL extra for people who record it.
-- It should not be the primary path when the sim will simply tell us.

-- Only the events worth a marker. A track generates hundreds of "group change option"
-- entries and every one would be noise on a timeline the width of a window.
local POI_TYPES = {
    ["shot"]         = "shot",
    ["hit"]          = "hit",
    ["kill"]         = "kill",
    ["dead"]         = "kill",
    ["crash"]        = "crash",
    ["eject"]        = "eject",
    ["pilot dead"]   = "kill",
    ["takeoff"]      = "takeoff",
    ["land"]         = "landing",
    ["landing"]      = "landing",
    ["refueling"]    = "refuel",
    ["mission end"]  = "end",
}

local function poi_label(e)
    -- Prefer the weapon, then the shooter, then the unit. "AIM-120C" says more on a
    -- timeline than "shot" does.
    local bits = {}
    if type(e.weapon) == "string" and #e.weapon > 0 then bits[#bits + 1] = e.weapon end
    if type(e.initiatorPilotName) == "string" and #e.initiatorPilotName > 0 then
        bits[#bits + 1] = e.initiatorPilotName
    elseif type(e.initiator_unit_type) == "string" and #e.initiator_unit_type > 0 then
        bits[#bits + 1] = e.initiator_unit_type
    end
    local label = table.concat(bits, " ")
    -- The wire format is space-separated key=value, and this is the only free-text field.
    return (label:gsub("%s+", "_"):gsub("[^%w_%-%.]", ""))
end


-- onGameEvent / onGameBdaEvent style: an event NAME plus loose arguments, with no timestamp
-- of its own. The model time is simply "now", which is correct -- these fire as the event
-- happens, and during a replay that is the moment on the timeline we want to mark.
local GAME_EVENT_TYPES = {
    kill = "kill", self_kill = "kill", crash = "crash", eject = "eject",
    pilot_death = "kill", takeoff = "takeoff", landing = "landing",
    friendly_fire = "kill", shot = "shot", hit = "hit",
}

local function on_game_event(name, a1, a2, a3)
    local kind = GAME_EVENT_TYPES[tostring(name or "")]
    if not kind then return end

    local okt, t = pcall(function() return DCS.getModelTime() end)
    if not (okt and type(t) == "number") then return end

    -- Best-effort label from whatever the arguments happen to be. The probe above will show
    -- what they actually contain, and this can be sharpened once we know.
    local label = ""
    for _, v in ipairs({ a1, a2, a3 }) do
        if type(v) == "string" and #v > 0 and #v < 40 then label = v break end
    end
    -- Through emit_poi rather than a hand-built string: it owns the wire format (including the
    -- unit= field) and the empty-label fallback. Building the line here meant this producer
    -- silently drifted out of the format the moment a field was added, and could emit a bare
    -- "label=" whenever none of a1/a2/a3 was a usable string.
    emit_poi(t, kind, 0, clean(label), nil)
end

local function on_debriefing_event(e)
    if type(e) ~= "table" then return end

    local kind = POI_TYPES[tostring(e.type or "")]
    if not kind then return end

    local t = tonumber(e.t)
    if not t then return end

    -- side lets the deck colour a marker by coalition later; harmless if it never does.
    local side = tonumber(e.initiator_coalition) or 0

    emit_poi(t, kind, side, poi_label(e), nil)
end

-- =====================================================================================
-- callbacks
-- =====================================================================================
local callbacks = {}

function callbacks.onMissionLoadEnd()
    st.in_mission = true
    st.frames  = 0
    st.m_prev, st.r_prev, st.speed, st.pending = nil, nil, nil, nil
    -- Re-latch the floor for the new mission. NOT preserved across a rewind restart: the
    -- track begins where it begins, and that is exactly the value we want back.
    st.start_time = nil

    -- THE WORLD-WATCHER MUST FORGET THE PREVIOUS PASS. This reset was missing, and it is half
    -- of the phantom-kill bug described at WORLD_MAX_GAP: `world` is file-scope state, so
    -- without this the first poll of a NEW pass diffed against the last snapshot of the OLD
    -- one and reported every unit not carried over as a death.
    --
    -- The diagnostic latches are cleared too. They are one-shot per run, so after pass 1 they
    -- stayed true and the object dumps -- the very lines that tell us what the sim can see --
    -- never printed again, exactly when a restarted pass most needed explaining.
    world.prev, world.last_t, world.gone = nil, nil, {}
    -- A new pass gets a clean slate: everything is alive again and nothing has been announced.
    world.dead, world.shot = {}, {}
    world.polls, world.logged, world.dump_n, world.newdump = 0, 0, 0, 0
    world.rebased, world.returns = 0, 0
    world.dumped, world.warned, world.rebase = false, false, false

    -- The camera probe advances one frame at a time. If a pass ended between its write and its
    -- restore, do not resume half-way through it against a pose from a mission that is gone.
    cam.phase, cam.base, cam.want = 0, nil, nil
    snap_stop("reload")     -- those coordinates belong to a pass that is gone

    -- GIVE A SEEK A LIFETIME. `seek` deliberately outlives a mission so a rewind can survive the
    -- restart it performs -- but nothing ever cleared `seek.active` if that seek then died: a
    -- closed deck, a dropped UDP datagram, or a target past the end of the track all strand it
    -- true forever. Because polling is gated on `not seek.active`, a stranded flag switches the
    -- world-watcher off for the REST OF THE DCS SESSION, silently, across every later track --
    -- a worse failure than the phantom kills this all started with.
    --
    -- A REWIND legitimately crosses exactly one load: the restart it asked for. A FORWARD seek
    -- crosses none -- it just runs the clock on -- so one still active at a load has been
    -- orphaned by a pass ending and gets no grace. `seek.restarting` is set by the RESTART
    -- command itself, which is the only reliable statement of intent: `seek.pending` would
    -- misjudge a rewind whose clock read failed at arm time.
    if seek.active then
        seek.loads = (seek.loads or 0) + 1
        local entitled = (seek.restarting or seek.pending) and seek.loads <= 1
        if not entitled then
            say("seek: dropping stale target %.2f (restarting=%s pending=%s loads=%d) -- it "
                .. "belongs to a pass that is over", seek.target or -1,
                tostring(seek.restarting), tostring(seek.pending), seek.loads)
            seek.active, seek.armed, seek.target, seek.pending = false, false, nil, false
            seek.loads, seek.restarting = 0, false
            world.rebase = true
            send("DISARMED")
        else
            seek.restarting = false     -- the one load it was owed has now been spent
        end
    end

    -- WHICH TRACK IS THIS? Fingerprint the mission, do not ask for its name.
    --
    -- DCS.getMissionName() is useless here: DCS copies every track's mission to
    -- tempMission.miz before playing it, so the name comes back as "tempMission" for EVERY
    -- replay. SYNTAX watched his deck label a fresh track "tempMission" and hand it the
    -- previous track's marks, because every track shared one key.
    --
    -- getCurrentMission() returns the real mission table (an earlier overlay hook of mine reads
    -- routes from it the same way). Theatre, start time, date and the shape of the order of
    -- battle together identify a mission well enough to key marks on, and all of them
    -- survive the copy to tempMission.
    local okf, fp = pcall(fingerprint_mission)
    st.mission = (okf and type(fp) == "string" and #fp > 0) and fp or "unknown"
    say("mission fingerprint: %s", st.mission)

    if not sock.tried then pcall(open_sockets) end

    local trk = select(2, pcall(function() return DCS.isTrackPlaying() end))
    say("mission loaded: %s (track=%s)", st.mission, tostring(trk))
    send(string.format("LOADED id=%s track=%s", st.mission, tostring(trk)))

    -- A rewind in progress reaches here on the far side of restartMission(). Take the
    -- briefing screen down ourselves so the pilot never sees the FLY button during a
    -- rewind -- the whole point is that it is one button, not a restart plus a click.
    -- The reload has happened, so a pending target is now safe to watch for: the clock has
    -- gone back to the start of the track and can only approach the target from below.
    if seek.pending and seek.target then
        seek.pending, seek.armed = false, true
        say("rewind: arming for %.2f now the track has reloaded", seek.target)
    end

    if seek.active and seek.armed then
        -- CLEAR THE BRIEFING DIALOG, not just the pause.
        --
        -- restartMission lands on the briefing screen with the FLY button. setPause(false)
        -- starts the clock, but the dialog stays up and owns the keyboard, so every
        -- accelerate keystroke goes to the dialog instead of the sim. SYNTAX had to click FLY
        -- by hand on every rewind, and the seek then ran at 1x -- while FORWARD seeks, which
        -- never restart and so never see a briefing, worked perfectly.
        --
        -- DCS.onShowDialog(false) alone did not do it, so this tries the real thing:
        -- BriefingDialog lives in the GUI Lua state, and net.dostring_in reaches across.
        -- The state name is not documented anywhere we can check, so each candidate is
        -- tried and the winner is logged -- one sortie names it for good.
        dismiss_briefing()
        pcall(function() DCS.setViewPause(false) end)
        pcall(function() DCS.setPause(false) end)
        say("rewind: resumed after restart (briefing dismissal attempted), running to %.2f",
            seek.target or -1)
    elseif seek.target then
        -- Should be unreachable. If it ever appears, an armed stop was lost across the
        -- reload -- exactly the failure that made every rewind sail past its mark.
        say("rewind: WARNING target %.2f survived but the arm did not", seek.target)
    end
end

function callbacks.onSimulationStop()
    st.in_mission = false

    -- The probe displaces the camera on one frame and puts it back on the next, and pump() stops
    -- running the moment st.in_mission goes false. If the pass ends inside that window this is
    -- the last chance to restore the view it borrowed. An interrupted probe is ABANDONED, never
    -- resumed: waking at half-sequence in a later mission would compare a fresh pose against a
    -- pose from a mission that no longer exists, then write it.
    -- Nothing to restore: this hook does not move the camera. See snap_hold.
    cam.ran, cam.phase, cam.base, cam.want = true, 0, nil, nil

    send("STOPPED")
end

callbacks.onMissionStop = callbacks.onSimulationStop

-- The live points-of-interest feed. Wrapped like everything else here: a malformed event
-- must not throw in the menu state.
function callbacks.onDebriefingEvent(e)
    pcall(probe_event, "onDebriefingEvent", e)
    pcall(on_debriefing_event, e)
end

-- The other two event feeds DCS declares. onGameEvent is known to fire (GameGUI.lua drives
-- the chat log from it); onGameBdaEvent feeds the battle-damage panel and may well be where
-- weapon releases actually live.
function callbacks.onGameEvent(name, a1, a2, a3, a4, a5, a6, a7)
    pcall(probe_event, "onGameEvent:" .. tostring(name), a1, a2, a3, a4, a5, a6, a7)
    pcall(on_game_event, name, a1, a2, a3, a4, a5, a6, a7)
end

function callbacks.onGameBdaEvent(name, a1, a2, a3, a4, a5, a6, a7)
    pcall(probe_event, "onGameBdaEvent:" .. tostring(name), a1, a2, a3, a4, a5, a6, a7)
    pcall(on_game_event, name, a1, a2, a3, a4, a5, a6, a7)
end

function callbacks.onSimulationFrame()
    pcall(pump)
end

DCS.setUserCallbacks(callbacks)
log.write(TAG, log.INFO, "Replay Deck agent installed")

-- TEST SEAM, as above: DCS never sets this flag, so this table is never built in the sim and no
-- internal is reachable from anywhere. test/kills_test.lua sets it before loading this file and
-- then drives the genuine poll_world through the phantom-kill scenarios taken from SYNTAX's own
-- logs. The kill detector is subtle enough -- and a test flight expensive enough -- that it is
-- worth exercising the real thing.
if _G.REPLAYDECK_TEST then
    _G.REPLAYDECK_TEST = { poll_world = poll_world, world = world, seek = seek }
end
