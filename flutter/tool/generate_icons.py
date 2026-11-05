"""Generate the Lexumo launcher icon set for the Flutter app.

Design: two materials, one shell — the same idea the app is built on.

    A dark stone frame (`--frame`) holds a light paper sheet (`--bg`). Down the
    left edge of the sheet runs an azurite spine (`--accent`), and a single ink
    dot sits on the paper: the mark of the one word you are on right now.

No gradients, no drop shadow, no second accent hue. The icon is the sidebar
brand mark with the paper showing through, so the launcher tile and the in-app
logo read as one thing.

Two drawings, not one. At 16px the spine lands on 1.4 pixels and the dot on
1.2, so both turn to grey mush; a simplified variant widens the spine, drops
the dot and thickens the stone wall for that size only. Every careful icon set
does this — one drawing where the details survive, one where they cannot.

Everything is drawn at 1024px and downsampled with LANCZOS.

Usage:
    python generate_icons.py           # writes every size into the app trees
    python generate_icons.py --check   # prints the geometry, writes nothing

Requires Pillow. Outputs (paths relative to the repo root):
    flutter/windows/runner/resources/app_icon.ico   16/32/48/64/128/256
    flutter/android/app/src/main/res/mipmap-mdpi/ic_launcher.png     48
    flutter/android/app/src/main/res/mipmap-hdpi/ic_launcher.png     72
    flutter/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png    96
    flutter/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png   144
    flutter/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png  192

Regeneration is a no-op on a clean tree *by eye*: the Windows `.ico` comes back
byte-identical, and the Android PNGs come back pixel-identical but with different
bytes, because Pillow's PNG encoder has changed since they were committed — so
check icon changes by comparing pixels, never by comparing file hashes. Run it
after changing the geometry below, then commit the result; nothing regenerates
these files during a build.
"""

from __future__ import annotations

import io
import os
import struct
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)          # flutter/
ROOT = os.path.dirname(APP)          # repo root
MASTER = 1024

# Palette — the app's own tokens, not new colours.
#   flutter/lib/ui/core/tokens.dart: Palette.frame, .bg, .line, .accent, .ink
STONE = (0x25, 0x2C, 0x28)        # --frame  #252c28
PAPER = (0xF9, 0xF7, 0xF3)        # --bg     #f9f7f3
PAPER_EDGE = (0xE0, 0xDE, 0xD7)   # --line   #e0ded7, where the paper meets stone
AZURITE = (0x17, 0x5B, 0x72)      # --accent #175b72
INK = (0x1E, 0x22, 0x1E)          # --ink    #1e221e

# Geometry, as fractions. Each one is a decision, so each one has a reason.
MARGIN = 0.100        # stone frame's outer edge; leaves the shell room to round it
FRAME_RADIUS = 0.220  # of the frame, not the canvas
PAPER_INSET = 0.130   # of the frame — the stone wall. Thinner and the frame
                      # vanishes when the shell draws us at 16px.
PAPER_RADIUS = 0.150  # of the paper — a sheet's corner is tighter than the
                      # frame's, or the two roundings fight each other
SPINE_W = 0.150       # of the paper
SPINE_INSET = 0.150   # of the paper, from its left edge
SPINE_Y = 0.170       # of the paper, top and bottom margin of the spine
DOT = 0.130           # of the paper, diameter

# The small-size variant.
SIMPLE_WALL_EXTRA = 0.045   # of the frame, added to PAPER_INSET
SIMPLE_SPINE_SCALE = 1.55   # of SPINE_W
SIMPLE_BELOW = 32           # px — this variant is used strictly below it

# Sizes the Windows shell asks for when it draws the .ico.
ICO_SIZES = [16, 32, 48, 64, 128, 256]

# Android's launcher densities, as the mipmap directory and its pixel size. These
# are the 48dp baseline scaled by each bucket (mdpi 1x, hdpi 1.5x, …).
ANDROID_DENSITIES = [
    ("mipmap-mdpi", 48),
    ("mipmap-hdpi", 72),
    ("mipmap-xhdpi", 96),
    ("mipmap-xxhdpi", 144),
    ("mipmap-xxxhdpi", 192),
]

ICO_PATH = os.path.join("flutter", "windows", "runner", "resources", "app_icon.ico")
ANDROID_DIR = os.path.join(
    "flutter", "android", "app", "src", "main", "res"
)


def geometry(simple: bool = False) -> dict[str, int]:
    frame = round(MASTER * (1 - 2 * MARGIN))
    origin = (MASTER - frame) // 2
    wall = round(frame * (PAPER_INSET + (SIMPLE_WALL_EXTRA if simple else 0)))
    paper = frame - 2 * wall
    paper_origin = origin + wall
    return {
        "frame": frame,
        "frame_origin": origin,
        "frame_radius": round(frame * FRAME_RADIUS),
        "wall": wall,
        "paper": paper,
        "paper_origin": paper_origin,
        "paper_radius": round(paper * PAPER_RADIUS),
        "spine_w": round(paper * SPINE_W * (SIMPLE_SPINE_SCALE if simple else 1)),
        "spine_x": paper_origin + round(paper * SPINE_INSET),
        "spine_y0": paper_origin + round(paper * SPINE_Y),
        "spine_y1": paper_origin + paper - round(paper * SPINE_Y),
        "dot_d": 0 if simple else round(paper * DOT),
    }


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=radius, fill=255
    )
    return mask


def build_master(simple: bool = False) -> Image.Image:
    g = geometry(simple)
    canvas = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))

    # Stone frame.
    frame_layer = Image.new("RGBA", (g["frame"], g["frame"]), STONE + (255,))
    frame_layer.putalpha(rounded_mask(g["frame"], g["frame_radius"]))
    canvas.alpha_composite(frame_layer, (g["frame_origin"], g["frame_origin"]))

    # Paper sheet, inset so the stone reads as a wall of even thickness.
    paper_layer = Image.new("RGBA", (g["paper"], g["paper"]), PAPER + (255,))
    paper_layer.putalpha(rounded_mask(g["paper"], g["paper_radius"]))
    canvas.alpha_composite(paper_layer, (g["paper_origin"], g["paper_origin"]))

    draw = ImageDraw.Draw(canvas)

    # One hairline where paper meets stone. Without it the two flat fills merge
    # at 32px; with it the edge survives the downsample.
    draw.rounded_rectangle(
        [
            g["paper_origin"],
            g["paper_origin"],
            g["paper_origin"] + g["paper"] - 1,
            g["paper_origin"] + g["paper"] - 1,
        ],
        radius=g["paper_radius"],
        outline=PAPER_EDGE + (255,),
        width=max(1, MASTER // 512),
    )

    # Azurite spine down the left edge of the sheet — the accent's one job.
    draw.rounded_rectangle(
        [g["spine_x"], g["spine_y0"], g["spine_x"] + g["spine_w"], g["spine_y1"]],
        radius=g["spine_w"] // 2,
        fill=AZURITE + (255,),
    )

    # The word being learned: one ink dot, optically centred in the space the
    # spine leaves rather than in the sheet as a whole.
    if g["dot_d"]:
        r = g["dot_d"] // 2
        cx = (g["spine_x"] + g["spine_w"] + g["paper_origin"] + g["paper"]) // 2
        cy = (g["spine_y0"] + g["spine_y1"]) // 2
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=INK + (255,))

    return canvas


def render(master: Image.Image, simple: Image.Image, size: int) -> Image.Image:
    """Downsample the drawing that suits this size."""
    source = simple if size < SIMPLE_BELOW else master
    return source.resize((size, size), Image.LANCZOS)


def png_bytes(image: Image.Image) -> bytes:
    buf = io.BytesIO()
    image.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def ico_bytes(master: Image.Image, simple: Image.Image) -> bytes:
    """Assemble an .ico container by hand.

    Pillow's ICO writer rescales one image into every slot, which would throw
    away the simplified 16px drawing, and it cannot mix sources. The format is
    small enough to assemble directly: a 6-byte directory header, then one
    16-byte entry per image pointing at a PNG payload.
    """
    payloads = [png_bytes(render(master, simple, size)) for size in ICO_SIZES]
    header = struct.pack("<HHH", 0, 1, len(payloads))  # reserved, type=icon, count
    entries = bytearray()
    offset = len(header) + 16 * len(payloads)
    for size, payload in zip(ICO_SIZES, payloads):
        entries += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,  # width, 0 means 256
            size if size < 256 else 0,  # height
            0,                          # palette size
            0,                          # reserved
            1,                          # colour planes
            32,                         # bits per pixel
            len(payload),
            offset,
        )
        offset += len(payload)
    return header + bytes(entries) + b"".join(payloads)


def main() -> None:
    if "--check" in sys.argv:
        for flag, label in ((False, "full"), (True, "simple")):
            print(f"{label}:")
            for key, value in geometry(flag).items():
                print(f"  {key:>14} = {value:>4}px")
        return

    master = build_master(False)
    simple = build_master(True)

    ico = os.path.join(ROOT, ICO_PATH)
    os.makedirs(os.path.dirname(ico), exist_ok=True)
    with open(ico, "wb") as handle:
        handle.write(ico_bytes(master, simple))
    print(f"  {ICO_PATH}: {', '.join(f'{s}x{s}' for s in ICO_SIZES)}")

    for bucket, size in ANDROID_DENSITIES:
        path = os.path.join(ROOT, ANDROID_DIR, bucket, "ic_launcher.png")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(png_bytes(render(master, simple, size)))
        print(f"  android/…/{bucket}/ic_launcher.png: {size}x{size}")


if __name__ == "__main__":
    main()
