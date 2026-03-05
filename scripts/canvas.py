#!/usr/bin/env python3
# canvas.py — Fetch Spotify Canvas MP4 URL for the current track
#
# Usage:
#   python3 canvas.py                   → prints CANVAS_URL <url>  or  CANVAS_NONE
#   python3 canvas.py spotify:track:ID  → fetch for a specific track URI
#
# Auth flow:
#   Uses librespot stored credentials from ~/.cache/spotify-player/credentials.json
#   No browser auth or sp_dc cookie required — works with existing spotify-player creds.
#
# Requires:  pip install librespot --break-system-packages

import sys, os, json, urllib.request, struct, subprocess

CREDENTIALS_FILE = os.path.expanduser("~/.cache/spotify-player/credentials.json")
CANVAS_URL  = "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases"
CANVAS_PATH = "/tmp/spotify-canvas.mp4"

# ── Token management via librespot ───────────────────────────────────────────

def get_valid_token():
    """Authenticate using stored librespot credentials and return a Bearer token."""
    if not os.path.exists(CREDENTIALS_FILE):
        print(f"CANVAS_ERROR no_credentials:{CREDENTIALS_FILE} not found", flush=True)
        sys.exit(1)
    try:
        from librespot.core import Session
        session = Session.Builder()\
            .stored_file(CREDENTIALS_FILE)\
            .create()
        return session.tokens().get("user-read-playback-state")
    except Exception as e:
        print(f"CANVAS_ERROR librespot_auth:{e}", flush=True)
        sys.exit(1)

# ── Protobuf helpers — hand-rolled (no protobuf library needed) ───────────────
# Spotify Canvas endpoint uses a minimal protobuf request:
#   message CanvazRequest  { repeated EntityCanvazRequest entities = 1; }
#   message EntityCanvazRequest { string entity_uri = 1; }
# We only need field tag + wire type + length-delimited string encoding.

def _varint(n):
    """Encode a non-negative integer as varint bytes."""
    buf = []
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            buf.append(b | 0x80)
        else:
            buf.append(b)
            break
    return bytes(buf)

def _pb_string(field_num, value: str) -> bytes:
    """Encode a protobuf length-delimited string field."""
    encoded = value.encode("utf-8")
    tag     = _varint((field_num << 3) | 2)   # wire type 2 = length-delimited
    return tag + _varint(len(encoded)) + encoded

def build_canvas_request(track_uri: str) -> bytes:
    """
    Build the protobuf body for CanvazRequest with a single entity.
    EntityCanvazRequest.entity_uri = track_uri (field 1)
    CanvazRequest.entities         = [entity]  (field 1)
    """
    inner = _pb_string(1, track_uri)           # EntityCanvazRequest { entity_uri }
    outer = _pb_string(1, inner.decode("latin-1"))  # CanvazRequest { entities }
    # The inner message is embedded as raw bytes, not a UTF-8 string.
    # Re-encode correctly: tag + varint(len) + raw_bytes
    inner_bytes = inner
    outer_tag   = _varint((1 << 3) | 2)
    return outer_tag + _varint(len(inner_bytes)) + inner_bytes

def parse_canvas_url(data: bytes) -> str:
    """
    Minimal protobuf parser to extract the canvas URL from CanvazResponse.
    CanvazResponse.canvases[0].canvas_url = string field 2 inside field 1.
    We walk the binary and find the first http/https URL.
    """
    # Simple scan: find any null-terminated or length-prefixed URL in the blob
    try:
        text = data.decode("latin-1")
        for i, ch in enumerate(text):
            if text[i:i+4] == "http":
                end = i
                while end < len(text) and ord(text[end]) >= 0x20 and text[end] not in (' ', '\n', '\r', '\x00'):
                    end += 1
                url = text[i:end]
                if url.endswith(".mp4") or "video" in url or "canvas" in url:
                    return url
    except Exception:
        pass
    return ""

# ── Main fetch logic ──────────────────────────────────────────────────────────

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

def fetch_canvas(track_uri: str, access_token: str) -> str:
    """Call Spotify's Canvas endpoint. Returns MP4 URL or empty string."""
    pb_body = build_canvas_request(track_uri)

    req = urllib.request.Request(
        CANVAS_URL,
        data=pb_body,
        method="POST",
        headers={
            "Authorization":  f"Bearer {access_token}",
            "Content-Type":   "application/x-protobuf",
            "Accept":         "application/x-protobuf",
            "User-Agent":     "Spotify/8.9.0 iOS/16 (iPhone13,2)",
            "spotify-app-version": "8.9.0.765",
            "App-Platform":   "iOS",
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            data = r.read()
        return parse_canvas_url(data)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")[:200]
        print(f"CANVAS_ERROR http_{e.code}:{err_body}", flush=True)
        return ""
    except Exception as e:
        print(f"CANVAS_ERROR fetch:{e}", flush=True)
        return ""

def download_canvas(url: str) -> bool:
    """Download canvas MP4 to /tmp/spotify-canvas.mp4. Returns True on success."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Spotify/8.9.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            data = r.read()
        with open(CANVAS_PATH, "wb") as f:
            f.write(data)
        return len(data) > 1024
    except Exception as e:
        print(f"CANVAS_ERROR download:{e}", flush=True)
        return False

# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    track_uri = sys.argv[1] if len(sys.argv) > 1 else get_track_uri()
    if not track_uri:
        print("CANVAS_NONE no_track", flush=True)
        return

    access_token = get_valid_token()
    canvas_url   = fetch_canvas(track_uri, access_token)

    if canvas_url:
        ok = download_canvas(canvas_url)
        if ok:
            print(f"CANVAS_URL {canvas_url}", flush=True)
            print(f"CANVAS_FILE {CANVAS_PATH}", flush=True)
        else:
            print("CANVAS_ERROR download_failed", flush=True)
    else:
        print("CANVAS_NONE no_canvas_for_track", flush=True)

if __name__ == "__main__":
    main()
