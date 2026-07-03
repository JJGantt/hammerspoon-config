-- Hammerspoon config — each module is a separate file
require("hs.ipc")  -- enables the `hs` CLI message port (used by speak.sh → conversationListen)
require("voice")
require("windows")
require("topbar")
require("voicehud")
require("voicelistener")

-- Ctrl+Alt+Cmd+R to reload
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "R", hs.reload)

hs.alert.show("Hammerspoon loaded")
