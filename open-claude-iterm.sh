#!/bin/bash
# Called by Hammerspoon when iTerm2 is frontmost.
# $1 = TTY of the current iTerm2 session (e.g. /dev/ttys004)
#
# If that TTY has a tmux client attached, opens a new tmux window in that session.
# Otherwise falls back to open-claude.sh (creates a fresh tmux session).

TTY="$1"
TMUX="/opt/homebrew/bin/tmux"
WORKSPACE="$HOME/workspace"

SESSION=""
if [ -n "$TTY" ]; then
    SESSION=$("$TMUX" list-clients -F "#{client_tty} #{session_name}" 2>/dev/null \
        | grep "^$TTY " | awk '{print $2}')
fi

if [ -n "$SESSION" ]; then
    WINDOW="claude-$(date +%s)"
    "$TMUX" new-window -t "$SESSION" -n "$WINDOW" -c "$WORKSPACE"
    "$TMUX" send-keys -t "$SESSION:$WINDOW" "claude --dangerously-skip-permissions" Enter
else
    exec "$HOME/.hammerspoon/open-claude.sh"
fi
