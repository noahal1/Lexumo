"""Generate the Lexilo app icon set.

Design: warm paper background + jade-green (#0f6b5b) rounded square with a
paper-white serif "L". Everything is drawn at 1024px and downsampled with
LANCZOS so the small sizes stay crisp.

Usage:
    python generate-icons.py

Requires Pillow. Outputs (next to this script):
    icon.png (512), 32x32.png, 128x128.png, 128x128@2x.png (256),
    icon.ico (16/32/48/64/128/256)
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
MASTER = 1024

# Palette
PAPER = (247, 242, 232)
PAPER_LIGHT = (252, 248, 240)
PAPER_DARK = (236, 228, 214)
JADE_TOP = (18, 129, 110)     # lighter jade, keeps the mark from looking flat
JADE_BOTTOM = (13, 95, 82)    # deep jade
JADE_CORE = (15, 107, 91)     # #0f6b5b, the brand jade
LETTER = (251, 247, 238)      # paper white

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\georgia.ttf",
    r"C:\Windows\Fonts\cambria.ttc",
    r"C:\Windows\Fonts\times.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
    "/System/Library/Fonts/Supplemental/Georgia.ttf",
]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    raise SystemExit("No serif font found; edit FONT_CANDIDATES.")


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = color
    return img


def radial_paper(size: int) -> Image.Image:
    """Warm paper with a soft light centre and slightly darker edges."""
    base = Image.new("RGB", (size, size), PAPER)
    glow = Image.new("L", (size, size), 0)
    gd = ImageDraw.Draw(glow)
    steps = 64
    for i in range(steps, 0, -1):
        t = i / steps
        r = int(size * 0.62 * t)
        cx = cy = size // 2
        value = int(70 * (1 - t) ** 1.6)
        gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=value)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.04))
    return Image.composite(Image.new("RGB", (size, size), PAPER_LIGHT), base, glow)


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def draw_letter(square: Image.Image, square_box: tuple[int, int, int, int]) -> None:
    """Draw the serif L, centred on the ink bounding box."""
    x0, y0, x1, y1 = square_box
    w, h = x1 - x0, y1 - y0
    font_size = int(h * 0.62)
    font = load_font(font_size)
    text = "L"
    bbox = font.getbbox(text)  # ink box, relative to draw origin
    ink_w = bbox[2] - bbox[0]
    ink_h = bbox[3] - bbox[1]
    cx = x0 + w / 2
    cy = y0 + h / 2
    # Optical nudge: a little up, serif L reads better slightly above centre.
    tx = cx - ink_w / 2 - bbox[0]
    ty = cy - ink_h / 2 - bbox[1] - h * 0.012
    layer = Image.new("RGBA", square.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).text(
        (tx, ty),
        text,
        font=font,
        fill=LETTER + (255,),
        stroke_width=max(1, font_size // 90),
        stroke_fill=LETTER + (255,),
    )
    square.alpha_composite(layer)


def build_master() -> Image.Image:
    canvas = radial_paper(MASTER).convert("RGBA")

    inset = int(MASTER * 0.115)
    box = (inset, inset, MASTER - inset, MASTER - inset)
    sq_size = box[2] - box[0]
    radius = int(sq_size * 0.235)

    # Soft drop shadow under the tile.
    shadow = Image.new("L", (MASTER, MASTER), 0)
    ImageDraw.Draw(shadow).rounded_rectangle(
        [box[0], box[1] + int(sq_size * 0.045), box[2], box[3] + int(sq_size * 0.045)],
        radius=radius,
        fill=90,
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(sq_size * 0.045))
    shadow_rgba = Image.new("RGBA", (MASTER, MASTER), (38, 48, 42, 0))
    shadow_rgba.putalpha(shadow)
    canvas.alpha_composite(shadow_rgba)

    tile = vertical_gradient(sq_size, JADE_TOP, JADE_BOTTOM).convert("RGBA")
    tile.putalpha(rounded_mask(sq_size, radius))
    canvas.alpha_composite(tile, (box[0], box[1]))

    # Faint inner hairline for a crisp, printed edge.
    hairline = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    ImageDraw.Draw(hairline).rounded_rectangle(
        [box[0] + 1, box[1] + 1, box[2] - 1, box[3] - 1],
        radius=radius - 1,
        outline=(255, 255, 255, 26),
        width=max(1, MASTER // 512),
    )
    canvas.alpha_composite(hairline)

    draw_letter(canvas, box)
    return canvas


def save_png(master: Image.Image, name: str, size: int) -> None:
    out = master.resize((size, size), Image.LANCZOS)
    out.save(os.path.join(HERE, name), "PNG", optimize=True)
    print(f"  {name}: {size}x{size}")


def main() -> None:
    master = build_master()

    save_png(master, "icon.png", 512)
    save_png(master, "32x32.png", 32)
    save_png(master, "128x128.png", 128)
    save_png(master, "128x128@2x.png", 256)

    ico_sizes = [16, 32, 48, 64, 128, 256]
    master.save(
        os.path.join(HERE, "icon.ico"),
        format="ICO",
        sizes=[(s, s) for s in ico_sizes],
    )
    print(f"  icon.ico: {', '.join(f'{s}x{s}' for s in ico_sizes)}")


if __name__ == "__main__":
    main()
