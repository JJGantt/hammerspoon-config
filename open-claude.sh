#!/bin/bash
# Open or reattach to the main Claude Code tmux session.
# Called by Hammerspoon Cmd+/ hotkey.
if tmux has-session -t claude 2>/dev/null; then
    tmux attach -t claude
else
    tmux new-session -s claude -c ~/workspace \; send-keys 'claude --dangerously-skip-permissions' Enter
fi
