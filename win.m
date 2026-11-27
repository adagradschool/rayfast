// win.m — window management: halves, quarters, thirds, maximize, center, next display, restore, fullscreen.
// Root commands "window.<name>"; geometry is a pure function of (command, window frame, screens, gap) in AX
// coordinates (top-left origin, y grows down, the primary display's top-left is 0,0), tested via `--run window geom`.
#import "rf.h"
#import <dlfcn.h>

enum { W_GRID, W_ALMOST, W_CENTER, W_CENTERHALF, W_REASONABLE, W_LARGER, W_SMALLER, W_NEXT, W_PREV, W_RESTORE, W_FULL };
typedef struct { const char *name, *title, *keys, *glyph; int kind, c0, c1, cn, r0, r1, rn; } WinCmd;
// grid commands cover columns [c0,c1) of cn and rows [r0,r1) of rn of the screen's visible frame
static const WinCmd gW[] = {
    {"left-half", "Left Half", "tile snap split resize window left half", "◧", W_GRID, 0, 1, 2, 0, 1, 1},
    {"right-half", "Right Half", "tile snap split resize window right half", "◨", W_GRID, 1, 2, 2, 0, 1, 1},
    {"top-half", "Top Half", "tile snap split resize window top half", "⬒", W_GRID, 0, 1, 1, 0, 1, 2},
    {"bottom-half", "Bottom Half", "tile snap split resize window bottom half", "⬓", W_GRID, 0, 1, 1, 1, 2, 2},
    {"top-left", "Top Left Quarter", "tile snap split resize window quarter corner", "◰", W_GRID, 0, 1, 2, 0, 1, 2},
    {"top-right", "Top Right Quarter", "tile snap split resize window quarter corner", "◳", W_GRID, 1, 2, 2, 0, 1, 2},
    {"bottom-left", "Bottom Left Quarter", "tile snap split resize window quarter corner", "◱", W_GRID, 0, 1, 2, 1, 2, 2},
    {"bottom-right", "Bottom Right Quarter", "tile snap split resize window quarter corner", "◲", W_GRID, 1, 2, 2, 1, 2, 2},
    {"first-third", "First Third", "tile snap split resize window left third", "▌", W_GRID, 0, 1, 3, 0, 1, 1},
    {"center-third", "Center Third", "tile snap split resize window middle third", "┃", W_GRID, 1, 2, 3, 0, 1, 1},
    {"last-third", "Last Third", "tile snap split resize window right third", "▐", W_GRID, 2, 3, 3, 0, 1, 1},
    {"first-two-thirds", "First Two Thirds", "tile snap split resize window left two thirds", "◀", W_GRID, 0, 2, 3, 0, 1, 1},
    {"last-two-thirds", "Last Two Thirds", "tile snap split resize window right two thirds", "▶", W_GRID, 1, 3, 3, 0, 1, 1},
    {"maximize", "Maximize", "tile snap resize window maximize fill zoom full", "■", W_GRID, 0, 1, 1, 0, 1, 1},
    {"almost-maximize", "Almost Maximize", "tile snap resize window maximize 90", "▣", W_ALMOST},
    {"center", "Center", "snap move window center middle", "⊡", W_CENTER},
    {"center-half", "Center Half", "tile snap split resize window center middle half", "▯", W_CENTERHALF},
    {"reasonable-size", "Reasonable Size", "resize window reasonable size", "▭", W_REASONABLE},
    {"make-larger", "Make Larger", "resize window larger bigger grow", "⤢", W_LARGER},
    {"make-smaller", "Make Smaller", "resize window smaller shrink", "⤡", W_SMALLER},
    {"next-display", "Move to Next Display", "move window next display screen monitor", "⇥", W_NEXT},
    {"previous-display", "Move to Previous Display", "move window previous display screen monitor", "⇤", W_PREV},
    {"restore", "Restore", "window restore undo previous size", "↺", W_RESTORE},
    {"toggle-fullscreen", "Toggle Fullscreen", "window fullscreen full screen", "⛶", W_FULL},
};
#define NW (int)(sizeof gW / sizeof *gW)

static const WinCmd *winCmd(const char *name) {
    for (int i = 0; i < NW; i++) if (!strcmp(gW[i].name, name)) return &gW[i];
    return NULL;
}

#pragma mark - geometry (pure)

// Cocoa screen rect (bottom-left origin) -> AX rect, given the primary display's height
static CGRect axRect(CGRect r, double primaryH) { return CGRectMake(r.origin.x, primaryH - r.origin.y - r.size.height, r.size.width, r.size.height); }
static CGRect rnd(CGRect r) { return CGRectMake(round(r.origin.x), round(r.origin.y), round(r.size.width), round(r.size.height)); }

// Edge i of n along one axis. Cells share edges, so neighbours never leave a 1-px gap or overlap; with a gap g the
// outer margin and the space between cells are both g, and all cells of a split are within 1 px of each other.
static double edge(double o, double len, double g, int i, int n) { return o + g + floor((len - g) * i / n); }
static CGRect cell(CGRect s, double g, int c0, int c1, int cn, int r0, int r1, int rn) {
    double x0 = edge(s.origin.x, s.size.width, g, c0, cn), x1 = edge(s.origin.x, s.size.width, g, c1, cn) - g;
    double y0 = edge(s.origin.y, s.size.height, g, r0, rn), y1 = edge(s.origin.y, s.size.height, g, r1, rn) - g;
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}
static CGRect inset(CGRect s, double g) { return CGRectMake(s.origin.x + g, s.origin.y + g, s.size.width - 2 * g, s.size.height - 2 * g); }
// a window of size w,h centred in area a (clamped to fit)
static CGRect centred(CGRect a, double w, double h) {
    w = MIN(round(w), a.size.width); h = MIN(round(h), a.size.height);
    return CGRectMake(a.origin.x + floor((a.size.width - w) / 2), a.origin.y + floor((a.size.height - h) / 2), w, h);
}
// shift (and if needed shrink) r so it lies inside a
static CGRect fitIn(CGRect r, CGRect a) {
    r.size.width = MIN(r.size.width, a.size.width); r.size.height = MIN(r.size.height, a.size.height);
    r.origin.x = MAX(a.origin.x, MIN(r.origin.x, CGRectGetMaxX(a) - r.size.width));
    r.origin.y = MAX(a.origin.y, MIN(r.origin.y, CGRectGetMaxY(a) - r.size.height));
    return r;
}
// "already there": apps round sizes (terminals snap to character cells), so allow a few points
static BOOL near(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) <= 2 && fabs(a.origin.y - b.origin.y) <= 2 && fabs(a.size.width - b.size.width) <= 2 && fabs(a.size.height - b.size.height) <= 2;
}
// the screen the window is on: largest overlap, else the one nearest its centre
static int screenOf(CGRect w, const CGRect *s, int n) {
    int best = 0; double bestA = -1;
    for (int i = 0; i < n; i++) {
        CGRect x = CGRectIntersection(w, s[i]);
        double a = CGRectIsNull(x) ? 0 : x.size.width * x.size.height;
        if (a > bestA) { bestA = a; best = i; }
    }
    if (bestA > 0) return best;
    double cx = CGRectGetMidX(w), cy = CGRectGetMidY(w), bestD = INFINITY;
    for (int i = 0; i < n; i++) {
        double dx = MAX(0, MAX(s[i].origin.x - cx, cx - CGRectGetMaxX(s[i]))), dy = MAX(0, MAX(s[i].origin.y - cy, cy - CGRectGetMaxY(s[i])));
        if (dx * dx + dy * dy < bestD) { bestD = dx * dx + dy * dy; best = i; }
    }
    return best;
}
// window.gap as used on screen s: a typo (2000, nan, inf, negative) must not send a window off screen or to NaN,
// so it is 0 unless positive and at most an eighth of the screen's shorter side
static double gapIn(double g, CGRect s) { return g > 0 ? MIN(g, floor(MIN(s.size.width, s.size.height) / 8)) : 0; }
static CGRect gridOf(const WinCmd *c, CGRect s, double g) { return cell(s, g, c->c0, c->c1, c->cn, c->r0, c->r1, c->rn); }

// Target frame for command c applied to window w, with the visible frames of all screens (AX coordinates).
// Returns CGRectNull when the command is not geometry (restore, fullscreen).
static CGRect winGeom(const WinCmd *c, CGRect w, const CGRect *scr, int n, double g) {
    w = rnd(w);
    CGRect s = rnd(scr[screenOf(w, scr, n)]);
    g = gapIn(g, s);
    CGRect a = inset(s, g);
    switch (c->kind) {
    case W_GRID:
        // Raycast-style cycling for the side halves: half -> two thirds -> one third -> half, read from the current frame
        if (c->cn == 2 && c->rn == 1) {
            int L = c->c0 == 0;
            CGRect seq[3] = {gridOf(c, s, g), cell(s, g, L ? 0 : 1, L ? 2 : 3, 3, 0, 1, 1), cell(s, g, L ? 0 : 2, L ? 1 : 3, 3, 0, 1, 1)};
            for (int i = 0; i < 3; i++) if (near(w, seq[i])) return seq[(i + 1) % 3];
            return seq[0];
        }
        return gridOf(c, s, g);
    case W_ALMOST: return centred(a, a.size.width * 0.9, a.size.height * 0.9);
    case W_CENTER: return centred(a, w.size.width, w.size.height);
    case W_CENTERHALF: { CGRect h = cell(s, g, 0, 1, 2, 0, 1, 1); return centred(a, h.size.width, a.size.height); }
    case W_REASONABLE: return centred(a, a.size.width * 0.6, a.size.height * 0.6);
    case W_LARGER: case W_SMALLER: {
        // 10% of the screen per step, around the window's centre, kept on screen
        double dw = round(a.size.width * 0.1), dh = round(a.size.height * 0.1), k = c->kind == W_LARGER ? 1 : -1;
        double nw = w.size.width + k * dw, nh = w.size.height + k * dh;
        if (k < 0 && (nw < 2 * dw || nh < 2 * dh)) return fitIn(w, a);   // already small: leave it
        CGRect r = CGRectMake(w.origin.x - k * floor(dw / 2), w.origin.y - k * floor(dh / 2), nw, nh);
        return fitIn(r, a);
    }
    case W_NEXT: case W_PREV: {
        if (n < 2) return w;
        // display order: left to right, then top to bottom
        int ord[16], m = MIN(n, 16), cur = screenOf(w, scr, n), pos = 0;
        for (int i = 0; i < m; i++) ord[i] = i;
        for (int i = 1; i < m; i++) for (int j = i; j > 0; j--) {
            CGRect p = scr[ord[j - 1]], q = scr[ord[j]];
            if (p.origin.x > q.origin.x || (p.origin.x == q.origin.x && p.origin.y > q.origin.y)) { int t = ord[j]; ord[j] = ord[j - 1]; ord[j - 1] = t; } else break;
        }
        for (int i = 0; i < m; i++) if (ord[i] == cur) pos = i;
        CGRect d = rnd(scr[ord[(pos + (c->kind == W_NEXT ? 1 : m - 1)) % m]]), da = inset(d, gapIn(g, d));
        // a window that sits exactly on a layout keeps that layout on the other display
        for (int i = 0; i < NW; i++) if (gW[i].kind == W_GRID && near(w, gridOf(&gW[i], s, g))) return gridOf(&gW[i], d, gapIn(g, d));
        if (near(w, winGeom(winCmd("almost-maximize"), w, &s, 1, g))) return winGeom(winCmd("almost-maximize"), w, &d, 1, g);
        // otherwise the same place relative to the visible frame, scaled
        double fx = da.size.width / a.size.width, fy = da.size.height / a.size.height;
        CGRect r = CGRectMake(da.origin.x + (w.origin.x - a.origin.x) * fx, da.origin.y + (w.origin.y - a.origin.y) * fy, w.size.width * fx, w.size.height * fy);
        return fitIn(rnd(r), da);
    }
    default: return CGRectNull;
    }
}

#pragma mark - applying

// A window to act on: the focused window of an app through the Accessibility API, or (fake = YES) a simulated
// one for tests, with the habits of real apps: a minimum size, a fixed size, full screen, AXEnhancedUserInterface
// on (it animates and fights every set), and resizing clamped to the screen the window is on at that moment.
typedef struct {
    BOOL fake;
    AXUIElementRef app, win;
    CGRect f, clampTo[16]; int nclamp; double minW, minH; BOOL fixed, full, eui, clamp;
    NSMutableString *log;
    NSString *store, *key; NSSet *live;   // restore frames file; this window's "pid:windowid" (nil: not kept); fake: live keys
} Win;

static BOOL axGet(AXUIElementRef e, CFStringRef attr, AXValueType t, void *out) {
    CFTypeRef v = NULL; BOOL ok = NO;
    if (AXUIElementCopyAttributeValue(e, attr, &v) == kAXErrorSuccess && v) {
        ok = CFGetTypeID(v) == AXValueGetTypeID() ? AXValueGetValue(v, t, out) : NO;
        CFRelease(v);
    }
    return ok;
}
static BOOL axBool(AXUIElementRef e, CFStringRef attr) {
    CFTypeRef v = NULL; BOOL b = NO;
    if (AXUIElementCopyAttributeValue(e, attr, &v) == kAXErrorSuccess && v) { b = CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(v); CFRelease(v); }
    return b;
}
static CGRect wGet(Win *w) {
    if (w->fake) return w->f;
    CGPoint p; CGSize z;
    if (!axGet(w->win, kAXPositionAttribute, kAXValueTypeCGPoint, &p) || !axGet(w->win, kAXSizeAttribute, kAXValueTypeCGSize, &z)) return CGRectNull;
    return (CGRect){p, z};
}
static void wPos(Win *w, CGPoint p) {
    if (w->fake) { [w->log appendFormat:@"pos %g,%g ", p.x, p.y]; w->f.origin = p; return; }
    AXValueRef v = AXValueCreate(kAXValueTypeCGPoint, &p); AXUIElementSetAttributeValue(w->win, kAXPositionAttribute, v); CFRelease(v);
}
static void wSize(Win *w, CGSize z) {
    if (w->fake) {
        [w->log appendFormat:@"size %g,%g ", z.width, z.height];
        if (w->fixed) return;
        z.width = MAX(z.width, w->minW); z.height = MAX(z.height, w->minH);
        if (w->clamp && w->nclamp) {   // grows only as far as the edges of the screen it is on now
            CGRect s = w->clampTo[screenOf(w->f, w->clampTo, w->nclamp)];
            z.width = MIN(z.width, CGRectGetMaxX(s) - w->f.origin.x); z.height = MIN(z.height, CGRectGetMaxY(s) - w->f.origin.y);
        }
        w->f.size = z; return;
    }
    AXValueRef v = AXValueCreate(kAXValueTypeCGSize, &z); AXUIElementSetAttributeValue(w->win, kAXSizeAttribute, v); CFRelease(v);
}
static BOOL wSizable(Win *w) {
    if (w->fake) return !w->fixed;
    Boolean b = false; return AXUIElementIsAttributeSettable(w->win, kAXSizeAttribute, &b) == kAXErrorSuccess && b;
}
static BOOL wFull(Win *w) { return w->fake ? w->full : axBool(w->win, CFSTR("AXFullScreen")); }
static void wSetFull(Win *w, BOOL on) {
    if (w->fake) { [w->log appendFormat:@"fullscreen %d ", on]; w->full = on; return; }
    AXUIElementSetAttributeValue(w->win, CFSTR("AXFullScreen"), on ? kCFBooleanTrue : kCFBooleanFalse);
}
static BOOL wEUI(Win *w) { return w->fake ? w->eui : axBool(w->app, CFSTR("AXEnhancedUserInterface")); }
static void wSetEUI(Win *w, BOOL on) {
    if (w->fake) { [w->log appendFormat:@"eui %d ", on]; w->eui = on; return; }
    AXUIElementSetAttributeValue(w->app, CFSTR("AXEnhancedUserInterface"), on ? kCFBooleanTrue : kCFBooleanFalse);
}

// One coordinate for a window of length got that was meant for [t0, t0+tl) inside area [a0, a0+al): it keeps the
// edge the target touches (left/top, else right/bottom, else the centre), then stays inside the area.
static double anchor(double t0, double tl, double got, double a0, double al) {
    double x = fabs(t0 - a0) <= 1 ? t0 : fabs(t0 + tl - (a0 + al)) <= 1 ? t0 + tl - got : round(t0 + (tl - got) / 2);
    return MAX(a0, MIN(x, a0 + al - got));
}

#pragma mark - restore frames

// The frame each window had before rayfast first moved it, one "pid:windowid<TAB>x,y,w,h" line per window, in a
// small file under rfDataDir() so it survives the respawn. Entries whose window is gone are pruned on every write.
// Is window wid still there and owned by pid? One CGWindowList lookup of that window, no AX.
static BOOL winAlive(NSString *key) {
    int pid = 0; unsigned wid = 0;
    if (sscanf(key.UTF8String, "%d:%u", &pid, &wid) != 2 || pid <= 0 || !wid) return NO;
    if (kill(pid, 0) && errno != EPERM) return NO;
    const void *v = (const void *)(uintptr_t)wid;   // CGWindowIDs go in a CFArray as raw values, not CFNumbers
    CFArrayRef ids = CFArrayCreate(NULL, &v, 1, NULL), a = CGWindowListCreateDescriptionFromArray(ids);
    CFRelease(ids);
    BOOL ok = NO;
    if (a) {
        if (CFArrayGetCount(a)) ok = [((__bridge NSDictionary *)CFArrayGetValueAtIndex(a, 0))[(id)kCGWindowOwnerPID] intValue] == pid;
        CFRelease(a);
    }
    return ok;
}
static NSMutableDictionary<NSString *, NSString *> *rsLoad(Win *w) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *l in [[NSString stringWithContentsOfFile:w->store encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"]) {
        NSArray *p = [l componentsSeparatedByString:@"\t"];
        if (p.count == 2) m[p[0]] = p[1];
    }
    return m;
}
static void rsSave(Win *w, NSDictionary<NSString *, NSString *> *m) {
    NSMutableString *out = [NSMutableString string];
    for (NSString *k in [m.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if ([k isEqual:w->key] || (w->fake ? !w->live || [w->live containsObject:k] : winAlive(k))) [out appendFormat:@"%@\t%@\n", k, m[k]];
    [out writeToFile:w->store atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static NSString *rectStr(CGRect r) { return [NSString stringWithFormat:@"%g,%g,%g,%g", r.origin.x + 0.0, r.origin.y + 0.0, r.size.width, r.size.height]; }   // + 0.0: no "-0"
static BOOL parseRect(const char *s, CGRect *r);

// Moves w for command c. Returns nil when done, else why not (shown to the user / printed by the tests).
static NSString *winApplyTo(Win *w, const WinCmd *c, const CGRect *scr, int n, double g) {
    CGRect cur = wGet(w);
    if (CGRectIsNull(cur)) return @"No window to move";
    if (c->kind == W_FULL) { wSetFull(w, !wFull(w)); return nil; }
    if (wFull(w)) return @"The window is in full screen: left alone";
    CGRect t;
    if (c->kind == W_RESTORE) {
        NSMutableDictionary *m = w->key && w->store ? rsLoad(w) : nil;
        NSString *r = m[w->key];
        if (!r || !parseRect(r.UTF8String, &t)) return @"Nothing to restore";
        [m removeObjectForKey:w->key]; rsSave(w, m);
    } else {
        t = winGeom(c, cur, scr, n, g);
        if (CGRectIsNull(t)) return @"Not a layout";
        if (w->key && w->store && !near(rnd(cur), t)) {   // only the first move counts: restore goes back to before rayfast
            NSMutableDictionary *m = rsLoad(w);
            if (!m[w->key]) m[w->key] = rectStr(rnd(cur));
            rsSave(w, m);
        }
    }
    BOOL eui = wEUI(w), sizable = wSizable(w);
    if (eui) wSetEUI(w, NO);
    // position, size, position: the first move takes the window to the target screen so apps that clamp a resize
    // to their current screen don't, the second puts it back where a clamped or min-sized resize pushed it
    wPos(w, t.origin);
    if (sizable) wSize(w, t.size);
    CGRect got = wGet(w), ts = rnd(scr[screenOf(t, scr, n)]), a = inset(ts, gapIn(g, ts));
    if (CGRectIsNull(got)) got = t;
    if (c->kind == W_RESTORE) wPos(w, fitIn((CGRect){t.origin, got.size}, rnd(scr[screenOf(t, scr, n)])).origin);   // keeps its old top-left
    else wPos(w, CGPointMake(anchor(t.origin.x, t.size.width, got.size.width, a.origin.x, a.size.width),
                        anchor(t.origin.y, t.size.height, got.size.height, a.origin.y, a.size.height)));
    if (eui) wSetEUI(w, YES);
    return nil;
}

// The visible frames of all displays in AX coordinates (menu bar and Dock taken out)
static int axScreens(CGRect *out, int max) {
    NSArray<NSScreen *> *ss = NSScreen.screens; int n = 0;
    if (!ss.count) return 0;
    double ph = ss[0].frame.size.height;
    for (NSScreen *s in ss) if (n < max) out[n++] = axRect(s.visibleFrame, ph);
    return n;
}
static double winGap(void) { return MAX(0, [rfSetting(@"window.gap", @"0") doubleValue]); }

// The window of app pid to act on: its focused window, else its main window, else its first (an app that is not
// active may have neither). Also names it for restore. Pair with winClose.
static NSString *winOpen(pid_t pid, Win *w) {
    w->app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(w->app, 1.0);   // a hung app must not hang the launcher
    CFTypeRef win = NULL;
    if (AXUIElementCopyAttributeValue(w->app, kAXFocusedWindowAttribute, &win) != kAXErrorSuccess || !win)
        AXUIElementCopyAttributeValue(w->app, kAXMainWindowAttribute, &win);
    if (!win) {
        CFArrayRef all = NULL;
        if (AXUIElementCopyAttributeValue(w->app, kAXWindowsAttribute, (CFTypeRef *)&all) == kAXErrorSuccess && all) {
            if (CFArrayGetCount(all)) win = CFRetain(CFArrayGetValueAtIndex(all, 0));
            CFRelease(all);
        }
    }
    if (!win) return @"No window to move";
    w->win = (AXUIElementRef)win;
    AXUIElementSetMessagingTimeout(w->win, 1.0);   // per element, not inherited: the window's own calls default to 6 s each
    // the window number names the window for restore: _AXUIElementGetWindow is private (Rectangle, yabai use it),
    // looked up at run time so a macOS without it just loses restore, never the launch
    static AXError (*getWid)(AXUIElementRef, CGWindowID *); static dispatch_once_t once;
    dispatch_once(&once, ^{ getWid = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"); });
    CGWindowID wid = 0;
    if (getWid && getWid(w->win, &wid) == kAXErrorSuccess && wid) w->key = [NSString stringWithFormat:@"%d:%u", pid, wid];
    w->store = [rfDataDir() stringByAppendingPathComponent:@"window-restore.tsv"];
    return nil;
}
static void winClose(Win *w) {
    if (w->win) CFRelease(w->win);
    if (w->app) CFRelease(w->app);
    w->win = w->app = NULL;
}

// Applies c to the focused window of app pid. Test instances (RF_DRYRUN, or any headless/no-hotkey instance as a
// safety net) never touch a real window: they log "<cid>\tpid=<pid> gap=<gap>" to rfDataDir()/dryrun.log.
static NSString *winApply(pid_t pid, const WinCmd *c) {
    double g = winGap();
    if (getenv("RF_DRYRUN") || getenv("RF_HEADLESS") || getenv("RF_NOHOTKEY")) {
        NSString *line = [NSString stringWithFormat:@"window.%s\tpid=%d gap=%g\n", c->name, pid, g];
        fprintf(stderr, "rayfast: dry run: %s", line.UTF8String);
        FILE *f = fopen([rfDataDir() stringByAppendingPathComponent:@"dryrun.log"].fileSystemRepresentation, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
        return getenv("RF_WINFAIL") ? @(getenv("RF_WINFAIL")) : nil;   // tests: pretend the command could not act
    }
    if (pid <= 0 || pid == getpid()) return @"No app to act on";
    if (!AXIsProcessTrusted()) return @"Accessibility permission is missing";
    Win w = {0};
    NSString *err = winOpen(pid, &w);
    if (!err) {
        CGRect scr[16]; int n = axScreens(scr, 16);
        err = n ? winApplyTo(&w, c, scr, n, g) : @"No display";
    }
    winClose(&w);
    return err;
}
// The app to act on: the frontmost one. The launcher is a non-activating panel, so while it is open the app the
// user was in is still frontmost; from a hotkey it is simply the active app.
static NSString *winRun(const WinCmd *c) {
    NSString *err = winApply(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier, c);
    if (err) fprintf(stderr, "rayfast: window.%s: %s\n", c->name, err.UTF8String);
    return err;
}
// Accessibility granted? The non-prompting check; RF_AXTRUST=0/1 overrides it so tests pick the path.
static BOOL winTrusted(void) { return getenv("RF_AXTRUST") ? atoi(getenv("RF_AXTRUST")) != 0 : AXIsProcessTrusted(); }

#define AX_PANE "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
// Shown instead of failing silently when Accessibility is missing: what to do, and a row that opens the pane.
static View *winPermissionView(const WinCmd *c) {
    View *v = [View new];
    v->title = @"Window Management needs Accessibility";
    v->placeholder = @"Accessibility permission";
    v->hint = @"System Settings → Privacy & Security → Accessibility: turn on rayfast";
    NSString *title = @(c->title);
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        Cmd *open = mkCmd(nil, @"Open Accessibility Settings", @"Turn on rayfast in the list, then run the command again", @"⚙", ^(BOOL alt) {
            uiHide();
            if (getenv("RF_DRYRUN") || getenv("RF_HEADLESS")) {   // never opens anything from a test
                FILE *f = fopen([rfDataDir() stringByAppendingPathComponent:@"dryrun.log"].fileSystemRepresentation, "a");
                if (f) { fputs("window.permission\topen " AX_PANE "\n", f); fclose(f); }
                return;
            }
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@AX_PANE]];
        });
        open->verb = @"Open Settings"; open->type = @"Settings";
        Cmd *why = mkCmd(nil, [NSString stringWithFormat:@"%@ moves windows of other apps", title], @"macOS allows that only to apps listed under Accessibility", @"ⓘ", ^(BOOL alt) {});
        why->type = @"Info";
        return @[open, why];
    };
    return v;
}

// Shown when a command could not act (full screen, no window, nothing to restore): there is no HUD, so the
// launcher says why in one row, and ↩ or Esc closes it.
static View *winSaysView(const WinCmd *c, NSString *why) {
    View *v = [View new];
    v->title = @(c->title);
    v->placeholder = @"Window Management";
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        Cmd *m = mkCmd(nil, why, @"Nothing was moved", @"ⓘ", ^(BOOL alt) { uiHide(); });
        m->type = @"Info"; m->verb = @"Close";
        return @[m];
    };
    return v;
}

#pragma mark - module

static void winSearch(NSString *q, const char *lq, NSMutableArray<Cmd *> *out) {
    for (int i = 0; i < NW; i++) {
        const WinCmd *c = &gW[i];
        int s = rfMatch(@(c->title), @(c->keys), lq);
        if (!s) continue;
        NSString *cid = [@"window." stringByAppendingString:@(c->name)];
        Cmd *m = mkCmd(cid, @(c->title), @"Window Management", @(c->glyph), ^(BOOL alt) {
            if (!winTrusted()) { uiPush(winPermissionView(c)); return; }
            NSString *e = winRun(c);   // the launcher is a non-activating panel: the user's app is still frontmost
            if (e) uiPush(winSaysView(c, e)); else uiHide();
        });
        m->type = @"Window"; m->verb = @"Move Window"; m->score = s;
        [out addObject:m];
    }
}
static BOOL winHotkey(NSString *cid) {
    if (![cid hasPrefix:@"window."]) return NO;
    const WinCmd *c = winCmd([cid substringFromIndex:7].UTF8String);
    if (!c) return NO;
    if (!winTrusted()) { uiShow(); uiPush(winPermissionView(c)); return YES; }
    NSString *e = winRun(c);
    if (e) { uiShow(); uiPush(winSaysView(c, e)); }
    return YES;
}

static BOOL parseRect(const char *s, CGRect *r) {
    double x, y, w, h;
    if (sscanf(s, "%lf,%lf,%lf,%lf", &x, &y, &w, &h) != 4) return NO;
    *r = CGRectMake(x, y, w, h); return YES;
}
static void printRect(CGRect r) { printf("%g,%g,%g,%g\n", r.origin.x, r.origin.y, r.size.width, r.size.height); }

// rayfast --run window geom <cmd> <x,y,w,h window> <x,y,w,h screen>[;<screen>…] [gap]   -> target frame, AX coordinates
//                      apply <cmd> <win> <screens> [gap] [opts]                        -> the set calls on a simulated window, then
//                                                                                          its frame (opts: min=W:H,fixed,full,eui,clamp)
//                      (opts for restore: store=<file>, id=<pid:wid>, live=<key>+<key>: windows still there)
//                      real <pid> <cmd>...                                              -> per cmd: target, frame after, ms (test window only)
//                      alive <pid:wid>                                                  -> 1 if that app still has that window
//                      ax <primary height> <x,y,w,h Cocoa rect>                        -> the same rect in AX coordinates
//                      list                                                             -> cid, glyph, title, keywords
static int winCli(int argc, const char **argv) {
    if (argc >= 4 && !strcmp(argv[0], "geom")) {
        const WinCmd *c = winCmd(argv[1]);
        CGRect w, scr[16]; int n = 0;
        if (!c || !parseRect(argv[2], &w)) { fprintf(stderr, "window geom: bad command or frame\n"); return 2; }
        for (NSString *p in [@(argv[3]) componentsSeparatedByString:@";"])
            if (n < 16 && parseRect(p.UTF8String, &scr[n])) n++;
        if (!n) { fprintf(stderr, "window geom: no screens\n"); return 2; }
        CGRect r = winGeom(c, w, scr, n, argc > 4 ? atof(argv[4]) : 0);
        if (CGRectIsNull(r)) printf("n/a\n"); else printRect(r);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[0], "apply")) {
        // a simulated window: opts is a comma list of min=W:H, fixed, full, eui, clamp
        const WinCmd *c = winCmd(argv[1]);
        Win w = {.fake = YES, .log = [NSMutableString string]};
        CGRect scr[16]; int n = 0;
        if (!c || !parseRect(argv[2], &w.f)) { fprintf(stderr, "window apply: bad command or frame\n"); return 2; }
        for (NSString *p in [@(argv[3]) componentsSeparatedByString:@";"])
            if (n < 16 && parseRect(p.UTF8String, &scr[n])) n++;
        if (!n) return 2;
        memcpy(w.clampTo, scr, sizeof scr); w.nclamp = n;
        for (NSString *o in [@(argc > 5 ? argv[5] : "") componentsSeparatedByString:@","]) {
            if ([o hasPrefix:@"min="]) sscanf(o.UTF8String + 4, "%lf:%lf", &w.minW, &w.minH);
            if ([o hasPrefix:@"store="]) w.store = [o substringFromIndex:6];
            if ([o hasPrefix:@"id="]) w.key = [o substringFromIndex:3];
            if ([o hasPrefix:@"live="]) w.live = [NSSet setWithArray:[[o substringFromIndex:5] componentsSeparatedByString:@"+"]];
            w.fixed |= [o isEqual:@"fixed"]; w.full |= [o isEqual:@"full"]; w.eui |= [o isEqual:@"eui"]; w.clamp |= [o isEqual:@"clamp"];
        }
        NSString *err = winApplyTo(&w, c, scr, n, argc > 4 ? atof(argv[4]) : 0);
        printf("%s-> ", w.log.UTF8String);
        if (err) printf("%s\n", err.UTF8String); else printRect(w.f);
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[0], "real")) {
        // the real AX path on one window of app pid, for tests: refuses any window not titled "rayfast-test-window"
        // (tests/windows/helper.m), so it can never move a window of the user's. Per command: target, result, ms.
        pid_t pid = atoi(argv[1]);
        if (!AXIsProcessTrusted()) { printf("untrusted\n"); return 3; }
        Win w = {0}; CFTypeRef t = NULL;
        NSString *err = winOpen(pid, &w);
        BOOL ours = !err && AXUIElementCopyAttributeValue(w.win, kAXTitleAttribute, &t) == kAXErrorSuccess && t && [(__bridge NSString *)t isEqual:@"rayfast-test-window"];
        if (t) CFRelease(t);
        winClose(&w);
        if (!ours) { fprintf(stderr, "window real: pid %d has no rayfast-test-window\n", pid); return 2; }
        winOpen(pid, &w); printf("start %s\n", rectStr(wGet(&w)).UTF8String); winClose(&w);
        for (int i = 2; i < argc; i++) {
            const WinCmd *c = winCmd(argv[i]);
            if (!c) return 2;
            CGRect scr[16]; int n = axScreens(scr, 16);
            winOpen(pid, &w); CGRect before = wGet(&w); winClose(&w);
            CGRect want = winGeom(c, before, scr, n, winGap());
            double t0 = CFAbsoluteTimeGetCurrent();
            NSString *e = winApply(pid, c);
            double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
            winOpen(pid, &w); CGRect got = wGet(&w); winClose(&w);
            printf("%s %s %s %.1f%s%s\n", c->name, CGRectIsNull(want) ? "n/a" : rectStr(want).UTF8String, rectStr(got).UTF8String, ms, e ? " " : "", e ? e.UTF8String : "");
        }
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[0], "alive")) { printf("%d\n", winAlive(@(argv[1]))); return 0; }
    if (argc >= 3 && !strcmp(argv[0], "ax")) {
        CGRect r;
        if (!parseRect(argv[2], &r)) return 2;
        printRect(axRect(r, atof(argv[1])));
        return 0;
    }
    if (argc >= 1 && !strcmp(argv[0], "list")) {
        for (int i = 0; i < NW; i++) printf("window.%s\t%s\t%s\t%s\n", gW[i].name, gW[i].glyph, gW[i].title, gW[i].keys);
        return 0;
    }
    fprintf(stderr, "usage: rayfast --run window geom <cmd> <win> <screens> [gap] | apply <cmd> <win> <screens> [gap] [opts] | ax <primaryH> <rect> | list\n");
    return 2;
}

static const RFModule winModule = {"window", NULL, winSearch, winHotkey, winCli};
RF_MODULE(winModule)
