#!/usr/bin/env python3
"""
beats.py — Spotify beat detector for QuickShell visualizer
Detects kicks (DSP low bandpass) and snares (DSP high bandpass + spectral flux)
from live audio. Uses only scipy + numpy — no madmom required.
Prints "BEAT <strength>" to stdout. QuickShell reads this via Process{}.
"""

import subprocess as sp
import numpy as np
import sys
import time
import collections
from scipy.signal import butter, sosfilt, sosfilt_zi

# ── CONFIG (tune these if beats feel off) ────────────────────────────────────
SAMPLE_RATE     = 48000   # native PipeWire rate
HOP_SIZE        = 256     # samples per chunk (~5.3ms at 48kHz) — halved for instant snap

# Layer 1 — 808 / Kick detector
# Full sub-bass band: 40–120 Hz catches the entire 808 fundamental range
KICK_LOW        = 40      # Hz — bottom of 808 sub-bass (was 80, too narrow)
KICK_HIGH       = 120     # Hz — top of 808 / kick body
KICK_THRESH     = 6.0     # spike ratio vs rolling avg (lower = more sensitive)
                          # 8.0 = heavy hits only | 5.0 = most kicks | 10+ = only drops
KICK_AVG_WIN    = 80      # 80 hops × 5.3ms = 426ms baseline (doubled since HOP_SIZE halved)
KICK_MIN_ABS    = 0.015   # absolute RMS floor — prevents quiet-section false fires

# Layer 2 — Snare / Clap detector
# Re-enabled — Phonk claps live in the 800–5000 Hz band as sharp spectral flux spikes
SNARE_LOW       = 800     # Hz — snare fundamental
SNARE_HIGH      = 5000    # Hz — clap/snare transient body (excludes hi-hat steady hiss)
SNARE_THRESH    = 20.0     # flux spike ratio — lower to 3.5 if missing snares
                          # raise to 7.0 if hi-hats still trigger
SNARE_AVG_WIN   = 40      # 40 hops × 5.3ms = 213ms baseline (doubled with hop change)
SNARE_MIN_ABS   = 0.005   # absolute floor for snare band — prevents silence false fires

# Output strengths — 808 biggest, snare medium
KICK_STRENGTH   = 1.00    # 808/kick — full dramatic pulse
SNARE_STRENGTH  = 0.60    # snare/clap — medium pulse
BOTH_STRENGTH   = 1.00    # simultaneous hit — full strength

# Cooldown — 220ms allows kick(beat1) then snare(half-beat later) to both fire
# At 130 BPM: half-beat = 230ms, so 220ms gate lets both through without blocking
# Raise to 350 if still double-firing | lower to 150 for very fast BPM
COOLDOWN_MS     = 180

# Silence gate — background hiss threshold
SILENCE_GATE    = 0.001   # rms below this = silence, skip chunk


# ── DYNAMIC SINK LOOKUP ──────────────────────────────────────────────────────
def find_active_monitor():
    """Find the .monitor source for the sink Spotify is currently playing on."""
    import re
    try:
        sink_inputs = sp.check_output(["pactl", "list", "sink-inputs"],
                                      stderr=sp.DEVNULL).decode()
        spotify_sink_id = None
        is_spotify = False
        for line in sink_inputs.splitlines():
            line = line.strip()
            if re.match(r"Sink Input #(\d+)", line):
                is_spotify = False
            if "application.name" in line and "spotify" in line.lower():
                is_spotify = True
            if is_spotify and line.startswith("Sink:"):
                spotify_sink_id = line.split("Sink:")[-1].strip()
                break

        if spotify_sink_id:
            sinks = sp.check_output(["pactl", "list", "sinks", "short"],
                                    stderr=sp.DEVNULL).decode()
            for line in sinks.splitlines():
                parts = line.split()
                if parts and parts[0] == spotify_sink_id:
                    return parts[1] + ".monitor"
    except Exception as e:
        print(f"ERROR find_active_monitor: {e}", file=sys.stderr, flush=True)

    # Fallback: first RUNNING .monitor
    try:
        sources = sp.check_output(["pactl", "list", "sources", "short"],
                                  stderr=sp.DEVNULL).decode()
        for line in sources.splitlines():
            parts = line.split()
            if len(parts) >= 2 and ".monitor" in parts[1] and parts[-1] == "RUNNING":
                return parts[1]
        for line in sources.splitlines():
            parts = line.split()
            if len(parts) >= 2 and ".monitor" in parts[1]:
                return parts[1]
    except Exception:
        pass

    return "@DEFAULT_MONITOR@"


# ── MAIN ─────────────────────────────────────────────────────────────────────
def main():
    sink = find_active_monitor()
    print(f"INFO monitor={sink}", file=sys.stderr, flush=True)

    cmd = ["parec",
           "--device",       sink,
           "--format",       "s16le",
           "--rate",         str(SAMPLE_RATE),
           "--channels",     "2",
           "--latency-msec", "10"]  # 10ms pipeline latency for instant snap (was 30)

    bytes_per_chunk = HOP_SIZE * 2 * 2  # hop * channels * 2 bytes/sample

    # Design kick filter (40–200 Hz bandpass)
    nyq = SAMPLE_RATE / 2
    sos_kick = butter(4,
                      [KICK_LOW / nyq, KICK_HIGH / nyq],
                      btype='bandpass', output='sos')

    # Design snare filter (800–5000 Hz bandpass)
    sos_snare = butter(4,
                       [SNARE_LOW / nyq, SNARE_HIGH / nyq],
                       btype='bandpass', output='sos')

    print("INFO DSP filters ready (scipy-only, no madmom)", file=sys.stderr, flush=True)

    while True:
        # Reset per-stream state on each (re)start
        zi_kick   = sosfilt_zi(sos_kick)  * 0
        zi_snare  = sosfilt_zi(sos_snare) * 0
        kick_avg  = collections.deque(maxlen=KICK_AVG_WIN)
        snare_avg = collections.deque(maxlen=SNARE_AVG_WIN)
        prev_snare_rms = 0.0
        last_beat = 0.0

        try:
            proc = sp.Popen(cmd, stdout=sp.PIPE, stderr=sp.DEVNULL)

            while True:
                raw = proc.stdout.read(bytes_per_chunk)
                if not raw or len(raw) < bytes_per_chunk:
                    if proc.poll() is not None:
                        print("INFO parec exited, restarting", file=sys.stderr, flush=True)
                        break
                    continue

                # stereo s16le → mono float32 [-1, 1]
                s16  = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
                mono = (s16[0::2] + s16[1::2]) / 2.0 / 32768.0
                chunk = mono[:HOP_SIZE]

                # Silence gate
                rms = float(np.sqrt(np.mean(chunk ** 2)))
                if rms < SILENCE_GATE:
                    kick_avg.append(0.0)
                    snare_avg.append(0.0)
                    prev_snare_rms = 0.0
                    continue

                # ── Layer 1: DSP kick (40–200 Hz energy spike) ────────────
                filtered_kick, zi_kick = sosfilt(sos_kick, chunk, zi=zi_kick)
                kick_rms = float(np.sqrt(np.mean(filtered_kick ** 2)))
                kick_mean = float(np.mean(kick_avg)) if kick_avg else 0.0
                kick_fire = (kick_rms > kick_mean * KICK_THRESH   # relative spike
                             and kick_mean > 0.0001                # baseline not silence
                             and kick_rms  > KICK_MIN_ABS)         # absolute floor gate
                kick_avg.append(kick_rms)

                # ── Layer 2: DSP snare (800–5000 Hz spectral flux) ────────
                # Spectral flux = rate of energy increase in the snare band.
                # A snare/clap produces a sharp positive energy spike; pure
                # hi-hats have lower flux because their energy is more steady.
                filtered_snare, zi_snare = sosfilt(sos_snare, chunk, zi=zi_snare)
                snare_rms = float(np.sqrt(np.mean(filtered_snare ** 2)))
                snare_flux = max(0.0, snare_rms - prev_snare_rms)  # positive-only flux
                snare_mean = float(np.mean(snare_avg)) if snare_avg else 0.0
                snare_fire = (snare_flux > snare_mean * SNARE_THRESH
                              and snare_mean > 0.00005
                              and snare_rms  > SNARE_MIN_ABS)
                snare_avg.append(snare_flux)
                prev_snare_rms = snare_rms

                # ── Combiner ──────────────────────────────────────────────
                if kick_fire or snare_fire:
                    now = time.monotonic()
                    if (now - last_beat) * 1000 >= COOLDOWN_MS:
                        if kick_fire and snare_fire:
                            strength = BOTH_STRENGTH
                        elif kick_fire:
                            strength = KICK_STRENGTH
                        else:
                            strength = SNARE_STRENGTH
                        print(f"BEAT {strength:.2f}", flush=True)
                        last_beat = now

        except Exception as e:
            print(f"ERROR {e}", file=sys.stderr, flush=True)
            try:
                proc.kill()
            except Exception:
                pass

        time.sleep(1.0)


if __name__ == "__main__":
    main()
