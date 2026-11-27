// Clipboard history. A cheap timer watches the pasteboard's changeCount; new copies are appended to an on-disk log
// under rfDataDir()/clipboard/. Nothing is read from disk until the history view opens: the process re-execs after
// every use (rf.h), so start() must stay nearly free.
#include "rf.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/xattr.h>
#include <mach/mach_time.h>
#include <spawn.h>
#include <CommonCrypto/CommonDigest.h>
extern char **environ;

static dispatch_source_t gTimer;
static NSInteger gSeen;   // changeCount already handled; carried across respawns in the environment (execv keeps it)
#define SEEN_ENV "RF_CLIP_SEEN"
#define MAX_BYTES (1 << 20)   // text over ~1 MB is not history material
#define MAX_ROWS 200          // rows handed to the list per keystroke: typing narrows the rest
#define COMPACT_AT (1 << 20)  // log bytes past which the resting process has a child compact it (users who never open the view)
#define THUMB_PX 48           // image rows: a 24 pt tile at 2x, raw BGRA premultiplied (ui.m's icon format)

static NSString *clipDir(void) {
    NSString *d = [rfDataDir() stringByAppendingPathComponent:@"clipboard"];
    mkdir(rfDataDir().fileSystemRepresentation, 0700);
    mkdir(d.fileSystemRepresentation, 0700);
    return d;
}
static NSString *logPath(void) { return [clipDir() stringByAppendingPathComponent:@"history"]; }
// Images live beside the log as img/<hash>.png plus img/<hash>.thumb; the log's payload is just "<hash> <w>x<h>".
static NSString *imgDir(void) { NSString *d = [clipDir() stringByAppendingPathComponent:@"img"]; mkdir(d.fileSystemRepresentation, 0700); return d; }
static NSString *imgPath(NSString *payload, NSString *ext) {
    return [imgDir() stringByAppendingPathComponent:[[payload componentsSeparatedByString:@" "][0] stringByAppendingPathExtension:ext]];
}
static void unlinkImage(NSString *payload) {
    unlink(imgPath(payload, @"png").fileSystemRepresentation); unlink(imgPath(payload, @"thumb").fileSystemRepresentation);
}
static int maxEntries(void) { int m = rfSetting(@"clipboard.max", @"500").intValue; return m > 0 ? m : 500; }

#pragma mark - store

// One record per event, appended (never rewritten):  "<op> <unix time> <payload bytes> <kind> <bundle id>\t<app name>\n<payload>\n"
// op E = copied (a later E with the same payload supersedes an earlier one: that is how a repeated copy moves to the
// top), P / U = pin / unpin, D = delete. Applied in file order on read.
// The bundle id comes from whatever app copied (its org.nspasteboard.source tag): only id characters reach the header,
// and the app name loses its tabs and line breaks, so a header is always one line the reader can split.
static NSString *cleanBid(NSString *bid) {
    NSString *b = [[bid componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:
                    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"].invertedSet] componentsJoinedByString:@""];
    return b.length ? (b.length > 200 ? [b substringToIndex:200] : b) : @"-";
}
static NSString *cleanApp(NSString *app) {
    NSString *a = [[app ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
    return a.length > 200 ? [a substringToIndex:200] : a;
}
static NSData *record(char op, long t, char kind, NSString *text, NSString *bid, NSString *app) {
    NSData *p = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString *h = [NSString stringWithFormat:@"%c %ld %lu %c %@\t%@\n", op, t, (unsigned long)p.length, kind, cleanBid(bid), cleanApp(app)];
    NSMutableData *rec = [[h dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [rec appendData:p]; [rec appendBytes:"\n" length:1];
    return rec;
}
// The log, open and flock'd. A compaction renames a new file over the path while an appender may be waiting on the
// old one's lock: whoever gets a lock on an inode that is no longer the path's reopens, so no append is lost.
static int openLocked(int flags) {
    const char *p = logPath().fileSystemRepresentation;
    for (int i = 0; i < 8; i++) {
        int fd = open(p, flags, 0600);
        if (fd < 0) return -1;
        struct stat a, b;
        if (!flock(fd, LOCK_EX) && !fstat(fd, &a) && !stat(p, &b) && a.st_ino == b.st_ino) return fd;
        close(fd);
    }
    return -1;
}
// Size of the log after its last compaction (or after a read that found nothing to drop): an xattr on the log itself.
#define SIZE_XATTR "rayfast.compacted"
static long compactedSize(void) { long v = 0; return getxattr(logPath().fileSystemRepresentation, SIZE_XATTR, &v, sizeof v, 0, 0) == sizeof v ? v : 0; }
static void noteCompacted(void) {
    struct stat st; const char *p = logPath().fileSystemRepresentation;
    if (!stat(p, &st)) { long v = st.st_size; setxattr(p, SIZE_XATTR, &v, sizeof v, 0, 0); }
}
// Returns YES when the log has outgrown its last compaction (twice its size, at least COMPACT_AT): time to compact.
static BOOL appendRecord(char op, char kind, NSString *text, NSString *bid, NSString *app) {
    NSData *rec = record(op, time(NULL), kind, text, bid, app);
    int fd = openLocked(O_WRONLY | O_APPEND | O_CREAT);
    if (fd < 0) return NO;
    write(fd, rec.bytes, rec.length);   // one write: a reader never sees half a record from us
    off_t sz = lseek(fd, 0, SEEK_END);
    close(fd);
    return sz > COMPACT_AT && sz > 2 * compactedSize();
}

// The live history: pinned entries first, then the rest newest first, at most `max` unpinned (pins never count or drop).
// [{t, kind, bid, app, text, seq, pin}]. *records = records in the file.
static NSArray<NSDictionary *> *readHistory(int max, NSUInteger *records) {
    NSData *d = [NSData dataWithContentsOfFile:logPath()];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byText = [NSMutableDictionary dictionary];
    NSUInteger nrec = 0;
    const char *b = d.bytes, *end = b + d.length;
    while (b && b < end) {
        const char *nl = memchr(b, '\n', end - b);
        if (!nl) break;
        // the header is parsed as its own NUL-terminated line: sscanf's whitespace must never run on into the payload
        char hdr[64]; size_t hl = MIN((size_t)(nl - b), sizeof hdr - 1);
        memcpy(hdr, b, hl); hdr[hl] = 0;
        long t = 0; unsigned long n = 0; char op = 0, kind = 0; int used = 0;
        if (sscanf(hdr, "%c %ld %lu %c %n", &op, &t, &n, &kind, &used) < 4 || n > (size_t)(end - nl - 1)) break;   // a torn tail ends the log
        if (used > nl - b) used = (int)(nl - b);
        NSString *text = [[NSString alloc] initWithBytes:nl + 1 length:n encoding:NSUTF8StringEncoding] ?: @"";
        NSMutableDictionary *e = byText[text];
        nrec++;
        if (op == 'E') {
            NSString *meta = [[NSString alloc] initWithBytes:b + used length:nl - b - used encoding:NSUTF8StringEncoding] ?: @"-\t";
            NSArray *m = [meta componentsSeparatedByString:@"\t"];
            if (!e) e = byText[text] = [@{@"text": text, @"pin": @NO} mutableCopy];
            [e addEntriesFromDictionary:@{@"t": @(t), @"kind": [NSString stringWithFormat:@"%c", kind], @"bid": m[0],
                                          @"app": m.count > 1 ? m[1] : @"", @"seq": @(nrec)}];
            if (kind == 'i') {   // "<hash> 1280x720" -> found and shown as "Image 1280×720"
                NSArray *p = [text componentsSeparatedByString:@" "];
                e[@"find"] = [@"Image " stringByAppendingString:[(p.count > 1 ? p[1] : @"") stringByReplacingOccurrencesOfString:@"x" withString:@"×"]];
            }
        } else if (op == 'P' || op == 'U') e[@"pin"] = @(op == 'P');
        else if (op == 'D') [byText removeObjectForKey:text];
        b = nl + 1 + n + 1;
    }
    if (records) *records = nrec;
    NSArray *all = [byText.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        if ([x[@"pin"] boolValue] != [y[@"pin"] boolValue]) return [x[@"pin"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
        return [y[@"seq"] compare:x[@"seq"]];
    }];
    NSMutableArray *out = [NSMutableArray array];
    int unpinned = 0;
    for (NSDictionary *e in all) {
        if (![e[@"pin"] boolValue] && unpinned++ >= max) break;
        [out addObject:e];
    }
    return out;
}

// Rewrite the log as just the live entries (temp file + rename, 0600). Only when the view opens or from `compact`:
// never in the resting process, whose footprint would keep the pages.
static void compactTo(NSArray<NSDictionary *> *live) {
    NSMutableData *all = [NSMutableData data];
    NSArray *bySeq = [live sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"seq" ascending:YES]]];
    for (NSDictionary *e in bySeq)
        [all appendData:record('E', [e[@"t"] longValue], [e[@"kind"] UTF8String][0], e[@"text"], e[@"bid"], e[@"app"])];
    for (NSDictionary *e in bySeq)
        if ([e[@"pin"] boolValue]) [all appendData:record('P', [e[@"t"] longValue], [e[@"kind"] UTF8String][0], e[@"text"], @"", @"")];
    NSString *tmp = [logPath() stringByAppendingString:@".tmp"];
    int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    BOOL ok = write(fd, all.bytes, all.length) == (ssize_t)all.length;
    close(fd);
    if (ok) rename(tmp.fileSystemRepresentation, logPath().fileSystemRepresentation); else { unlink(tmp.fileSystemRepresentation); return; }
    // images the cap dropped: their files go too
    NSMutableSet *keep = [NSMutableSet set];
    for (NSDictionary *e in live) if ([e[@"kind"] isEqual:@"i"]) [keep addObject:[e[@"text"] componentsSeparatedByString:@" "][0]];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:imgDir() error:nil])
        if (![keep containsObject:f.stringByDeletingPathExtension]) unlink([imgDir() stringByAppendingPathComponent:f].fileSystemRepresentation);
}
// Rewrite the log now, under its lock (after a delete: the deleted text must leave the disk, not wait for a cap).
static void compactNow(int max) {
    int fd = openLocked(O_RDONLY);
    if (fd < 0) return;
    compactTo(readHistory(max, NULL));
    close(fd);
    noteCompacted();
}
// Read the history and compact it when the cap dropped something or superseded records make up half the file.
// The rewrite happens under the log's lock, from a fresh read, so appends racing it land in the new file.
static NSArray<NSDictionary *> *loadHistory(int max) {
    NSUInteger n = 0;
    NSArray *live = readHistory(max, &n);
    if (n > live.count && ((int)live.count >= max || n > 2 * live.count)) {
        int fd = openLocked(O_RDONLY);
        if (fd >= 0) { live = readHistory(max, &n); if (n > live.count) compactTo(live); close(fd); }
    }
    noteCompacted();
    return live;
}

#pragma mark - watcher

static void noteSeen(NSInteger c) { gSeen = c; char b[24]; snprintf(b, sizeof b, "%ld", (long)c); setenv(SEEN_ENV, b, 1); }

// Password managers and generated content mark their copies (nspasteboard.org); those never reach the disk.
static BOOL isPrivate(NSArray<NSString *> *types) {
    for (NSString *t in @[@"org.nspasteboard.ConcealedType", @"org.nspasteboard.TransientType", @"org.nspasteboard.AutoGeneratedType",
                          @"com.agilebits.onepassword", @"de.petermaurer.TransientPasteboardType"])
        if ([types containsObject:t]) return YES;
    return NO;
}
static BOOL ignoredApp(NSString *bid) {
    if (!bid.length) return NO;
    for (NSString *s in [rfSetting(@"clipboard.ignore", @"") componentsSeparatedByString:@","])
        if ([trim(s) caseInsensitiveCompare:bid] == NSOrderedSame) return YES;
    return NO;
}

// Runs `rayfast --run clipboard <args…>` as a child, stdio to /dev/null; the respawn waits for it (uiBusy).
static BOOL spawnSelf(NSArray<NSString *> *args, void (^done)(void)) {
    const char *av[12] = {NSBundle.mainBundle.executablePath.fileSystemRepresentation, "--run", "clipboard"};
    int n = 3;
    for (NSString *a in args) if (n < 11) av[n++] = a.UTF8String;
    av[n] = NULL;
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    for (int fd = 0; fd < 2; fd++) posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);
    pid_t pid;
    int rc = posix_spawn(&pid, av[0], &fa, NULL, (char *const *)av, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc) return NO;
    uiBusy(1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int st; waitpid(pid, &st, 0);
        dispatch_async(dispatch_get_main_queue(), ^{ uiBusy(-1); if (done) done(); });
    });
    return YES;
}
// An image is decoded, converted and thumbnailed by a short-lived `--run clipboard ingest-image` child: a resting
// process that decoded a 5K screenshot would keep tens of MB of malloc'd pages. The respawn waits for it (uiBusy).
static void spawnIngest(NSInteger change, NSString *bid, NSString *app) {
    double mb = rfSetting(@"clipboard.imagemax", @"20").doubleValue;
    spawnSelf(@[@"ingest-image", [NSString stringWithFormat:@"%ld", (long)change], [NSString stringWithFormat:@"%.0f", (mb > 0 ? mb : 20) * 1048576],
                bid ?: @"-", app ?: @""], nil);
}
// A user who never opens the view still gets the cap applied: reading and rewriting the log happens in a child, so the
// resting process never holds its pages.
static void spawnCompact(void) {
    static BOOL running;
    if (running) return;
    running = spawnSelf(@[@"compact", [NSString stringWithFormat:@"%d", maxEntries()]], ^{ running = NO; });
}
// The child: read the image (if the pasteboard hasn't moved on), store it as PNG under the size cap, plus its thumbnail.
static int storeImage(NSData *png, NSData *src, long cap, NSString *bid, NSString *app) {
    if (!src.length || (long)src.length > 8 * cap) return 1;   // an uncompressed TIFF shrinks a lot as PNG, but not 8x
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:src];
    NSInteger w = rep.pixelsWide, h = rep.pixelsHigh;
    if (!rep || w <= 0 || h <= 0) return 1;
    if (!png) png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png.length || (long)png.length > cap) return 1;
    uint8_t md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(png.bytes, (CC_LONG)png.length, md);
    NSMutableString *hash = [NSMutableString string];
    for (int i = 0; i < 12; i++) [hash appendFormat:@"%02x", md[i]];
    NSString *payload = [NSString stringWithFormat:@"%@ %ldx%ld", hash, (long)w, (long)h];
    // the thumbnail: aspect-fit into THUMB_PX², drawn once here so the view only maps bytes
    static uint8_t px[THUMB_PX * THUMB_PX * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(px, THUMB_PX, THUMB_PX, 8, THUMB_PX * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!cg) return 1;
    double k = (double)THUMB_PX / MAX(w, h), tw = MAX(1, w * k), th = MAX(1, h * k);
    CGContextSetInterpolationQuality(cg, kCGInterpolationHigh);
    CGImageRef im = rep.CGImage;
    if (im) CGContextDrawImage(cg, CGRectMake((THUMB_PX - tw) / 2, (THUMB_PX - th) / 2, tw, th), im);
    CGContextRelease(cg);
    BOOL ok = YES;
    for (NSString *ext in @[@"png", @"thumb"]) {
        NSData *d = [ext isEqual:@"png"] ? png : [NSData dataWithBytesNoCopy:px length:sizeof px freeWhenDone:NO];
        NSString *p = imgPath(payload, ext), *tmp = [p stringByAppendingString:@".tmp"];
        int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        ok = ok && fd >= 0 && write(fd, d.bytes, d.length) == (ssize_t)d.length;
        if (fd >= 0) close(fd);
        if (ok) rename(tmp.fileSystemRepresentation, p.fileSystemRepresentation); else unlink(tmp.fileSystemRepresentation);
    }
    if (!ok) { unlinkImage(payload); return 1; }
    appendRecord('E', 'i', payload, [bid isEqual:@"-"] ? nil : bid, app);
    loadHistory(maxEntries());   // we are a short-lived child: apply the cap now, so dropped images leave the disk
    return 0;
}
static int ingestImage(NSInteger change, long cap, NSString *bid, NSString *app) {
    NSPasteboard *pb = rfPasteboard();
    if (pb.changeCount != change) return 1;
    NSData *png = [pb dataForType:NSPasteboardTypePNG];
    return storeImage(png, png ?: [pb dataForType:NSPasteboardTypeTIFF], cap, bid, app);
}

static BOOL gReadBig;   // this poll pulled a large copy into memory
static void pollOnce(void);
// A copy is only measured by reading it, and a big one's pages stay with the resting process (it re-execs after a
// hide, not while hidden). So after reading one, ask for the re-exec now: uiBusy's release schedules it when the launcher
// isn't open (and the open launcher re-execs after its hide anyway). gSeen survives in the environment.
static void poll(void) {
    pollOnce();
    if (gReadBig) { gReadBig = NO; uiBusy(1); uiBusy(-1); }
}
static void pollOnce(void) {
    @autoreleasepool {
        NSPasteboard *pb = rfPasteboard();
        NSInteger c = pb.changeCount;
        if (c == gSeen) return;
        noteSeen(c);
        NSArray *types = pb.types;
        if (isPrivate(types)) return;
        char kind = 't';
        NSString *s = nil;
        if ([types containsObject:NSPasteboardTypeFileURL]) {   // copied files (Finder's string is just the name): their paths, one per line
            NSMutableArray *paths = [NSMutableArray array];
            for (NSURL *u in [pb readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}])
                if (u.path.length) [paths addObject:u.path];
            if (paths.count) { s = [paths componentsJoinedByString:@"\n"]; kind = 'f'; }
        }
        if (!s) { s = [pb stringForType:NSPasteboardTypeString]; gReadBig = s.length > 256 * 1024; }
        BOOL image = !s && ([types containsObject:NSPasteboardTypePNG] || [types containsObject:NSPasteboardTypeTIFF]);
        if (!image && (!s.length || s.length > MAX_BYTES || !trim(s).length)) return;
        // the copying app: its own claim (nspasteboard.org source type) if it makes one, else whatever is frontmost
        NSString *bid = [types containsObject:@"org.nspasteboard.source"] ? [pb stringForType:@"org.nspasteboard.source"] : nil, *app = nil;
        if (bid.length) app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bid].URLByDeletingPathExtension.lastPathComponent;
        else { NSRunningApplication *fa = NSWorkspace.sharedWorkspace.frontmostApplication; bid = fa.bundleIdentifier; app = fa.localizedName; }
        if (ignoredApp(bid)) return;
        if (image) spawnIngest(c, bid, app); else if (appendRecord('E', kind, s, bid, app)) spawnCompact();
    }
}

#pragma mark - view

static NSString *typeOf(NSDictionary *e) {
    if ([e[@"kind"] isEqual:@"f"]) return @"File";
    if ([e[@"kind"] isEqual:@"i"]) return @"Image";
    NSString *t = trim(e[@"text"]);
    if ([t rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound) {
        if ([t hasPrefix:@"http://"] || [t hasPrefix:@"https://"] || [t hasPrefix:@"mailto:"]) return @"Link";
        if (([t hasPrefix:@"#"] && (t.length == 4 || t.length == 7 || t.length == 9)) &&
            [[t substringFromIndex:1] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet].location == NSNotFound)
            return @"Color";
    }
    return @"Text";
}
static NSString *age(long t) {
    long s = MAX(0, time(NULL) - t);
    if (s < 60) return @"now";
    if (s < 3600) return [NSString stringWithFormat:@"%ldm", s / 60];
    if (s < 86400) return [NSString stringWithFormat:@"%ldh", s / 3600];
    return [NSString stringWithFormat:@"%ldd", s / 86400];
}
static NSString *firstLine(NSString *s) {
    for (NSString *l in [s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *t = trim(l);
        if (t.length) return t.length > 120 ? [[t substringToIndex:120] stringByAppendingString:@"…"] : t;
    }
    return @"";
}
// Every word of the query occurs somewhere in the entry, ignoring case.
static NSArray<NSDictionary *> *filtered(NSArray<NSDictionary *> *h, NSString *q, NSUInteger limit) {
    NSArray *words = [q componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *e in h) {
        BOOL all = YES;
        NSString *s = e[@"find"] ?: e[@"text"];
        for (NSString *w in words) if ([s rangeOfString:w options:NSCaseInsensitiveSearch].location == NSNotFound) { all = NO; break; }
        if (all) { [out addObject:e]; if (out.count >= limit) break; }
    }
    return out;
}

static void putBack(NSDictionary *e, BOOL paste) {
    NSPasteboard *pb = rfPasteboard();
    [pb clearContents];
    if ([e[@"kind"] isEqual:@"f"]) {   // the file references themselves, as Finder puts them
        NSMutableArray *urls = [NSMutableArray array];
        for (NSString *p in [e[@"text"] componentsSeparatedByString:@"\n"]) [urls addObject:[NSURL fileURLWithPath:p]];
        [pb writeObjects:urls];
    } else if ([e[@"kind"] isEqual:@"i"]) {
        NSData *png = [NSData dataWithContentsOfFile:imgPath(e[@"text"], @"png")];
        if (!png) { uiHide(); return; }   // its file is gone: nothing sensible to paste
        [pb setData:png forType:NSPasteboardTypePNG];
    } else [pb setString:e[@"text"] forType:NSPasteboardTypeString];
    noteSeen(pb.changeCount);   // our own write is not a new copy "from rayfast"...
    appendRecord('E', [e[@"kind"] UTF8String][0], e[@"text"], e[@"bid"], e[@"app"]);   // ...but it does move to the top
    if (paste) uiHideAndPaste(); else uiHide();
}
static void reloadView(void);
// pin / unpin / delete: one appended record, then the open view re-reads the log
static void mark(NSDictionary *e, char op) {
    appendRecord(op, [e[@"kind"] UTF8String][0], e[@"text"], @"", @"");
    if (op == 'D') compactNow(maxEntries());   // a deleted entry (often a password copied by mistake) leaves the disk now, image files too
    reloadView();
}
// Thumbnails, while the view is open: the raw file is mapped, not read, so only the rows actually drawn touch pages.
static NSMutableDictionary *gThumbs;
static id thumbFor(NSDictionary *e) {
    NSString *p = imgPath(e[@"text"], @"thumb");
    id im = gThumbs[p];
    if (im) return im == NSNull.null ? nil : im;
    NSData *d = [NSData dataWithContentsOfFile:p options:NSDataReadingMappedAlways error:nil];
    if (d.length == THUMB_PX * THUMB_PX * 4) {
        static CGColorSpaceRef cs; if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
        im = CFBridgingRelease(CGImageCreate(THUMB_PX, THUMB_PX, 8, 32, THUMB_PX * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                             dp, NULL, false, kCGRenderingIntentDefault));
        CGDataProviderRelease(dp);
    }
    if (!gThumbs) gThumbs = [NSMutableDictionary dictionary];
    gThumbs[p] = im ?: NSNull.null;
    return im;
}
static Cmd *rowFor(NSDictionary *e) {
    NSString *app = [e[@"app"] length] ? e[@"app"] : e[@"bid"];
    NSString *type = typeOf(e), *title = e[@"find"] ?: firstLine(e[@"text"]);
    if ([type isEqual:@"File"]) {   // "name", or "name + 2 more"
        NSArray *paths = [e[@"text"] componentsSeparatedByString:@"\n"];
        title = [paths[0] lastPathComponent];
        if (paths.count > 1) title = [NSString stringWithFormat:@"%@ + %lu more", title, (unsigned long)paths.count - 1];
    }
    Cmd *k = mkCmd(nil, title, [NSString stringWithFormat:@"%@%@ · %@", [e[@"pin"] boolValue] ? @"Pinned · " : @"", app, age([e[@"t"] longValue])],
                   [type isEqual:@"Link"] ? @"↗" : [type isEqual:@"Color"] ? @"●" : [type isEqual:@"File"] ? @"▤" : [type isEqual:@"Image"] ? @"▣" : @"¶", ^(BOOL alt) { putBack(e, !alt); });
    k->type = type; k->verb = @"Paste"; k->altVerb = @"Copy";
    if ([type isEqual:@"Image"]) k->icon = thumbFor(e);
    k->keys = @{@"cmd+shift+p": ^{ mark(e, [e[@"pin"] boolValue] ? 'U' : 'P'); }, @"ctrl+x": ^{ mark(e, 'D'); }};
    return k;
}

static NSArray<NSDictionary *> *gHistory;   // only while the view is open
static View *gView;
static NSString *hintFor(NSUInteger n) {
    return n ? [NSString stringWithFormat:@"%lu entries · ⌘⇧P pin · ⌃X delete", (unsigned long)n] : @"Nothing copied yet";
}
static void reloadView(void) {
    if (!gView) return;
    gHistory = readHistory(maxEntries(), NULL);
    gView->hint = hintFor(gHistory.count);
    uiRefresh();
}
static void openView(void) {
    gHistory = loadHistory(maxEntries());
    View *v = gView = [View new];
    v->title = @"Clipboard History";
    v->placeholder = @"Search clipboard history…";
    v->hint = hintFor(gHistory.count);
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *e in filtered(gHistory, q, MAX_ROWS)) [rows addObject:rowFor(e)];
        return rows;
    };
    v->closed = ^{ gHistory = nil; gView = nil; gThumbs = nil; };
    uiPush(v);
}
static void clearHistory(void) {
    unlink(logPath().fileSystemRepresentation); unlink([logPath() stringByAppendingString:@".tmp"].fileSystemRepresentation);
    [NSFileManager.defaultManager removeItemAtPath:imgDir() error:nil];
}
// Clearing can't be undone, so it asks, with Cancel on the selected row: the ↩ that opened this view, doubled, cancels.
static void confirmClear(void) {
    NSUInteger n = readHistory(INT_MAX, NULL).count;
    NSString *what = n ? [NSString stringWithFormat:@"Removes %lu entr%@ from disk, pins included", (unsigned long)n, n == 1 ? @"y" : @"ies"] : @"The history is empty";
    View *v = [View new];
    v->title = @"Clear Clipboard History?";
    v->placeholder = @"↩ on Clear to confirm, esc to cancel";
    v->hint = @"esc Cancel";
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        Cmd *no = mkCmd(nil, @"Cancel", @"Keep the history", @"⎋", ^(BOOL alt) { uiHide(); });
        no->verb = @"Cancel";
        Cmd *yes = mkCmd(@"clipboard.clear.confirm", @"Clear Clipboard History", what, @"⎘", ^(BOOL alt) { clearHistory(); uiHide(); });
        yes->verb = @"Clear History";
        return @[no, yes];
    };
    uiPush(v);
}

#pragma mark - module

static void start(void) {
    if ([rfSetting(@"clipboard.enabled", @"on") isEqual:@"off"]) return;
    const char *e = getenv(SEEN_ENV);
    if (e) gSeen = atol(e); else noteSeen(rfPasteboard().changeCount);   // first launch: what's already there isn't a new copy
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // 0.5 s with wide leeway: the kernel coalesces our wakeup with others, so an idle rayfast stays asleep
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), 500 * NSEC_PER_MSEC, 300 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{ poll(); });
    dispatch_resume(gTimer);
}

static void search(NSString *q, const char *lq, NSMutableArray<Cmd *> *out) {
    int s = rfMatch(@"Clipboard History", @"paste copy pasteboard clip", lq);
    if (s) {
        Cmd *k = mkCmd(@"clipboard.history", @"Clipboard History", nil, @"⎘", ^(BOOL alt) { openView(); });
        k->score = s; k->verb = @"Open";
        [out addObject:k];
    }
    if ((s = rfMatch(@"Clear Clipboard History", @"wipe erase clipboard", lq))) {
        Cmd *k = mkCmd(@"clipboard.clear", @"Clear Clipboard History", nil, @"⎘", ^(BOOL alt) { confirmClear(); });
        k->score = s; k->verb = @"Continue…";
        [out addObject:k];
    }
}
static BOOL run(NSString *cid) {
    if ([cid isEqual:@"clipboard.history"]) { uiShow(); openView(); return YES; }
    if ([cid isEqual:@"clipboard.clear"]) { uiShow(); confirmClear(); return YES; }
    return NO;
}

#pragma mark - command line (tests)

static int cli(int argc, const char **argv) {
    NSString *cmd = argc ? @(argv[0]) : @"";
    NSPasteboard *pb = rfPasteboard();
    if ([cmd isEqual:@"pb-set"] && argc >= 2) {   // pb-set <text> [type[=value]…]: write the (test) pasteboard like an app would
        [pb clearContents];
        NSMutableArray *types = [NSMutableArray arrayWithObject:NSPasteboardTypeString];
        for (int i = 2; i < argc; i++) [types addObject:[@(argv[i]) componentsSeparatedByString:@"="][0]];
        [pb declareTypes:types owner:nil];
        [pb setString:@(argv[1]) forType:NSPasteboardTypeString];
        for (int i = 2; i < argc; i++) {
            NSArray *kv = [@(argv[i]) componentsSeparatedByString:@"="];
            [pb setString:kv.count > 1 ? kv[1] : @"" forType:kv[0]];
        }
        return 0;
    }
    if ([cmd isEqual:@"pb-set-file"] && argc >= 2) {   // the text from a file (too big for an argument)
        NSString *t = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        if (!t) return 1;
        [pb clearContents]; [pb setString:t forType:NSPasteboardTypeString];
        return 0;
    }
    if ([cmd isEqual:@"pb-set-files"] && argc >= 2) {   // pb-set-files <path>…: file references, like a copy in Finder
        NSMutableArray *urls = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [urls addObject:[NSURL fileURLWithPath:@(argv[i])]];
        [pb clearContents]; [pb writeObjects:urls];
        return 0;
    }
    if ([cmd isEqual:@"pb-set-data"] && argc >= 3) {   // pb-set-data <type> <file>: raw data, e.g. public.png, as a screenshot puts it
        NSData *d = [NSData dataWithContentsOfFile:@(argv[2])];
        if (!d) return 1;
        [pb clearContents]; [pb setData:d forType:@(argv[1])];
        return 0;
    }
    if ([cmd isEqual:@"pb-get-data"] && argc >= 3) return [[pb dataForType:@(argv[1])] writeToFile:@(argv[2]) atomically:NO] ? 0 : 1;
    if ([cmd isEqual:@"ingest-image"] && argc >= 5) return ingestImage(atol(argv[1]), atol(argv[2]), @(argv[3]), @(argv[4]));
    if ([cmd isEqual:@"add-image"] && argc >= 2) {   // add-image <png|tiff file>: store it as if copied (seeding tests)
        NSData *d = [NSData dataWithContentsOfFile:@(argv[1])];
        return storeImage([@(argv[1]) hasSuffix:@".png"] ? d : nil, d, 20 << 20, @"com.example.seed", @"Seed");
    }
    if ([cmd isEqual:@"pb-get-files"]) {
        for (NSURL *u in [pb readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}]) printf("%s\n", u.path.UTF8String);
        return 0;
    }
    if ([cmd isEqual:@"pb-get"]) { printf("%s\n", [pb stringForType:NSPasteboardTypeString].UTF8String ?: ""); return 0; }
    if ([cmd isEqual:@"list"]) {   // pinned, then newest first, one line each: "<P|-> <kind> <bundle id>\t<text with \n escaped>"
        for (NSDictionary *e in readHistory(INT_MAX, NULL))
            printf("%s %s %s\t%s\n", [e[@"pin"] boolValue] ? "P" : "-", [e[@"kind"] UTF8String], [e[@"bid"] UTF8String], [[e[@"text"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String]);
        return 0;
    }
    if ([cmd isEqual:@"records"]) { NSUInteger n = 0; readHistory(INT_MAX, &n); printf("%lu\n", (unsigned long)n); return 0; }
    if ([cmd isEqual:@"rows"]) {   // rows <query>: the view's rows as "title | subtitle | type"
        for (NSDictionary *e in filtered(readHistory(maxEntries(), NULL), argc > 1 ? @(argv[1]) : @"", MAX_ROWS)) {
            Cmd *k = rowFor(e);
            printf("%s | %s | %s%s\n", k->title.UTF8String, k->sub.UTF8String, k->type.UTF8String, k->icon ? " | thumb" : "");
        }
        return 0;
    }
    if ([cmd isEqual:@"bench-filter"] && argc >= 2) {   // bench-filter <n>: ms to filter n synthetic entries with two 2-word queries (median of 9)
        int n = atoi(argv[1]); NSMutableArray *h = [NSMutableArray array];
        for (int i = 0; i < n; i++)
            [h addObject:@{@"t": @(time(NULL)), @"kind": @"t", @"bid": @"-", @"app": @"",
                           @"text": [NSString stringWithFormat:@"entry %d: some copied text from a document, line %d\nwith a second line %x", i, i * 7, i * 31]}];
        double ms[9]; mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        for (int r = 0; r < 9; r++) {
            uint64_t t0 = mach_absolute_time();
            @autoreleasepool {   // the slow cases: every entry matches (MAX_ROWS rows built), or the scan runs to the end
                for (NSDictionary *e in filtered(h, @"Second DOCUMENT", MAX_ROWS)) rowFor(e);
                filtered(h, @"second zebra", MAX_ROWS);
            }
            ms[r] = (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
        }
        qsort_b(ms, 9, sizeof *ms, ^int(const void *a, const void *b) { return *(double *)a < *(double *)b ? -1 : *(double *)a > *(double *)b; });
        printf("%.2f\n", ms[4]);
        return 0;
    }
    if ([cmd isEqual:@"compact"] && argc >= 2) { loadHistory(atoi(argv[1])); return 0; }   // compact <max>
    fprintf(stderr, "usage: rayfast --run clipboard pb-set <text> [type[=value]…] | pb-set-file <path> | pb-set-files <path>… | pb-set-data <type> <file> | pb-get | pb-get-files | pb-get-data <type> <file> | list | records | rows <q> | bench-filter <n> | compact <max>\n");
    return 2;
}

static const RFModule M = {"clipboard", start, search, run, cli};
RF_MODULE(M)
