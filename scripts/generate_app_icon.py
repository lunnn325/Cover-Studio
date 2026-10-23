#!/usr/bin/env python3
"""Reproduce the original opaque iOS tool icon. Requires Pillow (development only)."""
from pathlib import Path
import json

from PIL import Image, ImageDraw


def main():
    destination = Path(__file__).resolve().parents[1] / "App/Assets.xcassets/AppIcon.appiconset"
    destination.mkdir(parents=True, exist_ok=True)
    scale = 4
    image = Image.new("RGB", (1024 * scale, 1024 * scale), (67, 56, 202))
    drawing = ImageDraw.Draw(image)
    heights = [120, 240, 390, 520, 390, 240, 120]
    width, spacing = 64, 32
    origin = (1024 - len(heights) * width - (len(heights) - 1) * spacing) / 2
    for index, height in enumerate(heights):
        left = origin + index * (width + spacing)
        top = (1024 - height) / 2
        drawing.rounded_rectangle(tuple(int(value * scale) for value in (left, top, left + width, top + height)),
                                  radius=width * scale // 2, fill=(255, 255, 255))
    image.resize((1024, 1024), Image.Resampling.LANCZOS).save(destination / "AppIcon.png", optimize=True)
    contents = {"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
                "info": {"author": "xcode", "version": 1}}
    (destination / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("Generated opaque 1024x1024 AppIcon; iOS applies its own corner mask.")


if __name__ == "__main__":
    main()
