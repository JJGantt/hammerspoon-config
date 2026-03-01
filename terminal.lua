-- Terminal / Claude launcher
-- Cmd+/: open a Claude session
--   - Terminal already open → new tab
--   - No Terminal window → new window
--     - Laptop only → full-screen
--     - External monitor → saved position (or default if none saved)
-- Cmd+Opt+/: save current Terminal window position (for monitor layout)

local CLAUDE_CMD = "cd ~ && claude"
local POSITION_KEY = "terminal_monitor_frame"

local function hasMonitor()
    return #hs.screen.allScreens() > 1
end

local function openClaude()
    local app = hs.application.get("com.apple.Terminal")
    local hasWindows = app and #app:allWindows() > 0

    if hasWindows then
        -- Open new tab in existing window
        app:activate()
        hs.timer.doAfter(0.15, function()
            hs.eventtap.keyStroke({"cmd"}, "t")
            hs.timer.doAfter(0.3, function()
                hs.eventtap.keyStrokes(CLAUDE_CMD .. "\n")
            end)
        end)
    else
        -- Open new window
        hs.execute('osascript -e \'tell application "Terminal" to do script "' .. CLAUDE_CMD .. '"\'')

        hs.timer.doAfter(0.6, function()
            local newApp = hs.application.get("com.apple.Terminal")
            if not newApp then return end
            local win = newApp:mainWindow()
            if not win then return end

            if hasMonitor() then
                local saved = hs.settings.get(POSITION_KEY)
                if saved then
                    win:setFrame(hs.geometry.rect(saved.x, saved.y, saved.w, saved.h))
                else
                    -- Default: right two-thirds of the main screen
                    local s = hs.screen.mainScreen():frame()
                    win:setFrame(hs.geometry.rect(s.x + s.w * 0.33, s.y, s.w * 0.67, s.h))
                end
            else
                win:setFullScreen(true)
            end
        end)
    end
end

local function savePosition()
    local app = hs.application.get("com.apple.Terminal")
    if not app then
        hs.alert.show("Terminal not open")
        return
    end
    local win = app:focusedWindow()
    if not win then
        hs.alert.show("No Terminal window focused")
        return
    end
    local f = win:frame()
    hs.settings.set(POSITION_KEY, {x = f.x, y = f.y, w = f.w, h = f.h})
    hs.alert.show("Terminal position saved")
end

hs.hotkey.bind({"cmd"}, "/", openClaude)
hs.hotkey.bind({"cmd", "alt"}, "/", savePosition)
