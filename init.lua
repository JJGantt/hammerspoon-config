-- Voice Transcription
-- Double-tap Option: start recording
-- Release Option: stop + transcribe + paste + send
-- Escape: cancel

local SOX = "/opt/homebrew/bin/sox"
local WHISPER = os.getenv("HOME") .. "/whisper.cpp/build/bin/whisper-cli"
local MODEL = os.getenv("HOME") .. "/whisper.cpp/models/ggml-base.en.bin"
local WAV = "/tmp/hs-voice.wav"
local DOUBLE_TAP = 0.35

local mode = nil       -- nil | "recording" | "transcribing"
local indicator = 0    -- how many chars of indicator are in the text field
local lastOptUp = 0

-- IMPORTANT: all hs.task/timer/watcher refs stored at module scope to prevent GC
local soxTask = nil
local whisperTask = nil

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

local function killSox()
    if soxTask then
        soxTask:terminate()
        soxTask = nil
    end
    hs.execute("pkill -9 -f 'sox.*hs-voice' 2>/dev/null", true)
end

local function reset()
    killSox()
    if whisperTask then
        whisperTask:terminate()
        whisperTask = nil
    end
    hs.execute("pkill -9 -f 'whisper-cli.*hs-voice' 2>/dev/null", true)
    setIndicator(nil)
    mode = nil
end

local function ding(name)
    local s = hs.sound.getByName(name)
    if s then s:play() end
end

local function startRecording()
    reset()
    os.remove(WAV)
    mode = "recording"
    ding("Tink")
    setIndicator(">")
    soxTask = hs.task.new(SOX, function() end,
        {"-d", "-r", "16000", "-c", "1", "-b", "16", WAV})
    soxTask:start()
end

local function stopAndTranscribe()
    killSox()
    mode = "transcribing"
    ding("Pop")
    setIndicator("..")

    hs.timer.doAfter(0.15, function()
        local f = io.open(WAV, "r")
        if not f then
            setIndicator(nil)
            mode = nil
            hs.alert.show("No audio")
            return
        end
        f:close()

        whisperTask = hs.task.new(WHISPER, function(code, stdout, stderr)
            whisperTask = nil
            if code ~= 0 then
                setIndicator(nil)
                mode = nil
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

            if text == "" then
                setIndicator(nil)
                mode = nil
                hs.alert.show("No speech detected")
                return
            end

            setIndicator(nil)
            local prev = hs.pasteboard.getContents()
            hs.pasteboard.setContents(text)
            hs.timer.doAfter(0.05, function()
                hs.eventtap.keyStroke({"cmd"}, "v")
                hs.timer.doAfter(0.15, function()
                    hs.eventtap.keyStroke({}, "return")
                    if prev then hs.pasteboard.setContents(prev) end
                    mode = nil
                end)
            end)
        end, {"-m", MODEL, "-f", WAV, "--no-prints", "-nt"})
        whisperTask:start()
    end)
end

-- Option key watcher
local optTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    local flags = event:getFlags()
    local kc = event:getKeyCode()
    if kc ~= 58 and kc ~= 61 then return false end
    if flags.cmd or flags.shift or flags.ctrl then return false end

    local optDown = flags.alt == true
    if optDown then return false end

    if mode == "recording" then
        stopAndTranscribe()
        lastOptUp = 0
        return false
    end

    if mode ~= nil then return false end

    local now = hs.timer.secondsSinceEpoch()
    if (now - lastOptUp) < DOUBLE_TAP then
        lastOptUp = 0
        startRecording()
    else
        lastOptUp = now
    end
    return false
end)
optTap:start()

-- Escape to cancel
local escTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    if event:getKeyCode() == 53 and mode ~= nil then
        reset()
        hs.alert.show("Cancelled")
        return true
    end
    return false
end)
escTap:start()

-- Keep-alive + stuck state recovery
local keepAlive = hs.timer.doEvery(30, function()
    if not optTap:isEnabled() then optTap:start() end
    if not escTap:isEnabled() then escTap:start() end
    if mode == "transcribing" and whisperTask == nil then
        mode = nil
    end
end)

-- Recover after sleep/unlock
local wakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock then
        hs.timer.doAfter(1, function()
            if not optTap:isEnabled() then optTap:start() end
            if not escTap:isEnabled() then escTap:start() end
            reset()
        end)
    end
end)
wakeWatcher:start()

-- Ctrl+Alt+Cmd+R to reload
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "R", function()
    reset()
    hs.reload()
end)

hs.alert.show("Hammerspoon loaded")
