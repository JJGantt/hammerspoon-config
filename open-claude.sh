#!/bin/bash
# Open a new Claude Code session inside a fresh tmux session.
# exec replaces this shell with tmux — the Terminal tab IS the tmux session.
# Unique session name per tab so sessions never interfere with each other.
SESSION="claude-$(date +%s)"
exec tmux new-session -s "$SESSION" -c "$HOME/workspace" \; send-keys 'claude --dangerously-skip-permissions' Enter
