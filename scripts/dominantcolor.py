#!/usr/bin/env python3
"""
dominantcolor.py — Extract the most vivid dominant color from an album art URL.
Usage: python3 dominantcolor.py <image_url_or_path>
Output: "COLOR r g b"  (integers 0–255)
Used by shell.qml to dynamically color cava bars to match album art.
"""

import sys
import urllib.request
import tempfile
import os
import colorsys

def get_dominant_color(path):
    from PIL import Image

    img = Image.open(path).convert("RGB")
    # Resize to small thumbnail for fast processing
    img = img.resize((64, 64), Image.LANCZOS)

    # Quantize to 8 palette colors (fast k-means via PIL median cut)
    quantized = img.quantize(colors=8, method=Image.Quantize.MEDIANCUT)
    palette_raw = quantized.getpalette()  # flat [r,g,b, r,g,b, ...]

    # Build list of (count, r, g, b) per palette color
    import numpy as np
    color_counts = {}
    pixels = np.array(quantized).flatten()
    for p in pixels:
        color_counts[int(p)] = color_counts.get(int(p), 0) + 1

    candidates = []
    for idx, count in color_counts.items():
        r = palette_raw[idx * 3]
        g = palette_raw[idx * 3 + 1]
        b = palette_raw[idx * 3 + 2]
        candidates.append((count, r, g, b))

    # Score each candidate: prefer vivid colors over near-black/white/grey
    best = None
    best_score = -1
    for count, r, g, b in candidates:
        h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
        # Skip near-black (dark) and near-white (too bright + low saturation)
        if v < 0.15:                  # too dark
            continue
        if v > 0.92 and s < 0.15:    # near-white grey
            continue
        # Score = saturation * sqrt(value) * log(count+1)
        # Weights vividness heavily, frequency lightly
        import math
        score = s * (v ** 0.5) * math.log(count + 1)
        if score > best_score:
            best_score = score
            best = (r, g, b)

    if best is None:
        # Fallback: just pick the most frequent color
        candidates.sort(reverse=True)
        best = (candidates[0][1], candidates[0][2], candidates[0][3])

    return best


def main():
    if len(sys.argv) < 2:
        print("COLOR 100 181 255", flush=True)  # default blue
        return

    source = sys.argv[1].strip()
    if not source:
        print("COLOR 100 181 255", flush=True)
        return

    tmp = None
    try:
        if source.startswith("http://") or source.startswith("https://"):
            # Download to temp file
            tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
            tmp.close()
            urllib.request.urlretrieve(source, tmp.name)
            path = tmp.name
        elif source.startswith("file://"):
            path = source[7:]
        else:
            path = source

        r, g, b = get_dominant_color(path)
        print(f"COLOR {r} {g} {b}", flush=True)

    except Exception as e:
        print(f"ERROR {e}", file=sys.stderr, flush=True)
        print("COLOR 100 181 255", flush=True)  # fallback blue
    finally:
        if tmp and os.path.exists(tmp.name):
            os.unlink(tmp.name)


if __name__ == "__main__":
    main()
