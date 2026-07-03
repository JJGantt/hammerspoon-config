-- Voice-listener wake recovery.
--
-- The always-on Mac wake-word listener runs as the launchd agent com.jaredgantt.voice-mac-listener
-- (KeepAlive=true). When the Mac sleeps (lid close), the listener's CoreAudio input stream wedges and
-- its own watchdog does a hard os._exit for a launchd restart. But when that exit lands inside the
-- sleep transition, launchd loses the KeepAlive respawn and never brings the listener back — it stays
-- dead until the next login or a manual kickstart. Neither RunAtLoad (fires at login) nor KeepAlive
-- (fires on exit) fires on wake, so nothing recovers it. That left the Mac mic dead for 13 hours once,
-- with a "Listening" HUD pill frozen on screen.
--
-- Fix: gate on the actual wake event. On systemDidWake / screensDidUnlock, kickstart the service.
-- `launchctl kickstart` WITHOUT -k starts the job only if it isn't already running — verified a no-op
-- on a live listener (PID unchanged), so a healthy one is never bounced. Once the Mac is awake again,
-- launchd's normal KeepAlive takes over, so a single kick per wake is enough; the small delay lets
-- CoreAudio finish coming back before the listener reopens its capture stream.

local SERVICE = "gui/501/com.jaredgantt.voice-mac-listener"

local kickTask = nil   -- module-scope so Lua's GC can't reap an in-flight launchctl call
local function kickListener()
  kickTask = hs.task.new("/bin/launchctl", nil, { "kickstart", SERVICE })
  if kickTask then kickTask:start() end
end

local wakeTimer = nil   -- module-scope (GC rule)
local listenerWake = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock then
    if wakeTimer then wakeTimer:stop() end
    wakeTimer = hs.timer.doAfter(3, kickListener)   -- let audio HW settle post-wake
  end
end)
listenerWake:start()
