-- Voice Transcription
-- Always:
--   Double-tap Opt : start recording (base model)
--   Opt+/ ' ]      : switch to small / medium / turbo model
--   Release Option : stop + transcribe + paste
--   Return         : stop + transcribe + paste + send
--   Escape         : cancel
--   Cmd+Opt+V      : paste last transcription (fallback)
-- Caps Lock mode (light = on):
--   Space          : start recording (current model)
--   Space          : stop + send
--   Cmd+Space      : stop + paste (no Enter)
--   Option         : switch to base
--   / ' ]          : switch to small / medium / turbo

local SOX = "/opt/homebrew/bin/sox"
local WHISPER = os.getenv("HOME") .. "/whisper.cpp/build/bin/whisper-cli"
local MODEL_BASE   = os.getenv("HOME") .. "/whisper.cpp/models/ggml-base.en.bin"
local MODEL_SMALL  = os.getenv("HOME") .. "/whisper.cpp/models/ggml-small.en.bin"
local MODEL_MEDIUM = os.getenv("HOME") .. "/whisper.cpp/models/ggml-medium.en.bin"
local MODEL_TURBO  = os.getenv("HOME") .. "/whisper.cpp/models/ggml-large-v3-turbo.bin"
local MODEL = MODEL_BASE
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

local function modelLabel(m)
    if     m == MODEL_BASE   then return "Base"
    elseif m == MODEL_SMALL  then return "Small"
    elseif m == MODEL_MEDIUM then return "Medium"
    elseif m == MODEL_TURBO  then return "Turbo"
    else return m:match("ggml%-(.-)%.bin") or "?" end
end

-- Screen border highlight: red=recording, amber=transcribing, nil=off
local recordBorder = nil
local function showBorder(color)
    if recordBorder then recordBorder:delete() recordBorder = nil end
    if not color then return end
    local win = targetWin or hs.window.focusedWindow()
    if not win then return end
    local f = win:frame()
    recordBorder = hs.canvas.new(f)
    recordBorder[1] = {
        type         = "rectangle",
        action       = "stroke",
        strokeColor  = color,
        strokeWidth  = 6,
        frame        = {x = 0, y = 0, w = f.w, h = f.h},
    }
    recordBorder:level(hs.canvas.windowLevels.overlay)
    recordBorder:show()
end

-- IMPORTANT: all hs.task/timer/watcher refs stored at module scope to prevent GC
local soxTask = nil
local whisperTask = nil
local whisperTimeout = nil
local activeTimers = {}
local sendAfter = false
local targetWin = nil
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
    if newMode == nil then showBorder(nil) end
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

local function reset()
    killSox()
    if whisperTask then whisperTask:terminate() whisperTask = nil end
    if whisperTimeout then whisperTimeout:stop() whisperTimeout = nil end
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
local MIN_RECORD_SECS = 0.5

local function startRecording(model)
    currentModel = model or MODEL_BASE
    log("startRecording model=" .. modelLabel(currentModel))
    reset()
    targetWin = hs.window.focusedWindow()
    os.remove(WAV)
    recordingStartedAt = hs.timer.secondsSinceEpoch()
    setMode("recording")
    showBorder({red=0.9, green=0.1, blue=0.1, alpha=0.85})
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
    showBorder({red=1, green=0.6, blue=0, alpha=0.85})
    ding("Purr")

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

                    lastTranscription = text
                    local lf = io.open(LAST_TXT, "w")
                    if lf then lf:write(text) lf:close() end

                    setIndicator(nil)
                    local prev = hs.pasteboard.getContents()
                    hs.pasteboard.setContents(text)

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
    end

    if targetWin then
        targetWin:focus()
        safeTimer(0.15, proceed)
    else
        proceed()
    end
end

-- Caps Lock tracker — keycode 57 fires twice per press (down+up), so read
-- the actual state from flags rather than toggling
local capslockTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    if event:getKeyCode() == 57 then
        local new = event:getFlags().capslock == true
        if new ~= capslockOn then
            capslockOn = new
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

    -- Caps Lock mode
    if capslockOn then
        if kc == 49 then  -- Space
            if mode == nil then
                safeTimer(0, function() startRecording(currentModel) end)
                return true
            elseif mode == "recording" then
                safeTimer(0, function()
                    sendAfter = not flags.cmd
                    stopAndTranscribe()
                end)
                return true
            end
        end
        if mode == nil then
            local m, label = nil, nil
            if     kc == 44 then m, label = MODEL_SMALL,  "Small"
            elseif kc == 39 then m, label = MODEL_MEDIUM, "Medium"
            elseif kc == 30 then m, label = MODEL_TURBO,  "Turbo"
            end
            if m then
                currentModel = m
                hs.alert.show("Model: " .. label, 1)
                return true
            end
        end
    end

    -- Escape cancels
    if kc == 53 and mode ~= nil then
        safeTimer(0, function()
            log("escape: cancelling (mode=" .. tostring(mode) .. ")")
            reset()
            hs.alert.show("Cancelled")
        end)
        return true
    end

    -- Enter stops + sends
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

    -- Opt+/ ' ] = switch model
    if flags.alt and not flags.cmd and not flags.shift and not flags.ctrl and mode == nil then
        local m, label = nil, nil
        if     kc == 44 then m, label = MODEL_SMALL,  "Small"
        elseif kc == 39 then m, label = MODEL_MEDIUM, "Medium"
        elseif kc == 30 then m, label = MODEL_TURBO,  "Turbo"
        end
        if m then
            currentModel = m
            hs.alert.show("Model: " .. label, 1)
            return true
        end
    end

    return false
end)
keyTap:start()

-- Block mouse clicks during transcription
local clickBlock = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function()
    if mode == "transcribing" then return true end
    return false
end)
clickBlock:start()

-- Keep-alive + stuck state recovery
local STUCK_TIMEOUT = 20
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
