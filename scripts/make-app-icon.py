#!/usr/bin/env python3
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = ROOT / "Resources" / "AppIcon.png"
OUTPUT_PATH = ROOT / "Resources" / "AppIcon.icns"


def resize_source(size):
    source = Image.open(SOURCE_PATH).convert("RGBA")
    return source.resize((size, size), Image.Resampling.LANCZOS)


def write_icns(images):
    base = images[1024]
    append_images = [
        images[32],
        images[64],
        images[128],
        images[256],
        images[512],
    ]
    base.save(OUTPUT_PATH, format="ICNS", append_images=append_images)


def main():
    images = {
        32: resize_source(32),
        64: resize_source(64),
        128: resize_source(128),
        256: resize_source(256),
        512: resize_source(512),
        1024: resize_source(1024),
    }
    write_icns(images)
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
