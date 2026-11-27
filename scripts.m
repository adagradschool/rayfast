// scripts.m — Script Commands: every executable in the scripts folder is a launcher command.
// Metadata follows Raycast's Script Commands format ("# @raycast.title …" comment lines near the top), so existing
// scripts work unchanged. Scripts run out of process; nothing here loads a framework or reads a file at start().
#import "rf.h"
#include <dirent.h>
#include <spawn.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
extern char **environ;

// One discovered script. Metadata is parsed from the file's head once and cached on disk by (mtime, size), so after a
// respawn only scripts that changed are read again.
@interface Script : NSObject { @public NSString *path, *rel; NSDictionary<NSString *, NSString *> *meta; NSArray *args; } @end
@implementation Script @end

static NSMutableDictionary<NSString *, Script *> *gScripts;   // path -> script, built on the first query after a start
static NSMutableDictionary *gCache;                           // path -> @{m: "mtime.size", meta: {…}}, mirrors scripts.plist
static double gScanAt;

static NSString *cachePath(void) { return [rfDataDir() stringByAppendingPathComponent:@"scripts.plist"]; }
static NSArray<NSString *> *scriptDirs(void) {
    NSString *def = [cfgDir() stringByAppendingPathComponent:@"scripts"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *d in [rfSetting(@"scripts.dir", def) componentsSeparatedByString:@":"])
        if (trim(d).length) [out addObject:trim(d).stringByExpandingTildeInPath];
    return out;
}

// "# @raycast.title Foo" (or //, --, and @rayfast.) in the first 8 KB -> @{title: Foo}
static NSDictionary *parseMeta(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return @{};
    char buf[8192]; ssize_t n = read(fd, buf, sizeof buf); close(fd);
    if (n <= 0) return @{};
    NSString *s = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding]
               ?: [[NSString alloc] initWithBytes:buf length:n encoding:NSISOLatin1StringEncoding];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        NSString *l = trim(line);
        if (!([l hasPrefix:@"#"] || [l hasPrefix:@"//"] || [l hasPrefix:@"--"])) continue;
        NSRange r = [l rangeOfString:@"@raycast."];
        if (r.location == NSNotFound) r = [l rangeOfString:@"@rayfast."];
        if (r.location == NSNotFound || r.location > 4) continue;
        NSString *kv = [l substringFromIndex:NSMaxRange(r)];
        NSRange sp = [kv rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *k = sp.location == NSNotFound ? kv : [kv substringToIndex:sp.location];
        NSString *v = sp.location == NSNotFound ? @"" : trim([kv substringFromIndex:sp.location]);
        if (k.length && !m[k]) m[k] = v;
    }
    return m;
}

static void addScript(NSString *dir, NSString *rel, const struct stat *st, NSMutableDictionary *seen, BOOL *dirty) {
    NSString *path = [dir stringByAppendingPathComponent:rel];
    NSString *stamp = [NSString stringWithFormat:@"%ld.%09ld.%lld", (long)st->st_mtimespec.tv_sec, st->st_mtimespec.tv_nsec, (long long)st->st_size];
    NSDictionary *c = gCache[path];
    if (![c[@"m"] isEqual:stamp]) { c = @{@"m": stamp, @"meta": parseMeta(path)}; gCache[path] = c; *dirty = YES; }
    Script *s = gScripts[path];
    if (!s || s->meta != c[@"meta"]) { s = [Script new]; s->path = path; s->rel = rel; s->meta = c[@"meta"]; }
    seen[path] = s;
}

// Stat the folders (and one level of subfolders); re-read only scripts whose mtime or size changed. At most once a second,
// so typing doesn't re-stat on every key, but a script added or edited shows up on the next open.
static void scan(void) {
    double now = CFAbsoluteTimeGetCurrent();
    if (gScripts && now - gScanAt < 1) return;
    gScanAt = now;
    BOOL dirty = NO;
    if (!gCache) gCache = [NSMutableDictionary dictionaryWithContentsOfFile:cachePath()] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    for (NSString *dir in scriptDirs()) {
        NSMutableArray *subs = [NSMutableArray arrayWithObject:@""];
        for (NSUInteger i = 0; i < subs.count; i++) {
            NSString *sub = subs[i];
            DIR *d = opendir([dir stringByAppendingPathComponent:sub].fileSystemRepresentation);
            if (!d) continue;
            struct dirent *e;
            while ((e = readdir(d))) {
                if (e->d_name[0] == '.') continue;   // dotfiles, . and ..
                NSString *rel = [sub stringByAppendingPathComponent:@(e->d_name)];
                struct stat st;
                if (stat([dir stringByAppendingPathComponent:rel].fileSystemRepresentation, &st)) continue;
                if (S_ISDIR(st.st_mode)) { if (!sub.length) [subs addObject:rel]; continue; }   // one level deep
                if (S_ISREG(st.st_mode) && (st.st_mode & 0111)) addScript(dir, rel, &st, seen, &dirty);
            }
            closedir(d);
        }
    }
    for (NSString *p in gCache.allKeys) if (!seen[p]) { [gCache removeObjectForKey:p]; dirty = YES; }
    gScripts = seen;
    if (dirty) [gCache writeToFile:cachePath() atomically:YES];
}

static NSString *sTitle(Script *s) {
    NSString *t = s->meta[@"title"];
    return t.length ? t : s->path.lastPathComponent.stringByDeletingPathExtension;
}
static NSString *sMode(Script *s) {
    NSString *m = s->meta[@"mode"].lowercaseString;
    return [@[@"silent", @"compact", @"fulloutput", @"inline"] containsObject:m] ? m : @"compact";
}
static NSString *sGlyph(Script *s) {
    NSString *i = s->meta[@"icon"];   // an emoji or one character; image paths: sImage; URLs: never fetched
    return i.length && [i rangeOfComposedCharacterSequenceAtIndex:0].length == i.length ? i : @"$";
}
// "@raycast.icon images/x.png" (relative to the script, absolute or ~): a 48 px tile (24 pt at 2x), made once by ImageIO
// without decoding the file at full size, then kept as raw BGRA under rfDataDir()/script-icons keyed by (path, mtime,
// size): after a respawn it is mapped, not decoded (16 decodes cost ~9 ms, 16 maps a fraction of one).
#define ICON_PX 48
static NSMutableDictionary *gImages;   // resolved path -> CGImage or NSNull, for this shown session only
static id tileImage(NSData *d) {
    static CGColorSpaceRef cs; if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
    id im = CFBridgingRelease(CGImageCreate(ICON_PX, ICON_PX, 8, 32, ICON_PX * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                            dp, NULL, false, kCGRenderingIntentDefault));
    CGDataProviderRelease(dp);
    return im;
}
static NSData *decodeTile(NSString *p) {   // the image fitted and centred in a transparent ICON_PX square, or nil
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:p], NULL);
    if (!src) return nil;
    CGImageRef t = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)@{
        (id)kCGImageSourceThumbnailMaxPixelSize: @ICON_PX, (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES});
    CFRelease(src);
    if (!t) return nil;
    NSMutableData *px = [NSMutableData dataWithLength:ICON_PX * ICON_PX * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(px.mutableBytes, ICON_PX, ICON_PX, 8, ICON_PX * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    size_t w = CGImageGetWidth(t), h = CGImageGetHeight(t);
    if (g) CGContextDrawImage(g, CGRectMake((ICON_PX - (double)w) / 2, (ICON_PX - (double)h) / 2, w, h), t);
    CGContextRelease(g); CGColorSpaceRelease(cs); CGImageRelease(t);
    return g ? px : nil;
}
static id sImage(Script *s) {
    NSString *i = s->meta[@"icon"];
    if (i.length < 2 || [i rangeOfComposedCharacterSequenceAtIndex:0].length == i.length || [i containsString:@"://"]) return nil;
    NSString *p = [i hasPrefix:@"/"] || [i hasPrefix:@"~"] ? i.stringByExpandingTildeInPath
                : [s->path.stringByDeletingLastPathComponent stringByAppendingPathComponent:i];
    id im = gImages[p];
    if (im) return im == NSNull.null ? nil : im;
    if (!gImages) gImages = [NSMutableDictionary dictionary];
    gImages[p] = NSNull.null;
    struct stat st;
    if (stat(p.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode)) return nil;
    uint64_t h = 1469598103934665603ULL;   // FNV-1a of "path mtime size": an edited image gets a new file
    for (const char *c = [NSString stringWithFormat:@"%@ %ld.%ld %lld", p, (long)st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec, (long long)st.st_size].UTF8String; *c; c++)
        h = (h ^ (uint8_t)*c) * 1099511628211ULL;
    NSString *dir = [rfDataDir() stringByAppendingPathComponent:@"script-icons"], *f = [dir stringByAppendingFormat:@"/%016llx", h];
    NSData *d = [NSData dataWithContentsOfFile:f options:NSDataReadingMappedAlways error:nil];
    if (d.length != ICON_PX * ICON_PX * 4) {   // not cached yet (or torn): decode, then write it whole under a temporary name
        if (!(d = decodeTile(p))) return nil;
        NSFileManager *fm = NSFileManager.defaultManager;   // edited images leave old tiles behind: past 512, start over
        if ([fm contentsOfDirectoryAtPath:dir error:nil].count > 512) [fm removeItemAtPath:dir error:nil];
        if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [d writeToFile:f atomically:YES];
    }
    return gImages[p] = tileImage(d);
}

#pragma mark running

// Running scripts' process groups. Each run is its own group; quitting rayfast (exit or SIGTERM) kills them all, so
// nothing outlives it. A respawn never happens mid-run (uiBusy), so execv() leaves nothing behind either. A crash or
// SIGKILL can't clean up, so the groups are also listed on disk (pgid + leader start time) for the next start() to reap.
static pid_t gGroups[64]; static long long gStarts[64]; static int gNGroups;
static NSString *runningPath(void) { return [rfDataDir() stringByAppendingPathComponent:@"running"]; }
static long long procStart(pid_t p, pid_t *pgid) {   // start time in µs, -1 if no such process
    struct kinfo_proc k; size_t n = sizeof k; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, p};
    if (sysctl(mib, 4, &k, &n, NULL, 0) || n < sizeof k) return -1;
    if (pgid) *pgid = k.kp_eproc.e_pgid;
    return k.kp_proc.p_starttime.tv_sec * 1000000LL + k.kp_proc.p_starttime.tv_usec;
}
static void reapLeftovers(void) {   // groups a crashed instance left running; one failed stat() when there are none
    const char *f = runningPath().fileSystemRepresentation; struct stat st;
    if (stat(f, &st)) return;
    for (NSString *l in [[NSString stringWithContentsOfFile:@(f) encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"]) {
        NSArray *w = [l componentsSeparatedByString:@" "]; if (w.count != 2) continue;
        pid_t pg = [w[0] intValue], grp = 0; long long at = [w[1] longLongValue]; if (pg <= 1) continue;
        long long now = procStart(pg, &grp);
        // leader alive: only if it is the very process we started. Leader gone: a pgid can't be reused while any
        // member of its group lives, so whatever still answers to it is ours (or nothing is, and kill fails)
        if (now < 0 || (now == at && grp == pg)) kill(-pg, SIGKILL);
    }
    unlink(f);
}
static void killGroups(void) { for (int i = 0; i < gNGroups; i++) kill(-gGroups[i], SIGKILL); unlink(runningPath().fileSystemRepresentation); }
static void trackGroup(pid_t pg, BOOL add) {
    static dispatch_source_t term;
    if (!term) {
        atexit(killGroups);
        term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{ killGroups(); signal(SIGTERM, SIG_DFL); raise(SIGTERM); });
        dispatch_resume(term);
    }
    if (add) { if (gNGroups < 64) { gStarts[gNGroups] = procStart(pg, NULL); gGroups[gNGroups++] = pg; } }
    else for (int i = 0; i < gNGroups; i++) if (gGroups[i] == pg) { gStarts[i] = gStarts[--gNGroups]; gGroups[i] = gGroups[gNGroups]; break; }
    NSMutableString *rec = [NSMutableString string];
    for (int i = 0; i < gNGroups; i++) [rec appendFormat:@"%d %lld\n", gGroups[i], gStarts[i]];
    if (gNGroups) [rec writeToFile:runningPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    else unlink(runningPath().fileSystemRepresentation);
    // SIGTERM is caught only while something runs: an ignored signal would survive the respawn's execv()
    signal(SIGTERM, gNGroups ? SIG_IGN : SIG_DFL);
}

// The login shell's PATH (Homebrew & co. live there, not in a GUI app's PATH), resolved by a clean `$SHELL -l` once and
// cached on disk for a day. Resolved off the main thread on the first query; a run that needs it before then waits
// for it off the main thread too (at most the 5 s guard), so a slow shell never freezes the launcher.
static dispatch_queue_t pathQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("scripts.path", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static NSString *gLoginPath;
static NSString *resolveLoginPath(void) {
    NSString *file = [rfDataDir() stringByAppendingPathComponent:@"login-path.txt"];
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
    NSString *cached = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    if (cached.length && a && -a.fileModificationDate.timeIntervalSinceNow < 86400) return cached;
    NSString *fallback = cached ?: @(getenv("PATH") ?: "/usr/bin:/bin:/usr/sbin:/sbin");
    const char *sh = getenv("SHELL"); if (!sh || access(sh, X_OK)) sh = "/bin/zsh";
    NSMutableArray *env = [NSMutableArray array];   // a fresh login, as a new Terminal window gets it
    for (NSString *k in @[@"HOME", @"USER", @"LOGNAME", @"SHELL", @"TMPDIR", @"LANG"])
        if (getenv(k.UTF8String)) [env addObject:[NSString stringWithFormat:@"%@=%s", k, getenv(k.UTF8String)]];
    const char *envp[8]; int n = 0; for (NSString *e in env) envp[n++] = e.UTF8String; envp[n] = NULL;
    int po[2]; if (pipe(po)) return fallback;
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, po[1], 1);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t at; posix_spawnattr_init(&at);
    posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawnattr_setpgroup(&at, 0);
    const char *argv[] = {sh, "-l", "-c", "/usr/bin/env", NULL};   // env's output parses the same whatever the shell
    pid_t pid; int rc = posix_spawn(&pid, sh, &fa, &at, (char **)argv, (char **)envp);
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at); close(po[1]);
    NSMutableData *d = [NSMutableData data];
    if (!rc) {   // a login script that hangs (or leaves a daemon holding the pipe) gets 5 s, then its group is killed
        double end = CFAbsoluteTimeGetCurrent() + 5; char b[4096]; ssize_t r;
        for (;;) {
            struct pollfd pf = {po[0], POLLIN, 0}; int left = (int)((end - CFAbsoluteTimeGetCurrent()) * 1000);
            if (left <= 0 || poll(&pf, 1, left) == 0) { kill(-pid, SIGKILL); d.length = 0; break; }
            if ((r = read(po[0], b, sizeof b)) > 0) { if (d.length < (1 << 20)) [d appendBytes:b length:r]; }
            else if (r == 0 || errno != EINTR) break;
        }
        int st; while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    }
    close(po[0]);
    NSString *path = nil;
    for (NSString *l in [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"])
        if ([l hasPrefix:@"PATH="]) path = [l substringFromIndex:5];
    if (!path.length) return fallback;
    [path writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}
static void prefetchLoginPath(void) {
    if (!gLoginPath) dispatch_async(pathQueue(), ^{ if (!gLoginPath) gLoginPath = resolveLoginPath(); });
}
static void withLoginPath(void (^f)(NSString *path)) {   // f on the main thread, at once when the PATH is known
    if (gLoginPath) { f(gLoginPath); return; }
    dispatch_async(pathQueue(), ^{
        if (!gLoginPath) gLoginPath = resolveLoginPath();
        dispatch_async(dispatch_get_main_queue(), ^{ f(gLoginPath); });
    });
}

// Run a script out of process: its own process group (so a timeout or quit kills everything it started), stdin closed,
// the login shell's PATH, stdout and stderr collected. done() gets the exit status (-1: couldn't start) on the main thread.
static void spawnScript(Script *s, NSArray<NSString *> *args, NSString *path, void (^done)(int, NSString *, NSString *));
static void runScript(Script *s, NSArray<NSString *> *args, void (^done)(int status, NSString *out, NSString *err)) {
    uiBusy(1);   // the run outlives the window, from ↩ on (it may wait for the PATH first): no respawn until it's over
    withLoginPath(^(NSString *path) { spawnScript(s, args, path, done); });
}
static void spawnScript(Script *s, NSArray<NSString *> *args, NSString *path, void (^done)(int, NSString *, NSString *)) {
    void (^fail)(NSString *) = ^(NSString *why) { done(-1, @"", why); uiBusy(-1); };
    NSMutableArray *env = [NSMutableArray arrayWithObject:[@"PATH=" stringByAppendingString:path]];
    for (char **e = environ; *e; e++) if (strncmp(*e, "PATH=", 5)) [env addObject:@(*e)];
    const char **envp = calloc(env.count + 1, sizeof *envp);
    for (NSUInteger i = 0; i < env.count; i++) envp[i] = [env[i] UTF8String];
    int po[2], pe[2];
    if (pipe(po)) { free(envp); fail(@"can't create a pipe"); return; }
    if (pipe(pe)) { free(envp); close(po[0]); close(po[1]); fail(@"can't create a pipe"); return; }
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, po[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pe[1], 2);
    NSString *cwd = s->meta[@"currentDirectoryPath"].stringByExpandingTildeInPath;
    if (!cwd.length) cwd = s->path.stringByDeletingLastPathComponent;
    posix_spawn_file_actions_addchdir_np(&fa, cwd.fileSystemRepresentation);
    posix_spawnattr_t at; posix_spawnattr_init(&at);
    posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    posix_spawnattr_setpgroup(&at, 0);
    sigset_t none, all; sigemptyset(&none); sigfillset(&all);
    posix_spawnattr_setsigmask(&at, &none);
    posix_spawnattr_setsigdefault(&at, &all);
    const char *argv[8] = {s->path.fileSystemRepresentation};
    for (NSUInteger i = 0; i < args.count && i < 6; i++) argv[i + 1] = args[i].UTF8String;
    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], &fa, &at, (char **)argv, (char **)envp);
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at); free(envp);
    close(po[1]); close(pe[1]);
    if (rc) { close(po[0]); close(pe[0]); fail(@(strerror(rc))); return; }
    trackGroup(pid, YES);
    int timeout = MAX(1, rfSetting(@"scripts.timeout", @"60").intValue);
    __block BOOL over = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!over) kill(-pid, SIGKILL);
    });
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t g = dispatch_group_create();
    // The run is over when the script exits, not at EOF: a daemon it started (out of its group, so no kill reaches it)
    // may hold stdout open for good. Readers keep draining until EOF or 0.5 s past the exit, whichever comes first.
    __block int st = 0; _Atomic double *exitedAt = calloc(1, sizeof *exitedAt);
    dispatch_group_async(g, q, ^{
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        kill(-pid, SIGKILL);   // whatever it left running in its group
        *exitedAt = CFAbsoluteTimeGetCurrent();
    });
    NSMutableData *out = [NSMutableData data], *err = [NSMutableData data];
    int fds[2] = {po[0], pe[0]}; NSMutableData *bufs[2] = {out, err};
    for (int i = 0; i < 2; i++) {
        int fd = fds[i]; NSMutableData *b = bufs[i];
        dispatch_group_async(g, q, ^{
            char chunk[16384]; ssize_t n;
            for (;;) {
                struct pollfd pf = {fd, POLLIN, 0};
                if (poll(&pf, 1, 100) == 0) { double t = *exitedAt; if (t && CFAbsoluteTimeGetCurrent() - t > 0.5) break; continue; }
                if ((n = read(fd, chunk, sizeof chunk)) > 0) { if (b.length < (4u << 20)) [b appendBytes:chunk length:n]; }   // drain past 4 MB, don't keep it
                else if (n == 0 || errno != EINTR) break;
            }
            close(fd);
        });
    }
    dispatch_group_notify(g, q, ^{
        free(exitedAt);
        int code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
        NSString *o = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:out encoding:NSISOLatin1StringEncoding];
        NSString *e = [[NSString alloc] initWithData:err encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:err encoding:NSISOLatin1StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{
            over = YES;
            trackGroup(pid, NO);
            done(code, o, e);
            uiBusy(-1);
        });
    });
}

static void logEvent(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logEvent(NSString *fmt, ...) {   // tests: RF_SCRIPTS_LOG=<file> gets one line per start and run
    const char *p = getenv("RF_SCRIPTS_LOG");
    if (!p) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen(p, "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

static NSString *lastLine(NSString *s) {
    for (NSString *l in [s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].reverseObjectEnumerator)
        if (trim(l).length) return trim(l);
    return @"";
}

static void inlineStore(Script *s, int code, NSString *out, NSString *err);
// compact: the launcher stays open on a one-row view that shows the run, then its last line of output
static void runCompact(Script *s, NSArray<NSString *> *args) {
    NSString *title = sTitle(s);
    __block NSString *line = nil, *status = @"Running…";
    View *v = [View new];
    v->title = title; v->placeholder = title; v->hint = status;
    __weak View *wv = v;
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        Cmd *c = mkCmd(nil, line ?: @"Running…", nil, sGlyph(s), ^(BOOL alt) { uiPop(); });
        c->type = @"Output"; c->verb = @"Back";
        return @[c];
    };
    uiPush(v);
    runScript(s, args, ^(int code, NSString *out, NSString *err) {
        logEvent(@"exit %@ %d", s->rel, code);
        if (code == 0) { line = lastLine(out); if (!line.length) line = @"Done"; status = @"Finished"; }
        else { line = lastLine(err); if (!line.length) line = lastLine(out); status = code < 0 ? @"Couldn't run the script" : [NSString stringWithFormat:@"Failed with exit code %d", code]; }
        inlineStore(s, code, out, err);   // ↩ on an inline script refreshes its row too
        View *sv = wv;
        if (sv) { sv->hint = status; uiRefresh(); }
    });
}

// Terminal output -> plain lines: ANSI escapes (CSI colours, OSC titles) dropped, a carriage return keeps what was drawn
// last (progress bars), tabs become spaces.
static NSArray<NSString *> *plainLines(NSString *s) {
    static NSRegularExpression *ansi;
    if (!ansi) ansi = [NSRegularExpression regularExpressionWithPattern:@"\\e\\[[0-?]*[ -/]*[@-~]|\\e\\][^\\a\\e]*(\\a|\\e\\\\)|\\e[@-Z\\\\-_]" options:0 error:nil];
    s = [ansi stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\t" withString:@"    "];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in [s componentsSeparatedByString:@"\n"]) {
        NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
        NSRange r = [t rangeOfString:@"\r" options:NSBackwardsSearch];
        [out addObject:r.location == NSNotFound ? t : [t substringFromIndex:NSMaxRange(r)]];
    }
    while (out.count && ![trim(out.lastObject) length]) [out removeLastObject];
    return out;
}
static void pbSet(NSString *s) { NSPasteboard *pb = rfPasteboard(); [pb clearContents]; [pb setString:s forType:NSPasteboardTypeString]; }

enum { MAXLINES = 2000 };
// fullOutput: the output as a list, one row per line (the query filters them); ↩ copies the line, ⌘↩ all of it
static void runFull(Script *s, NSArray<NSString *> *args) {
    NSString *title = sTitle(s);
    __block NSArray<Cmd *> *lines = nil;
    View *v = [View new];
    v->title = title; v->placeholder = @"Filter output"; v->hint = @"Running…";
    __weak View *wv = v;
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        if (!lines) { Cmd *c = mkCmd(nil, @"Running…", nil, sGlyph(s), ^(BOOL alt) { uiPop(); }); c->type = @"Output"; c->verb = @"Back"; return @[c]; }
        if (!q.length) return lines;
        return [lines filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(Cmd *c, NSDictionary *b) {
            return [c->title rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound; }]];
    };
    uiPush(v);
    runScript(s, args, ^(int code, NSString *out, NSString *err) {
        logEvent(@"exit %@ %d", s->rel, code);
        NSMutableArray *all = [plainLines(out) mutableCopy];
        if (code) [all addObjectsFromArray:plainLines(err)];   // a failure says why
        NSUInteger total = all.count;
        NSString *text = [all componentsJoinedByString:@"\n"];   // ⌘↩ copies everything, past the cap too
        if (total > MAXLINES) [all removeObjectsInRange:NSMakeRange(MAXLINES, total - MAXLINES)];
        NSMutableArray *rows = [NSMutableArray arrayWithCapacity:all.count];
        for (NSString *l in all) {
            Cmd *c = mkCmd(nil, l.length ? l : @" ", nil, nil, ^(BOOL alt) { pbSet(alt ? text : l); uiHide(); });
            c->type = @""; c->verb = @"Copy Line"; c->altVerb = @"Copy All";
            [rows addObject:c];
        }
        if (!rows.count) { Cmd *c = mkCmd(nil, @"No output", nil, sGlyph(s), ^(BOOL alt) { uiPop(); }); c->type = @""; c->verb = @"Back"; [rows addObject:c]; }
        lines = rows;
        View *sv = wv; if (!sv) return;
        NSString *st = code == 0 ? @"Finished" : code < 0 ? @"Couldn't run the script" : [NSString stringWithFormat:@"Failed with exit code %d", code];
        sv->hint = total > MAXLINES ? [NSString stringWithFormat:@"%@ · showing the first %d of %lu lines", st, MAXLINES, (unsigned long)total] : st;
        uiRefresh();
    });
}

static void runSilent(Script *s, NSArray<NSString *> *args) {
    uiHide();
    runScript(s, args, ^(int code, NSString *out, NSString *err) { logEvent(@"exit %@ %d", s->rel, code); });
}

static void runMode(Script *s, NSArray<NSString *> *args) {
    NSString *m = sMode(s);
    logEvent(@"run %@ %@", s->rel, m);   // never the arguments: one may be a password
    if ([m isEqual:@"silent"]) runSilent(s, args);
    else if ([m isEqual:@"fulloutput"]) runFull(s, args);
    else runCompact(s, args);   // inline: not yet, shown compactly for now
}

#pragma mark before the run: arguments, confirmation

// argument1..3: {"type": "text" | "password" | "dropdown", "placeholder": …, "optional": bool, "data": [{title, value}]}.
// Parsed when needed (a run or a query that names the script), never at start().
static NSArray<NSDictionary *> *sArgs(Script *s) {
    if (s->args) return s->args;
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 1; i <= 3; i++) {
        NSString *j = s->meta[[NSString stringWithFormat:@"argument%d", i]];
        if (!j.length) break;
        id a = [NSJSONSerialization JSONObjectWithData:[j dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        [out addObject:[a isKindOfClass:NSDictionary.class] ? a : @{}];
    }
    return s->args = out;
}
static NSString *argStr(NSDictionary *a, NSString *k) { id v = a[k]; return [v isKindOfClass:NSString.class] ? v : [v isKindOfClass:NSNumber.class] ? [v stringValue] : @""; }
static BOOL sConfirm(Script *s) { NSString *c = s->meta[@"needsConfirmation"].lowercaseString; return [c isEqual:@"true"] || [c isEqual:@"yes"]; }
static BOOL needsView(Script *s) { return sArgs(s).count || sConfirm(s); }

static void confirmThenRun(Script *s, NSArray<NSString *> *args) {
    if (!sConfirm(s)) { runMode(s, args); return; }
    NSString *title = sTitle(s);
    View *v = [View new];   // the same shape as the system commands' confirmations
    v->title = [title stringByAppendingString:@"?"]; v->placeholder = @"↩ to confirm, esc to cancel";
    v->hint = [NSString stringWithFormat:@"↩ Run %@   esc Cancel", title];
    uint64_t opened = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        Cmd *go = mkCmd(nil, title, s->meta[@"packageName"].length ? s->meta[@"packageName"] : @"Script Command", sGlyph(s), ^(BOOL alt) {
            if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - opened < 300 * NSEC_PER_MSEC) return;   // a double-tapped ↩ doesn't confirm
            runMode(s, args);
        });
        go->type = @"Script"; go->verb = @"Run Script";
        return @[go];
    };
    uiPush(v);
}

// One view per argument, in order: a text box (the row shows what will be passed; a password never), or the dropdown's
// choices filtered by the query. ↩ moves on; after the last one, the confirmation (if any) and the run.
static void askArgs(Script *s, NSArray<NSString *> *vals) {
    NSArray<NSDictionary *> *as = sArgs(s);
    if (vals.count >= as.count) { confirmThenRun(s, vals); return; }
    NSUInteger i = vals.count;
    NSDictionary *a = as[i];
    NSString *type = argStr(a, @"type").lowercaseString, *ph = argStr(a, @"placeholder");
    BOOL optional = [a[@"optional"] respondsToSelector:@selector(boolValue)] && [a[@"optional"] boolValue], last = i + 1 == as.count;
    if (!ph.length) ph = [NSString stringWithFormat:@"Argument %lu", (unsigned long)i + 1];
    NSString *verb = last && !sConfirm(s) ? @"Run Script" : @"Continue";
    View *v = [View new];
    v->title = sTitle(s);
    v->placeholder = optional ? [ph stringByAppendingString:@" (optional)"] : ph;
    v->secure = [type isEqual:@"password"];
    NSString *step = as.count > 1 ? [NSString stringWithFormat:@"Argument %lu of %lu", (unsigned long)i + 1, (unsigned long)as.count] : @"Argument";
    v->hint = step;
    __weak View *wv = v;
    void (^next)(NSString *) = ^(NSString *val) { askArgs(s, [vals arrayByAddingObject:val]); };
    if ([type isEqual:@"dropdown"]) {
        NSMutableArray<Cmd *> *choices = [NSMutableArray array];
        for (id d in [a[@"data"] isKindOfClass:NSArray.class] ? a[@"data"] : @[]) {
            if (![d isKindOfClass:NSDictionary.class]) continue;
            NSString *t = argStr(d, @"title"), *val = argStr(d, @"value");
            if (!t.length) t = val;
            Cmd *c = mkCmd(nil, t, nil, sGlyph(s), ^(BOOL alt) { next(val); });
            c->type = @"Choice"; c->verb = verb;
            [choices addObject:c];
        }
        if (optional) { Cmd *c = mkCmd(nil, @"None", nil, @"–", ^(BOOL alt) { next(@""); }); c->type = @"Choice"; c->verb = verb; [choices addObject:c]; }
        v->rows = ^NSArray<Cmd *> *(NSString *q) {
            if (!q.length) return choices;
            return [choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(Cmd *c, NSDictionary *b) {
                return [c->title rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound; }]];
        };
    } else {
        BOOL secret = v->secure;
        v->rows = ^NSArray<Cmd *> *(NSString *q) {
            NSString *shown = !q.length ? (optional ? @"Leave empty" : [@"Type the " stringByAppendingString:ph])
                            : secret ? [@"" stringByPaddingToLength:MIN(q.length, 24) withString:@"•" startingAtIndex:0] : q;
            Cmd *c = mkCmd(nil, shown, ph, sGlyph(s), ^(BOOL alt) {
                if (!q.length && !optional) { View *sv = wv; if (sv) { sv->hint = [ph stringByAppendingString:@" is required"]; uiRefresh(); } return; }
                next(q);
            });
            c->type = @"Argument"; c->verb = verb;
            return @[c];
        };
    }
    uiPush(v);
}

// ↩ on a script (from the root or a hotkey): ask what it needs, then run it
static void launch(Script *s, NSArray<NSString *> *args) {
    if (args) confirmThenRun(s, args); else askArgs(s, @[]);
}

#pragma mark inline

// inline + refreshTime: the row's subtitle is the script's first output line. Runs only from search() (the launcher is open),
// at most once per interval; results are kept in rfDataDir/inline.plist so a respawn doesn't re-run them.
static NSMutableDictionary *gInline;   // path -> @{v: first line, at: finished (absolute time)}
static NSMutableSet *gInlineRunning, *gInlineDue;   // running now; a refresh timer pending
static NSString *inlinePath(void) { return [rfDataDir() stringByAppendingPathComponent:@"inline.plist"]; }
static double refreshSecs(Script *s) {   // "10s" "5m" "1h" "1d"; Raycast's minimum is 10 s. 0 = not an inline script
    NSString *r = trim(s->meta[@"refreshTime"] ?: @"").lowercaseString;
    if (!r.length) return 0;
    double n = r.doubleValue, u = 1;
    switch ([r characterAtIndex:r.length - 1]) { case 'm': u = 60; break; case 'h': u = 3600; break; case 'd': u = 86400; break; }
    return MAX(10, n * u);
}
static BOOL isInline(Script *s);
static void inlineStore(Script *s, int code, NSString *out, NSString *err) {
    if (!isInline(s)) return;
    if (!gInline) gInline = [NSMutableDictionary dictionaryWithContentsOfFile:inlinePath()] ?: [NSMutableDictionary dictionary];
    NSString *v = nil;
    for (NSString *l in plainLines(code ? err : out)) if (trim(l).length) { v = trim(l); break; }
    if (code) v = [NSString stringWithFormat:@"Failed%@%@", v ? @": " : @"", v ?: [NSString stringWithFormat:@" with exit code %d", code]];
    gInline[s->path] = @{@"v": v ?: @"", @"at": @(CFAbsoluteTimeGetCurrent())};
    [gInline writeToFile:inlinePath() atomically:YES];
}
static BOOL isInline(Script *s) { return [sMode(s) isEqual:@"inline"] && refreshSecs(s) > 0; }
static NSString *inlineValue(Script *s) {
    if (!gInline) gInline = [NSMutableDictionary dictionaryWithContentsOfFile:inlinePath()] ?: [NSMutableDictionary dictionary];
    if (!gInlineRunning) gInlineRunning = [NSMutableSet set], gInlineDue = [NSMutableSet set];
    NSDictionary *e = gInline[s->path];
    double now = CFAbsoluteTimeGetCurrent();
    if ((!e || now - [e[@"at"] doubleValue] >= refreshSecs(s)) && ![gInlineRunning containsObject:s->path]) {
        [gInlineRunning addObject:s->path];
        logEvent(@"inline %@", s->rel);
        runScript(s, @[], ^(int code, NSString *out, NSString *err) {
            [gInlineRunning removeObject:s->path];
            inlineStore(s, code, out, err);
            uiRefresh();
        });
    } else if (e && ![gInlineRunning containsObject:s->path] && ![gInlineDue containsObject:s->path]) {
        // shown and fresh: look again when it goes stale. uiRefresh() is a no-op once hidden, and re-searches the
        // current query, so the script re-runs only if its row is still on screen.
        [gInlineDue addObject:s->path];
        double due = [e[@"at"] doubleValue] + refreshSecs(s) - now + 0.05;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(due * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [gInlineDue removeObject:s->path];
            uiRefresh();
        });
    }
    NSString *v = e[@"v"];
    return v.length ? v : e ? @"No output" : @"…";
}

#pragma mark folder commands

static NSString *firstDir(void) { NSString *d = scriptDirs().firstObject ?: [cfgDir() stringByAppendingPathComponent:@"scripts"]; return d; }
static BOOL dryRun(void) { const char *d = getenv("RF_DRYRUN"); return d && *d && strcmp(d, "0"); }
static void openPath(NSString *flag, NSString *path) {   // /usr/bin/open as a child, so no LaunchServices calls in-process
    const char *argv[] = {"/usr/bin/open", flag.UTF8String, path.fileSystemRepresentation, NULL};
    if (!flag.length) { argv[1] = argv[2]; argv[2] = NULL; }
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    pid_t pid;
    if (!posix_spawn(&pid, argv[0], &fa, NULL, (char **)argv, environ))
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ int st; waitpid(pid, &st, 0); });   // no zombie
    posix_spawn_file_actions_destroy(&fa);
}

// A commented template, never overwriting: my-script.sh, my-script-2.sh, … Then it opens in the default text editor.
static void createScript(void) {
    NSString *dir = firstDir();
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (int n = 1; n < 1000; n++) {
        NSString *suffix = n == 1 ? @"" : [NSString stringWithFormat:@"-%d", n];
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"my-script%@.sh", suffix]];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0755);
        if (fd < 0) { if (errno == EEXIST) continue; break; }
        NSString *t = [NSString stringWithFormat:@"#!/bin/bash\n\n"
            "# Required parameters:\n"
            "# @raycast.schemaVersion 1\n"
            "# @raycast.title My Script%@\n"
            "# @raycast.mode compact\n\n"
            "# Optional parameters:\n"
            "# @raycast.packageName My Scripts\n"
            "# @raycast.icon 🤖\n"
            "# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"name\", \"optional\": true }\n"
            "# @raycast.needsConfirmation false\n\n"
            "# mode: silent (run and hide) | compact (last line of output) | fullOutput (all of it) | inline (with refreshTime 1m)\n"
            "# Arguments arrive as $1..$3. The script runs with your login shell's PATH, in its own folder, stdin closed.\n\n"
            "echo \"Hello, ${1:-world}!\"\n", n == 1 ? @"" : [NSString stringWithFormat:@" %d", n]];
        NSData *d = [t dataUsingEncoding:NSUTF8StringEncoding];
        BOOL ok = write(fd, d.bytes, d.length) == (ssize_t)d.length;
        close(fd);
        if (!ok) break;
        gScanAt = 0;
        logEvent(@"create %@", path);
        if (dryRun()) fprintf(stderr, "dry-run: open -t %s\n", path.fileSystemRepresentation);
        else openPath(@"-t", path);
        uiHide();
        return;
    }
    logEvent(@"create failed in %@", dir);
}
static void revealDir(void) {
    NSString *dir = firstDir();
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    logEvent(@"reveal %@", dir);
    if (dryRun()) fprintf(stderr, "dry-run: open %s\n", dir.fileSystemRepresentation);
    else openPath(@"", dir);
    uiHide();
}
static void (*folderCmd(NSString *cid))(void) {
    return [cid isEqual:@"scripts.@create"] ? createScript : [cid isEqual:@"scripts.@reveal"] ? revealDir : NULL;
}

#pragma mark module

static void start(void) { logEvent(@"start"); reapLeftovers(); }   // no script read here: the folder is scanned on the first query

static void search(NSString *q, const char *lq, NSMutableArray<Cmd *> *out) {
    if (!*lq) return;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (NSArray<NSString *> *f in @[   // cid, title, subtitle, glyph, verb. A script's cid is scripts.<file path>, never @…
        @[@"scripts.@create", @"Create Script Command", @"A commented template in the scripts folder", @"+", @"Create Script"],
        @[@"scripts.@reveal", @"Reveal Scripts Folder", @"Open it in Finder", @"$", @"Reveal Folder"]]) {
        int score = rfMatch(f[1], @"script commands", lq);
        if (!score) continue;
        void (*fn)(void) = folderCmd(f[0]);
        Cmd *c = mkCmd(f[0], f[1], f[2], f[3], ^(BOOL alt) { fn(); });
        c->verb = f[4]; c->score = score;
        [out addObject:c];
    }
    scan();
    if (gScripts.count) prefetchLoginPath();
    NSMutableArray<NSArray *> *mine = [NSMutableArray array];   // [row, script]
    for (Script *s in gScripts.allValues) {
        NSString *title = sTitle(s), *pkg = s->meta[@"packageName"];
        if (q.length > title.length + 1 && [q rangeOfString:title options:NSCaseInsensitiveSearch | NSAnchoredSearch].location == 0
            && [q characterAtIndex:title.length] == ' ') {   // "lookup banana": the rest is the only (text) argument
            NSArray *as = sArgs(s);
            NSString *rest = trim([q substringFromIndex:title.length]);
            if (as.count == 1 && [@[@"", @"text"] containsObject:argStr(as[0], @"type").lowercaseString]) {
                Cmd *c = mkCmd([@"scripts." stringByAppendingString:s->rel], title, rest, sGlyph(s), ^(BOOL alt) { launch(s, @[rest]); });
                c->type = @"Script"; c->verb = @"Run Script"; c->score = rfMatch(title, nil, title.lowercaseString.UTF8String);
                [out addObject:c];
                [mine addObject:@[c, s]];
                continue;
            }
        }
        int score = rfMatch(title, pkg, lq);
        if (!score) continue;
        NSString *sub = isInline(s) ? inlineValue(s) : pkg.length ? pkg : @"Script Command";
        Cmd *c = mkCmd([@"scripts." stringByAppendingString:s->rel], title, sub, sGlyph(s), ^(BOOL alt) { launch(s, nil); });
        c->type = @"Script"; c->verb = sArgs(s).count ? @"Continue" : @"Run Script"; c->score = score;
        [out addObject:c];
        [mine addObject:@[c, s]];
    }
    // Image icons only for the best-scoring rows (the window shows about ten; another module may outrank them all), so
    // a query that matches 200 scripts decodes 16 images at most, each once per shown session.
    if (mine.count > 16) [mine sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { int x = ((Cmd *)a[0])->score, y = ((Cmd *)b[0])->score; return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame; }];
    uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (NSUInteger k = 0; k < MIN(mine.count, 16); k++) ((Cmd *)mine[k][0])->icon = sImage(mine[k][1]);
    uint64_t t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    logEvent(@"query %.2f ms (icons %.2f)", (t2 - t0) / 1e6, (t2 - t1) / 1e6);   // tests: the in-app cost (CoreGraphics is warm: the window renders at start)
}

// A hotkey bound to cmd:scripts.<rel>: silent ones just run; the others open the launcher on their view.
static BOOL run(NSString *cid) {
    if (![cid hasPrefix:@"scripts."]) return NO;
    if (folderCmd(cid)) { folderCmd(cid)(); return YES; }
    gScanAt = 0; scan();   // fresh: the script may have been edited since the last query
    NSString *rel = [cid substringFromIndex:8];
    for (Script *s in gScripts.allValues) {
        if (![s->rel isEqual:rel]) continue;
        if (![sMode(s) isEqual:@"silent"] || needsView(s)) uiShow();
        launch(s, nil);
        return YES;
    }
    return NO;
}

// rayfast --run scripts list: the discovered scripts, one per line (tests; the folder comes from $RF_CONFIG_DIR)
static int cli(int argc, const char **argv) {
    if (argc >= 1 && !strcmp(argv[0], "list")) {
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        scan();
        double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
        for (NSString *p in [gScripts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            Script *s = gScripts[p];
            printf("scripts.%s\t%s\t%s\t%s\n", s->rel.UTF8String, sTitle(s).UTF8String, (s->meta[@"packageName"] ?: @"").UTF8String, sMode(s).UTF8String);
        }
        fprintf(stderr, "scan %.2f ms\n", ms);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[0], "query")) {   // query <text>: the module's rows and the time to make them (icons included)
        NSString *q = @(argv[1]); NSMutableArray<Cmd *> *out = [NSMutableArray array];
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        search(q, q.lowercaseString.UTF8String, out);
        double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
        int icons = 0; for (Cmd *c in out) icons += c->icon != nil;
        for (Cmd *c in out) printf("%s\t%s%s\n", c->cid.UTF8String, c->title.UTF8String, c->icon ? "\ticon" : "");
        fprintf(stderr, "query %.2f ms, %lu rows, %d icons\n", ms, (unsigned long)out.count, icons);
        return 0;
    }
    if (argc >= 1 && !strcmp(argv[0], "pb-get")) { fputs(([rfPasteboard() stringForType:NSPasteboardTypeString] ?: @"").UTF8String, stdout); return 0; }
    fprintf(stderr, "usage: rayfast --run scripts list | query <text> | pb-get\n");
    return 2;
}

static const RFModule M = {"scripts", start, search, run, cli};
RF_MODULE(M)
