#!/bin/bash
# Toggle lyrics display in the Spotify visualizer overlay

STATE_LYRICS="/tmp/qs-viz-lyrics"
STATE_CANVAS="/tmp/qs-viz-canvas"

# Initialize state files if missing
[[ -f "$STATE_LYRICS" ]] || echo "ON" > "$STATE_LYRICS"
[[ -f "$STATE_CANVAS" ]] || echo "ON" > "$STATE_CANVAS"

# Flip lyrics state
current=$(cat "$STATE_LYRICS")
if [[ "$current" == "ON" ]]; then
    echo "OFF" > "$STATE_LYRICS"
else
    echo "ON" > "$STATE_LYRICS"
fi

qs -c spotify-visualizer ipc call toggleLyrics handle

# Print both states
echo "Lyrics: $(cat $STATE_LYRICS) | Canvas: $(cat $STATE_CANVAS)"
