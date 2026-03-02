-- Voice Transcription
-- Double-tap Option: start recording
-- Release Option: stop + transcribe + paste in place
-- Return (while recording): stop + transcribe + paste + send
-- Escape: cancel
-- Cmd+Opt+V: paste last transcription (fallback if paste failed)

local SOX = "/opt/homebrew/bin/sox"
local WHISPER = os.getenv("HOME") .. "/whisper.cpp/build/bin/whisper-cli"
local MODEL_BASE   = os.getenv("HOME") .. "/whisper.cpp/models/ggml-base.en.bin"
local MODEL_SMALL  = os.getenv("HOME") .. "/whisper.cpp/models/ggml-small.en.bin"
local MODEL_MEDIUM = os.getenv("HOME") .. "/whisper.cpp/models/ggml-medium.en.bin"
local MODEL_TURBO  = os.getenv("HOME") .. "/whisper.cpp/models/ggml-large-v3-turbo.bin"
local MODEL = MODEL_BASE  -- default (double-tap Option)
local WAV = "/tmp/hs-voice.wav"
local LAST_TXT = "/tmp/hs-voice-last.txt"
local DOUBLE_TAP = 0.35

-- Post-transcription substitutions — managed via voice-subs MCP tool
local SUBS_FILE = os.getenv("HOME") .. "/pi-data/voice_subs.json"
local function applySubs(text)
    local f = io.open(SUBS_FILE, "r")
    if not f then return text end
    local ok, data = pcall(function()
        return hs.json.decode(f:read("*a"))
    end)
    f:close()
    if not ok or not data or not data.subs then return text end
    for _, s in ipairs(data.subs) do
        text = text:gsub(s.pattern, s.replacement)
    end
    return text
end

local LOG_FILE = os.getenv("HOME") .. "/Library/Logs/hs-voice.log"
local hslog = hs.logger.new("voice", "info")

local function log(msg)
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = ts .. "  " .. msg
    hslog.i(line)
    local f = io.open(LOG_FILE, "a")
    if f then f:write(line .. "\n") f:close() end
end

local lastTranscription = nil  -- most recent successful transcription
local mode = nil       -- nil | "recording" | "transcribing"
local modeChangedAt = 0        -- timestamp of last mode change
local indicator = 0    -- how many chars of indicator are in the text field
local lastOptUp = 0

-- IMPORTANT: all hs.task/timer/watcher refs stored at module scope to prevent GC
local soxTask = nil
local whisperTask = nil
local whisperTimeout = nil  -- timer: kills whisper if it hangs
local activeTimers = {}     -- holds refs to all doAfter timers to prevent GC
local sendAfter = false     -- true = press Enter after pasting
local targetWin = nil       -- window focused when recording started
local currentModel = MODEL  -- model to use for current recording

-- Schedule a timer and keep a strong reference so GC can't collect it
local function safeTimer(delay, fn)
    local t = hs.timer.doAfter(delay, function()
        fn()
    end)
    activeTimers[#activeTimers + 1] = t
    return t
end

-- Clean up completed timers periodically (called from reset)
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
end

-- Type into the focused text field, replacing any existing indicator
local function setIndicator(str)
    for i = 1, indicator do
        hs.eventtap.keyStroke({}, "delete", 0)
    end
    if str and #str > 0 then
        hs.eventtap.keyStrokes(str)
        indicator = #str
    else
        indicator = 0
    end
end

-- Async pkill — never blocks the calling thread
local function asyncPkill(pattern)
    hs.task.new("/usr/bin/pkill", nil, {"-9", "-f", pattern}):start()
end

local function killSox()
    if soxTask then
        soxTask:terminate()
        soxTask = nil
    end
    asyncPkill("sox.*hs-voice")
end

local function reset()
    killSox()
    if whisperTask then
        whisperTask:terminate()
        whisperTask = nil
    end
    if whisperTimeout then
        whisperTimeout:stop()
        whisperTimeout = nil
    end
    asyncPkill("whisper-cli.*hs-voice")
    setIndicator(nil)
    targetWin = nil
    cleanTimers()
    setMode(nil)
end

local function ding(name)
    local s = hs.sound.getByName(name)
    if s then s:play() end
end

local recordingStartedAt = 0
local MIN_RECORD_SECS = 0.5  -- ignore Option release this soon after starting

local function startRecording(model)
    currentModel = model or MODEL_BASE
    local modelName = currentModel:match("ggml%-(.-)%.bin") or "?"
    log("startRecording model=" .. modelName)
    reset()
    targetWin = hs.window.focusedWindow()
    os.remove(WAV)
    recordingStartedAt = hs.timer.secondsSinceEpoch()
    setMode("recording")
    ding("Glass")
    setIndicator(">")
    soxTask = hs.task.new(SOX, function() end,
        {"-d", "-r", "16000", "-c", "1", "-b", "16", WAV})
    soxTask:start()
end

local function stopAndTranscribe()
    log("stopAndTranscribe (sendAfter=" .. tostring(sendAfter) .. ")")
    killSox()
    setMode("transcribing")
    ding("Purr")

    -- Focus the target window immediately so the ".." indicator (and later the
    -- paste) all happen in the right place, not wherever the user happened to be.
    local function proceed()
        setIndicator("..")

        safeTimer(0.15, function()
            local f = io.open(WAV, "r")
            if not f then
                setIndicator(nil)
                setMode(nil)
                hs.alert.show("No audio")
                return
            end
            f:close()

            whisperTask = hs.task.new(WHISPER, function(code, stdout, stderr)
                local ok, err = pcall(function()
                    whisperTask = nil
                    if whisperTimeout then whisperTimeout:stop() whisperTimeout = nil end
                    if code ~= 0 then
                        log("WARN: whisper exited with code " .. tostring(code))
                        setIndicator(nil)
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
                    text = applySubs(text)

                    if text == "" then
                        setIndicator(nil)
                        setMode(nil)
                        hs.alert.show("No speech detected")
                        return
                    end

                    log("transcribed: " .. text:sub(1, 80))

                    -- Save transcription so it's never lost
                    lastTranscription = text
                    local lf = io.open(LAST_TXT, "w")
                    if lf then lf:write(text) lf:close() end

                    setIndicator(nil)
                    local prev = hs.pasteboard.getContents()
                    hs.pasteboard.setContents(text)

                    -- targetWin already focused at the start of stopAndTranscribe
                    safeTimer(0.05, function()
                        hs.eventtap.keyStroke({"cmd"}, "v")
                        if sendAfter then
                            safeTimer(0.15, function()
                                hs.eventtap.keyStroke({}, "return")
                                if prev then hs.pasteboard.setContents(prev) end
                                setMode(nil)
                            end)
                        else
                            safeTimer(0.05, function()
                                hs.eventtap.keyStrokes(" ")
                                if prev then hs.pasteboard.setContents(prev) end
                                setMode(nil)
                            end)
                        end
                    end)
                end)
                if not ok then
                    log("ERROR in whisper callback: " .. tostring(err))
                    setIndicator(nil)
                    setMode(nil)
                    hs.alert.show("Voice error: " .. tostring(err):sub(1, 50))
                end
            end, {"-m", currentModel, "-f", WAV, "--no-prints", "-nt"})
            whisperTask:start()

            -- Whisper timeout — stored at module scope so GC can't collect it
            whisperTimeout = safeTimer(15, function()
                if whisperTask then
                    log("WARN: whisper timed out after 15s — killing")
                    whisperTask:terminate()
                    whisperTask = nil
                    asyncPkill("whisper-cli.*hs-voice")
                    setIndicator(nil)
                    setMode(nil)
                    hs.alert.show("Transcription timed out")
                end
                whisperTimeout = nil
            end)
        end)
    end -- proceed()

    if targetWin then
        targetWin:focus()
        safeTimer(0.15, proceed)
    else
        proceed()
    end
end

-- Option key watcher — callback returns IMMEDIATELY, defers all work
local optTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    local flags = event:getFlags()
    local kc = event:getKeyCode()
    if kc ~= 58 and kc ~= 61 then return false end
    if flags.cmd or flags.shift or flags.ctrl then return false end

    local optDown = flags.alt == true
    if optDown then return false end

    -- Option was released — defer all work
    if mode == "recording" then
        local elapsed = hs.timer.secondsSinceEpoch() - recordingStartedAt
        if elapsed < MIN_RECORD_SECS then
            -- Too soon after starting (e.g. Opt+key release) — ignore
            return false
        end
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
        safeTimer(0, function() startRecording(MODEL_BASE) end)
    else
        lastOptUp = now
    end
    return false
end)
optTap:start()

-- Escape to cancel, Return to send, Opt+/'" to start with specific model
local keyTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local kc = event:getKeyCode()
    local flags = event:getFlags()

    if kc == 53 and mode ~= nil then
        safeTimer(0, function()
            log("escape: cancelling (mode=" .. tostring(mode) .. ")")
            reset()
            hs.alert.show("Cancelled")
        end)
        return true
    end
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

    -- Opt+/ = small, Opt+' = medium, Opt+] = large-v3-turbo
    if flags.alt and not flags.cmd and not flags.shift and not flags.ctrl and mode == nil then
        local m = nil
        if     kc == 44 then m = MODEL_SMALL
        elseif kc == 39 then m = MODEL_MEDIUM
        elseif kc == 30 then m = MODEL_TURBO
        end
        if m then
            safeTimer(0, function() startRecording(m) end)
            return true
        end
    end

    return false
end)
keyTap:start()

-- Block mouse clicks during transcription so window focus can't change
local clickBlock = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function()
    if mode == "transcribing" then return true end
    return false
end)
clickBlock:start()

-- Keep-alive + stuck state recovery — self-rescheduling chain
local STUCK_TIMEOUT = 20
local keepAliveCount = 0
local function keepAliveTick()
    keepAliveCount = keepAliveCount + 1
    -- Heartbeat every ~30s
    if keepAliveCount % 6 == 0 then
        log(string.format("heartbeat (mode=%s)", tostring(mode)))
    end
    if not optTap:isEnabled() then
        log("WARN: optTap was disabled — restarting")
        optTap:start()
    end
    if not keyTap:isEnabled() then
        log("WARN: keyTap was disabled — restarting")
        keyTap:start()
    end
    if not clickBlock:isEnabled() then
        log("WARN: clickBlock was disabled — restarting")
        clickBlock:start()
    end
    if mode == "transcribing" then
        local elapsed = hs.timer.secondsSinceEpoch() - modeChangedAt
        if elapsed > STUCK_TIMEOUT then
            log(string.format("WARN: stuck in '%s' for %.0fs — force resetting", mode, elapsed))
            hs.alert.show("Voice: recovered from stuck state")
            reset()
        end
    end
    -- Schedule next tick
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

-- Cmd+Opt+V: paste last transcription (fallback if normal paste failed)
hs.hotkey.bind({"cmd", "alt"}, "v", function()
    -- Try in-memory first, fall back to file
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
