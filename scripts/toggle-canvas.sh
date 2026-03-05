#!/bin/bash
# Toggle canvas video display in the Spotify visualizer overlay

STATE_LYRICS="/tmp/qs-viz-lyrics"
STATE_CANVAS="/tmp/qs-viz-canvas"

# Initialize state files if missing
[[ -f "$STATE_LYRICS" ]] || echo "ON" > "$STATE_LYRICS"
[[ -f "$STATE_CANVAS" ]] || echo "ON" > "$STATE_CANVAS"

# Flip canvas state
current=$(cat "$STATE_CANVAS")
if [[ "$current" == "ON" ]]; then
    echo "OFF" > "$STATE_CANVAS"
else
    echo "ON" > "$STATE_CANVAS"
fi

qs -c spotify-visualizer ipc call toggleCanvas handle

# Print both states
echo "Lyrics: $(cat $STATE_LYRICS) | Canvas: $(cat $STATE_CANVAS)"
