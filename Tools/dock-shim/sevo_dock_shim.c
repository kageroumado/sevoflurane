// The bottle's face is Sevoflurane. winemac.drv promotes a wine process
// into the Dock (TransformProcessType → foreground) the moment it shows a
// window, and there is no demotion API — so Steam's own processes, whose
// windows this app renders natively, must never be promoted in the first
// place. Games keep the real call: a promoted game process is how
// fullscreen and input capture behave correctly.
//
// Built x86_64 (the whole bottle runs under Rosetta) and injected with
// DYLD_INSERT_LIBRARIES by Engine.environment; wine's argv is rewritten to
// the Windows command line, which is where the process tells us who it is.
#include <ApplicationServices/ApplicationServices.h>
#include <crt_externs.h>
#include <string.h>
#include <strings.h>

static int is_steam_infrastructure(void) {
    char **argv = *_NSGetArgv();
    int argc = *_NSGetArgc();
    if (argc < 1 || argv == NULL || argv[0] == NULL) return 0;
    const char *exe = strrchr(argv[0], '\\');
    exe = exe ? exe + 1 : argv[0];
    static const char *quiet[] = {
        "steamwebhelper.exe", "steam.exe", "steamservice.exe",
        "explorer.exe", "SteamSetup.exe",
    };
    for (unsigned i = 0; i < sizeof(quiet) / sizeof(quiet[0]); i++) {
        if (strcasecmp(exe, quiet[i]) == 0) return 1;
    }
    return 0;
}

static OSStatus sevo_transform(ProcessSerialNumber *psn,
                               ProcessApplicationTransformState state) {
    if (state == kProcessTransformToForegroundApplication
        && is_steam_infrastructure()) {
        return noErr;
    }
    return TransformProcessType(psn, state);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)sevo_transform, (const void *)TransformProcessType },
};
