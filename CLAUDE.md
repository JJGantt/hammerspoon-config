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
  objects and silently break things. This was the root cause of the
  "works once then dies after idle" bug.
- Keep modules self-contained. Each module starts its own taps/timers
  and doesn't depend on other modules.
