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
    if not sock.tx then return end
    pcall(function() sock.tx:send(msg) end)
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

            say("armstop: target %.2f, now %s -> %s", t, tostring(now),
                ahead and "armed" or "pending until the track reloads")
            send(string.format("ARMED %.3f", t))
        end

    elseif line == "DISARM" then
        seek.active, seek.armed, seek.target, seek.pending = false, false, nil, false
        send("DISARMED")

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
    label = label:gsub("%s+", "_"):gsub("[^%w_%-%.]", "")

    send(string.format("POI t=%.3f kind=%s side=0 label=%s", t, kind, label))
end

local function on_debriefing_event(e)
    if type(e) ~= "table" then return end

    local kind = POI_TYPES[tostring(e.type or "")]
    if not kind then return end

    local t = tonumber(e.t)
    if not t then return end

    -- side lets the deck colour a marker by coalition later; harmless if it never does.
    local side = tonumber(e.initiator_coalition) or 0

    send(string.format("POI t=%.3f kind=%s side=%d label=%s",
        t, kind, side, poi_label(e)))
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
