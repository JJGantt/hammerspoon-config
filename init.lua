-- Hammerspoon config — each module is a separate file
require("voice")
require("windows")

-- Ctrl+Alt+Cmd+R to reload
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "R", hs.reload)

hs.alert.show("Hammerspoon loaded")
