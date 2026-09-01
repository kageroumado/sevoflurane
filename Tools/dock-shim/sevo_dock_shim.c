// The bottle's face is Sevoflurane; its infrastructure must not reach the
// screen. Two levers, both per-process by the Windows exe name (wine
// rewrites argv to the Windows command line):
//
// 1. TransformProcessType is interposed away for Steam's own processes —
//    winemac.drv promotes any wine process that shows a window into the
//    Dock, and there is no demotion API. Games keep the real call: a
//    promoted game process is how fullscreen and input capture behave.
//
// 2. With SEVO_SUPPRESS_WINDOWS=1 in the environment (set by supervised
//    client launches, never by winecfg or a game), NSWindow ordering is
//    swizzled: infrastructure processes cannot put a window on screen at
//    all — the app mirrors everything meaningful natively over CDP, and
//    the supervisor narrates failures in its own UI. Every suppressed
//    window is chronicled to ~/Library/Logs/Sevoflurane-windows.log with
//    who/what/when — the audit trail for "what tried to appear and why".
//    Games get no swizzle at all: their windows order normally at zero
//    overhead.
//
// Built x86_64 (the whole bottle runs under Rosetta) and injected with
// DYLD_INSERT_LIBRARIES by Engine.environment.
#include <ApplicationServices/ApplicationServices.h>
#include <crt_externs.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/time.h>
#include <unistd.h>
#include <mach-o/dyld.h>

static const char *exe_name(void) {
    char **argv = *_NSGetArgv();
    if (*_NSGetArgc() < 1 || argv == NULL || argv[0] == NULL) return "?";
    const char *exe = strrchr(argv[0], '\\');
    return exe ? exe + 1 : argv[0];
}

static int is_steam_infrastructure(void) {
    static const char *quiet[] = {
        "steamwebhelper.exe", "steam.exe", "steamservice.exe",
        "steamerrorreporter.exe", "steamerrorreporter64.exe",
        "explorer.exe", "SteamSetup.exe",
    };
    const char *exe = exe_name();
    for (unsigned i = 0; i < sizeof(quiet) / sizeof(quiet[0]); i++) {
        if (strcasecmp(exe, quiet[i]) == 0) return 1;
    }
    return 0;
}

// MARK: - The chronicle

static void chronicle(const char *verb, id window) {
    const char *home = getenv("HOME");
    if (!home) return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/Library/Logs/Sevoflurane-windows.log", home);
    FILE *log = fopen(path, "a");
    if (!log) return;
    const char *title = "";
    const char *class_name = "";
    CGRect frame = CGRectZero;
    if (window) {
        class_name = object_getClassName(window);
        id ns_title = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("title"));
        if (ns_title) {
            title = ((const char *(*)(id, SEL))objc_msgSend)(
                ns_title, sel_registerName("UTF8String"));
            if (!title) title = "";
        }
        frame = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel_registerName("frame"));
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm parts;
    localtime_r(&now.tv_sec, &parts);
    fprintf(log, "%02d:%02d:%02d.%03d %s pid=%d %s %s \"%s\" %.0fx%.0f\n",
            parts.tm_hour, parts.tm_min, parts.tm_sec, (int)(now.tv_usec / 1000),
            verb, getpid(), exe_name(), class_name, title,
            frame.size.width, frame.size.height);
    fclose(log);
}

// MARK: - Dock promotion

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

// MARK: - Window ordering

// Suppression swizzles install only in infrastructure processes — a game
// never pays the fopen, and its windows order normally.
static void sevo_order_window(id self, SEL _cmd, long place, long other) {
    (void)_cmd; (void)place; (void)other;
    chronicle("suppressed", self);
}

static void sevo_order_front(id self, SEL _cmd, id sender) {
    (void)_cmd; (void)sender;
    chronicle("suppressed", self);
}

static void sevo_order_regardless(id self, SEL _cmd) {
    (void)_cmd;
    chronicle("suppressed", self);
}

static void swizzle(Class window_class, const char *name, IMP replacement) {
    Method method = class_getInstanceMethod(window_class, sel_registerName(name));
    if (method) method_setImplementation(method, replacement);
}

static int swizzled;

// This dylib loads before AppKit (insert libraries come first), so NSWindow
// doesn't exist yet at constructor time — try again as each image lands.
static void sevo_try_swizzle(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    if (swizzled) return;
    Class window_class = objc_getClass("NSWindow");
    if (!window_class) return;
    swizzled = 1;
    swizzle(window_class, "orderWindow:relativeTo:", (IMP)sevo_order_window);
    swizzle(window_class, "orderFront:", (IMP)sevo_order_front);
    swizzle(window_class, "makeKeyAndOrderFront:", (IMP)sevo_order_front);
    swizzle(window_class, "orderFrontRegardless", (IMP)sevo_order_regardless);
    chronicle("armed", NULL);
}

__attribute__((constructor)) static void sevo_shim_init(void) {
    const char *mode = getenv("SEVO_SUPPRESS_WINDOWS");
    if (!mode || strcmp(mode, "1") != 0) return;
    if (!is_steam_infrastructure()) return;
    _dyld_register_func_for_add_image(sevo_try_swizzle);
}
