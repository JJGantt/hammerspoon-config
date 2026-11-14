-- Which session tab is on screen — reported the moment it changes, never polled.
--
-- A Claude session's reply is "unread" until someone reads it (desk_sessions.seen_at). Opening it in
-- the hub says so; this is the other half, for the Mac, where an answer is most often actually read.
--
-- THE BELL CANNOT BE ASKED FOR. Terminal.app sets its unread bell from a BEL character and clears it
-- when the tab is selected, and its AppleScript dictionary exposes no property for it — a tab offers
-- busy, selected, tty and custom title, nothing more. So this watches the thing that CLEARS the bell
-- instead: the tab being frontmost. Same moment, same reason, different handle.
--
-- EVENTS, NOT A TIMER. Three of them, and together they cover every way the front tab changes:
--   app activated      — Terminal came forward from another app
--   window focused     — a different Terminal window came forward
--   window title       — the tab changed inside a window (each tab retitles the window)
-- Hammerspoon already holds Accessibility permission and already runs, so this costs nothing at rest.
--
-- The title also carries Claude Code's own ✳ / ◐ status glyph, so it changes whenever any visible
-- session starts or stops working — several times a minute. Hence the two guards below: bursts
-- coalesce into one lookup, and a lookup that finds the same tab as last time sends nothing.

local M = {}

local ORCH = "http://127.0.0.1:7682"
-- The orchestrator's own token, read from its installed launchd plist (the one place it lives) and sent
-- as the X-Token header; the orchestrator refuses a token in the URL.
local PLIST = os.getenv("HOME") .. "/Library/LaunchAgents/com.jaredgantt.voice-orchestrator.plist"
local TOKEN = (hs.execute("/usr/bin/plutil -extract EnvironmentVariables.ORCH_TOKEN raw '" .. PLIST .. "'") or ""):gsub("%s+$", "")
local COALESCE = 0.25   -- seconds; a burst of title changes is one lookup

local lastTty = nil
local pending = nil

-- The tty of the tab actually on screen. Both halves are required: `selected` is per WINDOW, so every
-- window's open tab reports true, and a Terminal tab behind another app is not being read.
local FRONT_TTY = [[
  tell application "System Events" to set fg to name of first application process whose frontmost is true
  if fg is not "Terminal" then return ""
  tell application "Terminal" to return tty of selected tab of front window
]]

local function report()
  pending = nil
  local ok, tty = hs.osascript.applescript(FRONT_TTY)
  if not ok or type(tty) ~= "string" then return end
  tty = tty:gsub("%s+$", "")
  if tty == "" then lastTty = nil; return end
  if tty == lastTty then return end         -- the same tab, still on screen: nothing has been read anew
  lastTty = tty
  hs.http.asyncPost(ORCH .. "/session-read?tty=" .. hs.http.encodeForQuery(tty),
    "", { ["X-Token"] = TOKEN }, function() end)                -- fire and forget; the orchestrator decides if it matters
end

local function schedule()
  if pending then pending:stop() end
  pending = hs.timer.doAfter(COALESCE, report)
end

-- Module scope, or Hammerspoon garbage-collects the watchers and they silently stop firing.
M.appWatcher = hs.application.watcher.new(function(name, event)
  if name == "Terminal" and event == hs.application.watcher.activated then schedule() end
end)

M.winFilter = hs.window.filter.new(false):setAppFilter("Terminal", {})
M.winFilter:subscribe({
  hs.window.filter.windowFocused,
  hs.window.filter.windowTitleChanged,
}, schedule)

function M.start()
  M.appWatcher:start()
  schedule()   -- whatever is already on screen when Hammerspoon loads
end

return M
