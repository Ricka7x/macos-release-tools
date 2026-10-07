#!/usr/bin/env python3
"""update-catalog-link.py <catalog_file> <app_slug> <new_url>

Safely updates one app's `download:` link in a catalog data file like
66-studio's apps.ts. Scopes the edit to the block of lines between this
app's `slug: "<app_slug>"` line and the next app's `slug:` line (or end of
file), so this can never touch a different app's entry, and only ever
changes the one `download:` line within that block.

Exits non-zero (leaving the file untouched) if the slug or its `download:`
field can't be found unambiguously.
"""
import re
import sys

SLUG_RE = re.compile(r'slug:\s*"([^"]*)"')
DOWNLOAD_RE = re.compile(r'(download:\s*")([^"]*)(")')


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: update-catalog-link.py <catalog_file> <app_slug> <new_url>", file=sys.stderr)
        return 1

    catalog_file, app_slug, new_url = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(catalog_file, "r") as f:
        original_lines = f.readlines()
    lines = list(original_lines)

    start = None
    for i, line in enumerate(lines):
        match = SLUG_RE.search(line)
        if match and match.group(1) == app_slug:
            start = i
            break

    if start is None:
        print(f'ERROR: no app with slug "{app_slug}" found in {catalog_file}', file=sys.stderr)
        return 1

    end = len(lines)
    for i in range(start + 1, len(lines)):
        if SLUG_RE.search(lines[i]):
            end = i
            break

    download_index = None
    for i in range(start, end):
        if DOWNLOAD_RE.search(lines[i]):
            download_index = i
            break

    if download_index is None:
        print(
            f'ERROR: no `download:` field found for slug "{app_slug}" '
            f"between lines {start + 1} and {end}",
            file=sys.stderr,
        )
        return 1

    new_line = DOWNLOAD_RE.sub(
        lambda m: m.group(1) + new_url + m.group(3), lines[download_index], count=1
    )

    if new_line == lines[download_index]:
        print(f'No change needed: "{app_slug}" download link is already {new_url!r}')
        return 0

    lines[download_index] = new_line

    # Correct by construction (only lines[download_index] was ever touched),
    # but asserted explicitly so a future change to this script can't
    # silently widen its blast radius without this failing loudly.
    changed = sum(1 for a, b in zip(original_lines, lines) if a != b)
    assert changed == 1, f"expected exactly 1 line to change, got {changed}"

    with open(catalog_file, "w") as f:
        f.writelines(lines)

    print(f'Updated "{app_slug}" download link to {new_url}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
