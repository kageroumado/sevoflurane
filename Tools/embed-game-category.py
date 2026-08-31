#!/usr/bin/env python3
"""Embed a games-category Info.plist into a bare Mach-O loader.

macOS engages Game Mode automatically for a games-category app that is
frontmost and full screen. A Wine game's window belongs to the wine loader
process, and Gcenx's `wine` loader carries no `__info_plist` at all — so
macOS has no way to see the game as a game. This adds a `__TEXT,__info_plist`
section declaring `public.app-category.games` + `GCSupportsGameMode`, then the
loader must be re-signed (the caller does that).

Idempotent: a loader that already has the section is left untouched. Needs
LIEF (`pip install lief`); it is a packaging-time dependency only, never
shipped or required on a user's machine.

    embed-game-category.py <mach-o> [<mach-o> ...]
"""
import sys

PLIST = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n'
    b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    b'<plist version="1.0"><dict>'
    b'<key>LSApplicationCategoryType</key><string>public.app-category.games</string>'
    b'<key>GCSupportsGameMode</key><true/>'
    b'</dict></plist>'
)


def embed(path: str) -> str:
    import lief
    binary = lief.MachO.parse(path).at(0)
    if binary.get_section("__info_plist"):
        return "already tagged"
    segment = binary.get_segment("__TEXT")
    section = lief.MachO.Section.create("__info_plist", list(PLIST))
    binary.add_section(segment, section)
    binary.write(path)
    return "tagged"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        import lief  # noqa: F401
    except ImportError:
        print("embed-game-category: needs LIEF (pip install lief)", file=sys.stderr)
        return 3
    for path in sys.argv[1:]:
        print(f"  {path}: {embed(path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
