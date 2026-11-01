#!/usr/bin/env python3
"""Turn exported xcresult attachments into small, named JPEG screenshots (macOS only).

Usage: collect_screenshots.py <exported-attachments-dir> <output-dir>

`xcrun xcresulttool export attachments` writes files named by UUID plus a manifest.json. This
maps each image back to the attachment name given in the UI test (for example "02-confirmed-mining"),
converts it with `sips` to a 600 px wide JPEG, and writes INDEX.txt listing the test of each shot.
"""
import json
import pathlib
import re
import subprocess
import sys

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic"}
IMAGE_MAGIC = (b"\x89PNG", b"\xff\xd8\xff")


def is_image(path):
    """By suffix or, since exported names may lack one, by PNG/JPEG magic bytes."""
    if not path.is_file():
        return False
    if path.suffix.lower() in IMAGE_SUFFIXES:
        return True
    with path.open("rb") as handle:
        return handle.read(4).startswith(IMAGE_MAGIC)


def attachments(node, test=None):
    """Yield (test identifier, attachment dict) from the manifest, whatever its nesting."""
    if isinstance(node, list):
        for item in node:
            yield from attachments(item, test)
    elif isinstance(node, dict):
        test = node.get("testIdentifier", test)
        if "exportedFileName" in node:
            yield test, node
        for value in node.values():
            if isinstance(value, (list, dict)):
                yield from attachments(value, test)


def readable_name(attachment):
    """'02-confirmed-mining_0_<UUID>.png' -> '02-confirmed-mining'."""
    stem = pathlib.Path(attachment.get("suggestedHumanReadableName") or attachment["exportedFileName"]).stem
    stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", stem)
    return re.sub(r"[^0-9A-Za-z._-]+", "-", stem).strip("-") or "screenshot"


def main():
    source, output = map(pathlib.Path, sys.argv[1:3])
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    index = []
    entries = list(attachments(manifest))
    for test, attachment in entries:
        image = source / attachment["exportedFileName"]
        if not is_image(image):
            continue
        name = readable_name(attachment)
        target = output / f"{name}.jpg"
        counter = 2
        while target.exists():
            target = output / f"{name}-{counter}.jpg"
            counter += 1
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "60",
                        "--resampleWidth", "600", str(image), "--out", str(target)],
                       check=True, stdout=subprocess.DEVNULL)
        failed = " (failure)" if attachment.get("isAssociatedWithFailure") else ""
        index.append(f"{target.name}\t{test}{failed}")
    (output / "INDEX.txt").write_text("\n".join(sorted(index)) + "\n", encoding="utf-8")
    print(f"collected {len(index)} screenshots into {output}")
    if not index:
        # Shows up as a CI annotation so the export format can be fixed without the full log.
        files = sorted(p.name for p in source.iterdir())[:8]
        sample = json.dumps(entries[:2], ensure_ascii=False)[:600] if entries else json.dumps(manifest)[:600]
        print(f"::warning title=screenshots::0 images; {len(entries)} manifest entries; files {files}; sample {sample}")


if __name__ == "__main__":
    main()
