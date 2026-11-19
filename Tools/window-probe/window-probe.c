/* window-probe.exe: asks every visible top-level window whether its thread is
   answering, the way Task Manager decides "Not responding".

   One line per window on stdout, UTF-8, tab-separated:

       <process id>  <1 answered | 0 did not>  <executable's file name>

   A thread waiting in GetMessage answers WM_NULL at once, however long it has
   been idle. One that is deadlocked, or busy without pumping messages, does
   not answer inside the timeout. Sevoflurane's stall watchdog runs this in
   the bottle before it ends a game that has stopped using the processor. */

#include <windows.h>
#include <stdio.h>
#include <string.h>

/* How long one window has to answer, and how long the whole pass may take:
   the caller waits on the output. */
#define ANSWER_MS 3000
#define BUDGET_MS 12000

static DWORD started;

static void print_line(DWORD pid, int answered, const WCHAR *name)
{
    char utf8[MAX_PATH * 4];
    char line[MAX_PATH * 4 + 64];
    DWORD written;
    int length;

    if (!WideCharToMultiByte(CP_UTF8, 0, name, -1, utf8, sizeof(utf8), NULL, NULL)) return;
    length = snprintf(line, sizeof(line), "%lu\t%d\t%s\n", (unsigned long)pid, answered, utf8);
    if (length > 0)
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line, (DWORD)length, &written, NULL);
}

static BOOL CALLBACK each_window(HWND window, LPARAM unused)
{
    WCHAR path[MAX_PATH];
    const WCHAR *name = path;
    DWORD size = MAX_PATH, pid = 0;
    DWORD_PTR result = 0;
    HANDLE process;
    RECT frame;
    int answered;

    (void)unused;
    if (GetTickCount() - started > BUDGET_MS) return FALSE;
    if (!IsWindowVisible(window)) return TRUE;
    if (!GetWindowRect(window, &frame) || frame.right <= frame.left || frame.bottom <= frame.top) return TRUE;
    if (!GetWindowThreadProcessId(window, &pid) || pid == GetCurrentProcessId()) return TRUE;

    process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return TRUE;
    if (!QueryFullProcessImageNameW(process, 0, path, &size)) size = 0;
    CloseHandle(process);
    if (!size) return TRUE;
    for (const WCHAR *c = path; *c; c++)
        if (*c == L'\\' || *c == L'/') name = c + 1;

    answered = SendMessageTimeoutW(window, WM_NULL, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, ANSWER_MS, &result) != 0;
    print_line(pid, answered, name);
    return TRUE;
}

int main(void)
{
    started = GetTickCount();
    EnumWindows(each_window, 0);
    return 0;
}
