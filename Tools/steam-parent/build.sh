#!/bin/sh
# Rebuilds steam-parent.exe from steam-parent.c with mingw-w64 from Homebrew
# (`brew install mingw-w64`). The source and the built exe are both committed:
# the app bundles the exe, so a Mac without a Windows toolchain still builds it.
set -eu
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -municode -mwindows -s -Wall -Wextra \
  -o ../../Sevoflurane/Resources/SteamParent/steam-parent.exe steam-parent.c
ls -l ../../Sevoflurane/Resources/SteamParent/steam-parent.exe
