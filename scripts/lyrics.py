#!/usr/bin/env python3
"""
lyrics.py — Fetch synced lyrics from Spotify's internal color-lyrics API.

Uses the same librespot credentials as canvas.py — no sp_dc cookie needed.
Gets the current track URI from playerctl, then hits:
  GET spclient.wg.spotify.com/color-lyrics/v2/track/{track_id}

Output:
  LYRICS_DATA [{\"t\": <ms>, \"text\": \"<line>\"}, ...]
  LYRICS_NONE   (instrumental, no synced lyrics, or error)
"""

import sys, os, json, urllib.request, subprocess

CREDENTIALS_FILE = os.path.expanduser("~/.cache/spotify-player/credentials.json")
LYRICS_URL = "https://spclient.wg.spotify.com/color-lyrics/v2/track/{track_id}?format=json&vocalRemoval=false&market=from_token"


def get_valid_token() -> str:
    """Authenticate using stored librespot credentials and return a Bearer token."""
    if not os.path.exists(CREDENTIALS_FILE):
        print(f"LYRICS_NONE no_credentials", flush=True)
        sys.exit(0)
    try:
        from librespot.core import Session
        session = Session.Builder()\
            .stored_file(CREDENTIALS_FILE)\
            .create()
        return session.tokens().get("user-read-playback-state")
    except Exception as e:
        print(f"LYRICS_NONE librespot_error:{e}", flush=True)
        sys.exit(0)


def get_track_uri() -> str:
    """Get current Spotify track URI from playerctl."""
    try:
        raw = subprocess.check_output(
            ["playerctl", "--player=spotify", "metadata", "mpris:trackid"],
            stderr=subprocess.DEVNULL
        ).decode().strip()
        # Convert /com/spotify/track/XXXX → spotify:track:XXXX
        if raw.startswith("/com/spotify/"):
            parts = raw.strip("/").split("/")
            return f"spotify:{':'.join(parts[2:])}"
        return raw
    except Exception:
        return ""


def fetch_lyrics(track_id: str, token: str) -> None:
    url = LYRICS_URL.format(track_id=track_id)
    req = urllib.request.Request(
        url,
        headers={
            "Authorization":       f"Bearer {token}",
            "User-Agent":          "Spotify/8.9.0 iOS/16 (iPhone13,2)",
            "App-Platform":        "iOS",
            "spotify-app-version": "8.9.0.765",
            "Accept":              "application/json",
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"LYRICS_NONE http_{e.code}", flush=True)
        return
    except Exception as e:
        print(f"LYRICS_NONE fetch_error:{e}", flush=True)
        return

    lyrics = data.get("lyrics", {})
    sync_type = lyrics.get("syncType", "")

    # Only LINE_SYNCED is useful — UNSYNCED has no timestamps
    if sync_type != "LINE_SYNCED":
        print("LYRICS_NONE not_synced", flush=True)
        return

    lines = []
    for line in lyrics.get("lines", []):
        text = (line.get("words") or "").strip()
        try:
            t = int(line.get("startTimeMs", 0))
        except (ValueError, TypeError):
            t = 0
        # Skip empty lines and "♪" instrumental markers
        if text and text != "♪":
            lines.append({"t": t, "text": text})

    if lines:
        print("LYRICS_DATA " + json.dumps(lines), flush=True)
    else:
        print("LYRICS_NONE empty", flush=True)


def main():
    track_uri = get_track_uri()
    if not track_uri:
        print("LYRICS_NONE no_track", flush=True)
        return

    # Extract track ID from URI: spotify:track:XXXX → XXXX
    parts = track_uri.split(":")
    if len(parts) < 3 or parts[1] != "track":
        print(f"LYRICS_NONE bad_uri:{track_uri}", flush=True)
        return
    track_id = parts[2]

    token = get_valid_token()
    fetch_lyrics(track_id, token)


if __name__ == "__main__":
    main()

