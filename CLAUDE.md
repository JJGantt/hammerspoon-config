# Hammerspoon Config

macOS automation via Hammerspoon. Each feature is its own Lua module,
loaded by `init.lua` with `require("module_name")`.

## Structure
- `init.lua` — entry point, loads modules, global hotkeys (reload)
- `voice.lua` — voice transcription (sox + whisper.cpp)
- New modules: create `feature.lua`, add `require("feature")` to init.lua

## Rules
- Every `hs.task`, `hs.timer`, `hs.eventtap`, and `hs.caffeinate.watcher`
  MUST be stored in a module-scope variable. Lua's GC will kill orphaned
  objects and silently break things (symptom: a feature works once, then
  dies after idle).
- Keep modules self-contained. Each module starts its own taps/timers
  and doesn't depend on other modules.

## Failures go to the ops responder
- A failure is `report(msg, context)` in voice.lua, never a bare `log("WARN …")`: it logs and runs
  `~/repos/health/responder/bin/ops error hammerspoon-voice …`, which opens an incident. A plain log
  line is only for a fallback that already handled it.
- keepAliveTick sends `ops beat hammerspoon-voice 300`, so Hammerspoon dying shows as a missed beat.
