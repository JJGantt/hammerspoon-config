-- Hammerspoon config — each module is a separate file
require("hs.ipc")  -- enables the `hs` CLI message port (used by speak.sh → conversationListen)
require("voice")
require("windows")
require("topbar")
require("voicehud")
require("voicelistener")
-- Reading a Claude session's tab on screen marks its reply read everywhere (session-read.lua).
require("session-read").start()

-- Ctrl+Alt+Cmd+R to reload
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "R", hs.reload)

hs.alert.show("Hammerspoon loaded")

