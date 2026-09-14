#!/usr/bin/env python3
"""Pull the screenshots out of an xcresult bundle and name them properly.

`ScreenshotTests` attaches one image per screen; Xcode stores them under opaque
UUIDs. This extracts them under their attachment names and downscales them, so
a README does not carry six full-resolution phone screens.

    python3 scripts/export-screenshots.py <result.xcresult> docs/screenshots
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

# Half of a 3x phone screen: sharp on a retina display, a third of the bytes.
SCALE = 0.5


def walk(node):
    if isinstance(node, dict):
        if "exportedFileName" in node and "suggestedHumanReadableName" in node:
            yield node["exportedFileName"], node["suggestedHumanReadableName"]
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    bundle, out_dir = sys.argv[1], sys.argv[2]
    if not os.path.exists(bundle):
        raise SystemExit(f"No result bundle at {bundle}")

    os.makedirs(out_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as staging:
        subprocess.run(
            ["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", staging],
            check=True, capture_output=True,
        )
        manifest = json.load(open(os.path.join(staging, "manifest.json")))

        written = 0
        for exported, suggested in walk(manifest):
            # "01-repos_1_<uuid>.png" -> "01-repos.png"
            name = suggested.split("_")[0]
            if not name or not name[0].isdigit():
                continue
            source = os.path.join(staging, exported)
            target = os.path.join(out_dir, f"{name}.png")
            try:
                from PIL import Image

                image = Image.open(source)
                image.resize((int(image.width * SCALE), int(image.height * SCALE)), Image.LANCZOS).save(target)
            except ImportError:
                shutil.copy(source, target)
            written += 1
            print(f"  {name}.png")

    if not written:
        raise SystemExit("No named screenshots in that bundle — did ScreenshotTests run with HUBHUB_SHOTS=1?")
    print(f"{written} screenshots -> {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
