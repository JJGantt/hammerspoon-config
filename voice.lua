-- Voice Transcription (simplified)
-- Double-tap Option : start recording (only in a terminal while OPTION_TERMINAL_ONLY is true)
-- Release Option    : stop + transcribe + paste + space
-- Enter             : stop + transcribe + paste + send (Enter)
-- Escape            : cancel
-- Adaptive: <15s local whisper, >=15s OpenAI Whisper API
-- Cmd+Opt+V         : paste last transcription
--
-- Double-tap Control : record a command for the hub (the orchestrator), the same path as the watch's
--                      Hub control: the clip goes to the hub's /api/voice-command, which transcribes it
--                      and queues it as source `mac-cmd`. Tap Control again (or Enter) to send, Escape
--                      to cancel. The reply lands in the hub thread, not in a window here. While it
--                      records it streams to the hub in acknowledged chunks, and stops itself loudly
--                      the moment they are not acknowledged (see "A HUB COMMAND STREAMS" below).

local SOX = "/opt/homebrew/bin/sox"
local WHISPER = os.getenv("HOME") .. "/whisper.cpp/build/bin/whisper-cli"
local WHISPER_MODEL_SMALL  = os.getenv("HOME") .. "/whisper.cpp/models/ggml-small.en.bin"
local WHISPER_MODEL_MEDIUM = os.getenv("HOME") .. "/whisper.cpp/models/ggml-medium.en.bin"
local OPENAI_KEY_FILE = os.getenv("HOME") .. "/.config/openai-api-key"
local SUBS_FILE = os.getenv("HOME") .. "/pi-data/voice_subs.json"
local WAV = "/tmp/hs-voice.wav"
local MP3 = "/tmp/hs-voice.mp3"
local LAST_TXT = "/tmp/hs-voice-last.txt"
local RECORDING_DIR = os.getenv("HOME") .. "/voice-recordings"
local MAX_RECORDINGS = 20
local DOUBLE_TAP = 0.35
local MIN_RECORD_SECS = 0.5
local ADAPTIVE_THRESHOLD = 9999 -- set back to 15 to re-enable OpenAI API tier
local STUCK_TIMEOUT = 120
local TMUX = "/opt/homebrew/bin/tmux"
local AI_TERMINAL_TAB_FILE = "/tmp/ai-terminal-active-tab"
local AI_TERMINAL_BUNDLE = "com.github.Electron"
-- Double-tap Option works only while a terminal is frontmost when true; everywhere when false.
local OPTION_TERMINAL_ONLY = true
local TERMINAL_BUNDLES = {
    ["com.apple.Terminal"] = true,
    ["com.googlecode.iterm2"] = true,
    ["com.mitchellh.ghostty"] = true,
    ["dev.warp.Warp-Stable"] = true,
    [AI_TERMINAL_BUNDLE] = true,
}
local HUB_URL = "https://jared-status-hub.fly.dev"
local FALLBACK_URL = "https://felyggqjjhltwokdfhop.supabase.co/functions/v1/voice-fallback"
local OPS = os.getenv("HOME") .. "/repos/health/responder/bin/ops"
local OPS_SERVICE = "hammerspoon-voice"
local HUB_ENV = os.getenv("HOME") .. "/repos/status-hub/.env"   -- HUB_TOKEN=

-- A recording ends only when you end it: Enter to send, Option-release to paste, Escape to cancel.
-- Silence never stops it, however long the pause.
local LOG_FILE = os.getenv("HOME") .. "/Library/Logs/hs-voice.log"
local hslog = hs.logger.new("voice", "info")

local function log(msg)
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = ts .. "  " .. msg
    hslog.i(line)
    local f = io.open(LOG_FILE, "a")
    if f then f:write(line .. "\n") f:close() end
end

-- A failure goes to the ops responder (health/responder), which opens an incident and investigates.
local opsTasks = {}
local function ops(args)
    local t
    t = hs.task.new(OPS, function(code, out, err)
        opsTasks[t] = nil
        if code ~= 0 then log("WARN: ops " .. args[1] .. " not delivered: " .. ((err ~= "" and err) or out or ""):sub(1, 200)) end
    end, args)
    opsTasks[t] = true
    t:start()
end

local function report(msg, context)
    log("ERROR: " .. msg .. (context and context ~= "" and (" | " .. context) or ""))
    ops({"error", OPS_SERVICE, msg, (context and context ~= "" and (context .. "\n") or "") .. "log: " .. LOG_FILE})
end

-- A failure this file heals by itself is counted, not raised: the responder opens an incident only when
-- its watch rate is crossed.
local function occur(msg)
    log("OCCURRENCE: " .. msg)
    ops({"occurrence", OPS_SERVICE, msg})
end

-- macOS disables an event tap that stalls. Restarting it saves the key; a restart that does not take is an error.
local function ensureTap(tap, name)
    if tap:isEnabled() then return end
    tap:start()
    if tap:isEnabled() then occur(name .. " was disabled; restarted")
    else report(name .. " was disabled and did not restart") end
end

local function applySubs(text)
    local f = io.open(SUBS_FILE, "r")
    if not f then return text end
    local ok, data = pcall(function() return hs.json.decode(f:read("*a")) end)
    f:close()
    if not ok or not data or not data.subs then return text end
    for _, s in ipairs(data.subs) do
        text = text:gsub(s.pattern, s.replacement)
    end
    return text
end

local lastTranscription = nil
local mode = nil       -- nil | "recording" | "transcribing"
local modeChangedAt = 0
local lastOptUp = 0
local sendAfter = false
local targetWin = nil
local targetAITab = nil  -- ai-terminal tab ID
local targetPane = nil   -- tmux pane target
local toHub = false      -- this recording goes to the hub (double-tap Control), not into a window
local hubTasks = {}      -- in-flight curl tasks, held so the GC cannot collect them
local recordingStartedAt = 0

local soxTask = nil

-- Always record from the Mac's own microphone, never the default input. Connected AirPods become the
-- default, and opening their mic drops the whole Bluetooth link into the hands-free profile: narrowband
-- call-quality audio for Whisper, a second of switching that clips the first words, and degraded
-- playback for as long as the mic is open. Pinned here, the AirPods stay on output only.
local function soxArgs()
    for _, d in ipairs(hs.audiodevice.allInputDevices()) do
        if d:transportType() == "Built-in" then
            return {"-q", "-t", "coreaudio", d:name(), "-r", "16000", "-c", "1", "-b", "16", WAV}
        end
    end
    log("WARN: no built-in microphone found — recording from the default input")
    return {"-q", "-d", "-r", "16000", "-c", "1", "-b", "16", WAV}
end
local whisperTask = nil
local activeTimers = {}
local stopAndTranscribe  -- forward declaration: assigned further down, so the local exists for
                         -- callers above it (Lua locals aren't visible before declaration)
local streamStart, streamAbandon  -- forward declarations: the hub command's stream, further down

local function safeTimer(delay, fn)
    local t = hs.timer.doAfter(delay, function() fn() end)
    activeTimers[#activeTimers + 1] = t
    return t
end

local function cleanTimers()
    local live = {}
    for _, t in ipairs(activeTimers) do
        if t:running() then live[#live + 1] = t end
    end
    activeTimers = live
end

local function setMode(newMode)
    log(string.format("mode: %s -> %s", tostring(mode), tostring(newMode)))
    mode = newMode
    modeChangedAt = hs.timer.secondsSinceEpoch()
    -- While push-to-talk is actively recording, mute the always-on voice listeners (wake-word AND
    -- wake-free) so they don't fight for the mic or execute what you're dictating to Claude. SIGUSR1 =
    -- pause + release the mic; SIGUSR2 = resume. SYNCHRONOUS hs.execute — an async hs.task here got
    -- garbage-collected before it fired, silently breaking the mute (the ESP then captured the dictation).
    local sig = (newMode == "recording") and "-USR1" or "-USR2"
    local r1 = hs.execute("/usr/bin/pkill " .. sig .. " -f listener.py; /usr/bin/pkill " .. sig .. " -f wakefree.py; echo done")
    log("ptt mute (" .. sig .. ") -> " .. tostring(r1))
end

local function asyncPkill(pattern)
    hs.task.new("/usr/bin/pkill", nil, {"-9", "-f", pattern}):start()
end

local function killSox()
    local pid = soxTask and soxTask:pid()
    if soxTask then soxTask:terminate() soxTask = nil end
    -- Clean up orphans from prior reloads via pattern, but only on startup.
    -- For normal stops, SIGTERM the tracked PID then SIGKILL it by PID after 0.5s.
    if pid then
        hs.timer.doAfter(0.5, function()
            hs.task.new("/bin/kill", nil, {"-9", tostring(pid)}):start()
        end)
    end
end

-- Get tmux pane for a Terminal.app window
local function getTerminalTTY(win)
    if not win then return nil end
    local app = win:application()
    if not app or app:bundleID() ~= "com.apple.Terminal" then return nil end
    local winId = win:id()
    local ok, tty = hs.osascript.applescript(
        string.format('tell application "Terminal" to return tty of selected tab of window id %d', winId)
    )
    if ok and tty and tty:match("^/dev/") then return tty end
    return nil
end

local function getTmuxPane(tty)
    if not tty then return nil end
    local output, status = hs.execute(TMUX .. " list-clients -F '#{client_tty} #{client_session}' 2>/dev/null")
    if not status or not output or output == "" then return nil end
    for line in output:gmatch("[^\n]+") do
        local clientTTY, session = line:match("^(/dev/%S+)%s+(%S+)$")
        if clientTTY == tty then return session end
    end
    return nil
end

local function reset()
    streamAbandon()
    killSox()
    if whisperTask then whisperTask:terminate() whisperTask = nil end
    for t in pairs(hubTasks) do t:terminate() end
    hubTasks = {}
    toHub = false
    asyncPkill("whisper-cli.*hs-voice")
    targetWin = nil
    targetAITab = nil
    targetPane = nil
    cleanTimers()
    setMode(nil)
end

local function ding(name)
    local s = hs.sound.getByName(name)
    if s then s:play() end
end

local function startRecording(forHub)
    log("startRecording" .. (forHub and " (hub)" or ""))
    reset()
    toHub = forHub == true
    targetWin = not toHub and hs.window.focusedWindow() or nil

    -- Check if ai-terminal is focused
    local focusedApp = targetWin and targetWin:application()
    local focusedBundle = focusedApp and focusedApp:bundleID() or ""
    if toHub then
        -- no target: the command goes to the hub
    elseif focusedBundle == AI_TERMINAL_BUNDLE then
        local f = io.open(AI_TERMINAL_TAB_FILE, "r")
        if f then
            targetAITab = f:read("*a"):match("^%s*(.-)%s*$")
            f:close()
            log("ai-terminal tab=" .. tostring(targetAITab))
        end
    else
        local tty = getTerminalTTY(targetWin)
        targetPane = getTmuxPane(tty)
    end

    os.remove(WAV)
    recordingStartedAt = hs.timer.secondsSinceEpoch()
    setMode("recording")
    ding(toHub and "Hero" or "Glass")
    if toHub then streamStart() end
    soxTask = hs.task.new(SOX, function(code)
        if mode == "recording" then
            report("sox exited mid-recording; audio after this point is lost", "code " .. tostring(code))
            hs.alert.show("⚠️ Recording device dropped")
        end
    end, soxArgs())
    soxTask:start()
end

local function saveRecording()
    hs.fs.mkdir(RECORDING_DIR)
    local dest = RECORDING_DIR .. "/" .. os.date("%Y-%m-%d_%H%M%S") .. ".wav"
    local _, ok = hs.execute(string.format("/bin/cp '%s' '%s'", WAV, dest))
    if not ok then report("could not save recording", WAV .. " -> " .. dest) return nil end
    -- prune oldest beyond MAX_RECORDINGS
    local files = {}
    for f in hs.fs.dir(RECORDING_DIR) do
        if f:match("%.wav$") then files[#files + 1] = f end
    end
    table.sort(files)
    while #files > MAX_RECORDINGS do
        os.remove(RECORDING_DIR .. "/" .. files[1])
        table.remove(files, 1)
    end
    log("saved recording: " .. dest .. " (" .. #files .. " kept)")
    return dest
end

local function hubToken()
    local f = io.open(HUB_ENV, "r")
    if not f then return nil end
    local tok
    for line in f:lines() do
        local v = line:match("^HUB_TOKEN=(.*)$")
        if v then tok = v:match("^%s*(.-)%s*$") end
    end
    f:close()
    return tok
end

-- curl reads the token from a config file (mkstemp: 0600) rather than argv, so `ps` never shows it.
local function curlConfig(url, token)
    local path = os.tmpname()
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(string.format('url = "%s"\nheader = "X-Hub-Token: %s"\n', url, token))
    f:close()
    return path
end

-- Run curl; done(httpCode, body, curlExit, stderr). The status rides the last line of stdout (-w).
-- `tasks` is the set that holds the task (hubTasks unless given), which is the set reset() kills.
local function curlPost(url, token, clip, contentType, maxTime, done, tasks)
    tasks = tasks or hubTasks
    local cfg = curlConfig(url, token)
    if not cfg then return done(0, "", -1, "could not write curl config") end
    local t
    t = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
        os.remove(cfg)
        tasks[t] = nil
        local body, status = (stdout or ""):match("^(.*)\n(%d%d%d)$")
        done(tonumber(status) or 0, body or stdout or "", code, stderr or "")
    end, {"-sS", "--max-time", tostring(maxTime), "-X", "POST", "-H", "Content-Type: " .. contentType,
          "--data-binary", "@" .. clip, "-w", "\n%{http_code}", "-K", cfg})
    tasks[t] = true
    t:start()
end

-- The hub did not answer, as against answering with a refusal: no route, no connection, a timeout, or
-- Fly's proxy answering 5xx for a machine it does not have. Same rule as the watch (Hub.swift unreachable).
local function hubUnreachable(status, curlExit)
    return curlExit ~= 0 or status >= 500 or status == 0
end

-- ---- A HUB COMMAND STREAMS TO THE HUB WHILE IT RECORDS ------------------------------------------------
-- The hub side is status-hub routes/voice.js /api/voice-chunk (docs/VOICE-ON-THE-PHONE.md § Every
-- pressed recording streams to the hub). What sox has written is posted about once a second, one request
-- in flight, in order, and each answer is that chunk's acknowledgement. NOTHING ACKNOWLEDGED FOR
-- CHUNK_ACK_S, or an answer saying the capture is damaged, means the audio is not reaching the hub: the
-- recording stops right then, everything recorded goes up exactly as a normal stop sends it (sendToHub,
-- with its voice-fallback), and it is loud and reported. That one deadline also catches sox going quiet,
-- since a chunk is only cut when sox has written something.
-- The upload names the stream (`streams=` on /api/voice-command) so the hub marks it used. A stream left
-- without that — Hammerspoon dies, the Mac sleeps mid-recording — is recovered by the hub after a minute
-- of silence and acted on, so the command survives even then.
-- Chunks are cut on sox's own writes to the file (hs.pathwatcher, which FSEvents coalesces to about
-- every 0.4s), never on a timer asking whether the file grew. Every chunk's bytes are kept until the
-- stream ends, because a 409 asks for a resend from `next` and a 410 (the hub restarted) from seq 0.
local CHUNK_EVERY = 1.0   -- seconds between chunks, at most: a write event sooner than this cuts nothing
local CHUNK_ACK_S = 6     -- longest a recording may go with nothing acknowledged
local stream = nil        -- the stream of the hub command recording now, until it ends
local liveStreams = {}    -- every stream still delivering, held so the GC cannot collect its timers
local streamTasks = {}    -- its curl tasks; reset() leaves these alone, so an end or cancel still goes
local streamPump          -- forward declaration

local function streamDone(s)
    if s.watcher then s.watcher:stop() s.watcher = nil end
    if s.deadline then s.deadline:stop() s.deadline = nil end
    if s.retry then s.retry:stop() s.retry = nil end
    liveStreams[s] = nil
end

-- The bytes sox has written past what this stream already holds.
local function streamRead(s, path)
    local f = io.open(path, "rb")
    if not f then return "" end
    f:seek("set", s.read)
    local b = f:read("*a") or ""
    f:close()
    s.read = s.read + #b
    return b
end

-- The audio is not reaching the hub: stop now and send what was recorded, loudly.
local function streamBroken(s, why, label)
    if s ~= stream or s.closed or mode ~= "recording" or not toHub then return end
    ding("Basso")
    hs.alert.show(label, 4)
    report("hub command stream broken; recording stopped and sent", string.format("%s; stream %s, %d of %d chunks acknowledged",
        why, s.id, s.next, #s.chunks))
    stopAndTranscribe()
end

local function armDeadline(s)
    if s.deadline then s.deadline:stop() end
    s.deadline = hs.timer.doAfter(CHUNK_ACK_S, function()
        streamBroken(s, string.format("nothing acknowledged for %ds (last: %s)", CHUNK_ACK_S, s.lastErr or "no answer yet"),
            "⚠️ Hub stream lost")
    end)
end

function streamPump(s)  -- assigns to the forward-declared local above
    if s.inflight or s.abandoned then return end
    local c = s.chunks[s.next + 1]
    if not c then
        if s.closed then   -- the final chunk is acknowledged
            log(string.format("hub stream %s: delivered %d chunks; the hub holds %.1fs", s.id, #s.chunks, s.held or 0))
            streamDone(s)
        end
        return
    end
    if not s.token then
        s.lastErr = "no HUB_TOKEN in " .. HUB_ENV
        if s.closed then streamDone(s) end
        return
    end
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")
    if not f then s.lastErr = "could not write chunk file" return end
    f:write(c.bytes)
    f:close()
    local seq = s.next
    local url = string.format("%s/api/voice-chunk?id=%s&seq=%d&type=wav&secs=%.1f&state=%s&source=mac-cmd",
        HUB_URL, s.id, seq, c.secs, c.state)
    s.inflight = true
    curlPost(url, s.token, tmp, "application/octet-stream", CHUNK_ACK_S, function(status, body, curlExit, stderr)
        os.remove(tmp)
        s.inflight = false
        if s.abandoned then return end
        local ok, res = pcall(hs.json.decode, body)
        if not ok or type(res) ~= "table" then res = nil end
        if status == 200 and res and res.next then
            s.next = res.next
            s.failures = 0
            s.held = tonumber(res.held_s)
            if res.damaged then
                return streamBroken(s, string.format("hub says the capture is damaged: holds %.1fs of %.1fs",
                    tonumber(res.held_s) or 0, tonumber(res.secs) or 0), "⚠️ Recording damaged")
            end
            if not s.closed then armDeadline(s) end
            return streamPump(s)
        elseif status == 409 and res and res.next then
            s.next = res.next
            return streamPump(s)
        elseif status == 410 then
            log("hub stream " .. s.id .. ": hub lost it (410); resending from seq 0")
            s.next = 0
            return streamPump(s)
        end
        s.failures = s.failures + 1
        s.lastErr = string.format("chunk %d: http %d curl %d %s", seq, status, curlExit, (stderr ~= "" and stderr or body):sub(1, 200))
        log("WARN: hub stream " .. s.id .. ": " .. s.lastErr)
        if s.closed and s.failures >= 3 then
            -- the upload carries the whole clip and names this stream; it stands in for the missing end
            log("WARN: hub stream " .. s.id .. ": final chunk not delivered; the upload stands in for it")
            return streamDone(s)
        end
        s.retry = hs.timer.doAfter(1, function() s.retry = nil streamPump(s) end)
    end, streamTasks)
end

function streamStart()  -- assigns to the forward-declared local
    local s = {id = hs.host.uuid():lower(), token = hubToken(), chunks = {}, next = 0, read = 0,
               lastCut = hs.timer.secondsSinceEpoch(), failures = 0}
    stream = s
    liveStreams[s] = true
    s.watcher = hs.pathwatcher.new(WAV, function()
        if s.closed then return end
        local now = hs.timer.secondsSinceEpoch()
        if now - s.lastCut < CHUNK_EVERY then return end
        local b = streamRead(s, WAV)
        if #b == 0 then return end
        s.lastCut = now
        s.chunks[#s.chunks + 1] = {bytes = b, state = "rec", secs = now - recordingStartedAt}
        streamPump(s)
    end):start()
    armDeadline(s)
    log("hub stream " .. s.id .. " started")
end

-- Close the open stream with its last chunk (state `end` carrying the rest of `path`, or `cancel`).
-- Best effort: answers the stream id for the upload to name, nil when there was none.
local function streamClose(state, path, secs)
    local s = stream
    if not s or s.closed then return nil end
    stream = nil
    s.closed = true
    if s.watcher then s.watcher:stop() s.watcher = nil end
    if s.deadline then s.deadline:stop() s.deadline = nil end
    s.chunks[#s.chunks + 1] = {bytes = path and streamRead(s, path) or "", state = state, secs = secs}
    log(string.format("hub stream %s: %s after %d chunks", s.id, state, #s.chunks))
    streamPump(s)
    return s.id
end

-- reset() mid-recording (the Mac woke from sleep): the recording is gone here, so the stream is left as it
-- is, and the hub recovers what reached it.
function streamAbandon()  -- assigns to the forward-declared local
    local s = stream
    if not s or s.closed then return end
    stream = nil
    s.abandoned = true
    streamDone(s)
    log("hub stream " .. s.id .. " abandoned mid-recording; the hub recovers what reached it")
end

-- Send a recorded command the way the watch's Hub control does: to the hub's /api/voice-command, which
-- transcribes it and queues it (source `mac-cmd`). When the hub cannot be reached, the same clip goes to
-- Supabase's voice-fallback function (data-layer supabase/functions/voice-fallback), the watch's route
-- around a hub outage. Every failure is reported to the ops responder; the clip stays in RECORDING_DIR.
local function sendToHub(wav, secs, streamId)
    local function finish(alert) setMode(nil) hs.alert.show(alert) end
    local token = hubToken()
    if not token or token == "" then
        report("hub command not sent: no HUB_TOKEN", HUB_ENV .. "; clip kept at " .. wav)
        return finish("Hub: no token (clip kept)")
    end
    -- AAC is a tenth of the WAV, and the fallback names its upload .m4a for Groq.
    local clip, ctype = wav:gsub("%.wav$", ".m4a"), "audio/mp4"
    local _, conv = hs.execute(string.format("/usr/bin/afconvert -f m4af -d aac '%s' '%s'", wav, clip))
    if not conv then
        report("hub command: afconvert to m4a failed, sending WAV", wav)
        clip, ctype = wav, "audio/wav"
    end
    local msgId = hs.host.uuid():lower()
    local q = string.format("client_msg_id=%s&dur=%.1f&client_now=%s", msgId, secs, os.date("%Y-%m-%dT%H:%M:%S"))

    local function viaFallback(why)
        curlPost(FALLBACK_URL .. "?" .. q, token, clip, ctype, 60, function(status, body, curlExit, stderr)
            local res = status == 200 and hs.json.decode(body) or nil
            if res and res.id then
                report("hub unreachable; command sent through voice-fallback", why .. "; request " .. res.id)
                return finish("→ Hub (fallback): " .. ((res.transcript and res.transcript ~= "") and res.transcript or "sent"))
            end
            report("hub command lost: hub and voice-fallback both failed",
                string.format("hub: %s; fallback: http %d curl %d %s %s; clip kept at %s",
                    why, status, curlExit, body:sub(1, 200), stderr:sub(1, 200), wav))
            finish("Hub: send failed (clip kept)")
        end)
    end

    local streams = streamId and ("&streams=" .. streamId) or ""
    curlPost(HUB_URL .. "/api/voice-command?source=mac-cmd&" .. q .. streams, token, clip, ctype, 25, function(status, body, curlExit, stderr)
        if hubUnreachable(status, curlExit) then
            return viaFallback(string.format("http %d curl %d %s", status, curlExit, (stderr ~= "" and stderr or body):sub(1, 200)))
        end
        local res = hs.json.decode(body)
        if status ~= 200 or not res then
            report("hub refused a command", string.format("http %d: %s; clip kept at %s", status, body:sub(1, 300), wav))
            return finish("Hub: refused (clip kept)")
        end
        if res.enqueued then
            log("hub: queued " .. tostring(res.id) .. ": " .. tostring(res.transcript or ""):sub(1, 80))
            return finish("→ Hub: " .. ((res.transcript and res.transcript ~= "") and res.transcript or "sent"))
        end
        log("hub: not queued: " .. body:sub(1, 200))
        if res.capture == "damaged" then
            report("hub judged a Mac recording damaged", body:sub(1, 200) .. "; clip kept at " .. wav)
            return finish("Hub: recording damaged")
        end
        finish("No speech detected")
    end)
end

function stopAndTranscribe()  -- assigns to the forward-declared local above
    log("stopAndTranscribe (sendAfter=" .. tostring(sendAfter) .. ")")
    killSox()
    local saved = saveRecording()
    local recordingSecs = hs.timer.secondsSinceEpoch() - recordingStartedAt
    if toHub then
        setMode("transcribing")
        ding("Purr")
        -- the saved copy, so a new recording overwriting WAV cannot cut the upload short
        local streamId = streamClose("end", saved or WAV, recordingSecs)
        safeTimer(0.15, function() sendToHub(saved or WAV, recordingSecs, streamId) end)
        return
    end
    local useAPI = recordingSecs >= ADAPTIVE_THRESHOLD
    log(string.format("duration=%.1fs using %s", recordingSecs, useAPI and "API" or "local"))
    setMode("transcribing")
    ding("Purr")

    local function deliver(text)
        text = applySubs(text)
        -- Whisper writes "Thank you." for a recording with no speech in it. On its own it is never
        -- dictation, so it is dropped like silence rather than typed into a session.
        if text:lower():gsub("[^%a]", "") == "thankyou" then text = "" end
        if text == "" then
            setMode(nil)
            hs.alert.show("No speech detected")
            return
        end

        log("transcribed: " .. text:sub(1, 80))
        lastTranscription = text
        local lf = io.open(LAST_TXT, "w")
        if lf then lf:write(text) lf:close() end

        local prev = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)

        -- ai-terminal: deliver via tmux send-keys
        if targetAITab then
            local sessionName = "ai-tab-" .. targetAITab:sub(1, 8)
            local safe = text:gsub("'", "")
            local cmd
            if sendAfter then
                cmd = string.format("%s send-keys -t '%s' -l '%s' && %s send-keys -t '%s' Enter",
                    TMUX, sessionName, safe, TMUX, sessionName)
            else
                cmd = string.format("%s send-keys -t '%s' -l '%s '", TMUX, sessionName, safe)
            end
            local _, ok = hs.execute(cmd)
            log(string.format("ai-terminal %s: %s (ok=%s)", sendAfter and "sent" or "pasted", sessionName, tostring(ok)))
            if prev then hs.pasteboard.setContents(prev) end
            setMode(nil)
            return
        end

        -- tmux pane: send text directly
        if targetPane then
            local safe = text:gsub("'", "")
            local cmd
            if sendAfter then
                cmd = string.format("%s send-keys -t '%s' '%s' Enter", TMUX, targetPane, safe)
            else
                cmd = string.format("%s send-keys -t '%s' '%s '", TMUX, targetPane, safe)
            end
            local _, ok = hs.execute(cmd)
            log(string.format("%s via tmux: %s (ok=%s)", sendAfter and "sent" or "pasted", targetPane, tostring(ok)))
            if prev then hs.pasteboard.setContents(prev) end
            setMode(nil)
            return
        end

        -- Generic: focus target window and paste
        log(string.format("deliver: generic paste sendAfter=%s win=%s clipLen=%d",
            tostring(sendAfter), tostring(targetWin and targetWin:title() or "nil"), #(hs.pasteboard.getContents() or "")))
        local function doPaste()
            log(string.format("doPaste: sendAfter=%s", tostring(sendAfter)))
            hs.eventtap.keyStroke({"cmd"}, "v")
            if sendAfter then
                -- Wait for the paste to settle (bracketed-paste terminals drop an Enter
                -- sent too soon), then submit.
                safeTimer(0.35, function()
                    log("dispatching Enter (submit)")
                    hs.eventtap.keyStroke({}, "return")
                    setMode(nil)
                end)
            else
                hs.eventtap.keyStrokes(" ")
                setMode(nil)
            end
        end
        if targetWin then
            targetWin:focus()
            safeTimer(0.15, doPaste)
        else
            doPaste()
        end
    end

    local function runLocalWhisper(model)
        model = model or WHISPER_MODEL_SMALL
        log("local whisper: " .. model:match("[^/]+$"))
        whisperTask = hs.task.new(WHISPER, function(code, stdout, stderr)
            local ok, err = pcall(function()
                whisperTask = nil
                if code ~= 0 then
                    report("whisper failed", "code " .. tostring(code) .. " " .. (stderr or ""):sub(1, 200))
                    setMode(nil)
                    hs.alert.show("Transcription failed")
                    return
                end
                local text = ""
                for line in stdout:gmatch("[^\r\n]+") do
                    local c = line:match("%]%s*(.+)") or line
                    if c:match("%S") then
                        if text ~= "" then text = text .. " " end
                        text = text .. c:match("^%s*(.-)%s*$")
                    end
                end
                text = text:gsub("%[.-%]", ""):gsub("%(.-%)", ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
                deliver(text)
            end)
            if not ok then
                report("whisper callback error", tostring(err))
                setMode(nil)
                hs.alert.show("Voice error")
            end
        end, {"-m", model, "-f", WAV, "--no-prints", "-nt"})
        whisperTask:start()
    end

    safeTimer(0.15, function()
        local f = io.open(WAV, "r")
        if not f then
            setMode(nil)
            hs.alert.show("No audio")
            return
        end
        f:close()

        if useAPI then
            local kf = io.open(OPENAI_KEY_FILE, "r")
            if not kf then
                log("WARN: no API key, falling back to medium")
                runLocalWhisper(WHISPER_MODEL_MEDIUM)
                return
            end
            local apiKey = kf:read("*a"):match("^%s*(.-)%s*$")
            kf:close()

            -- Convert to MP3 for smaller upload (avoids SSL errors on large WAVs)
            local _, convertOk = hs.execute(SOX .. " " .. WAV .. " " .. MP3 .. " 2>/dev/null")
            if not convertOk then
                log("WARN: MP3 conversion failed, falling back to medium")
                runLocalWhisper(WHISPER_MODEL_MEDIUM)
                return
            end
            log("converted to MP3 for API upload")

            local curlCmd = string.format(
                '/usr/bin/curl -sS -X POST "https://api.openai.com/v1/audio/transcriptions" '
                .. '-H "Authorization: Bearer %s" '
                .. '-F "file=@%s" '
                .. '-F "model=whisper-1" '
                .. '-F "response_format=verbose_json" '
                .. '-F "language=en"',
                apiKey, MP3
            )
            whisperTask = hs.task.new("/bin/sh", function(code, stdout, stderr)
                local ok, err = pcall(function()
                    whisperTask = nil
                    if code ~= 0 then
                        log("WARN: API curl failed: " .. (stderr or ""):sub(1, 200))
                        runLocalWhisper(WHISPER_MODEL_MEDIUM)
                        return
                    end
                    local json = hs.json.decode(stdout)
                    if not json or not json.text then
                        log("WARN: API unexpected response: " .. (stdout or ""):sub(1, 200))
                        runLocalWhisper(WHISPER_MODEL_MEDIUM)
                        return
                    end
                    local apiText = json.text:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$") or ""
                    deliver(apiText)
                end)
                if not ok then
                    report("transcription API callback error", tostring(err))
                    runLocalWhisper(WHISPER_MODEL_MEDIUM)
                end
            end, {"-c", curlCmd})
            whisperTask:start()
        else
            runLocalWhisper(WHISPER_MODEL_SMALL)
        end
    end)
end

-- Option key watcher (double-tap to start, release to stop)
local optTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    local flags = event:getFlags()
    local kc = event:getKeyCode()
    if kc ~= 58 and kc ~= 61 then return false end
    if flags.cmd or flags.shift or flags.ctrl then return false end

    local optDown = flags.alt == true
    if optDown then return false end

    -- Option released
    if mode == "recording" then
        local elapsed = hs.timer.secondsSinceEpoch() - recordingStartedAt
        if elapsed < MIN_RECORD_SECS then return false end
        safeTimer(0, function()
            log("opt-release: stopping recording")
            sendAfter = false
            stopAndTranscribe()
        end)
        lastOptUp = 0
        return false
    end

    if mode ~= nil then return false end

    local now = hs.timer.secondsSinceEpoch()
    if (now - lastOptUp) < DOUBLE_TAP then
        lastOptUp = 0
        if OPTION_TERMINAL_ONLY then
            local app = hs.application.frontmostApplication()
            if not (app and TERMINAL_BUNDLES[app:bundleID() or ""]) then return false end
        end
        safeTimer(0, function() startRecording() end)
    else
        lastOptUp = now
    end
    return false
end)
optTap:start()

-- Key watcher (Enter to send, Escape to cancel)
-- Control watcher (double-tap to record for the hub, tap again to send). A Control that was part of a
-- chord (Ctrl-C, Ctrl-R, ...) never counts as a tap, so Ctrl-C twice in a terminal does not start one.
local lastCtrlUp = 0
local ctrlChord = false
local ctrlTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    local kc = event:getKeyCode()
    if kc ~= 59 and kc ~= 62 then return false end
    local flags = event:getFlags()
    if flags.ctrl then
        ctrlChord = (flags.cmd or flags.alt or flags.shift) and true or false
        return false
    end
    -- Control released
    if ctrlChord or flags.cmd or flags.alt or flags.shift then
        ctrlChord = false
        lastCtrlUp = 0
        return false
    end
    if mode == "recording" and toHub then
        local elapsed = hs.timer.secondsSinceEpoch() - recordingStartedAt
        if elapsed < MIN_RECORD_SECS then return false end
        safeTimer(0, function()
            log("ctrl-tap: sending to hub")
            stopAndTranscribe()
        end)
        lastCtrlUp = 0
        return false
    end
    if mode ~= nil then return false end
    local now = hs.timer.secondsSinceEpoch()
    if (now - lastCtrlUp) < DOUBLE_TAP then
        lastCtrlUp = 0
        safeTimer(0, function() startRecording(true) end)
    else
        lastCtrlUp = now
    end
    return false
end)
ctrlTap:start()

local keyTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local kc = event:getKeyCode()
    if event:getFlags().ctrl then ctrlChord = true lastCtrlUp = 0 end

    -- Escape: cancel
    if kc == 53 and mode ~= nil then
        safeTimer(0, function()
            log("escape: cancelling")
            if mode == "recording" and toHub then
                streamClose("cancel", nil, hs.timer.secondsSinceEpoch() - recordingStartedAt)
            end
            reset()
            hs.alert.show("Cancelled")
        end)
        return true
    end

    -- Enter: stop + send
    if kc == 36 then
        if mode == "recording" then
            safeTimer(0, function()
                log("enter: stopping recording to send")
                sendAfter = true
                stopAndTranscribe()
            end)
            return true
        elseif mode == "transcribing" then
            return true
        end
    end

    return false
end)
keyTap:start()

-- Keep-alive + stuck state recovery
local keepAliveCount = 0
local function keepAliveTick()
    keepAliveCount = keepAliveCount + 1
    if keepAliveCount % 12 == 0 then
        log(string.format("heartbeat (mode=%s)", tostring(mode)))
    end
    ensureTap(optTap, "optTap")
    ensureTap(keyTap, "keyTap")
    ensureTap(ctrlTap, "ctrlTap")
    -- Liveness: if Hammerspoon dies, the beats stop and the responder notices.
    if keepAliveCount % 60 == 1 then ops({"beat", OPS_SERVICE, "300"}) end
    if mode == "transcribing" then
        local elapsed = hs.timer.secondsSinceEpoch() - modeChangedAt
        if elapsed > STUCK_TIMEOUT then
            report(string.format("voice stuck in %s for %.0fs; reset", mode, elapsed))
            hs.alert.show("Voice: recovered from stuck state")
            reset()
        end
    end
    safeTimer(5, keepAliveTick)
end
safeTimer(5, keepAliveTick)

-- Recover after sleep/unlock
local wakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock then
        hs.timer.doAfter(1, function()
            if not optTap:isEnabled() then optTap:start() end
            if not keyTap:isEnabled() then keyTap:start() end
            if not ctrlTap:isEnabled() then ctrlTap:start() end
            reset()
        end)
    end
end)
wakeWatcher:start()

-- Kill any orphaned sox processes left over from a previous Hammerspoon session
hs.task.new("/usr/bin/pkill", nil, {"-TERM", "-f", "sox.*hs-voice"}):start()

-- Cmd+Opt+V: paste last transcription
hs.hotkey.bind({"cmd", "alt"}, "v", function()
    local text = lastTranscription
    if not text then
        local f = io.open(LAST_TXT, "r")
        if f then text = f:read("*a") f:close() end
    end
    if not text or text == "" then
        hs.alert.show("No transcription saved")
        return
    end
    local prev = hs.pasteboard.getContents()
    hs.pasteboard.setContents(text)
    hs.eventtap.keyStroke({"cmd"}, "v")
    hs.timer.doAfter(0.3, function()
        if prev then hs.pasteboard.setContents(prev) end
    end)
end)

-- Voice inject mode: paste arbitrary text into the FRONTMOST window and submit (Enter). Called by the
-- always-listening wake-free speaker-ID engine (wakefree.py, via `hs -c`) when inject mode is on, so a
-- spoken command lands directly in whatever window is focused — a hands-free back-and-forth. Global (no
-- `local`) so the hs CLI can invoke it. Mirrors deliver()'s generic paste path; safeTimer keeps the
-- timers GC-safe.
function injectVoiceText(text)
    if not text or text == "" then return end
    local prev = hs.pasteboard.getContents()
    hs.pasteboard.setContents(text)
    safeTimer(0.05, function()
        hs.eventtap.keyStroke({"cmd"}, "v")
        -- Let the paste settle before Enter (bracketed-paste terminals drop a too-early Enter), then submit.
        safeTimer(0.35, function()
            hs.eventtap.keyStroke({}, "return")
            if prev then safeTimer(0.2, function() hs.pasteboard.setContents(prev) end) end
        end)
    end)
end

