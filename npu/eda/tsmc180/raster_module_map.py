from PIL import Image, ImageDraw, ImageFont
import xml.etree.ElementTree as E
from pathlib import Path
import argparse

parser = argparse.ArgumentParser(
    description="Rasterize module map SVG rectangles and text using Pillow."
)
parser.add_argument("svg", type=Path)
p = parser.parse_args().svg
r = E.parse(p).getroot()
scale = 0.8
im = Image.new("RGB", (2160, 1680))
d = ImageDraw.Draw(im)


def render(parent, dx=0, dy=0):
    for e in parent:
        tag = e.tag.split("}")[-1]
        if tag == "g":
            render(e, 40, 80)
        elif tag == "rect":
            x = (float(e.get("x", 0)) + dx) * scale
            y = (float(e.get("y", 0)) + dy) * scale
            w = float(e.get("width")) * scale
            h = float(e.get("height")) * scale
            d.rectangle((x, y, x + w, y + h), fill=e.get("fill"), outline=e.get("stroke"))
        elif tag == "text":
            font = ImageFont.truetype(
                "/usr/share/fonts/dejavu/DejaVuSans.ttf", int(float(e.get("font-size")) * scale)
            )
            d.text(
                ((float(e.get("x")) + dx) * scale, (float(e.get("y")) + dy) * scale),
                e.text,
                fill=e.get("fill"),
                font=font,
                anchor="ls",
            )


render(r)
im.save(p.with_suffix(".png"))
