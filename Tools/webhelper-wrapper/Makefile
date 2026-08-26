# Cross-compiled with mingw-w64 (`brew install mingw-w64`); the exe rides
# the managed-engine tarball, never the app bundle.
CC := x86_64-w64-mingw32-gcc
CFLAGS := -O2 -municode -mwindows -Wall -Wextra

webhelper-wrapper.exe: webhelper_wrapper.c
	$(CC) $(CFLAGS) -static -o $@ $<

clean:
	trash -F webhelper-wrapper.exe 2>/dev/null || true

.PHONY: clean
