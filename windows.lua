-- Windows / Claude launcher / Layout manager
--
-- Cmd+/:         open a Claude session
-- Cmd+Opt+/:     save current Terminal window position (monitor layout)
-- Cmd+Opt+S:     save full window layout (context-aware: laptop or monitor slot)
-- Cmd+Opt+R:     restore window layout for current context

local CLAUDE_CMD = os.getenv("HOME") .. "/.hammerspoon/open-claude.sh"
local POSITION_KEY = "terminal_monitor_frame"

local function hasMonitor()
    return #hs.screen.allScreens() > 1
end

-- ── Claude terminal launcher ──────────────────────────────────────────────────

local function openClaude()
    local app = hs.application.get("com.apple.Terminal")
    local hasWindows = app and #app:allWindows() > 0

    if hasWindows then
        app:activate()
        hs.timer.doAfter(0.15, function()
            hs.eventtap.keyStroke({"cmd"}, "t")
            hs.timer.doAfter(0.3, function()
                hs.eventtap.keyStrokes(CLAUDE_CMD .. "\n")
            end)
        end)
    else
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
                    local s = hs.screen.mainScreen():frame()
                    win:setFrame(hs.geometry.rect(s.x + s.w * 0.33, s.y, s.w * 0.67, s.h))
                end
            else
                win:setFullScreen(true)
            end
        end)
    end
end

local function saveTerminalPosition()
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

-- ── Layout save / restore ─────────────────────────────────────────────────────

local function saveLayout()
    local context = hasMonitor() and "monitor" or "laptop"
    local layout = {}
    -- Track per-app window index so we can match multi-window apps on restore
    local appIndex = {}
    for _, win in ipairs(hs.window.orderedWindows()) do
        if win:isStandard() then
            local app = win:application()
            local bid = app and app:bundleID() or "unknown"
            appIndex[bid] = (appIndex[bid] or 0) + 1
            local f = win:frame()
            local s = win:screen()
            layout[#layout + 1] = {
                bundleID     = bid,
                appWinIndex  = appIndex[bid],
                screenName   = s and s:name() or nil,
                isFullScreen = win:isFullScreen(),
                frame        = {x = f.x, y = f.y, w = f.w, h = f.h},
            }
        end
    end
    hs.settings.set("window_layout_" .. context, layout)
    hs.alert.show("Layout saved (" .. context .. ")")
end

local function restoreLayout()
    local context = hasMonitor() and "monitor" or "laptop"
    local layout = hs.settings.get("window_layout_" .. context)
    if not layout then
        hs.alert.show("No layout saved for " .. context)
        return
    end

    -- Build bundleID → ordered list of windows
    local appWindows = {}
    for _, win in ipairs(hs.window.orderedWindows()) do
        if win:isStandard() then
            local app = win:application()
            local bid = app and app:bundleID() or "unknown"
            if not appWindows[bid] then appWindows[bid] = {} end
            appWindows[bid][#appWindows[bid] + 1] = win
        end
    end

    -- Match saved entries to current windows by bundleID + window index
    local toRestore = {}
    for _, entry in ipairs(layout) do
        local wins = appWindows[entry.bundleID]
        if wins and wins[entry.appWinIndex] then
            toRestore[#toRestore + 1] = {win = wins[entry.appWinIndex], entry = entry}
        end
    end

    -- Step 1: exit full-screen on any window saved as non-FS (need animation time)
    local needsExit = false
    for _, item in ipairs(toRestore) do
        if item.win:isFullScreen() and not item.entry.isFullScreen then
            item.win:setFullScreen(false)
            needsExit = true
        end
    end

    -- Step 2: after FS-exit animation settles, move/resize/fullscreen everything
    hs.timer.doAfter(needsExit and 0.9 or 0, function()
        for _, item in ipairs(toRestore) do
            local win, entry = item.win, item.entry

            -- Find the target screen by name (skip if not connected)
            local targetScreen = nil
            if entry.screenName then
                for _, s in ipairs(hs.screen.allScreens()) do
                    if s:name() == entry.screenName then
                        targetScreen = s
                        break
                    end
                end
            end

            if entry.isFullScreen then
                if not win:isFullScreen() then
                    if targetScreen then win:moveToScreen(targetScreen) end
                    hs.timer.doAfter(0.1, function() win:setFullScreen(true) end)
                end
            else
                if targetScreen then win:moveToScreen(targetScreen) end
                win:setFrame(hs.geometry.rect(entry.frame.x, entry.frame.y, entry.frame.w, entry.frame.h))
            end
        end
    end)

    hs.alert.show("Layout restored (" .. context .. ")")
end

-- ── Hotkeys ───────────────────────────────────────────────────────────────────

hs.hotkey.bind({"cmd"},           "/",  openClaude)
hs.hotkey.bind({"cmd", "alt"},    "/",  saveTerminalPosition)
hs.hotkey.bind({"cmd", "alt"},    "s",  saveLayout)
hs.hotkey.bind({"cmd", "alt"},    "r",  restoreLayout)
