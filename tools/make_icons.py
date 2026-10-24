"""Draw XYZ's app icon (the _xyz wordmark), write it, and a review sheet.

Usage: make_icons.py [--sheet OUT.html] [--write]

The icon is the name set in Inter and converted to outlines, on a soft gray
field (light) or near-black (dark). Details, set 2026-10-24:
  - The underscore is drawn, not set: a bar as heavy as the letters' stems,
    as wide as the x, sitting on the baseline, so it reads as part of the word
    rather than a lighter mark below it.
  - The underscore stands a little apart from the x, as far as x is from y
    to the eye: the slanted letters leave more air between them than a bar.
  - The word spans two thirds of the icon (it was under half), and the
    x-height sits a little above the center so the y's descender does not
    pull the word down.
  - Up to 64 pixels (Finder lists and sidebars, Open With menus) the word is
    larger, heavier and a little wider apart, so the letters do not fill in.

`--write` renders the iOS 1024 images (light, dark, tinted; full bleed) and the
macOS sizes (on the rounded plate with its shadow) into
`XYZ/Resources/Assets.xcassets/AppIcon.appiconset`, and the source vectors
into `Design/Icon/`. Needs fontTools (`pip3 install fonttools`) and Inter
(https://rsms.me/inter, SIL Open Font License 1.1); set INTER to the folder
that holds Inter-*.otf if it is not in a standard font folder. SVGs are
rendered with headless Chrome; set CHROME to use another Chromium binary.
"""
import argparse, glob, html, os, subprocess, tempfile

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPICON = os.path.join(ROOT, "XYZ", "Resources", "Assets.xcassets", "AppIcon.appiconset")
DESIGN = os.path.join(ROOT, "Design", "Icon")
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
FONT_DIRS = [os.environ.get("INTER", ""), os.path.expanduser("~/Library/Fonts"), "/Library/Fonts",
             "/usr/share/fonts/opentype/inter", "/usr/share/fonts"]

# Fields: a soft vertical gradient, top to bottom. Tinted is white on black for the system to tint.
APPEARANCES = {
    "light": dict(top="#FBFBF9", bottom="#ECECEA", ink="#1D1D1F"),
    "dark": dict(top="#2A2A2C", bottom="#1A1A1C", ink="#F2F2F0"),
    "tinted": dict(top="#000000", bottom="#000000", ink="#FFFFFF"),
}

# Each style: Inter face, ink width of the word on the 1024 canvas, extra space
# between letters and after the underscore (in font units), and where the
# middle of the x-height sits. The large style is the face the first icon used.
STYLES = {
    "large": dict(face="InterDisplay-Bold", width=680, tracking=0, under_gap=40, center=500),
    "small": dict(face="Inter-ExtraBold", width=800, tracking=24, under_gap=60, center=496),
}
# Pixel sizes up to this are drawn with the small style, as the first icon did.
SMALL_PIXELS = 64


def find_font(face):
    for folder in FONT_DIRS:
        if folder:
            hits = glob.glob(os.path.join(folder, "**", face + ".otf"), recursive=True)
            if hits:
                return hits[0]
    raise SystemExit(f"{face}.otf not found; set INTER to the folder that holds Inter")


def wordmark(style, ink):
    """The _xyz paths, scaled and placed on the 1024 canvas."""
    spec = STYLES[style]
    font = TTFont(find_font(spec["face"]))
    glyphs, cmap = font.getGlyphSet(), font.getBestCmap()
    x_height = font["OS/2"].sxHeight

    def bounds(char):
        pen = BoundsPen(glyphs)
        glyphs[cmap[ord(char)]].draw(pen)
        return pen.bounds

    # Stem weight: the upright of the l.
    l_bounds = bounds("l")
    stem = l_bounds[2] - l_bounds[0]
    x_bounds = bounds("x")
    # Gap after the underscore: x's right side bearing plus y's left, plus a little air.
    advance = glyphs[cmap[ord("x")]].width
    gap = (advance - x_bounds[2]) + bounds("y")[0] + spec["under_gap"]

    # Lay out in font units: the underscore bar, then x, y, z on the baseline.
    under_w = x_bounds[2] - x_bounds[0]
    pieces, pen_x = [], under_w + gap - x_bounds[0]
    for i, char in enumerate("xyz"):
        pieces.append((char, pen_x))
        pen_x += glyphs[cmap[ord(char)]].width + (spec["tracking"] if i < 2 else 0)
    z_bounds = bounds("z")
    ink_right = pieces[-1][1] + z_bounds[2]

    scale = spec["width"] / ink_right
    left = (1024 - spec["width"]) / 2
    baseline = spec["center"] + x_height * scale / 2

    def place(dx):
        # Font units are y-up; the canvas is y-down.
        return (scale, 0, 0, -scale, left + dx * scale, baseline)

    pen = SVGPathPen(glyphs)
    for char, dx in pieces:
        glyphs[cmap[ord(char)]].draw(TransformPen(pen, place(dx)))
    bar = (f'<rect x="{left:.2f}" y="{baseline - stem * scale:.2f}" width="{under_w * scale:.2f}" '
           f'height="{stem * scale:.2f}" fill="{ink}"/>')
    return bar + f'<path fill="{ink}" d="{pen.getCommands()}"/>'


def body(appearance, style="large"):
    c = APPEARANCES[appearance]
    return (f'<defs><linearGradient id="bg-{appearance}" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{c["top"]}"/><stop offset="1" stop-color="{c["bottom"]}"/>'
            f'</linearGradient></defs><rect width="1024" height="1024" fill="url(#bg-{appearance})"/>'
            + wordmark(style, c["ink"]))


def ios_svg(appearance, size=1024, style="large"):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">'
            + body(appearance, style) + "</svg>")


def mac_svg(appearance, size=1024):
    """The icon on the macOS plate: 824 points of the 1024 grid, rounded, with a soft shadow."""
    style = "small" if size <= SMALL_PIXELS else "large"
    plate = 'x="100" y="100" width="824" height="824" rx="185"'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">'
            '<defs><clipPath id="plate"><rect ' + plate + '/></clipPath>'
            '<filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">'
            '<feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.3"/></filter></defs>'
            # The shadow is cast by a plate in the field's color, so no dark rim shows at the rounded edge.
            f'<rect {plate} fill="{APPEARANCES[appearance]["bottom"]}" filter="url(#shadow)"/>'
            '<g clip-path="url(#plate)"><g transform="translate(100 100) scale(0.8046875)">'
            + body(appearance, style) + "</g></g></svg>")


MAC_SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def render(svg, png, size, work):
    # A page around the SVG, so Chrome draws it at the window size from the top-left corner.
    src = os.path.join(work, os.path.basename(png) + ".html")
    with open(src, "w") as f:
        f.write(f'<html><body style="margin:0;overflow:hidden">{svg}</body></html>')
    subprocess.run(
        [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
         "--default-background-color=00000000", f"--window-size={size},{size}", f"--screenshot={png}",
         "file://" + src],
        check=True, capture_output=True, timeout=60)


def write():
    with tempfile.TemporaryDirectory() as work:
        for appearance, suffix in (("light", ""), ("dark", "-dark"), ("tinted", "-tinted")):
            render(ios_svg(appearance), os.path.join(APPICON, f"icon-ios-1024{suffix}.png"), 1024, work)
        for points, scale in MAC_SIZES:
            px = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            render(mac_svg("light", px), os.path.join(APPICON, name), px, work)
    for appearance in ("light", "dark"):
        with open(os.path.join(DESIGN, f"icon-{appearance}.svg"), "w") as f:
            f.write(ios_svg(appearance) + "\n")
    print(f"app icon written to {os.path.relpath(APPICON, ROOT)} and Design/Icon")


def sheet(out):
    """The icon in light, dark and tinted, on the Mac plate, and at Dock and Finder sizes."""
    cells = "".join(f'<figure>{ios_svg(a, 200)}<figcaption>iOS {a}</figcaption></figure>' for a in APPEARANCES)
    cells += f'<figure>{mac_svg("light", 200)}<figcaption>macOS</figcaption></figure>'
    small = "".join(mac_svg("light", s) for s in (128, 64, 32, 16))
    cells += f'<figure class=small>{small}<figcaption>128 · 64 · 32 · 16</figcaption></figure>'
    page = ("<!doctype html><meta charset=utf-8><title>XYZ icon</title><style>"
            "body{font:14px -apple-system,system-ui,sans-serif;background:#D8D8D6;color:#1D1D1F;margin:24px}"
            ".row{display:flex;flex-wrap:wrap;gap:20px;align-items:end}figure{margin:0;text-align:center}"
            "figure>svg:only-of-type{border-radius:44px}.small svg{margin:0 6px;vertical-align:bottom}"
            "figcaption{color:#6E6E73;font-size:12px;margin-top:6px}"
            f"</style><h1>XYZ app icon</h1><div class=row>{cells}</div>")
    with open(out, "w") as f:
        f.write(page)
    print(f"sheet written to {out}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--sheet")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.sheet:
        sheet(args.sheet)
    if args.write:
        write()
    if not (args.sheet or args.write):
        parser.print_help()
