-- Top bar margin — reserves space at the top of the screen where ai-terminal is
--
-- Finds the ai-terminal window, gets its frame, and only pushes down windows
-- that horizontally overlap with it. If ai-terminal isn't running or isn't
-- visible, no margin is enforced.

local BAR_HEIGHT = 36
local AI_TERMINAL_NAMES = { ["ai-terminal"] = true, ["Electron"] = true }

-- Stored in module scope to prevent GC (see CLAUDE.md rules)
local wf = hs.window.filter.new():setOverrideFilter({
    visible = true,
    allowRoles = {"AXStandardWindow"},
})

local function getBarFrame()
    for _, win in ipairs(hs.window.allWindows()) do
        local app = win:application()
        if app and AI_TERMINAL_NAMES[app:name()] then
            return win:frame()
        end
    end
    return nil
end

local adjusting = false
local function enforceMargin(win)
    if adjusting then return end
    if not win or not win:isStandard() then return end
    local app = win:application()
    if app and AI_TERMINAL_NAMES[app:name()] then return end
    if win:isFullScreen() then return end

    local bar = getBarFrame()
    if not bar then return end

    local f = win:frame()
    local screen = win:screen()
    if not screen then return end
    local sf = screen:frame()

    -- Check if window horizontally overlaps with the bar
    local overlapLeft = math.max(f.x, bar.x)
    local overlapRight = math.min(f.x + f.w, bar.x + bar.w)
    if overlapLeft >= overlapRight then return end -- no horizontal overlap

    local minY = sf.y + BAR_HEIGHT
    if f.y < minY then
        adjusting = true
        f.y = minY
        if f.y + f.h > sf.y + sf.h then
            f.h = sf.y + sf.h - f.y
        end
        win:setFrame(f)
        adjusting = false
    end
end

wf:subscribe("windowCreated", enforceMargin)
wf:subscribe("windowMoved", enforceMargin)
wf:subscribe("windowOnScreen", enforceMargin)

-- Enforce on all existing windows at load time
hs.timer.doAfter(1, function()
    for _, win in ipairs(hs.window.allWindows()) do
        enforceMargin(win)
    end
end)
