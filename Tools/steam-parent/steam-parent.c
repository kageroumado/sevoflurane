/*
 * steam-parent: a companion prefix's C:\windows\system32\steam.exe.
 *
 * It starts the program named on its command line as its own child, with the
 * same environment and working directory, waits for it, and returns its exit
 * code. It runs no Steam code at all.
 *
 * HoYoverse's games (GenshinImpact.exe and its siblings) skip their kernel
 * anti-cheat driver when their parent is a steam.exe in system32 and every
 * steam.exe they can see lives there too, which is what Proton's steam.exe
 * gives them when SteamGameId is unset. Anything else sends them down the
 * driver path, and no Wine can load that driver. See SteamParent.swift.
 *
 * One `sevo:steam-parent` line on stderr, which lands in the wine log, says
 * what the child was and how it ended: `started pid=<windows pid>` when it
 * starts, `exit pid=<windows pid> code=<exit code>` when it is gone, and
 * `CreateProcess failed with <error>` when it never started. The parent's
 * own exit status is the child's exit code (2 with no program named, 3 when
 * the child could not start).
 */
#include <windows.h>
#include <stdio.h>

/* The command line past our own name, which Windows hands over quoted as
 * typed: the first token may be quoted, the rest is passed on untouched. */
static WCHAR *after_first_argument(WCHAR *cmd)
{
    BOOL quoted = FALSE;
    while (*cmd && (quoted || (*cmd != L' ' && *cmd != L'\t'))) {
        if (*cmd == L'"') quoted = !quoted;
        cmd++;
    }
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

static void say(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    fputs("sevo:steam-parent ", stderr);
    vfprintf(stderr, format, args);
    va_end(args);
    fputc('\n', stderr);
    fflush(stderr);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR ignored, int show)
{
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD code = 1;
    WCHAR *child = after_first_argument(GetCommandLineW());

    (void)instance; (void)previous; (void)ignored; (void)show;
    ZeroMemory(&startup, sizeof(startup));
    startup.cb = sizeof(startup);
    if (!*child) {
        say("no program named on the command line");
        return 2;
    }
    if (!CreateProcessW(NULL, child, NULL, NULL, FALSE, CREATE_UNICODE_ENVIRONMENT,
                        NULL, NULL, &startup, &process)) {
        say("CreateProcess failed with %lu for %ls", GetLastError(), child);
        return 3;
    }
    say("started pid=%lu %ls", process.dwProcessId, child);
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    if (!GetExitCodeProcess(process.hProcess, &code)) code = 1;
    CloseHandle(process.hProcess);
    say("exit pid=%lu code=%lu", process.dwProcessId, code);
    return (int)code;
}
