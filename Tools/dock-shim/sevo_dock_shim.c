// The bottle's face is Sevoflurane; its infrastructure must not reach the
// screen. Two levers, both per-process by the Windows exe name:
//
// 1. TransformProcessType is interposed away for Steam's own processes —
//    winemac.drv promotes any wine process that shows a window into the
//    Dock, and there is no demotion API. Games keep the real call: a
//    promoted game process is how fullscreen and input capture behave.
//
// 2. With SEVO_SUPPRESS_WINDOWS=1 in the environment (set by every managed
//    bottle spawn, in Engine.environment), NSWindow ordering is swizzled:
//    infrastructure processes cannot put a window on screen at all — the
//    app mirrors everything meaningful natively over CDP, and the
//    supervisor narrates failures in its own UI. Every suppressed window is
//    chronicled to ~/Library/Logs/Sevoflurane-windows.log with who/what/when
//    — the audit trail for "what tried to appear and why". A game's windows
//    reach the original implementation and order normally.
//
// Both levers ask "is this Steam's own infrastructure?" at call time, never
// at load time: wine rewrites argv to the Windows command line long after
// this dylib's constructor runs, so a name read in the constructor is the
// unix loader's path and matches nothing.
//
// Built x86_64 (the whole bottle runs under Rosetta) and injected with
// DYLD_INSERT_LIBRARIES by Engine.environment.
#include <ApplicationServices/ApplicationServices.h>
#include <crt_externs.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <pwd.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/time.h>
#include <unistd.h>
#include <mach-o/dyld.h>

// Wine rewrites argv[0] to the program's Windows path for a program named
// the Windows way and leaves the unix path alone for one named that way, so
// the file name is whatever follows the last separator of either kind.
static const char *exe_name(void) {
    char **argv = *_NSGetArgv();
    if (*_NSGetArgc() < 1 || argv == NULL || argv[0] == NULL) return "?";
    const char *exe = argv[0];
    for (const char *at = argv[0]; *at; at++) {
        if (*at == '\\' || *at == '/') exe = at + 1;
    }
    return exe;
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

// A managed bottle spawn gets a purpose-built environment holding only what
// wine needs, and wine needs no HOME — so the account database is where the
// chronicle's directory comes from when the variable is absent.
static const char *home_directory(void) {
    const char *home = getenv("HOME");
    if (home && *home) return home;
    struct passwd *account = getpwuid(getuid());
    return account ? account->pw_dir : NULL;
}

static void chronicle(const char *verb, id window) {
    const char *home = home_directory();
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
        // `-frame` answers 32 bytes, which the x86_64 ABI returns through a
        // hidden pointer: sent with plain objc_msgSend it corrupts the
        // caller's stack, and the first suppressed window takes the process
        // down with it.
        ((void (*)(CGRect *, id, SEL))objc_msgSend_stret)(
            &frame, window, sel_registerName("frame"));
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

// The verdict is settled once and reused: the first window a process orders
// comes long after wine has rewritten argv, and the name never changes
// again. A game therefore pays one name comparison for its whole run and
// then a direct jump to AppKit's own implementation.
static int verdict = -1;

static int suppressing(void) {
    if (verdict < 0) verdict = is_steam_infrastructure();
    return verdict;
}

// The overrides go on `WineWindow`, winemac.drv's own NSWindow subclass,
// never on NSWindow itself: replacing an AppKit implementation process-wide
// leaves a wine process unable to put up any window at all, its own or a
// game's — measured, on winemine, with every ordering entry point still
// chained to its original.
//
// A suppressed call therefore returns without reaching the superclass, and
// an allowed one is forwarded with `objc_msgSendSuper` — which is what
// `[super orderFront:]` compiles to, so AppKit sees exactly the call
// winemac.drv made.
static Class wine_window_class;

static void forward_to_super(id self, SEL selector, void *first, void *second) {
    struct objc_super target = { self, class_getSuperclass(wine_window_class) };
    ((void (*)(struct objc_super *, SEL, void *, void *))objc_msgSendSuper)(
        &target, selector, first, second);
}

static void sevo_order_window(id self, SEL _cmd, long place, long other) {
    if (suppressing()) {
        chronicle("suppressed", self);
        return;
    }
    forward_to_super(self, _cmd, (void *)place, (void *)other);
}

static void sevo_order_front(id self, SEL _cmd, id sender) {
    if (suppressing()) {
        chronicle("suppressed", self);
        return;
    }
    forward_to_super(self, _cmd, sender, NULL);
}

static void sevo_order_regardless(id self, SEL _cmd) {
    if (suppressing()) {
        chronicle("suppressed", self);
        return;
    }
    forward_to_super(self, _cmd, NULL, NULL);
}

// `-[WineWindow makeKeyAndOrderFront:]` is winemac.drv's own override, so
// there is no superclass call to make: it routes through
// `-orderBelow:orAbove:activate:`, which orders by `-orderFront:` and
// `-orderWindow:relativeTo:`. Suppressing those covers it, and this one is
// only chronicled so the audit trail shows the ask.
static IMP original_key_and_order_front;

static void sevo_key_and_order_front(id self, SEL _cmd, id sender) {
    if (suppressing()) chronicle("asked", self);
    ((void (*)(id, SEL, id))original_key_and_order_front)(self, _cmd, sender);
}

static void override(const char *name, IMP implementation, const char *types) {
    class_addMethod(wine_window_class, sel_registerName(name), implementation, types);
}

static int swizzled;

// This dylib loads before AppKit (insert libraries come first), so the class
// doesn't exist yet at constructor time — try again as each image lands.
// `WineWindow` arrives with winemac.drv, which is loaded on demand, long
// after AppKit is up.
static void sevo_try_swizzle(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    if (swizzled) return;
    wine_window_class = objc_getClass("WineWindow");
    if (!wine_window_class) return;
    swizzled = 1;
    override("orderWindow:relativeTo:", (IMP)sevo_order_window, "v@:qq");
    override("orderFront:", (IMP)sevo_order_front, "v@:@");
    override("orderFrontRegardless", (IMP)sevo_order_regardless, "v@:");
    Method key_and_order_front = class_getInstanceMethod(
        wine_window_class, sel_registerName("makeKeyAndOrderFront:"));
    if (key_and_order_front) {
        original_key_and_order_front
            = method_setImplementation(key_and_order_front, (IMP)sevo_key_and_order_front);
    }
    // One line per bottle process that can show a window, before the verdict
    // is asked for: this is how "the shim is live here" gets proved without a
    // window to point at.
    chronicle("armed", NULL);
}

__attribute__((constructor)) static void sevo_shim_init(void) {
    const char *mode = getenv("SEVO_SUPPRESS_WINDOWS");
    if (!mode || strcmp(mode, "1") != 0) return;
    _dyld_register_func_for_add_image(sevo_try_swizzle);
}
