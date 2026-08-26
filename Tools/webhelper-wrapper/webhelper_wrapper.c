/*
 * webhelper_wrapper.c — the steamwebhelper shim a managed engine needs.
 *
 * Installed as `steamwebhelper.exe` with the genuine exe parked next to it
 * as `steamwebhelper.real.exe` (EngineInstaller.swift does the swap). Every
 * invocation re-execs the real exe with the original command line plus the
 * CEF flags OSS Wine needs — without them CEF's GPU process dies and the
 * whole client renders black (SPEC "Engine strategy", the vineport-proven
 * recipe). CEF tolerates repeated flags, so subprocess invocations
 * (--type=renderer …) get them appended too.
 *
 * Build: `make` here (needs mingw-w64: `brew install mingw-w64`).
 */
#include <windows.h>

/* EngineInstaller greps the binary for this to tell the wrapper from a
 * genuine steamwebhelper.exe (a client self-update swaps one back in). */
static volatile const char kMarker[] = "sevoflurane-webhelper-wrapper";

static const wchar_t kRealName[] = L"steamwebhelper.real.exe";
static const wchar_t kFlags[] =
    L" --no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing";

/* Skips argv[0] of a raw command line, quotes respected. */
static const wchar_t *skip_program_token(const wchar_t *cmd)
{
    if (*cmd == L'"') {
        cmd++;
        while (*cmd && *cmd != L'"')
            cmd++;
        if (*cmd == L'"')
            cmd++;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t')
            cmd++;
    }
    while (*cmd == L' ' || *cmd == L'\t')
        cmd++;
    return cmd;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR args, int show)
{
    (void)inst; (void)prev; (void)args; (void)show;
    if (kMarker[0] == '\0')
        return 1;

    wchar_t real[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, real, MAX_PATH);
    if (n == 0 || n >= MAX_PATH)
        return 127;
    wchar_t *slash = wcsrchr(real, L'\\');
    if (!slash || (slash - real) + 1 + wcslen(kRealName) + 1 > MAX_PATH)
        return 127;
    lstrcpyW(slash + 1, kRealName);

    /* Assembled by concatenation: CEF subprocess command lines run to
     * several KB, past wsprintfW's 1024-char ceiling. */
    const wchar_t *rest = skip_program_token(GetCommandLineW());
    size_t len = 1 + wcslen(real) + 2 + wcslen(rest) + wcslen(kFlags) + 1;
    wchar_t *cmdline = HeapAlloc(GetProcessHeap(), 0, len * sizeof(wchar_t));
    if (!cmdline)
        return 127;
    cmdline[0] = L'"';
    lstrcpyW(cmdline + 1, real);
    lstrcatW(cmdline, L"\" ");
    lstrcatW(cmdline, rest);
    lstrcatW(cmdline, kFlags);

    STARTUPINFOW si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(real, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 127;

    /* Steam holds the handle of what it spawned — the wrapper must live as
     * long as the real webhelper and answer with its exit code. */
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}
