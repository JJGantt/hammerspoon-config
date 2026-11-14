-- Menu bar control for the external-display filter (repo JJGantt/screen-filter).
-- Every choice runs the `screenfilter` CLI; the daemon it talks to does the actual tinting.
-- The menu is rebuilt from the settings file each time it opens, so it always shows what is set.

local M = {}

local CLI = os.getenv("HOME") .. "/.local/bin/screenfilter"
local CONFIG_DIR = os.getenv("HOME") .. "/.config/screen-filter"
local CONFIG = CONFIG_DIR .. "/config.json"

local BRIGHTNESS = { 100, 85, 70, 55, 40, 30, 20, 10 }
local WARMTH = { 0, 25, 50, 65, 80, 100 }

local function settings()
  return hs.json.read(CONFIG) or { mode = "auto", warmth = 50, brightness = 100 }
end

M.task = nil
local function run(...)
  local args = { ... }
  M.task = hs.task.new(CLI, function(code, _, err)
    if code ~= 0 then
      print("ERROR screenfilter " .. table.concat(args, " ") .. " exited " .. code .. ": " .. (err or ""))
    end
  end, args)
  if not M.task:start() then print("ERROR screenfilter: could not start " .. CLI) end
end

function M.refreshIcon()
  local s = settings()
  M.menubar:setTitle(s.mode == "off" and "○" or "◐")
end

local function buildMenu()
  local s = settings()
  local menu = {
    { title = "Auto (sunset to sunrise)", checked = s.mode == "auto", fn = function() run("auto") end },
    { title = "Always on", checked = s.mode == "on", fn = function() run("on") end },
    { title = "Off", checked = s.mode == "off", fn = function() run("off") end },
    { title = "-" },
  }
  local function submenu(title, values, current, suffix, command)
    local items = {}
    for _, v in ipairs(values) do
      table.insert(items, { title = v .. suffix, checked = current == v, fn = function() run(command, tostring(v)) end })
    end
    table.insert(menu, { title = title .. ": " .. tostring(current) .. suffix, menu = items })
  end
  submenu("Warmth", WARMTH, s.warmth, "", "warmth")
  submenu("Monitor brightness", BRIGHTNESS, s.brightness, "%", "brightness")
  submenu("Laptop brightness", BRIGHTNESS, s.laptopBrightness or 100, "%", "laptop-brightness")
  return menu
end

M.menubar = hs.menubar.new()
M.menubar:setTooltip("Screen filter")
M.menubar:setMenu(buildMenu)
M.refreshIcon()

-- The icon follows the mode whoever changes it (this menu, the CLI, a Claude session).
M.watcher = hs.pathwatcher.new(CONFIG_DIR, function() M.refreshIcon() end):start()

return M
