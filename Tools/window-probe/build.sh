#!/bin/sh
# Rebuilds window-probe.exe from window-probe.c with mingw-w64 from Homebrew
# (`brew install mingw-w64`). The source and the built exe are both committed:
# the app bundles the exe, so a Mac without a Windows toolchain still builds it.
set -eu
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -s -Wall -Wextra \
  -o ../../Sevoflurane/Resources/WindowProbe/window-probe.exe window-probe.c
ls -l ../../Sevoflurane/Resources/WindowProbe/window-probe.exe
