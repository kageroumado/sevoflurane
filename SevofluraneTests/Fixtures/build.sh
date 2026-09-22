#!/bin/sh
# Rebuilds fixture.exe and admin.exe from the sources beside it, with mingw-w64 from
# Homebrew. The sources and the built exe are both committed: the tests read
# the exe, so a Mac without a Windows toolchain still runs them.
set -eu
cd "$(dirname "$0")"
python3 make-icon.py fixture.ico
x86_64-w64-mingw32-windres fixture.rc -O coff -o fixture-res.o
x86_64-w64-mingw32-gcc -Os -s -o fixture.exe fixture.c fixture-res.o
rm -f fixture-res.o
# admin.exe: the same program whose manifest asks for administrator, for the
# installer heuristics.
x86_64-w64-mingw32-windres admin.rc -O coff -o admin-res.o
x86_64-w64-mingw32-gcc -Os -s -o admin.exe fixture.c admin-res.o
rm -f admin-res.o
ls -l fixture.ico fixture.exe admin.exe
