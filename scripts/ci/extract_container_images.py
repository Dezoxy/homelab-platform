"""Extract literal tagged container image references from Ansible YAML or a diff."""

from __future__ import annotations

import re
import sys
from collections.abc import Iterable, Iterator
from pathlib import Path

NAME = r"[A-Za-z0-9][A-Za-z0-9._-]*"
IMAGE_PATH = rf"(?:{NAME}(?::[0-9]+)?/)*{NAME}"
TAG = r"[A-Za-z0-9][A-Za-z0-9._-]*"
DIGEST = r"(?:@sha256:[a-f0-9]{64})?"
TAGGED_IMAGE = rf"{IMAGE_PATH}:{TAG}{DIGEST}"

IMAGE_VARIABLE = re.compile(
    rf"""^\+?\s*{NAME}_image:\s*["']?(?P<image>{TAGGED_IMAGE})["']?\s*(?:#.*)?$"""
)
NESTED_IMAGE = re.compile(
    rf"""^\+?\s+{NAME}:\s*["']?(?P<image>(?:{NAME}(?::[0-9]+)?/)+{NAME}:{TAG}{DIGEST})["']?\s*(?:#.*)?$"""
)


def read_lines(paths: list[str]) -> Iterator[str]:
    if not paths:
        yield from sys.stdin
        return

    for path in paths:
        yield from Path(path).read_text(encoding="utf-8").splitlines()


def extract_images(lines: Iterable[str]) -> set[str]:
    images: set[str] = set()
    for line in lines:
        match = IMAGE_VARIABLE.match(line) or NESTED_IMAGE.match(line)
        if match:
            images.add(match.group("image"))
    return images


def main() -> int:
    for image in sorted(extract_images(read_lines(sys.argv[1:]))):
        print(image)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
