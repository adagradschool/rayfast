// sys.m — system and utility commands: sleep, lock, restart, volume, Wi-Fi… (module "system").
// Every command is a row of a static C table: nothing is built at idle, rows only exist while a query matches.
// "How" is an argv for a short-lived child (pmset, osascript, networksetup), so rayfast loads nothing for it.
// RF_DRYRUN=1 writes "<cid>\t<argv>" to rfDataDir()/dryrun.log instead of acting (all tests run that way).
#import "rf.h"
#include <spawn.h>
#include <dlfcn.h>
#include <pwd.h>
#include <libproc.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <CommonCrypto/CommonDigest.h>
extern char **environ;

#define OSA "/usr/bin/osascript", "-e"
// Not here, on purpose: Do Not Disturb/Focus (no public API or command; only the private DoNotDisturb framework or a
// user-made Shortcut), Bluetooth power (IOBluetooth's power call is private; blueutil is a dependency), display
// brightness (DisplayServices is private). See docs/system.md.
typedef struct { const char *name, *title, *kw, *glyph; char confirm; const char *argv[8]; } SysCmd;
static const SysCmd kCmds[] = {
    {"sleep", "Sleep", "sleep suspend hibernate computer mac", "☾", 0, {"/usr/bin/pmset", "sleepnow"}},
    {"sleep-displays", "Sleep Displays", "sleep displays screen monitor off", "◐", 0, {"/usr/bin/pmset", "displaysleepnow"}},
    {"lock-screen", "Lock Screen", "lock screen computer away", "⚿", 0, {"@lock"}},
    {"screen-saver", "Start Screen Saver", "screen saver screensaver", "▦", 0, {"/usr/bin/open", "-a", "ScreenSaverEngine"}},
    {"log-out", "Log Out", "log out logout sign out sign off user", "⇥", 1, {OSA, "tell application \"loginwindow\" to «event aevtrlgo»"}},
    {"restart", "Restart", "restart reboot computer mac", "↻", 1, {OSA, "tell application \"loginwindow\" to «event aevtrrst»"}},
    {"shut-down", "Shut Down", "shut down shutdown power off turn off computer mac", "⏻", 1, {OSA, "tell application \"loginwindow\" to «event aevtrsdn»"}},
    {"empty-trash", "Empty Trash", "empty trash bin delete", "⌫", 1, {OSA, "tell application \"Finder\" to empty trash"}},
    {"show-desktop", "Show Desktop", "show desktop hide windows", "▭", 0, {"/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", "1"}},
    {"dark-mode", "Toggle Dark Mode", "toggle dark mode light mode appearance theme", "◑", 0,
        {OSA, "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"}},
    {"hidden-files", "Toggle Hidden Files", "toggle hidden files show hidden dotfiles finder", "◌", 1, {"/bin/sh", "-c",
        "case $(/usr/bin/defaults read com.apple.finder AppleShowAllFiles 2>/dev/null) in 1|[Yy]*|[Tt]*) v=false;; *) v=true;; esac; "
        "/usr/bin/defaults write com.apple.finder AppleShowAllFiles -bool $v && /usr/bin/killall Finder"}},
    {"eject-all", "Eject All Disks", "eject all disks drives volumes unmount", "⏏", 1, {OSA, "tell application \"Finder\" to eject (every disk whose ejectable is true)"}},
    {"wifi", "Toggle Wi-Fi", "toggle wifi wi-fi wireless airport network", "◠", 0, {"/bin/sh", "-c",
        "d=$(/usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '/Wi-Fi|AirPort/{getline; print $2; exit}'); "
        "case $(/usr/sbin/networksetup -getairportpower \"$d\") in *On) s=off;; *) s=on;; esac; /usr/sbin/networksetup -setairportpower \"$d\" $s"}},
    {"volume-up", "Volume Up", "volume up louder sound audio", "♪", 0, {OSA, "set volume output volume ((output volume of (get volume settings)) + 6.25)"}},
    {"volume-down", "Volume Down", "volume down quieter softer sound audio", "♪", 0, {OSA, "set volume output volume ((output volume of (get volume settings)) - 6.25)"}},
    {"quit-all", "Quit All Applications", "quit all applications apps close everything", "⌧", 1, {"@quit-all"}},
    {"kill-process", "Kill Process", "kill process task end force quit activity monitor pid cpu memory", "✕", 0, {"@view"}},
    {"mute", "Toggle Mute", "toggle mute unmute volume sound audio silence", "♪", 0, {OSA, "set volume output muted (not output muted of (get volume settings))"}},
};
#define NCMDS (sizeof kCmds / sizeof *kCmds)

static NSString *argvLine(const char *const *av) {
    NSMutableArray *p = [NSMutableArray array];
    for (int i = 0; i < 8 && av[i]; i++) [p addObject:@(av[i])];
    return [p componentsJoinedByString:@" "];
}
// Runs argv detached from the UI; the respawn waits for it (uiBusy) so it is reaped before execv().
static void spawnArgv(const char *const *av, BOOL wait) {
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    for (int fd = 0; fd < 3; fd++) posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);
    posix_spawnattr_t at; posix_spawnattr_init(&at);
    posix_spawnattr_setflags(&at, POSIX_SPAWN_CLOEXEC_DEFAULT);   // only the three /dev/null fds reach the child
    pid_t pid;
    int rc = posix_spawn(&pid, av[0], &fa, &at, (char *const *)av, environ);
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at);
    if (rc) { fprintf(stderr, "rayfast: system: can't run %s: %s\n", av[0], strerror(rc)); return; }
    if (wait) { int st; waitpid(pid, &st, 0); return; }
    uiBusy(1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int st; waitpid(pid, &st, 0);
        dispatch_async(dispatch_get_main_queue(), ^{ uiBusy(-1); });
    });
}
static BOOL dryRun(NSString *cid, NSString *what) {
    if (!getenv("RF_DRYRUN")) return NO;
    NSString *line = [NSString stringWithFormat:@"%@\t%@\n", cid, what];
    fprintf(stderr, "rayfast: dry run: %s", line.UTF8String);
    NSString *p = [rfDataDir() stringByAppendingPathComponent:@"dryrun.log"];
    FILE *f = fopen(p.fileSystemRepresentation, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
    return YES;
}
static NSArray<NSRunningApplication *> *regularApps(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSRunningApplication *r in NSWorkspace.sharedWorkspace.runningApplications)
        if (r.activationPolicy == NSApplicationActivationPolicyRegular && r.processIdentifier != getpid()) [a addObject:r];
    return a;
}
static void act(NSString *cid, const char *const *av, BOOL wait) {
    if (!strcmp(av[0], "@lock")) {   // no command locks the screen; login.framework is loaded only when asked
        if (dryRun(cid, @"SACLockScreenImmediate (login.framework)")) return;
        void *h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY);
        int (*lock)(void) = h ? (int (*)(void))dlsym(h, "SACLockScreenImmediate") : NULL;
        if (lock) { lock(); return; }
        static const char *const dim[] = {"/usr/bin/pmset", "displaysleepnow", NULL};   // private call gone: sleeping the displays
        spawnArgv(dim, NO);                                                             // locks when a password is required after sleep
        return;
    }
    if (!strcmp(av[0], "@view")) return;   // opens a view; nothing to run
    if (!strcmp(av[0], "@quit-all")) {     // every regular app but Finder (macOS relaunches it anyway) and rayfast
        NSMutableArray *ids = [NSMutableArray array];
        for (NSRunningApplication *r in regularApps()) if (![r.bundleIdentifier isEqual:@"com.apple.finder"]) [ids addObject:r.bundleIdentifier ?: @(r.processIdentifier).stringValue];
        if (dryRun(cid, [@"terminate " stringByAppendingString:[ids componentsJoinedByString:@" "]])) return;
        for (NSRunningApplication *r in regularApps()) if (![r.bundleIdentifier isEqual:@"com.apple.finder"]) [r terminate];
        return;
    }
    if (!dryRun(cid, argvLine(av))) spawnArgv(av, wait);
}
static const SysCmd *cmdNamed(NSString *cid) {
    if (![cid hasPrefix:@"system."]) return NULL;
    const char *n = [cid substringFromIndex:7].UTF8String;
    for (size_t i = 0; i < NCMDS; i++) if (!strcmp(kCmds[i].name, n)) return &kCmds[i];
    return NULL;
}
static NSString *cidOf(const SysCmd *c) { return [@"system." stringByAppendingString:@(c->name)]; }

#pragma mark confirm views
// What a destructive command will cost, said before ↩: cheap facts only (counts, sizes computed off the main thread).
static NSString *gConsequence;
static NSString *trashDir(void) { return getenv("RF_TRASH") ? @(getenv("RF_TRASH")) : [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"]; }
static NSString *sizeString(unsigned long long b) { return [NSByteCountFormatter stringFromByteCount:(long long)b countStyle:NSByteCountFormatterCountStyleFile]; }
static NSString *plural(NSUInteger n, NSString *one) { return [NSString stringWithFormat:@"%lu %@%@", (unsigned long)n, one, n == 1 ? @"" : @"s"]; }
static NSString *consequence(const SysCmd *c) {
    const char *n = c->name;
    if (!strcmp(n, "empty-trash")) {
        NSArray *top = [NSFileManager.defaultManager contentsOfDirectoryAtPath:trashDir() error:nil];
        if (!top) return @"Everything in the Trash, deleted for good (counting it needs Full Disk Access)";
        if (!top.count) return @"The Trash is already empty";
        NSUInteger items = 0; for (NSString *f in top) if (![f isEqual:@".DS_Store"]) items++;
        NSString *head = [NSString stringWithFormat:@"%@ deleted for good", plural(items, @"item")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // the size can take a while
            unsigned long long bytes = 0; NSUInteger seen = 0;
            NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:trashDir()]
                includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey] options:0 errorHandler:nil];
            for (NSURL *u in e) {
                NSNumber *s; [u getResourceValue:&s forKey:NSURLTotalFileAllocatedSizeKey error:nil];
                bytes += s.unsignedLongLongValue;
                if (++seen > 200000) break;
            }
            NSString *full = [NSString stringWithFormat:@"%@, %@, deleted for good", plural(items, @"item"), sizeString(bytes)];
            dispatch_async(dispatch_get_main_queue(), ^{ if ([gConsequence isEqual:head]) { gConsequence = full; uiRefresh(); } });
        });
        return head;
    }
    if (!strcmp(n, "hidden-files")) return @"Finder relaunches: its windows reopen, copies in progress stop";
    if (!strcmp(n, "eject-all")) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSURL *u in [NSFileManager.defaultManager mountedVolumeURLsIncludingResourceValuesForKeys:@[NSURLVolumeIsEjectableKey, NSURLVolumeNameKey]
                                                                                              options:NSVolumeEnumerationSkipHiddenVolumes]) {
            NSNumber *ej; NSString *nm;
            [u getResourceValue:&ej forKey:NSURLVolumeIsEjectableKey error:nil]; [u getResourceValue:&nm forKey:NSURLVolumeNameKey error:nil];
            if (ej.boolValue && nm) [names addObject:nm];
        }
        return names.count ? [NSString stringWithFormat:@"%@: %@", plural(names.count, @"disk"), [names componentsJoinedByString:@", "]] : @"No ejectable disks are mounted";
    }
    if (!strcmp(n, "quit-all")) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSRunningApplication *r in regularApps()) if (![r.bundleIdentifier isEqual:@"com.apple.finder"]) [names addObject:r.localizedName ?: @"?"];
        return names.count ? [NSString stringWithFormat:@"%@: %@", plural(names.count, @"app"), [names componentsJoinedByString:@", "]] : @"No apps to quit";
    }
    NSUInteger apps = regularApps().count;   // log out, restart, shut down
    return apps ? [NSString stringWithFormat:@"%@ will be asked to quit first", plural(apps, @"open app")] : @"No apps are open";
}
static void confirmView(const SysCmd *c) {
    NSString *cid = cidOf(c), *title = @(c->title);
    gConsequence = consequence(c);
    uint64_t opened = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    View *v = [View new];
    v->title = [title stringByAppendingString:@"?"];
    v->placeholder = @"↩ to confirm, esc to cancel";
    v->hint = [NSString stringWithFormat:@"↩ %@   esc Cancel", title];
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        Cmd *k = mkCmd([cid stringByAppendingString:@".confirm"], title, gConsequence, @(c->glyph), ^(BOOL alt) {
            if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - opened < 300 * NSEC_PER_MSEC) return;   // a double-tapped ↩ doesn't confirm
            act(cid, c->argv, NO); uiHide();
        });
        k->type = @"System"; k->verb = title;
        return @[k];
    };
    v->closed = ^{ gConsequence = nil; };
    uiPush(v);
}

#pragma mark kill process
// A snapshot of `ps` taken when the view opens (and after each kill): ps runs out of process, so rayfast never asks the
// kernel about other processes itself. A plain C array, freed when the view closes.
typedef struct { pid_t pid; uid_t uid; float cpu; long rssKB; time_t at; char name[64]; } Proc;   // at: when ps ran
static Proc *gProcs; static int gNProcs, gByMem;
static NSString *gKillNote, *gKillNoteQ;   // what the last ↩ did, shown in the acted row's place until the filter changes
static NSArray<Cmd *> *gKillRows; static NSUInteger gKillNoteAt;   // the rows last shown, and where the note goes
static int byCpu(const void *a, const void *b) { float d = ((const Proc *)b)->cpu - ((const Proc *)a)->cpu; return d > 0 ? 1 : d < 0 ? -1 : 0; }
static int byMem(const void *a, const void *b) { long d = ((const Proc *)b)->rssKB - ((const Proc *)a)->rssKB; return d > 0 ? 1 : d < 0 ? -1 : 0; }
static void loadProcs(void) {
    free(gProcs); gProcs = NULL; gNProcs = 0;
    FILE *f = popen("/bin/ps -axo pid=,uid=,pcpu=,rss=,comm=", "r");
    if (!f) return;
    int cap = 0; char line[1200]; time_t at = time(NULL);
    while (fgets(line, sizeof line, f)) {
        Proc p = {.at = at}; int n = 0;
        if (sscanf(line, " %d %u %f %ld %n", &p.pid, &p.uid, &p.cpu, &p.rssKB, &n) < 4 || !line[n]) continue;
        line[strcspn(line, "\n")] = 0;
        const char *path = line + n, *base = strrchr(path, '/');
        snprintf(p.name, sizeof p.name, "%s", base && base[1] ? base + 1 : path);
        if (gNProcs == cap) gProcs = realloc(gProcs, (cap = cap ? cap * 2 : 512) * sizeof *gProcs);
        gProcs[gNProcs++] = p;
    }
    pclose(f);
    qsort(gProcs, gNProcs, sizeof *gProcs, gByMem ? byMem : byCpu);
}
static NSString *ownerName(uid_t uid) { struct passwd *pw = getpwuid(uid); return pw ? @(pw->pw_name) : [NSString stringWithFormat:@"uid %u", uid]; }
// The note row matters for safety, not just feedback: a refresh keeps the selection at the same position, so the note
// takes the acted row's position. Anything else there (the next process, or one the 300 ms ps reload moved up) would get
// a double-tapped ↩ the user never aimed at it.
static void setNote(NSString *h, NSString *q, pid_t pid) {
    NSString *cid = [NSString stringWithFormat:@"system.kill.%d", pid];
    NSUInteger i = [gKillRows indexOfObjectPassingTest:^BOOL(Cmd *c, NSUInteger j, BOOL *stop) { return [c->cid isEqual:cid]; }];
    gKillNote = h; gKillNoteQ = q; gKillNoteAt = i == NSNotFound ? 0 : i; uiRefresh();
}
static void killProc(Proc p, BOOL hard, NSString *q) {
    NSString *name = @(p.name), *sig = hard ? @"KILL" : @"TERM";
    if (p.uid != getuid()) { setNote([NSString stringWithFormat:@"%@ belongs to %@: not yours to kill", name, ownerName(p.uid)], q, p.pid); return; }
    if (p.pid == getpid()) { setNote(@"That is rayfast itself", q, p.pid); return; }
    // The list can be minutes old and pids get reused: a process that started after ps ran is not the one shown.
    // (Not by name: ps shows argv[0], which programs rename, while the kernel keeps the executable's name.)
    struct proc_bsdinfo bi;
    if (proc_pidinfo(p.pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != sizeof bi || (time_t)bi.pbi_start_tvsec > p.at) {
        setNote([NSString stringWithFormat:@"%@ (%d) has already exited: nothing sent", name, p.pid], q, p.pid); loadProcs(); uiRefresh(); return;
    }
    NSString *cid = [NSString stringWithFormat:@"system.kill.%d", p.pid];
    if (!dryRun(cid, [NSString stringWithFormat:@"kill -%@ %d", sig, p.pid]) && kill(p.pid, hard ? SIGKILL : SIGTERM))
        setNote([NSString stringWithFormat:@"Couldn't stop %@: %s", name, strerror(errno)], q, p.pid);
    else setNote([NSString stringWithFormat:@"Sent %@ to %@ (%d)", sig, name, p.pid], q, p.pid);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ if (gProcs) { loadProcs(); uiRefresh(); } });
}
static void killView(void) {
    gByMem = 0; loadProcs();
    View *v = [View new];
    v->title = @"Kill Process";
    v->placeholder = @"Filter by name or pid…";
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        NSMutableArray *out = [NSMutableArray array];
        Cmd *note = nil;
        if (gKillNote && [q isEqual:gKillNoteQ]) {
            note = mkCmd(@"system.kill.note", gKillNote, nil, @"✓", ^(BOOL alt) {});
            note->type = @"Done"; note->verb = @"Nothing (pick another row)";
        } else gKillNote = nil;
        const char *lq = q.lowercaseString.UTF8String;
        BOOL num = q.length && [q rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
        if (!q.length) {   // the sort switch sits on top, so a stray ↩ in an unfiltered list kills nothing
            Cmd *k = mkCmd(@"system.kill.sort", gByMem ? @"Sort by CPU" : @"Sort by Memory",
                           gByMem ? @"Sorted by memory" : @"Sorted by CPU", @"⇅", ^(BOOL alt) {
                gByMem = !gByMem; qsort(gProcs, gNProcs, sizeof *gProcs, gByMem ? byMem : byCpu); uiRefresh();
            });
            k->type = @"Sort"; k->verb = @"Switch Sort";
            [out addObject:k];
        }
        uid_t me = getuid();
        for (int i = 0; i < gNProcs && out.count < 300; i++) {
            Proc p = gProcs[i];
            char pid[16]; snprintf(pid, sizeof pid, "%d", p.pid);
            if (q.length && !(num ? !strncmp(pid, lq, strlen(lq)) : rfMatch(@(p.name), nil, lq))) continue;
            BOOL exact = num && !strcmp(pid, lq);   // a typed pid is that process, ahead of every pid it prefixes
            NSString *sub = [NSString stringWithFormat:@"pid %d · %.1f%% CPU · %@", p.pid, p.cpu, sizeString((unsigned long long)p.rssKB * 1024)];
            if (p.uid != me) sub = [sub stringByAppendingFormat:@" · not yours (%@)", ownerName(p.uid)];
            Cmd *k = mkCmd([NSString stringWithFormat:@"system.kill.%d", p.pid], @(p.name), sub, @"✕", ^(BOOL alt) { killProc(p, alt, q); });
            k->type = p.uid == me ? @"Process" : @"Not Yours";
            k->verb = p.uid == me ? @"Quit (TERM)" : @"Can't Kill"; k->altVerb = p.uid == me ? @"Force Kill (KILL)" : nil;
            if (exact) [out insertObject:k atIndex:0]; else [out addObject:k];
        }
        if (note) [out insertObject:note atIndex:MIN(gKillNoteAt, out.count)];
        return gKillRows = out;
    };
    v->hint = @"↩ TERM   ⌘↩ KILL";
    v->closed = ^{ free(gProcs); gProcs = NULL; gNProcs = 0; gKillNote = gKillNoteQ = nil; gKillRows = nil; };
    gKillNote = nil;
    uiPush(v);
}

#pragma mark info rows
// battery, ip, disk, uptime, wifi: nothing is computed until the query names one. The cheap ones are syscalls
// (getifaddrs, statfs, sysctl); pmset and ipconfig run as a child off the main thread and refresh the list when they
// answer. Answers live in gInfo until the next respawn, which comes ~4 s after the launcher hides.
static NSMutableDictionary<NSString *, NSString *> *gInfo;
static void copyText(NSString *s) { NSPasteboard *pb = rfPasteboard(); [pb clearContents]; [pb setString:s forType:NSPasteboardTypeString]; }
// A secret: marked the way password managers do, so clipboard history (clip.m and others) doesn't keep it.
static void copySecret(NSString *s) {
    NSPasteboard *pb = rfPasteboard();
    [pb declareTypes:@[NSPasteboardTypeString, @"org.nspasteboard.ConcealedType"] owner:nil];
    [pb setString:s forType:NSPasteboardTypeString]; [pb setString:@"" forType:@"org.nspasteboard.ConcealedType"];
}
static NSString *runOut(const char *sh) {
    FILE *f = popen(sh, "r");
    if (!f) return @"";
    NSMutableData *d = [NSMutableData data]; char b[4096]; size_t n;
    while ((n = fread(b, 1, sizeof b, f))) [d appendBytes:b length:n];
    pclose(f);
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
}
// pmset -g batt: " -InternalBattery-0 (id=…)\t27%; discharging; 1:34 remaining present: true"
static NSString *parseBattery(NSString *o) {
    for (NSString *l in [o componentsSeparatedByString:@"\n"]) {
        NSRange t = [l rangeOfString:@"\t"];
        if (t.location == NSNotFound || [l rangeOfString:@"%"].location == NSNotFound) continue;
        NSString *r = [l substringFromIndex:NSMaxRange(t)];
        NSRange p = [r rangeOfString:@" present:"]; if (p.location != NSNotFound) r = [r substringToIndex:p.location];
        r = [r stringByReplacingOccurrencesOfString:@"(no estimate)" withString:@"estimating time"];
        return [r stringByReplacingOccurrencesOfString:@"; " withString:@", "];
    }
    return @"No battery";
}
// ipconfig getsummary: macOS hides the network's name ("<redacted>") from apps without Location access
static NSString *parseWifi(NSString *o) {
    if (!o.length || [o rangeOfString:@"LinkStatusActive : TRUE"].location == NSNotFound) return @"Not connected";
    for (NSString *l in [o componentsSeparatedByString:@"\n"]) {
        NSString *t = trim(l);
        if (![t hasPrefix:@"SSID : "]) continue;
        NSString *n = [t substringFromIndex:7];
        return [n isEqual:@"<redacted>"] ? @"Connected (macOS hides the name from apps without Location access)" : n;
    }
    return @"Connected";
}
static NSString *info(NSString *name, NSString *sh, NSString *(*parse)(NSString *)) {   // async; "…" until it answers
    if (!gInfo) gInfo = [NSMutableDictionary dictionary];
    if (gInfo[name]) return gInfo[name];
    gInfo[name] = @"…"; uiBusy(1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *r = parse(runOut(sh.UTF8String));
        dispatch_async(dispatch_get_main_queue(), ^{ gInfo[name] = r; uiBusy(-1); uiRefresh(); });
    });
    return @"…";
}
static NSString *wifiDev(void) {
    return @"d=$(/usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '/Wi-Fi|AirPort/{getline; print $2; exit}'); ";
}
static NSString *uptimeString(void) {
    struct timeval bt; size_t n = sizeof bt; int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &bt, &n, NULL, 0)) return @"Unknown";
    long s = time(NULL) - bt.tv_sec, d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60;
    return d ? [NSString stringWithFormat:@"%ld day%s, %ld h %ld min", d, d == 1 ? "" : "s", h, m] : [NSString stringWithFormat:@"%ld h %ld min", h, m];
}
static NSString *diskString(void) {
    struct statfs f;
    if (statfs("/System/Volumes/Data", &f) && statfs("/", &f)) return @"Unknown";
    return [NSString stringWithFormat:@"%@ free of %@", sizeString((unsigned long long)f.f_bavail * f.f_bsize), sizeString((unsigned long long)f.f_blocks * f.f_bsize)];
}
static void publicIP(void) {   // only on ↩: the one network call in this file
    NSString *cid = @"system.info.public-ip";
    if (dryRun(cid, @"/usr/bin/curl -s -m 5 https://api.ipify.org")) { gInfo[@"public"] = @"(dry run)"; uiRefresh(); return; }
    if (gInfo[@"public"]) return;
    gInfo[@"public"] = @"Asking api.ipify.org…"; uiRefresh(); uiBusy(1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *r = trim(runOut("/usr/bin/curl -s -m 5 https://api.ipify.org"));
        BOOL good = r.length && r.length < 64 && [r rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF.:"].invertedSet].location == NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            gInfo[@"public"] = good ? r : @"No answer (offline?)"; if (good) copyText(r);
            uiBusy(-1); uiRefresh();
        });
    });
}
static Cmd *infoRow(NSString *name, NSString *title, NSString *value, NSString *glyph) {
    Cmd *k = mkCmd([@"system.info." stringByAppendingString:name], value, title, glyph, ^(BOOL alt) { copyText(value); uiHide(); });
    k->type = @"Info"; k->verb = @"Copy"; k->score = 5000;
    return k;
}
// The query asks for an info row when it is one of the words, or a 3+ letter prefix of one
static BOOL asks(const char *lq, const char *words) {
    size_t n = strlen(lq);
    for (const char *w = words; *w; ) {
        size_t l = strcspn(w, "|");
        if (n == l ? !strncmp(w, lq, l) : n >= 3 && n < l && !strncmp(w, lq, n)) return YES;
        w += l; if (*w) w++;
    }
    return NO;
}
static void infoRows(const char *lq, NSMutableArray<Cmd *> *out) {
    if (asks(lq, "battery|power|charge|charging"))
        [out addObject:infoRow(@"battery", @"Battery", info(@"battery", @"/usr/bin/pmset -g batt", parseBattery), @"▮")];
    if (asks(lq, "ip|ip address|my ip|local ip|public ip|address")) {
        struct ifaddrs *ifs, *i;
        if (!getifaddrs(&ifs)) {
            for (i = ifs; i; i = i->ifa_next) {
                if (!i->ifa_addr || !(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK) || i->ifa_addr->sa_family != AF_INET) continue;
                char a[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, a, sizeof a);
                Cmd *k = infoRow([@"ip." stringByAppendingString:@(i->ifa_name)], [NSString stringWithFormat:@"Local IP · %s", i->ifa_name], @(a), @"⌖");
                [out addObject:k];
            }
            freeifaddrs(ifs);
        }
        NSString *pub = gInfo[@"public"];
        Cmd *k = mkCmd(@"system.info.public-ip", pub ?: @"Public IP", pub ? @"Public IP" : @"↩ asks api.ipify.org", @"⌖", ^(BOOL alt) {
            NSString *p = gInfo[@"public"];
            if (p && [p rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound && ![p hasPrefix:@"No "]) { copyText(p); uiHide(); }
            else { if (!gInfo) gInfo = [NSMutableDictionary dictionary]; publicIP(); }
        });
        k->type = @"Info"; k->verb = pub ? @"Copy" : @"Look Up"; k->score = 4999;
        [out addObject:k];
    }
    if (asks(lq, "disk|disk space|free space|storage")) [out addObject:infoRow(@"disk", @"Disk", diskString(), @"◔")];
    if (asks(lq, "uptime|boot|booted")) [out addObject:infoRow(@"uptime", @"Uptime", uptimeString(), @"◷")];
    if (asks(lq, "wifi|wi-fi|ssid|network name")) {
        NSString *sh = [wifiDev() stringByAppendingString:@"/usr/sbin/ipconfig getsummary \"$d\""];
        [out addObject:infoRow(@"wifi", @"Wi-Fi", info(@"wifi", sh, parseWifi), @"◠")];
    }
}

#pragma mark rows
static Cmd *rowFor(const SysCmd *c, int score) {
    Cmd *k = mkCmd(cidOf(c), @(c->title), nil, @(c->glyph), ^(BOOL alt) {
        if (c->confirm) confirmView(c);
        else if (!strcmp(c->argv[0], "@view")) killView();
        else { act(cidOf(c), c->argv, NO); uiHide(); }
    });
    k->type = @"System"; k->score = score;
    if (c->confirm || !strcmp(c->argv[0], "@view")) k->verb = c->confirm ? @"Continue…" : @"Open";
    return k;
}
// "set volume 40", "volume 40", "vol 40%"
static int volumeArg(const char *lq) {
    int v = -1, n = 0;
    if (sscanf(lq, "set volume %d%n", &v, &n) == 1 || sscanf(lq, "volume %d%n", &v, &n) == 1 || sscanf(lq, "vol %d%n", &v, &n) == 1) {
        const char *r = lq + n; if (*r == '%') r++;
        if (!*r && v >= 0 && v <= 100) return v;
    }
    return -1;
}
static void setVolume(int v, BOOL wait) {
    char script[64]; snprintf(script, sizeof script, "set volume output volume %d", v);
    const char *av[] = {OSA, script, NULL};
    act(@"system.set-volume", av, wait);
}
// "quit safari", "close mail", "force quit xcode": one row per running regular app whose name matches the rest.
// Only behind a quit prefix, so typing an app's name never offers to quit it.
static void quitApp(NSString *bid, BOOL force) {
    NSString *cid = [NSString stringWithFormat:@"system.%@.%@", force ? @"force-quit" : @"quit", bid];
    if (dryRun(cid, [NSString stringWithFormat:@"%@ %@", force ? @"forceTerminate" : @"terminate", bid])) return;
    for (NSRunningApplication *r in [NSRunningApplication runningApplicationsWithBundleIdentifier:bid])
        if (r.processIdentifier != getpid()) { if (force) [r forceTerminate]; else [r terminate]; }
}
static void quitRows(const char *lq, NSMutableArray<Cmd *> *out) {
    BOOL force = !strncmp(lq, "force quit ", 11);
    const char *rest = force ? lq + 11 : !strncmp(lq, "quit ", 5) ? lq + 5 : !strncmp(lq, "close ", 6) ? lq + 6 : NULL;
    if (!rest || !*rest) return;
    for (NSRunningApplication *r in regularApps()) {
        NSString *bid = r.bundleIdentifier, *name = r.localizedName;
        int sc = bid && name ? rfMatch(name, nil, rest) : 0;
        if (!sc) continue;
        Cmd *k = mkCmd([NSString stringWithFormat:@"system.%@.%@", force ? @"force-quit" : @"quit", bid],
                       [NSString stringWithFormat:@"%@ %@", force ? @"Force Quit" : @"Quit", name], nil, force ? @"⌧" : @"⨯", ^(BOOL alt) {
            quitApp(bid, force || alt); uiHide();
        });
        k->type = @"System"; k->score = sc + 1000;   // above the app itself: the prefix says what is wanted
        k->verb = force ? @"Force Quit" : @"Quit"; if (!force) k->altVerb = @"Force Quit";
        [out addObject:k];
    }
}
static void sysSearch(NSString *q, const char *lq, NSMutableArray<Cmd *> *out) {
    quitRows(lq, out);
    infoRows(lq, out);
    int v = volumeArg(lq);
    if (v >= 0) {
        Cmd *k = mkCmd([NSString stringWithFormat:@"system.set-volume.%d", v], [NSString stringWithFormat:@"Set Volume to %d%%", v], nil, @"♪", ^(BOOL alt) { setVolume(v, NO); uiHide(); });
        k->type = @"System"; k->score = 10000;
        [out addObject:k];
        return;
    }
    for (size_t i = 0; i < NCMDS; i++) {
        int s = rfMatch(@(kCmds[i].title), @(kCmds[i].kw), lq);
        if (s) [out addObject:rowFor(&kCmds[i], s)];
    }
}
// A hotkey bound to an info row (⌘K binds any row with a cid) opens the launcher on that row, computed fresh.
static void infoView(NSString *name) {
    NSString *word = [name hasPrefix:@"ip."] || [name isEqual:@"public-ip"] ? @"ip" : name;
    View *v = [View new];
    v->title = @"System Info"; v->placeholder = @"↩ copies"; v->hint = @"↩ Copy   esc Close";
    v->rows = ^NSArray<Cmd *> *(NSString *q) { NSMutableArray *o = [NSMutableArray array]; infoRows(word.UTF8String, o); return o; };
    uiPush(v);
}
// A hotkey: plain commands act at once; destructive ones open the launcher on their confirm view. Every cid a row
// carries lands somewhere: rows inside a view (confirm, kill) open that view, info rows open on themselves.
static BOOL sysRun(NSString *cid) {
    if ([cid hasPrefix:@"system.set-volume."]) {
        int v = [cid substringFromIndex:18].intValue;
        if (v < 0 || v > 100) return NO;
        setVolume(v, NO); return YES;
    }
    if ([cid hasPrefix:@"system.info."]) { uiShow(); infoView([cid substringFromIndex:12]); return YES; }
    if ([cid hasPrefix:@"system.kill."]) cid = @"system.kill-process";
    if ([cid hasSuffix:@".confirm"]) cid = [cid substringToIndex:cid.length - 8];
    if ([cid hasPrefix:@"system.quit."]) { quitApp([cid substringFromIndex:12], NO); return YES; }
    if ([cid hasPrefix:@"system.force-quit."]) { quitApp([cid substringFromIndex:18], YES); return YES; }
    const SysCmd *c = cmdNamed(cid);
    if (!c) return NO;
    if (c->confirm) { uiShow(); confirmView(c); }
    else if (!strcmp(c->argv[0], "@view")) { uiShow(); killView(); }
    else act(cid, c->argv, NO);
    return YES;
}
static int sysCli(int argc, const char **argv) {
    if (argc >= 1 && !strcmp(argv[0], "list")) {   // cid, type, title, argv
        for (size_t i = 0; i < NCMDS; i++)
            printf("system.%s\tSystem\t%s\t%s\n", kCmds[i].name, kCmds[i].title, argvLine(kCmds[i].argv).UTF8String);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[0], "do")) {    // act now, no confirm (dry-run honoured)
        if (!strcmp(argv[1], "system.set-volume") && argc >= 3) { setVolume(atoi(argv[2]), YES); return 0; }
        const SysCmd *c = cmdNamed(@(argv[1]));
        if (!c) { fprintf(stderr, "no such command %s\n", argv[1]); return 1; }
        act(@(argv[1]), c->argv, YES);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[0], "hotkey")) return sysRun(@(argv[1])) ? 0 : 1;
    fprintf(stderr, "usage: rayfast --run system list | do <cid> [arg] | hotkey <cid>\n");
    return 2;
}
static const RFModule kSystem = {"system", NULL, sysSearch, sysRun, sysCli};
RF_MODULE(kSystem)

#pragma mark utilities (module "util")
// uuid, lorem 50, password 24, base64/unbase64, url encode/decode, sha256/sha1/md5, epoch, color, wc: answers computed
// from the query like the calculator's, each behind its own word, so a query the calculator answers never reaches
// one (the only bare form is a 9-10 or 12-13 digit number, which the calculator leaves alone). ↩ copies the answer.
static NSString *argAfter(NSString *q, NSString *word) {   // "base64 hello" -> "hello"; nil unless q starts with word + space
    if (q.length <= word.length + 1 || [q rangeOfString:word options:NSCaseInsensitiveSearch | NSAnchoredSearch].location == NSNotFound
        || [q characterAtIndex:word.length] != ' ') return nil;
    return [q substringFromIndex:word.length + 1];
}
static int numAfter(const char *lq, const char *word, int def, int lo, int hi) {   // "lorem" -> def, "lorem 50" -> 50, else -1
    size_t n = strlen(word);
    if (strncmp(lq, word, n)) return -1;
    if (!lq[n]) return def;
    char *e; long v = strtol(lq + n, &e, 10);
    return lq[n] == ' ' && !*e && v >= lo && v <= hi ? (int)v : -1;
}
static NSString *lorem(int n) {
    static const char *w[] = {"lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do",
        "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore", "magna", "aliqua", "enim", "ad", "minim", "veniam",
        "quis", "nostrud", "exercitation", "ullamco", "laboris", "nisi", "aliquip", "ex", "ea", "commodo", "consequat", "duis",
        "aute", "irure", "in", "reprehenderit", "voluptate", "velit", "esse", "cillum", "fugiat", "nulla", "pariatur"};
    NSMutableString *s = [NSMutableString string];
    for (int i = 0, k = 0, len = 8; i < n; i++, k++) {   // sentences of 6-12 words
        NSString *word = @(w[i % (sizeof w / sizeof *w)]);
        BOOL end = i == n - 1 || k == len - 1;
        if (end) len = 6 + (len * 5 + i) % 7;
        [s appendString:k ? word : word.capitalizedString];
        [s appendString:end ? (i == n - 1 ? @"." : @". ") : @" "];
        if (end) k = -1;
    }
    return s;
}
static NSString *password(int n) {   // arc4random_uniform: no modulo bias
    static const char set[] = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*-_=+?";
    char b[129];
    for (int i = 0; i < n; i++) b[i] = set[arc4random_uniform(sizeof set - 1)];
    b[n] = 0;
    return @(b);
}
static NSString *hexOf(const unsigned char *d, int n) { NSMutableString *s = [NSMutableString string]; for (int i = 0; i < n; i++) [s appendFormat:@"%02x", d[i]]; return s; }
static NSString *dateOf(double t) {
    time_t s = (time_t)t; struct tm lt, ut; char a[64], b[32];
    localtime_r(&s, &lt); gmtime_r(&s, &ut);
    strftime(a, sizeof a, "%a %e %b %Y, %H:%M:%S %Z", &lt); strftime(b, sizeof b, "%Y-%m-%dT%H:%M:%SZ", &ut);
    return [NSString stringWithFormat:@"%s  ·  %s", a, b];
}
static BOOL parseHex(NSString *h, int rgb[3]) {
    if ([h hasPrefix:@"#"]) h = [h substringFromIndex:1];
    if ((h.length != 3 && h.length != 6) || [h rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet].location != NSNotFound) return NO;
    unsigned v = (unsigned)strtoul(h.UTF8String, NULL, 16);
    if (h.length == 3) v = (v >> 8 & 0xf) * 0x110000 + (v >> 4 & 0xf) * 0x1100 + (v & 0xf) * 0x11;
    rgb[0] = v >> 16 & 255; rgb[1] = v >> 8 & 255; rgb[2] = v & 255;
    return YES;
}
static id swatch(int rgb[3]) {   // the colour itself as the row's icon
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, 32, 32, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(c, rgb[0] / 255., rgb[1] / 255., rgb[2] / 255., 1);
    CGContextFillEllipseInRect(c, CGRectMake(2, 2, 28, 28));
    CGImageRef im = CGBitmapContextCreateImage(c);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    return CFBridgingRelease(im);
}
static NSString *colorString(int rgb[3]) {
    double r = rgb[0] / 255., g = rgb[1] / 255., b = rgb[2] / 255., mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b)), l = (mx + mn) / 2, h = 0, s = 0, d = mx - mn;
    if (d > 0) {
        s = d / (1 - fabs(2 * l - 1));
        h = mx == r ? fmod((g - b) / d + 6, 6) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4;
        h *= 60;
    }
    return [NSString stringWithFormat:@"rgb(%d, %d, %d)  ·  hsl(%.0f, %.0f%%, %.0f%%)  ·  #%02x%02x%02x", rgb[0], rgb[1], rgb[2], h, s * 100, l * 100, rgb[0], rgb[1], rgb[2]];
}
static NSString *wcString(NSString *t) {
    __block NSUInteger words = 0, chars = 0, lines = 1;
    [t enumerateSubstringsInRange:NSMakeRange(0, t.length) options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                       usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) { words++; }];
    [t enumerateSubstringsInRange:NSMakeRange(0, t.length) options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationSubstringNotRequired
                       usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) { chars++; }];
    for (NSUInteger i = 0; i < t.length; i++) if ([t characterAtIndex:i] == '\n') lines++;
    return [NSString stringWithFormat:@"%@, %@%@", plural(words, @"word"), plural(chars, @"character"), lines > 1 ? [@", " stringByAppendingString:plural(lines, @"line")] : @""];
}
// One answer for the query, or nil. *name gets the cid's tail, *what the row's subtitle.
static NSString *utilAnswer(NSString *q, const char *lq, NSString **name, NSString **what, id *icon, int *score) {
    NSString *a; int n;
    *score = 5000;
    if (!strcmp(lq, "uuid") || !strcmp(lq, "guid")) { *name = @"uuid"; *what = @"New UUID"; return NSUUID.UUID.UUIDString; }
    if ((n = numAfter(lq, "lorem", 50, 1, 2000)) > 0) { *name = @"lorem"; *what = [NSString stringWithFormat:@"Lorem ipsum, %d words", n]; return lorem(n); }
    if ((n = numAfter(lq, "password", 20, 4, 128)) > 0) {
        if (!lq[8]) *score = 1;   // bare "password" may well mean the Passwords app
        *name = @"password"; *what = [NSString stringWithFormat:@"Random password, %d characters", n]; return password(n);
    }
    if ((a = argAfter(q, @"unbase64")) || (a = argAfter(q, @"base64d")) || (a = argAfter(q, @"base64 decode"))) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:trim(a) options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        *name = @"unbase64"; *what = s ? @"Decoded from Base64" : @"Not valid Base64 text";
        return s ?: nil;
    }
    if ((a = argAfter(q, @"base64"))) { *name = @"base64"; *what = @"Base64"; return [[a dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]; }
    if ((a = argAfter(q, @"url encode")) || (a = argAfter(q, @"urlencode"))) {
        NSMutableCharacterSet *ok = [NSMutableCharacterSet alphanumericCharacterSet]; [ok addCharactersInString:@"-._~"];
        *name = @"url-encode"; *what = @"URL-encoded"; return [a stringByAddingPercentEncodingWithAllowedCharacters:ok];
    }
    if ((a = argAfter(q, @"url decode")) || (a = argAfter(q, @"urldecode"))) {
        *name = @"url-decode"; *what = @"URL-decoded"; return [[a stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
    }
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    if ((a = argAfter(q, @"sha256"))) { NSData *d = [a dataUsingEncoding:NSUTF8StringEncoding]; CC_SHA256(d.bytes, (CC_LONG)d.length, md); *name = @"sha256"; *what = @"SHA-256"; return hexOf(md, CC_SHA256_DIGEST_LENGTH); }
    if ((a = argAfter(q, @"sha1"))) { NSData *d = [a dataUsingEncoding:NSUTF8StringEncoding]; CC_SHA1(d.bytes, (CC_LONG)d.length, md); *name = @"sha1"; *what = @"SHA-1"; return hexOf(md, CC_SHA1_DIGEST_LENGTH); }
    if ((a = argAfter(q, @"md5"))) { NSData *d = [a dataUsingEncoding:NSUTF8StringEncoding]; CC_MD5(d.bytes, (CC_LONG)d.length, md); *name = @"md5"; *what = @"MD5"; return hexOf(md, CC_MD5_DIGEST_LENGTH); }
    if (!strcmp(lq, "epoch") || !strcmp(lq, "unix time") || !strcmp(lq, "timestamp")) {
        *name = @"epoch"; *what = @"Unix time now"; return [NSString stringWithFormat:@"%ld", time(NULL)];
    }
    size_t l = strlen(lq);
    const char *ep = !strncmp(lq, "epoch ", 6) ? lq + 6 : lq;
    if ((l = strlen(ep)) && strspn(ep, "0123456789") == l && (l == 9 || l == 10 || l == 12 || l == 13)) {
        *name = @"epoch"; *what = l > 10 ? @"Unix time in milliseconds, as a date" : @"Unix time, as a date";
        return dateOf(strtod(ep, NULL) / (l > 10 ? 1000 : 1));
    }
    int rgb[3];
    if (((a = argAfter(q, @"color")) || (a = argAfter(q, @"colour")) || ([q hasPrefix:@"#"] && (a = q))) && parseHex(trim(a), rgb)) {
        *name = @"color"; *what = @"Colour"; *icon = swatch(rgb); return colorString(rgb);
    }
    if ((a = argAfter(q, @"wc")) || (a = argAfter(q, @"count"))) { *name = @"wc"; *what = @"Word count"; return wcString(a); }
    return nil;
}
static void utilSearch(NSString *q, const char *lq, NSMutableArray<Cmd *> *out) {
    NSString *name, *what; id icon = nil; int score;
    NSString *ans = utilAnswer(q, lq, &name, &what, &icon, &score);
    if (!ans.length) return;
    NSString *shown = [[ans componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" ⏎ "];
    if (shown.length > 300) shown = [[shown substringToIndex:300] stringByAppendingString:@"…"];
    Cmd *k = mkCmd([@"util." stringByAppendingString:name], shown, what, @"=", ^(BOOL alt) {
        if ([name isEqual:@"password"]) copySecret(ans); else copyText(ans);
        uiHide();
    });
    k->icon = icon; k->type = @"Utility"; k->verb = @"Copy Answer"; k->score = score;
    [out addObject:k];
}
static int utilCli(int argc, const char **argv) {
    if (argc >= 1 && !strcmp(argv[0], "pb-get")) { printf("%s\n", [rfPasteboard() stringForType:NSPasteboardTypeString].UTF8String ?: ""); return 0; }
    if (argc >= 1 && !strcmp(argv[0], "pb-types")) { for (NSString *t in rfPasteboard().types) printf("%s\n", t.UTF8String); return 0; }
    if (argc >= 1) {   // `rayfast --run util "sha256 abc"`: the answer, as ↩ would copy it
        NSString *q = trim(@(argv[0])), *name, *what; id icon; int score;
        NSString *a = utilAnswer(q, q.lowercaseString.UTF8String, &name, &what, &icon, &score);
        if (!a) return 1;
        printf("util.%s\t%s\n", name.UTF8String, a.UTF8String);
        return 0;
    }
    fprintf(stderr, "usage: rayfast --run util pb-get | <query>\n");
    return 2;
}
// A hotkey bound to a utility row opens the launcher on that utility: what is typed is its argument ("hello" for
// util.base64), and the ones that need none (uuid, password, lorem, epoch) answer at once.
static const struct { const char *name, *word, *title; } kUtilWords[] = {
    {"uuid", "uuid", "New UUID"}, {"lorem", "lorem", "Lorem Ipsum"}, {"password", "password", "Random Password"},
    {"unbase64", "unbase64", "Decode Base64"}, {"base64", "base64", "Base64"}, {"url-encode", "url encode", "URL Encode"},
    {"url-decode", "url decode", "URL Decode"}, {"sha256", "sha256", "SHA-256"}, {"sha1", "sha1", "SHA-1"}, {"md5", "md5", "MD5"},
    {"epoch", "epoch", "Unix Time"}, {"color", "color", "Colour"}, {"wc", "wc", "Word Count"},
};
static BOOL utilRun(NSString *cid) {
    for (size_t i = 0; i < sizeof kUtilWords / sizeof *kUtilWords; i++) {
        if (![cid isEqual:[@"util." stringByAppendingString:@(kUtilWords[i].name)]]) continue;
        NSString *word = @(kUtilWords[i].word);
        View *v = [View new];
        v->title = @(kUtilWords[i].title); v->placeholder = [word stringByAppendingString:@" …"]; v->hint = @"↩ Copy Answer   esc Close";
        v->rows = ^NSArray<Cmd *> *(NSString *q) {
            NSString *full = q.length ? [NSString stringWithFormat:@"%@ %@", word, q] : word;
            NSMutableArray *o = [NSMutableArray array]; utilSearch(full, full.lowercaseString.UTF8String, o); return o;
        };
        uiShow(); uiPush(v);
        return YES;
    }
    return NO;
}
static const RFModule kUtil = {"util", NULL, utilSearch, utilRun, utilCli};
// A second constructor in one file needs its own name (RF_MODULE always defines rfModuleInit).
__attribute__((constructor)) static void rfUtilInit(void) { rfAddModule(&kUtil); }

#pragma mark emoji picker (module "emoji")
// Names come from the system, not from bundled data: on first use every scalar the Apple Color Emoji font draws is
// named by CFStringTransform (kCFStringTransformToUnicodeName), flags by NSLocale's country names, and the result is
// written once to rfDataDir()/emoji.idx ("<emoji>\t<name>\t<keywords>\t<m if it takes a skin tone>\n", ~40 KB, ~30 ms),
// rebuilt when the OS build changes. The view mmap()s it while open; idle holds nothing. Not covered: ZWJ sequences
// (family, profession, rainbow flag) and keycaps, which have no single-scalar name.
#include <sys/mman.h>
#include <sys/stat.h>
#import <CoreText/CoreText.h>
// Words people type that the formal Unicode names don't have.
static const char *const kEmojiKw[][2] = {
    {"😂", "lol laugh crying"}, {"🤣", "rofl lol laugh"}, {"😀", "smile happy"}, {"😊", "smile happy blush"},
    {"🙂", "smile"}, {"😍", "love eyes crush"}, {"🥰", "love hearts"}, {"😘", "kiss love"}, {"😉", "wink"},
    {"😎", "cool sunglasses"}, {"🤔", "think hmm"}, {"😢", "sad cry tear"}, {"😭", "sob cry sad"}, {"😡", "angry mad"},
    {"😱", "scream shock"}, {"🙄", "eyeroll"}, {"😅", "sweat nervous"}, {"🥲", "smile tear"}, {"😴", "sleep tired zzz"},
    {"🤯", "mind blown"}, {"🥳", "party celebrate birthday"}, {"🎉", "party tada celebrate"}, {"🎂", "birthday cake"},
    {"👍", "+1 like yes ok approve thumbsup"}, {"👎", "-1 dislike no thumbsdown"}, {"👌", "ok perfect"}, {"👏", "clap applause bravo"},
    {"🙏", "pray please thanks hope"}, {"👋", "wave hi hello bye"}, {"💪", "strong muscle flex"}, {"🤝", "deal agree"},
    {"✌", "peace victory"}, {"🤞", "luck hope fingers crossed"}, {"👀", "eyes look see"}, {"❤", "heart love red"},
    {"💔", "heartbreak broken"}, {"🔥", "fire lit hot"}, {"✨", "sparkles magic shiny"}, {"⭐", "star"}, {"💯", "100 hundred perfect"},
    {"✅", "check done yes ok tick"}, {"❌", "x no cross wrong"}, {"⚠", "warning caution"}, {"🚀", "rocket launch ship"},
    {"💡", "idea bulb"}, {"🐛", "bug"}, {"☕", "coffee tea"}, {"🍺", "beer"}, {"🍕", "pizza"}, {"💩", "poop poo"},
    {"🤷", "shrug dunno whatever"}, {"🤦", "facepalm"}, {"🙈", "monkey see no evil"}, {"💀", "skull dead"},
};
static NSString *emojiIdxPath(void) { return [rfDataDir() stringByAppendingPathComponent:@"emoji.idx"]; }
static NSString *osBuild(void) { char b[64] = ""; size_t n = sizeof b; sysctlbyname("kern.osversion", b, &n, NULL, 0); return @(b); }
static CTFontRef emojiFont(CGFloat size) { return CTFontCreateWithName(CFSTR("AppleColorEmoji"), size, NULL); }
static CFIndex glyphCount(CTFontRef f, NSString *s) {
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:s attributes:@{(id)kCTFontAttributeName: (__bridge id)f}];
    CTLineRef l = CTLineCreateWithAttributedString((CFAttributedStringRef)a);
    CFIndex n = CTLineGetGlyphCount(l); CFRelease(l);
    return n;
}
// Returns how long it took (ms), or -1.
static double buildEmojiIndex(void) {
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    CTFontRef f = emojiFont(16);
    if (!f) return -1;
    NSMutableDictionary *kw = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < sizeof kEmojiKw / sizeof *kEmojiKw; i++) kw[@(kEmojiKw[i][0])] = @(kEmojiKw[i][1]);
    NSMutableString *out = [NSMutableString stringWithFormat:@"v1 %@\n", osBuild()];
    // faces and people first: the order an empty query shows after the recents
    static const uint32_t R[][2] = {{0x1F600, 0x1F64F}, {0x1F900, 0x1FAFF}, {0x1F440, 0x1F4FF}, {0x1F300, 0x1F43F}, {0x1F500, 0x1F5FF},
                                    {0x1F680, 0x1F6FF}, {0x2600, 0x27BF}, {0x1F000, 0x1F2FF}, {0x1F700, 0x1F8FF}, {0x203C, 0x25FF},
                                    {0x27C0, 0x3299}, {0xA9, 0xAE}};
    for (int r = 0; r < (int)(sizeof R / sizeof *R); r++) for (uint32_t c = R[r][0]; c <= R[r][1]; c++) {
        if ((c >= 0x1F3FB && c <= 0x1F3FF) || (c >= 0x1F1E6 && c <= 0x1F1FF) || (c >= 0x20D0 && c <= 0x20FF)) continue;   // tones, flag letters, combining marks (keycap)
        UniChar u[2]; CGGlyph g[2];
        CFIndex len = CFStringGetSurrogatePairForLongCharacter(c, u) ? 2 : 1;
        if (!CTFontGetGlyphsForCharacters(f, u, g, len)) continue;
        NSString *s = [NSString stringWithCharacters:u length:len];
        NSMutableString *nm = [s mutableCopy];
        CFStringTransform((__bridge CFMutableStringRef)nm, NULL, kCFStringTransformToUnicodeName, false);
        if (![nm hasPrefix:@"\\N{"]) continue;
        NSString *name = [nm substringWithRange:NSMakeRange(3, nm.length - 4)].lowercaseString;
        if ([name hasSuffix:@" sign"] && [name componentsSeparatedByString:@" "].count > 2) name = [name substringToIndex:name.length - 5];   // "thumbs up sign", not "warning sign"
        if (c == 0x2764) name = @"red heart";   // its Unicode name is "heavy black heart"
        BOOL tone = glyphCount(f, [s stringByAppendingString:@"\U0001F3FD"]) == 1;
        if (c < 0x1F000) s = [s stringByAppendingString:@"️"];   // text-default symbols: ask for the emoji form
        [out appendFormat:@"%@\t%@\t%@\t%@\n", s, name, kw[[s stringByReplacingOccurrencesOfString:@"️" withString:@""]] ?: @"", tone ? @"m" : @""];
    }
    NSLocale *en = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    for (NSString *cc in NSLocale.ISOCountryCodes) {
        if (cc.length != 2) continue;
        NSMutableString *s = [NSMutableString string];
        for (int i = 0; i < 2; i++) { UniChar u[2]; CFStringGetSurrogatePairForLongCharacter(0x1F1E6 + [cc characterAtIndex:i] - 'A', u); [s appendString:[NSString stringWithCharacters:u length:2]]; }
        NSString *name = [en localizedStringForCountryCode:cc];
        if (name && glyphCount(f, s) == 1) [out appendFormat:@"%@\tflag %@\t%@ country\t\n", s, name.lowercaseString, cc.lowercaseString];
    }
    CFRelease(f);
    NSString *tmp = [emojiIdxPath() stringByAppendingString:@".tmp"];
    if (![out writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:nil] || rename(tmp.fileSystemRepresentation, emojiIdxPath().fileSystemRepresentation)) return -1;
    return (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
}
// The index, mapped read-only while the view is open.
static const char *gEmo; static size_t gEmoLen;
static void unmapEmoji(void) { if (gEmo) munmap((void *)gEmo, gEmoLen); gEmo = NULL; gEmoLen = 0; }
static BOOL mapEmoji(void) {
    if (gEmo) return YES;
    for (int pass = 0; pass < 2; pass++) {
        int fd = open(emojiIdxPath().fileSystemRepresentation, O_RDONLY);
        struct stat st;
        if (fd >= 0 && !fstat(fd, &st) && st.st_size > 0) {
            gEmo = mmap(NULL, gEmoLen = st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
            if (gEmo == MAP_FAILED) gEmo = NULL;
        }
        if (fd >= 0) close(fd);
        const char *nl = gEmo ? memchr(gEmo, '\n', gEmoLen) : NULL;
        NSString *head = nl ? [[NSString alloc] initWithBytes:gEmo length:nl - gEmo encoding:NSUTF8StringEncoding] : nil;
        if ([head isEqual:[@"v1 " stringByAppendingString:osBuild()]]) return YES;
        unmapEmoji();
        if (pass || buildEmojiIndex() < 0) return NO;
    }
    return NO;
}
static NSString *emojiRecentPath(void) { return [rfDataDir() stringByAppendingPathComponent:@"emoji-recent"]; }
static NSArray<NSString *> *emojiRecents(void) {
    NSString *s = [NSString stringWithContentsOfFile:emojiRecentPath() encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *a = [[s componentsSeparatedByString:@"\n"] mutableCopy] ?: [NSMutableArray array];
    [a removeObject:@""];
    return a;
}
static void noteEmoji(NSString *base) {   // stored without the skin tone, so a changed setting applies to recents too
    NSMutableArray *a = [emojiRecents() mutableCopy];
    [a removeObject:base]; [a insertObject:base atIndex:0];
    while (a.count > 24) [a removeLastObject];
    [[[a componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:emojiRecentPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
// emoji.skin = 1..5 (light … dark), or none
static NSString *withTone(NSString *e, BOOL takesTone) {
    int t = rfSetting(@"emoji.skin", @"0").intValue;
    if (!takesTone || t < 1 || t > 5) return e;
    UniChar u[2]; CFStringGetSurrogatePairForLongCharacter(0x1F3FA + t, u);
    return [[e stringByReplacingOccurrencesOfString:@"️" withString:@""] stringByAppendingString:[NSString stringWithCharacters:u length:2]];
}
static id emojiIcon(NSString *e) {   // 48 px, the size ui.m draws app icons at
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, 48, 48, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CTFontRef f = emojiFont(38);
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:e attributes:@{(id)kCTFontAttributeName: (__bridge id)f}];
    CTLineRef l = CTLineCreateWithAttributedString((CFAttributedStringRef)a);
    CGRect b = CTLineGetImageBounds(l, c);
    CGContextSetTextPosition(c, (48 - b.size.width) / 2 - b.origin.x, (48 - b.size.height) / 2 - b.origin.y);
    CTLineDraw(l, c);
    CGImageRef im = CGBitmapContextCreateImage(c);
    CFRelease(l); CFRelease(f); CGContextRelease(c); CGColorSpaceRelease(cs);
    return CFBridgingRelease(im);
}
typedef struct { const char *line; int score; int order; } EmoHit;
static int byEmoHit(const void *a, const void *b) {
    const EmoHit *x = a, *y = b;
    return x->score != y->score ? y->score - x->score : x->order - y->order;
}
// 5: the name is the query; 4: a keyword is; 3: the name starts with it; 2: every query word starts a word of the name
// or keywords; 1: substring
static int emojiScore(const char *name, size_t nlen, const char *kw, size_t klen, const char *lq) {
    char hay[512], pat[260]; snprintf(hay, sizeof hay, " %.*s %.*s ", (int)nlen, name, (int)klen, kw);
    if (strlen(lq) == nlen && !strncmp(name, lq, nlen)) return 5;
    snprintf(pat, sizeof pat, " %s ", lq);
    if (strstr(hay + nlen + 1, pat)) return 4;
    if (!strncmp(name, lq, strlen(lq)) && strlen(lq) <= nlen) return 3;
    char q[256]; snprintf(q, sizeof q, "%s", lq);
    BOOL all = YES; int words = 0;
    for (char *save, *w = strtok_r(q, " ", &save); w; w = strtok_r(NULL, " ", &save)) {
        snprintf(pat, sizeof pat, " %s", w); words++;
        if (!strstr(hay, pat)) { all = NO; break; }
    }
    if (words && all) return 2;
    return strlen(lq) >= 3 && strstr(hay, lq) ? 1 : 0;
}
#define EMOJI_ROWS 40   // each row renders its colour icon, so the list stays short; typing narrows it
static Cmd *emojiRow(NSString *base, NSString *name, BOOL tone) {
    NSString *e = withTone(base, tone);
    NSString *title = name.capitalizedString;
    Cmd *k = mkCmd([@"emoji." stringByAppendingString:base], title, nil, e, ^(BOOL alt) {
        copyText(e); noteEmoji(base);
        if (alt) uiHide(); else uiHideAndPaste();
    });
    k->icon = emojiIcon(e); k->type = @"Emoji"; k->verb = @"Paste Emoji"; k->altVerb = @"Copy Emoji";
    return k;
}
static NSArray<Cmd *> *emojiRows(NSString *q) {
    if (!mapEmoji()) return @[mkCmd(nil, @"Couldn't build the emoji list", emojiIdxPath(), @"!", ^(BOOL alt) {})];
    const char *lq = q.lowercaseString.UTF8String, *p = memchr(gEmo, '\n', gEmoLen) + 1, *end = gEmo + gEmoLen;
    NSArray *recent = q.length ? @[] : emojiRecents();
    EmoHit *hits = malloc(sizeof *hits * 4096); int n = 0;
    while (p < end && n < 4096) {
        const char *nl = memchr(p, '\n', end - p) ?: end, *t1 = memchr(p, '\t', nl - p), *t2 = t1 ? memchr(t1 + 1, '\t', nl - t1 - 1) : NULL,
                   *t3 = t2 ? memchr(t2 + 1, '\t', nl - t2 - 1) : NULL;
        if (t3) {
            int s = q.length ? emojiScore(t1 + 1, t2 - t1 - 1, t2 + 1, t3 - t2 - 1, lq) : 1;
            if (s) { hits[n] = (EmoHit){p, s, n}; n++; }
        }
        p = nl + 1;
    }
    qsort(hits, n, sizeof *hits, byEmoHit);
    NSMutableArray *out = [NSMutableArray array];
    NSMutableDictionary *byBase = recent.count ? [NSMutableDictionary dictionary] : nil;
    for (int i = 0; i < n && (byBase || out.count < EMOJI_ROWS); i++) {
        const char *l = hits[i].line, *nl = memchr(l, '\n', end - l) ?: end, *t1 = memchr(l, '\t', nl - l), *t2 = memchr(t1 + 1, '\t', nl - t1 - 1),
                   *t3 = memchr(t2 + 1, '\t', nl - t2 - 1);
        NSString *base = [[NSString alloc] initWithBytes:l length:t1 - l encoding:NSUTF8StringEncoding];
        NSString *name = [[NSString alloc] initWithBytes:t1 + 1 length:t2 - t1 - 1 encoding:NSUTF8StringEncoding];
        BOOL tone = t3 + 1 < nl && t3[1] == 'm';
        if (byBase) { byBase[base] = @[name, @(tone)]; continue; }
        [out addObject:emojiRow(base, name, tone)];
    }
    if (byBase) {   // empty query: recently used first, then the list in font order
        for (NSString *b in recent) { NSArray *v = byBase[b]; if (v && out.count < EMOJI_ROWS) [out addObject:emojiRow(b, v[0], [v[1] boolValue])]; }
        for (int i = 0; i < n && out.count < EMOJI_ROWS; i++) {
            const char *l = hits[i].line, *t1 = memchr(l, '\t', end - l);
            NSString *base = [[NSString alloc] initWithBytes:l length:t1 - l encoding:NSUTF8StringEncoding];
            if ([recent containsObject:base]) continue;
            NSArray *v = byBase[base]; [out addObject:emojiRow(base, v[0], [v[1] boolValue])];
        }
    }
    free(hits);
    return out;
}
static void emojiView(void) {
    View *v = [View new];
    v->title = @"Search Emoji";
    v->placeholder = @"Search emoji by name or keyword…";
    v->hint = @"Skin tone: emoji.skin = 1 (light) … 5 (dark) in the config";
    v->rows = ^NSArray<Cmd *> *(NSString *q) { return emojiRows(q); };
    v->closed = ^{ unmapEmoji(); };
    uiPush(v);
}
static void emojiSearch(NSString *q, const char *lq, NSMutableArray<Cmd *> *out) {
    int s = rfMatch(@"Search Emoji", @"emoji emoticon smiley symbols picker", lq);
    if (!s) return;
    Cmd *k = mkCmd(@"emoji.search", @"Search Emoji", @"Paste an emoji by name", @"☺", ^(BOOL alt) { emojiView(); });
    k->type = @"Command"; k->verb = @"Open"; k->score = s;
    [out addObject:k];
}
static BOOL emojiRun(NSString *cid) {
    if ([cid isEqual:@"emoji.search"]) { uiShow(); emojiView(); return YES; }
    if ([cid hasPrefix:@"emoji."]) { NSString *e = [cid substringFromIndex:6]; copyText(e); noteEmoji(e); uiHideAndPaste(); return YES; }   // a bound emoji
    return NO;
}
static int emojiCli(int argc, const char **argv) {
    if (argc >= 1 && !strcmp(argv[0], "build")) {   // rebuild the index; prints entries, bytes, ms
        double ms = buildEmojiIndex();
        if (ms < 0 || !mapEmoji()) return 1;
        int n = 0; for (size_t i = 0; i < gEmoLen; i++) n += gEmo[i] == '\n';
        printf("%d emoji, %zu bytes, %.1f ms\n", n - 1, gEmoLen, ms);
        return 0;
    }
    if (argc >= 1 && !strcmp(argv[0], "search")) {  // the view's rows for a query: emoji, cid, title
        for (Cmd *k in emojiRows(argc > 1 ? @(argv[1]) : @"")) printf("%s\t%s\t%s\n", k->glyph.UTF8String, k->cid.UTF8String, k->title.UTF8String);
        return 0;
    }
    fprintf(stderr, "usage: rayfast --run emoji build | search [query]\n");
    return 2;
}
static const RFModule kEmoji = {"emoji", NULL, emojiSearch, emojiRun, emojiCli};
__attribute__((constructor)) static void rfEmojiInit(void) { rfAddModule(&kEmoji); }
