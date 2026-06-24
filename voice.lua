-- Voice Transcription (simplified)
-- Double-tap Option : start recording
-- Release Option    : stop + transcribe + paste + space
-- Enter             : stop + transcribe + paste + send (Enter)
-- Escape            : cancel
-- Adaptive: <15s local whisper, >=15s OpenAI Whisper API
-- Cmd+Opt+V         : paste last transcription

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

-- Hands-free VAD auto-end (silero). See voice-conversation-design.md.
local VAD_PYTHON = os.getenv("HOME") .. "/voice/mac/.venv-kokoro/bin/python"
local VAD_SCRIPT = os.getenv("HOME") .. "/scripts/vad_listen.py"
local BASELINE_FILE = os.getenv("HOME") .. "/.hammerspoon/voice-baseline"
local VAD_BASELINE = 5.0       -- seconds of non-speech (after speech) before auto-ending
do  -- restore persisted baseline (set via Cmd+Opt+number)
    local f = io.open(BASELINE_FILE, "r")
    if f then
        local v = tonumber(f:read("*a") or "")
        f:close()
        if v and v > 0 then VAD_BASELINE = v end
    end
end
local VAD_MAX_INITIAL = 20.0   -- give up (NOSPEECH) if no speech at all within this window
local LOG_FILE = os.getenv("HOME") .. "/Library/Logs/hs-voice.log"
local hslog = hs.logger.new("voice", "info")

local function log(msg)
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = ts .. "  " .. msg
    hslog.i(line)
    local f = io.open(LOG_FILE, "a")
    if f then f:write(line .. "\n") f:close() end
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
local recordingStartedAt = 0

local soxTask = nil
local whisperTask = nil
local vadTask = nil
local autoSendOnStop = false
local activeTimers = {}
local stopAndTranscribe  -- forward declaration: referenced by startRecording's VAD callback,
                         -- but defined later in the file (Lua locals aren't visible before declaration)

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
    -- pause + release the mic; SIGUSR2 = resume. Sent to both; whichever isn't running is a no-op.
    local sig = (newMode == "recording") and "-USR1" or "-USR2"
    hs.task.new("/usr/bin/pkill", nil, {sig, "-f", "listener.py"}):start()
    hs.task.new("/usr/bin/pkill", nil, {sig, "-f", "wakefree.py"}):start()
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

local function killVad()
    if vadTask then vadTask:terminate() vadTask = nil end
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
    killSox()
    killVad()
    if whisperTask then whisperTask:terminate() whisperTask = nil end
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

local function startRecording(autoStop, autoSend)
    log("startRecording" .. (autoStop and " (auto-stop)" or ""))
    reset()
    targetWin = hs.window.focusedWindow()

    -- Check if ai-terminal is focused
    local focusedApp = targetWin and targetWin:application()
    local focusedBundle = focusedApp and focusedApp:bundleID() or ""
    if focusedBundle == AI_TERMINAL_BUNDLE then
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
    ding("Glass")
    soxTask = hs.task.new(SOX, function(code)
        if mode == "recording" then
            log("WARN: sox exited early (code=" .. tostring(code) .. ") — recording lost audio after this point")
            hs.alert.show("⚠️ Recording device dropped")
        end
    end, {"-q", "-d", "-r", "16000", "-c", "1", "-b", "16", WAV})
    soxTask:start()

    -- Parallel VAD listener: ends the recording automatically after VAD_BASELINE
    -- seconds of non-speech (or cancels if no speech at all). Reads the mic
    -- independently of sox.
    if autoStop then
        autoSendOnStop = autoSend and true or false
        vadTask = hs.task.new(VAD_PYTHON, function(code, stdout, stderr)
            local out = stdout or ""
            local decision = out:match("STOP") and "STOP" or (out:match("NOSPEECH") and "NOSPEECH" or nil)
            safeTimer(0, function()
                vadTask = nil
                if mode ~= "recording" then return end  -- already stopped/cancelled manually
                if decision == "STOP" then
                    log("vad: auto-stop after baseline silence (send=" .. tostring(autoSendOnStop) .. ")")
                    sendAfter = autoSendOnStop
                    stopAndTranscribe()
                elseif decision == "NOSPEECH" then
                    log("vad: no speech detected — cancelling")
                    reset()
                    hs.alert.show("No speech")
                else
                    log("vad: exited without decision (code=" .. tostring(code) .. ")")
                end
            end)
        end, {VAD_SCRIPT, "--baseline", tostring(VAD_BASELINE), "--max-initial", tostring(VAD_MAX_INITIAL)})
        vadTask:start()
    end
end

local function saveRecording()
    hs.fs.mkdir(RECORDING_DIR)
    local dest = RECORDING_DIR .. "/" .. os.date("%Y-%m-%d_%H%M%S") .. ".wav"
    local _, ok = hs.execute(string.format("/bin/cp '%s' '%s'", WAV, dest))
    if not ok then log("WARN: failed to copy recording") return end
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
end

function stopAndTranscribe()  -- assigns to the forward-declared local above
    log("stopAndTranscribe (sendAfter=" .. tostring(sendAfter) .. ")")
    killSox()
    killVad()
    saveRecording()
    local recordingSecs = hs.timer.secondsSinceEpoch() - recordingStartedAt
    local useAPI = recordingSecs >= ADAPTIVE_THRESHOLD
    log(string.format("duration=%.1fs using %s", recordingSecs, useAPI and "API" or "local"))
    setMode("transcribing")
    ding("Purr")

    local function deliver(text)
        text = applySubs(text)
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
                    log("WARN: whisper failed (code " .. tostring(code) .. ")")
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
                log("ERROR in whisper callback: " .. tostring(err))
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
                    log("ERROR in API callback: " .. tostring(err))
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
        safeTimer(0, function() startRecording(true, true) end)  -- manual: auto-end on silence, then send (Enter)
    else
        lastOptUp = now
    end
    return false
end)
optTap:start()

-- Key watcher (Enter to send, Escape to cancel)
local keyTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local kc = event:getKeyCode()

    -- Escape: cancel
    if kc == 53 and mode ~= nil then
        safeTimer(0, function()
            log("escape: cancelling")
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
    if not optTap:isEnabled() then log("WARN: optTap disabled — restarting") optTap:start() end
    if not keyTap:isEnabled() then log("WARN: keyTap disabled — restarting") keyTap:start() end
    if mode == "transcribing" then
        local elapsed = hs.timer.secondsSinceEpoch() - modeChangedAt
        if elapsed > STUCK_TIMEOUT then
            log(string.format("WARN: stuck for %.0fs — resetting", elapsed))
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

-- Cmd+Opt+1..9 set the auto-end pause to that many seconds; Cmd+Opt+0 = 10s. Persisted.
local function setBaseline(secs)
    VAD_BASELINE = secs
    local f = io.open(BASELINE_FILE, "w")
    if f then f:write(tostring(secs)); f:close() end
    log("baseline set to " .. secs .. "s")
    hs.alert.show("⏱️ Auto-end pause: " .. secs .. "s")
end
for d = 1, 9 do
    hs.hotkey.bind({"cmd", "alt"}, tostring(d), function() setBaseline(d) end)
end
hs.hotkey.bind({"cmd", "alt"}, "0", function() setBaseline(10) end)
