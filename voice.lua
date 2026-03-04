-- Voice Transcription
-- Adaptive space (non-capslock, empty line):
--   Space          : start recording (if no typing since last reset event)
--   Space          : stop + send
--   Cmd+Space      : stop + paste (no Enter)
--   Reset events: mouse click, Enter, window focus change, voice delivery
-- Always:
--   Double-tap Opt : start recording (base model)
--   Opt+/ ' ] \    : switch to small / medium / turbo / API model
--   Release Option : stop + transcribe + paste
--   Return         : stop + transcribe + paste + send
--   Escape         : cancel
--   Cmd+Opt+V      : paste last transcription (fallback)
-- Caps Lock mode (light = on):
--   Space          : start recording (current model)
--   Space          : stop + send
--   Cmd+Space      : stop + paste (no Enter)
--   Option         : switch to base
--   / ' ] \        : switch to small / medium / turbo / API

local SOX = "/opt/homebrew/bin/sox"
local WHISPER = os.getenv("HOME") .. "/whisper.cpp/build/bin/whisper-cli"
local MODEL_BASE   = os.getenv("HOME") .. "/whisper.cpp/models/ggml-base.en.bin"
local MODEL_SMALL  = os.getenv("HOME") .. "/whisper.cpp/models/ggml-small.en.bin"
local MODEL_MEDIUM = os.getenv("HOME") .. "/whisper.cpp/models/ggml-medium.en.bin"
local MODEL_TURBO  = os.getenv("HOME") .. "/whisper.cpp/models/ggml-large-v3-turbo.bin"
local MODEL_API    = "api"
local MODEL = MODEL_BASE
local OPENAI_KEY_FILE = os.getenv("HOME") .. "/.config/openai-api-key"
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

local lastTranscription = nil
local mode = nil       -- nil | "recording" | "transcribing"
local modeChangedAt = 0
local indicator = 0
local lastOptUp = 0
local capslockOn = hs.eventtap.checkKeyboardModifiers().capslock == true  -- init from hardware
local hasTyped = false  -- adaptive space: reset on click, Enter, focus change, voice delivery

local function modelLabel(m)
    if     m == MODEL_BASE   then return "Base"
    elseif m == MODEL_SMALL  then return "Small"
    elseif m == MODEL_MEDIUM then return "Medium"
    elseif m == MODEL_TURBO  then return "Turbo"
    elseif m == MODEL_API    then return "API"
    else return m:match("ggml%-(.-)%.bin") or "?" end
end

-- IMPORTANT: all hs.task/timer/watcher refs stored at module scope to prevent GC
local soxTask = nil
local whisperTask = nil
local activeTimers = {}
local sendAfter = false
local targetWin = nil
local targetTTY = nil   -- TTY path if target is a Terminal tab; nil otherwise
local targetPane = nil  -- tmux pane target (e.g. "claude:0.0") if inside tmux; nil otherwise
local currentModel = MODEL

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
    if newMode == nil then hasTyped = false end
end

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

local function asyncPkill(pattern)
    hs.task.new("/usr/bin/pkill", nil, {"-9", "-f", pattern}):start()
end

local function killSox()
    if soxTask then soxTask:terminate() soxTask = nil end
    asyncPkill("sox.*hs-voice")
end

-- If the focused window is a Terminal tab, return its TTY device path.
-- Uses the specific window ID rather than "front window" to avoid mismatches.
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

-- If the given TTY is a tmux client, return the session name as a send-keys target.
-- Terminal.app's TTY matches the tmux CLIENT tty, not the pane tty.
local function getTmuxPane(tty)
    if not tty then return nil end
    local output, status = hs.execute("/opt/homebrew/bin/tmux list-clients -F '#{client_tty} #{client_session}' 2>/dev/null")
    if not status or not output or output == "" then return nil end
    for line in output:gmatch("[^\n]+") do
        local clientTTY, session = line:match("^(/dev/%S+)%s+(%S+)$")
        if clientTTY == tty then return session end
    end
    return nil
end

local function reset()
    killSox()
    if whisperTask then whisperTask:terminate() whisperTask = nil end
    asyncPkill("whisper-cli.*hs-voice")
    setIndicator(nil)
    targetWin = nil
    targetTTY = nil
    targetPane = nil
    cleanTimers()
    setMode(nil)
end

local function ding(name)
    local s = hs.sound.getByName(name)
    if s then s:play() end
end

local recordingStartedAt = 0
local MIN_RECORD_SECS = 0.5

local function startRecording(model)
    currentModel = model or MODEL_BASE
    log("startRecording model=" .. modelLabel(currentModel))
    reset()
    targetWin = hs.window.focusedWindow()
    targetTTY = getTerminalTTY(targetWin)
    targetPane = getTmuxPane(targetTTY)
    os.remove(WAV)
    recordingStartedAt = hs.timer.secondsSinceEpoch()
    setMode("recording")
    ding("Glass")
    if not targetPane and not targetTTY then setIndicator(">") end
    soxTask = hs.task.new(SOX, function() end,
        {"-d", "-r", "16000", "-c", "1", "-b", "16", WAV})
    soxTask:start()
end

local function stopAndTranscribe()
    log("stopAndTranscribe (sendAfter=" .. tostring(sendAfter) .. ")")
    killSox()
    local recordingSecs = hs.timer.secondsSinceEpoch() - recordingStartedAt
    local useModel = currentModel
    if recordingSecs > 30 and useModel ~= MODEL_API then
        log(string.format("adaptive: %.0fs recording, switching to API", recordingSecs))
        useModel = MODEL_API
    end
    setMode("transcribing")
    ding("Purr")

    -- Deliver transcribed text to the target
    local function deliver(text)
        text = applySubs(text)
        if text == "" then
            setIndicator(nil)
            setMode(nil)
            hs.alert.show("No speech detected")
            return
        end

        log("transcribed: " .. text:sub(1, 80))
        lastTranscription = text
        local lf = io.open(LAST_TXT, "w")
        if lf then lf:write(text) lf:close() end

        setIndicator(nil)

        local prev = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)

        -- tmux pane: write to temp file, load into tmux buffer, paste (+ Enter if sendAfter)
        if targetPane then
            local tmpFile = "/tmp/hs-voice-input.txt"
            local content = sendAfter and text or (text .. " ")
            local f = io.open(tmpFile, "w")
            if f then f:write(content) f:close() end
            local cmd = string.format(
                "/opt/homebrew/bin/tmux load-buffer %s && /opt/homebrew/bin/tmux paste-buffer -t '%s'",
                tmpFile, targetPane
            )
            if sendAfter then
                cmd = cmd .. string.format(" && /opt/homebrew/bin/tmux send-keys -t '%s' Enter", targetPane)
            end
            hs.execute(cmd)
            if prev then hs.pasteboard.setContents(prev) end
            log((sendAfter and "sent" or "pasted") .. " via tmux: " .. targetPane)
            setMode(nil)
            return
        end

        -- Non-TTY paste: focus target window and paste
        local function doPaste()
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
        end
        if targetWin then
            targetWin:focus()
            safeTimer(0.15, doPaste)
        else
            doPaste()
        end
    end

    local function proceed()
        if not targetPane and not targetTTY then setIndicator("..") end
        safeTimer(0.15, function()
            local f = io.open(WAV, "r")
            if not f then
                setIndicator(nil)
                setMode(nil)
                hs.alert.show("No audio")
                return
            end
            f:close()

            local function runLocalWhisper()
                whisperTask = hs.task.new(WHISPER, function(code, stdout, stderr)
                    local ok, err = pcall(function()
                        whisperTask = nil
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
                        deliver(text)
                    end)
                    if not ok then
                        log("ERROR in whisper callback: " .. tostring(err))
                        setIndicator(nil)
                        setMode(nil)
                        hs.alert.show("Voice error: " .. tostring(err):sub(1, 50))
                    end
                end, {"-m", MODEL_BASE, "-f", WAV, "--no-prints", "-nt"})
                whisperTask:start()
            end

            if useModel == MODEL_API then
                -- OpenAI Whisper API (falls back to local on failure)
                local kf = io.open(OPENAI_KEY_FILE, "r")
                if not kf then
                    log("WARN: no API key, falling back to local")
                    runLocalWhisper()
                    return
                end
                local apiKey = kf:read("*a"):match("^%s*(.-)%s*$")
                kf:close()

                local curlCmd = string.format(
                    '/usr/bin/curl -sS -X POST "https://api.openai.com/v1/audio/transcriptions" '
                    .. '-H "Authorization: Bearer %s" '
                    .. '-F "file=@%s" '
                    .. '-F "model=whisper-1" '
                    .. '-F "response_format=verbose_json" '
                    .. '-F "language=en"',
                    apiKey, WAV
                )
                whisperTask = hs.task.new("/bin/sh", function(code, stdout, stderr)
                    local ok, err = pcall(function()
                        whisperTask = nil
                        if code ~= 0 then
                            log("WARN: API curl failed (code " .. tostring(code) .. "): " .. (stderr or ""):sub(1, 200))
                            log("falling back to local whisper")
                            runLocalWhisper()
                            return
                        end
                        local json = hs.json.decode(stdout)
                        if not json or not json.text then
                            log("WARN: API returned unexpected response: " .. (stdout or ""):sub(1, 200))
                            log("falling back to local whisper")
                            runLocalWhisper()
                            return
                        end
                        deliver(json.text:match("^%s*(.-)%s*$") or "")
                    end)
                    if not ok then
                        log("ERROR in API callback: " .. tostring(err) .. " — falling back to local")
                        runLocalWhisper()
                    end
                end, {"-c", curlCmd})
                whisperTask:start()
            else
                runLocalWhisper()
            end
        end)
    end

    proceed()
end

-- Caps Lock tracker — keycode 57 fires twice per press (down+up), debounce
-- so only the first event per physical press actually toggles
local capslockTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    if event:getKeyCode() == 57 then
        -- checkKeyboardModifiers returns the pre-toggle state during the event, so invert it
        local actual = not (hs.eventtap.checkKeyboardModifiers().capslock == true)
        if actual ~= capslockOn then
            capslockOn = actual
            log("capslockOn = " .. tostring(capslockOn))
        end
    end
    return false
end)
capslockTap:start()

-- Option key watcher
local optTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    local flags = event:getFlags()
    local kc = event:getKeyCode()
    if kc ~= 58 and kc ~= 61 then return false end
    if flags.cmd or flags.shift or flags.ctrl then return false end

    local optDown = flags.alt == true
    if optDown then
        if capslockOn and mode == nil then
            currentModel = MODEL_BASE
            hs.alert.show("Model: " .. modelLabel(MODEL_BASE), 1)
            return true
        end
        return false
    end

    -- Option released
    if mode == "recording" and not capslockOn then
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
    if capslockOn then return false end

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

local keyTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local kc = event:getKeyCode()
    local flags = event:getFlags()
    local noRepeat = event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 0

    -- ── UNIVERSAL (both modes) ───────────────────────────────────────────────

    -- Escape: cancel recording/transcription
    if kc == 53 and mode ~= nil then
        safeTimer(0, function()
            log("escape: cancelling (mode=" .. tostring(mode) .. ")")
            reset()
            hs.alert.show("Cancelled")
        end)
        return true
    end

    -- Enter: stop recording + send
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

    -- ── CAPS LOCK MODE ───────────────────────────────────────────────────────

    if capslockOn then
        -- / ' ] \ = switch persistent model (no Option needed)
        if mode == nil and not flags.alt and not flags.cmd then
            local m = nil
            if     kc == 44 then m = MODEL_SMALL
            elseif kc == 39 then m = MODEL_MEDIUM
            elseif kc == 30 then m = MODEL_TURBO
            elseif kc == 42 then m = MODEL_API
            end
            if m then
                currentModel = m
                hs.alert.show("Model: " .. modelLabel(m), 1)
                return true
            end
        end

        -- Space: start recording / stop + send (Cmd+Space = stop + paste)
        if kc == 49 and noRepeat then
            log("capslock space (mode=" .. tostring(mode) .. ")")
            if mode == nil then
                safeTimer(0, function() startRecording(currentModel) end)
                return true
            elseif mode == "recording" then
                local elapsed = hs.timer.secondsSinceEpoch() - recordingStartedAt
                if elapsed < MIN_RECORD_SECS then return true end
                safeTimer(0, function()
                    sendAfter = not flags.cmd
                    stopAndTranscribe()
                end)
                return true
            end
        end

        return false  -- let everything else through in caps lock mode
    end

    -- ── CAPS LOCK OFF ────────────────────────────────────────────────────────

    -- Adaptive space: start recording if input is empty (Cmd+Space = Spotlight, let through)
    if kc == 49 and noRepeat and not flags.alt then
        if mode == "recording" then
            -- Stop recording: Cmd+Space = paste only, plain Space = send
            local elapsed = hs.timer.secondsSinceEpoch() - recordingStartedAt
            if elapsed < MIN_RECORD_SECS then return true end
            safeTimer(0, function()
                sendAfter = not flags.cmd
                stopAndTranscribe()
            end)
            return true
        elseif mode == nil and not flags.cmd then
            -- Start recording only if input appears empty
            local shouldRecord = false
            if not hasTyped then
                shouldRecord = true
            else
                -- tmux: check actual pane content in case user backspaced everything
                local win = hs.window.focusedWindow()
                local tty = getTerminalTTY(win)
                local pane = getTmuxPane(tty)
                if pane then
                    local out, ok = hs.execute("/opt/homebrew/bin/tmux capture-pane -t '" .. pane .. "' -p 2>/dev/null")
                    if ok and out then
                        local lastLine = ""
                        for line in out:gmatch("[^\n]+") do lastLine = line end
                        if lastLine:match("^>%s*$") or lastLine:match("^%$%s*$") then
                            shouldRecord = true
                        end
                    end
                end
            end
            if shouldRecord then
                log("adaptive space: starting recording")
                safeTimer(0, function() startRecording(currentModel) end)
                return true
            end
        end
    end

    -- Opt+/ ' ] \ = switch model and start recording (release Opt to stop)
    if flags.alt and not flags.cmd and not flags.shift and not flags.ctrl and mode == nil then
        local m, label = nil, nil
        if     kc == 44 then m, label = MODEL_SMALL,  "Small"
        elseif kc == 39 then m, label = MODEL_MEDIUM, "Medium"
        elseif kc == 30 then m, label = MODEL_TURBO,  "Turbo"
        elseif kc == 42 then m, label = MODEL_API,    "API"
        end
        if m then
            lastOptUp = 0  -- prevent Option release from double-tap triggering
            safeTimer(0, function() startRecording(m) end)
            return true
        end
    end

    -- Track typing for adaptive space (any non-consumed key = user is typing)
    if not capslockOn and mode == nil then
        if kc == 36 or kc == 76 then  -- Return/Enter resets (new line)
            hasTyped = false
        else
            hasTyped = true
        end
    end

    return false
end)
keyTap:start()

-- Block mouse clicks during transcription + reset typing state on click
local clickBlock = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function()
    if mode == "transcribing" then return true end
    hasTyped = false
    return false
end)
clickBlock:start()

-- Keep-alive + stuck state recovery
local STUCK_TIMEOUT = 120
local keepAliveCount = 0
local function keepAliveTick()
    keepAliveCount = keepAliveCount + 1
    if keepAliveCount % 6 == 0 then
        log(string.format("heartbeat (mode=%s capslock=%s)", tostring(mode), tostring(capslockOn)))
    end
    if not optTap:isEnabled()      then log("WARN: optTap disabled — restarting")      optTap:start()      end
    if not keyTap:isEnabled()      then log("WARN: keyTap disabled — restarting")      keyTap:start()      end
    if not clickBlock:isEnabled()  then log("WARN: clickBlock disabled — restarting")  clickBlock:start()  end
    if not capslockTap:isEnabled() then log("WARN: capslockTap disabled — restarting") capslockTap:start() end
    if mode == "transcribing" then
        local elapsed = hs.timer.secondsSinceEpoch() - modeChangedAt
        if elapsed > STUCK_TIMEOUT then
            log(string.format("WARN: stuck in '%s' for %.0fs — force resetting", mode, elapsed))
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
            if not optTap:isEnabled()      then optTap:start()      end
            if not keyTap:isEnabled()      then keyTap:start()      end
            if not capslockTap:isEnabled() then capslockTap:start() end
            capslockOn = hs.eventtap.checkKeyboardModifiers().capslock == true
            log("wake: capslockOn = " .. tostring(capslockOn))
            reset()
        end)
    end
end)
wakeWatcher:start()

-- Cmd+Opt+V: paste last transcription (fallback)
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
