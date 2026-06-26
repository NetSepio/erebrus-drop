#!/usr/bin/env python3
"""Generate desktop brand assets: tray icons, About icon, Linux window icon."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
GLYPH = ROOT / 'assets/images/erebrus-glyph.png'
GLOSSY = ROOT / 'assets/images/erebrus-glossy.png'
ASSET_DIR = ROOT / 'assets/images'
LINUX_ICON = ROOT / 'linux/runner/resources/app_icon.png'
ABOUT_ICON_DIR = ROOT / 'macos/Runner/Assets.xcassets/AboutIcon.imageset'


def is_background(r: int, g: int, b: int, a: int) -> bool:
    return a < 16 or (r > 215 and g > 215 and b > 220)


def generate_tray_icons() -> None:
    src = Image.open(GLYPH).convert('RGBA')
    color = Image.new('RGBA', src.size, (0, 0, 0, 0))
    template = Image.new('RGBA', src.size, (0, 0, 0, 0))
    src_px = src.load()
    color_px = color.load()
    template_px = template.load()
    for y in range(src.height):
        for x in range(src.width):
            r, g, b, a = src_px[x, y]
            if is_background(r, g, b, a):
                continue
            color_px[x, y] = (r, g, b, 255)
            template_px[x, y] = (0, 0, 0, 255)

    color.save(ASSET_DIR / 'erebrus-tray.png')
    template.save(ASSET_DIR / 'erebrus-tray-template.png')
    color.resize((64, 64), Image.Resampling.LANCZOS).save(
        ASSET_DIR / 'erebrus-tray-64.png'
    )
    template.resize((64, 64), Image.Resampling.LANCZOS).save(
        ASSET_DIR / 'erebrus-tray-template-64.png'
    )


def save_glossy_icon(path: Path, size: int) -> None:
    glossy = Image.open(GLOSSY).convert('RGBA')
    glossy.resize((size, size), Image.Resampling.LANCZOS).save(path)


def generate_about_and_linux_icons() -> None:
    ABOUT_ICON_DIR.mkdir(parents=True, exist_ok=True)
    save_glossy_icon(ABOUT_ICON_DIR / 'about_icon.png', 128)
    save_glossy_icon(ABOUT_ICON_DIR / 'about_icon@2x.png', 256)

    contents = {
        'images': [
            {
                'filename': 'about_icon.png',
                'idiom': 'universal',
                'scale': '1x',
            },
            {
                'filename': 'about_icon@2x.png',
                'idiom': 'universal',
                'scale': '2x',
            },
        ],
        'info': {'author': 'xcode', 'version': 1},
    }
    (ABOUT_ICON_DIR / 'Contents.json').write_text(
        json.dumps(contents, indent=2) + '\n',
        encoding='utf-8',
    )

    LINUX_ICON.parent.mkdir(parents=True, exist_ok=True)
    save_glossy_icon(LINUX_ICON, 128)


def generate_launcher_icons() -> None:
    subprocess.run(
        ['dart', 'run', 'flutter_launcher_icons'],
        cwd=ROOT,
        check=True,
    )


def main() -> None:
    if not GLYPH.exists() or not GLOSSY.exists():
        print('Missing brand source images in assets/images/', file=sys.stderr)
        sys.exit(1)
    generate_tray_icons()
    generate_about_and_linux_icons()
    generate_launcher_icons()
    print('Desktop brand assets generated.')


if __name__ == '__main__':
    main()