#!/bin/bash
# Open a new Claude Code session in a new tmux window.
# Each call opens a fresh Claude instance. The tmux session 'claude'
# is created on first run; subsequent runs add a new window to it.
if tmux has-session -t claude 2>/dev/null; then
    tmux new-window -t claude -c ~/workspace \; send-keys 'claude --dangerously-skip-permissions' Enter
else
    tmux new-session -s claude -c ~/workspace \; send-keys 'claude --dangerously-skip-permissions' Enter
fi
