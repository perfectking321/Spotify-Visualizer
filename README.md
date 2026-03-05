# spotify-visualizer

Full-screen Spotify visualizer overlay for Hyprland, built with [QuickShell](https://quickshell.outfoxxed.me/) QML.

![preview](https://i.imgur.com/placeholder.png)

## Features

- Circular album art with 48 radial cava bars
- Dynamic glow color extracted from album art
- Breathing pulse animation driven by audio energy
- Top + bottom edge cava bar strips
- Spotify Canvas video (animated album artwork)
- Karaoke lyrics synced to playback position
- IPC toggle controls for lyrics and canvas
- Wayland layer-shell — passthrough (doesn't steal input)

## Requirements

| Package | Purpose |
|---------|---------|
| `quickshell` | QML shell runtime |
| `cava` | Audio visualizer (writes to FIFO) |
| `spotify-player` | Provides librespot credentials |
| `playerctl` | MPRIS track info |
| `pipewire` + `pipewire-pulse` | Audio capture for beat detection |
| `python` | Runs all scripts |
| `python-pillow` | Album art color extraction |
| `python-numpy` + `python-scipy` | Beat detection DSP |
| `librespot` (pip) | Spotify API auth (lyrics + canvas) |

Install pip dependency:
```bash
pip install librespot --break-system-packages
```

## File Structure

```
spotify-visualizer/
├── shell.qml              # Main QuickShell QML — entire UI
└── scripts/
    ├── beats.py           # Live beat detector (PipeWire → BEAT lines)
    ├── canvas.py          # Spotify Canvas video downloader
    ├── lyrics.py          # Synced lyrics fetcher (Spotify internal API)
    ├── dominantcolor.py   # Album art dominant color extractor
    ├── toggle-lyrics.sh   # Toggle lyrics display
    └── toggle-canvas.sh   # Toggle canvas video
```

## Setup

### 1. Install QuickShell

```bash
yay -S quickshell-git
```

### 2. Install cava

```bash
yay -S cava
```

### 3. Configure cava FIFO output

Create or edit `~/.config/cava/spotipaper.conf`:

```ini
[general]
bars = 48
framerate = 60

[smoothing]
monstercat = 1
noise_reduction = 55
gravity = 180

[output]
method = raw
raw_target = /tmp/cava-fifo
data_format = ascii
ascii_max_range = 100
```

Start cava with this config:
```bash
cava -p ~/.config/cava/spotipaper.conf &
```

### 4. Place the files

```bash
# QML shell
mkdir -p ~/.config/quickshell/spotify-visualizer
cp shell.qml ~/.config/quickshell/spotify-visualizer/

# Python scripts + toggle scripts
cp scripts/*.py  ~/.config/hypr/scripts/
cp scripts/*.sh  ~/.config/hypr/scripts/
chmod +x ~/.config/hypr/scripts/toggle-lyrics.sh
chmod +x ~/.config/hypr/scripts/toggle-canvas.sh
```

### 5. Set up librespot credentials

The canvas and lyrics scripts use stored librespot credentials from `spotify-player`:

```bash
yay -S spotify-player
spotify_player  # run once to log in, then close it
```

Credentials will be saved at `~/.cache/spotify-player/credentials.json`.

### 6. Run the visualizer

```bash
quickshell -p ~/.config/quickshell/spotify-visualizer
```

Or add it to your Hyprland autostart:
```ini
# hyprland.conf
exec-once = cava -p ~/.config/cava/spotipaper.conf
exec-once = quickshell -p ~/.config/quickshell/spotify-visualizer
```

## Usage

### Toggle controls

```bash
# Toggle lyrics on/off
qs -c spotify-visualizer ipc call toggleLyrics handle

# Toggle canvas video on/off
qs -c spotify-visualizer ipc call toggleCanvas handle
```

Or use the provided scripts:
```bash
~/.config/hypr/scripts/toggle-lyrics.sh
~/.config/hypr/scripts/toggle-canvas.sh
```

Bind them in Hyprland:
```ini
# hyprland.conf
bind = $mainMod, L, exec, ~/.config/hypr/scripts/toggle-lyrics.sh
bind = $mainMod, K, exec, ~/.config/hypr/scripts/toggle-canvas.sh
```

## How It Works

```
cava (spotipaper.conf) ──► /tmp/cava-fifo ──► shell.qml (barValues[])
                                                     │
beats.py (PipeWire DSP) ──► BEAT 0.85 ──────────────┤
                                                     │
playerctl (MPRIS) ──────► track info ───────────────┤
                                                     │
dominantcolor.py ───────► COLOR r g b ─────────────►│ glowColor
                                                     │
lyrics.py ──────────────► LYRICS_DATA [...] ────────►│ karaoke display
                                                     │
canvas.py ──────────────► /tmp/spotify-canvas.mp4 ──►│ video overlay
```

## Troubleshooting

**No cava bars showing**
```bash
ls /tmp/cava-fifo       # must exist
cava -p ~/.config/cava/spotipaper.conf  # start cava
```

**No lyrics / canvas**
```bash
ls ~/.cache/spotify-player/credentials.json   # must exist
python3 ~/.config/hypr/scripts/lyrics.py      # test directly
python3 ~/.config/hypr/scripts/canvas.py      # test directly
```

**Beat detection not working**
```bash
python3 ~/.config/hypr/scripts/beats.py       # should print BEAT lines
pactl list sources short | grep monitor       # verify PipeWire monitor source
```
