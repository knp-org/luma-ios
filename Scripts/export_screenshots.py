#!/usr/bin/env python3
"""Publish documentation attachments, keeping existing image aliases in sync."""

import argparse
import json
import shutil
from pathlib import Path


DESTINATIONS = {
    "README Listen": ["listen.png"],
    "README Library": ["readme-library.png"],
    "README Now Playing": ["readme-now-playing.png", "now-playing.png", "album-color-warm.png"],
    "README Playlist": ["readme-playlist.png", "playlist.png"],
    "README Insights": ["readme-insights.png", "insights.png"],
    "README Visualizer": ["visualizer.png"],
    "README Queue": ["queue.png"],
    "README Cool Artwork": ["album-color-cool.png"],
    "README Cool Library": ["album-color-library.png"],
    "README Online Lyrics": ["online-lyrics.png"],
    "README Lyrics Preview": ["lyrics-preview.png"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments", type=Path, help="xcresulttool export attachments output directory")
    args = parser.parse_args()
    sources = {}
    for test in json.loads((args.attachments / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            name = attachment["suggestedHumanReadableName"]
            for label in DESTINATIONS:
                if name.startswith(label + "_"):
                    if label in sources:
                        parser.error(f"Multiple captures for {label}; export a single test run.")
                    source = args.attachments / attachment["exportedFileName"]
                    if source.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                        parser.error(f"Expected a PNG capture: {source}")
                    sources[label] = source
    missing = DESTINATIONS.keys() - sources.keys()
    if missing:
        parser.error("Missing captures: " + ", ".join(sorted(missing)))
    output = Path(__file__).resolve().parent.parent / "Screenshots"
    for label, filenames in DESTINATIONS.items():
        for filename in filenames:
            shutil.copyfile(sources[label], output / filename)
            print(filename)


if __name__ == "__main__":
    main()
