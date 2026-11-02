#!/usr/bin/env python3
"""Build contact_sheet.html for a store-screenshots folder.

Usage: contact_sheet.py DIR

DIR holds one sub-folder per screenshot set (see SET_ORDER). The page lists
each set with a row of its PNGs, in file-name order, using paths relative to
the page so the folder can be moved or zipped. A set with no PNGs says
"missing". Standard library only; runs on the system python3 (3.9).
"""
from __future__ import annotations

import argparse
import html
import sys
from pathlib import Path
from typing import List, Optional

SET_ORDER = ["ios-iphone-69", "ios-ipad-13", "watch-46", "android-phone"]

_STYLE = """
body { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 24px;
       background: #f4f4f6; color: #1c1c1e; }
h1 { font-size: 20px; }
h2 { font-size: 16px; margin: 28px 0 8px; }
.row { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
figure { margin: 0; }
figure img { height: 560px; width: auto; border: 1px solid #c7c7cc;
             background: #fff; }
figcaption { font-size: 12px; color: #636366; margin-top: 4px; }
.empty { color: #b00020; font-weight: 600; }
"""


def _images(set_dir: Path) -> List[Path]:
    if not set_dir.is_dir():
        return []
    return sorted(
        (p for p in set_dir.iterdir() if p.is_file() and p.suffix.lower() == ".png"),
        key=lambda p: p.name,
    )


def build_html(root: Path) -> str:
    root = Path(root)
    parts = [
        "<!DOCTYPE html>",
        '<html lang="en"><head><meta charset="utf-8">',
        "<title>MeshMapper store screenshots</title>",
        f"<style>{_STYLE}</style></head><body>",
        f"<h1>MeshMapper store screenshots: {html.escape(root.name)}</h1>",
    ]
    for name in SET_ORDER:
        parts.append(f"<h2>{html.escape(name)}</h2>")
        images = _images(root / name)
        if not images:
            parts.append('<p class="empty">missing</p>')
            continue
        parts.append('<div class="row">')
        for image in images:
            rel = html.escape(f"{name}/{image.name}", quote=True)
            parts.append(
                f'<figure><img src="{rel}" alt="{rel}">'
                f"<figcaption>{html.escape(image.name)}</figcaption></figure>"
            )
        parts.append("</div>")
    parts.append("</body></html>")
    return "\n".join(parts) + "\n"


def write_contact_sheet(root: Path) -> Path:
    root = Path(root)
    out = root / "contact_sheet.html"
    out.write_text(build_html(root), encoding="utf-8")
    return out


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("dir", type=Path, help="store-screenshots folder")
    args = parser.parse_args(argv)
    if not args.dir.is_dir():
        print(f"not a directory: {args.dir}", file=sys.stderr)
        return 2
    print(write_contact_sheet(args.dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
