-- Voice HUD — a screen-level overlay pill showing the voice pipeline's live state on the Mac
-- (listening → working → done). Drawn as an hs.canvas at *overlay* window level with the
-- canJoinAllSpaces behavior, so it sits ON TOP of full-screen apps and ignores Focus / Do-Not-
-- Disturb entirely. That's the whole point: macOS notifications (the listener's old osascript
-- banner) are suppressed in full-screen + DnD and need Script Editor's notification permission,
-- so they showed nothing. A canvas window has none of those constraints.
--
-- Driven externally over the `hs` IPC CLI from the Mac listener / worker:
--     hs -c 'VoiceHUD("listening")'   -- mic open, capturing the command
--     hs -c 'VoiceHUD("working")'     -- handed off; worker is thinking / running tools (pulses)
--     hs -c 'VoiceHUD("done")'        -- reply landed; lingers ~2.5s then fades
--     hs -c 'VoiceHUD("error")'       -- something failed; lingers then fades
--     hs -c 'VoiceHUD("off")'         -- hide now

-- module-scope refs (CLAUDE.md GC rule: timers/canvas must survive collection)
local hud = nil
local pulseTimer = nil
local hideTimer = nil

local W, H = 168, 44
local MARGIN = 16

local STATES = {
  listening = { label = "Listening",  color = { red = 0.30, green = 0.65, blue = 1.00 } },  -- blue
  working   = { label = "Working\u{2026}", color = { red = 1.00, green = 0.72, blue = 0.20 } }, -- amber
  done      = { label = "Done",       color = { red = 0.30, green = 0.85, blue = 0.45 } },  -- green
  error     = { label = "Error",      color = { red = 1.00, green = 0.35, blue = 0.35 } },  -- red
  locked    = { label = "Hearing you", color = { red = 0.15, green = 0.90, blue = 0.55 } }, -- vivid green: speaker-ID confirmed it's Jared, live
}

local function hudFrame()
  -- top-right corner, just below the menu bar — macOS's own notification spot, rarely clickable
  local sf = hs.screen.primaryScreen():fullFrame()
  return { x = sf.x + sf.w - W - MARGIN, y = sf.y + MARGIN + 24, w = W, h = H }
end

local function ensure()
  if hud then return end
  hud = hs.canvas.new(hudFrame())
  -- screenSaver level: 'overlay' (102) renders on normal Spaces but full-screen app content still
  -- covered it. screenSaver (1000) sits above everything but the cursor — fine for a tiny
  -- non-interactive pill.
  hud:level(hs.canvas.windowLevels.screenSaver)
  -- fullScreenAuxiliary is what ADMITS a window into full-screen Spaces at all —
  -- canJoinAllSpaces alone only covers normal Spaces, which is why the HUD vanished
  -- whenever a window was full-screen.
  hud:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  hud:clickActivating(false)                           -- never steal focus from the front app
  hud[1] = { type = "rectangle", action = "fill",
             roundedRectRadii = { xRadius = H / 2, yRadius = H / 2 },
             fillColor = { red = 0.07, green = 0.07, blue = 0.09, alpha = 0.93 } }
  hud[2] = { type = "circle", center = { x = 26, y = H / 2 }, radius = 8,
             fillColor = STATES.listening.color }       -- status dot
  hud[3] = { type = "text", text = "", frame = { x = 46, y = 12, w = W - 54, h = 22 },
             textColor = { white = 1 }, textSize = 15 }
end

local function stopTimers()
  if pulseTimer then pulseTimer:stop(); pulseTimer = nil end
  if hideTimer then hideTimer:stop(); hideTimer = nil end
end

-- global so `hs -c 'VoiceHUD("…")'` can reach it
function VoiceHUD(state)
  ensure()
  stopTimers()

  if state == nil or state == "off" or state == "idle" then
    hud:hide()
    return
  end

  local s = STATES[state] or STATES.working
  hud[2].fillColor = s.color
  hud[2].radius = 8
  hud[3].text = s.label
  hud:show()

  if state == "working" then
    local big = true                                   -- pulse the dot: obviously "in progress"
    pulseTimer = hs.timer.doEvery(0.5, function()
      if not hud then return end
      hud[2].radius = big and 11 or 6
      big = not big
    end)
  elseif state == "done" or state == "error" then
    hideTimer = hs.timer.doAfter(2.5, function()
      if hud then hud:hide() end
    end)
  end
end
