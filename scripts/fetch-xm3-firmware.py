#!/usr/bin/env python3
"""Fetch a pinned international WH-1000XM3 firmware image. Does not contact headphones."""
import argparse
import hashlib
from pathlib import Path
import urllib.request

IMAGES = {
    "2.0.0": {
        "url": ("https://raw.githubusercontent.com/lzghzr/MDR_Proxy/"
                "2e80d32e05f55ebf354389283e767e5a7c273e27/firmware/2916/MDRID291600/"
                "HDX-2916_V0200.952e4c5816428f871f6f3a29d30976feb17d51c8.bin"),
        "size": 2711470,
        "sha256": "c0f3a263011e14d3ad24f53661dc9c9c4e7f4a2171efff0e929f2053a0ffe3bd",
    },
    "4.5.2": {
        "url": "https://info.update.sony.net/HP001/MDRID291600/contents/0004/HDX-2916_V0452_with_stack.bin",
        "size": 3776802,
        "sha256": "b67330f6f75a87c7798bc7c994a25f2df09ac66d8013f2536e8799838850aa43",
    },
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", choices=IMAGES, default="2.0.0",
                        help="Target firmware version (default: 2.0.0).")
    parser.add_argument("destination", nargs="?", type=Path)
    args = parser.parse_args()
    image = IMAGES[args.version]
    size, sha256 = image["size"], image["sha256"]
    if args.destination is None:
        args.destination = Path(__file__).resolve().parent.parent / f".work/firmware/xm3-{args.version}.bin"
    if args.destination.exists():
        if args.destination.is_file() and args.destination.stat().st_size == size and hashlib.sha256(args.destination.read_bytes()).hexdigest() == sha256:
            print(f"Already verified: {args.destination}")
            return
        parser.error("Destination exists with different contents; choose a new path.")
    with urllib.request.urlopen(image["url"], timeout=60) as response:
        data = response.read(size + 1)
    if len(data) != size or hashlib.sha256(data).hexdigest() != sha256:
        parser.error("Downloaded image does not match the pinned firmware; no file was saved.")
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    with args.destination.open("xb") as output:
        output.write(data)
    print(f"Verified {args.version}, {size:,} bytes: {args.destination}\nSHA-256: {sha256}")


if __name__ == "__main__":
    main()
