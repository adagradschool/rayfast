// snip.m — snippets and quicklinks: user-edited text files in cfgDir(), parsed lazily, shown as root rows.
#include "rf.h"
#include <sys/stat.h>

#pragma mark - snippet file

// cfgDir()/snippets. A line "--- name" starts a snippet, "--- name | keywords" adds words it's also found by, and
// everything up to the next such line is the body, so multi-line bodies are just lines. Blank lines at the end of a
// body are dropped (they separate snippets). A body line that has to start with "--- " is written "\--- " (one
// backslash is removed from any line starting with backslashes then "---"). A lone "---" is body text (markdown).
// Before the first snippet, blank lines and "# comments" are ignored. Mistakes skip that one snippet and leave a
// "line N: ..." problem; they never stop the rest from loading.
@interface Snip : NSObject { @public NSString *name, *keys, *body; int line; }
@end
@implementation Snip
@end

static BOOL isHeader(NSString *t, NSUInteger a, NSUInteger e) {
    return e - a >= 4 && [t characterAtIndex:a] == '-' && [t characterAtIndex:a + 1] == '-' && [t characterAtIndex:a + 2] == '-' && [t characterAtIndex:a + 3] == ' ';
}
// drops trailing whitespace-only lines and the newline before them; keeps the last real line as typed
static NSString *trimBody(NSString *b) {
    NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
    NSUInteger n = b.length;
    for (;;) {
        NSRange nl = [b rangeOfString:@"\n" options:NSBackwardsSearch range:NSMakeRange(0, n)];
        NSUInteger from = nl.location == NSNotFound ? 0 : nl.location + 1;
        if ([[b substringWithRange:NSMakeRange(from, n - from)] stringByTrimmingCharactersInSet:ws].length) break;
        if (nl.location == NSNotFound) { n = 0; break; }
        n = nl.location;
    }
    b = [b substringToIndex:n];
    if ([b rangeOfString:@"\\---"].location == NSNotFound) return b;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^\\\\(\\\\*---)" options:NSRegularExpressionAnchorsMatchLines error:nil];
    return [re stringByReplacingMatchesInString:b options:0 range:NSMakeRange(0, b.length) withTemplate:@"$1"];
}
static NSArray<Snip *> *parseSnippets(NSString *txt, NSMutableArray<NSString *> *problems) {
    NSMutableArray<Snip *> *out = [NSMutableArray array];
    if ([txt hasPrefix:@"﻿"]) txt = [txt substringFromIndex:1];
    if ([txt containsString:@"\r"]) txt = [[txt stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableSet *seen = [NSMutableSet set];
    __block Snip *cur = nil; BOOL skipping = NO, strayNoted = NO;
    __block NSUInteger bodyAt = 0; NSUInteger len = txt.length, a = 0; int line = 0;
    void (^close)(NSUInteger) = ^(NSUInteger end) {
        cur->body = trimBody([txt substringWithRange:NSMakeRange(bodyAt, end - bodyAt)]);
        if (!cur->body.length) [problems addObject:[NSString stringWithFormat:@"line %d: \"%@\" has no text, skipped", cur->line, cur->name]];
        else [out addObject:cur];
    };
    while (a < len) {
        NSRange nl = [txt rangeOfString:@"\n" options:NSLiteralSearch range:NSMakeRange(a, len - a)];
        NSUInteger e = nl.location == NSNotFound ? len : nl.location, next = nl.location == NSNotFound ? len : e + 1;
        line++;
        if (isHeader(txt, a, e)) {
            if (cur) close(a);
            cur = nil; skipping = YES;
            NSString *h = [txt substringWithRange:NSMakeRange(a + 4, e - a - 4)];
            NSRange bar = [h rangeOfString:@" | "];
            NSString *name = trim(bar.location == NSNotFound ? h : [h substringToIndex:bar.location]);
            NSString *keys = bar.location == NSNotFound ? @"" : trim([h substringFromIndex:NSMaxRange(bar)]);
            if ([name hasSuffix:@" |"]) name = trim([name substringToIndex:name.length - 1]);   // "--- name |" with no keywords
            if (!name.length) [problems addObject:[NSString stringWithFormat:@"line %d: a snippet needs a name after \"--- \", skipped", line]];
            else if ([seen containsObject:name.lowercaseString]) [problems addObject:[NSString stringWithFormat:@"line %d: \"%@\" is already used above, skipped", line, name]];
            else {
                [seen addObject:name.lowercaseString];
                cur = [Snip new]; cur->name = name; cur->keys = keys; cur->line = line; skipping = NO;
                bodyAt = next;
            }
        } else if (!cur && !skipping && !strayNoted) {
            NSString *l = trim([txt substringWithRange:NSMakeRange(a, e - a)]);
            if (l.length && ![l hasPrefix:@"#"]) {
                [problems addObject:[NSString stringWithFormat:@"line %d: text before the first \"--- name\" line, ignored", line]];
                strayNoted = YES;
            }
        }
        a = next;
    }
    if (cur) close(len);
    return out;
}
static NSString *snippetsPath(void) { return [cfgDir() stringByAppendingPathComponent:@"snippets"]; }
static NSArray<Snip *> *parseSnippetsFile(NSString *path, NSMutableArray<NSString *> *problems) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return @[];
    NSString *txt = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!txt) { [problems addObject:@"the file is not UTF-8 text, nothing loaded"]; return @[]; }
    return parseSnippets(txt, problems);
}

#pragma mark - module

static NSString *pbString(void) { return [rfPasteboard() stringForType:NSPasteboardTypeString]; }
static void pbSet(NSString *s) { NSPasteboard *pb = rfPasteboard(); [pb clearContents]; [pb setString:s forType:NSPasteboardTypeString]; }

// The parsed file, kept until its mtime or size changes. Nothing is read until the first root query; after a respawn
// that is one more read (a few ms for a big file), which is cheaper than keeping anything at idle.
static NSArray<Snip *> *gSnips; static NSArray<NSString *> *gSnipProblems;
static struct timespec gSnipMt; static off_t gSnipSize = -1;
static NSArray<Snip *> *snippets(void) {
    struct stat st; NSString *p = snippetsPath();
    if (stat(p.fileSystemRepresentation, &st)) { gSnips = @[]; gSnipProblems = @[]; gSnipSize = -1; return gSnips; }
    if (gSnips && st.st_size == gSnipSize && st.st_mtimespec.tv_sec == gSnipMt.tv_sec && st.st_mtimespec.tv_nsec == gSnipMt.tv_nsec) return gSnips;
    if (getenv("RF_HEADLESS")) fprintf(stderr, "snippets: read %s\n", p.fileSystemRepresentation);
    NSMutableArray *problems = [NSMutableArray array];
    gSnips = parseSnippetsFile(p, problems); gSnipProblems = problems;
    gSnipMt = st.st_mtimespec; gSnipSize = st.st_size;
    return gSnips;
}
static Snip *snipNamed(NSString *name) {
    for (Snip *s in snippets()) if ([s->name caseInsensitiveCompare:name] == NSOrderedSame) return s;
    return nil;
}
static NSString *firstLine(NSString *b) {
    NSString *l = [b componentsSeparatedByString:@"\n"][0];
    NSString *t = trim(l);
    if (!t.length) for (NSString *x in [b componentsSeparatedByString:@"\n"]) if ((t = trim(x)).length) break;   // body opens with blank lines
    return t.length > 72 ? [[t substringToIndex:[t rangeOfComposedCharacterSequenceAtIndex:71].location] stringByAppendingString:@"…"] : t;
}
#pragma mark - placeholders

// Raycast's syntax: {date} {time} {datetime} with optional format="yyyy-MM-dd" and offset="+2d -3h" (units m h d w M y),
// {clipboard}, {uuid}, {cursor}, {argument name="who" default="you"}. Anything else in braces is left as typed.
// {cursor} is dropped and the caret stays at the end of the paste: moving it would mean posting arrow keys from here,
// outside the one guarded paste path in ui.m.
static NSRegularExpression *phRe(void) {
    static NSRegularExpression *re;
    if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"\\{(date|time|datetime|clipboard|uuid|cursor|argument)((?:\\s+[a-z]+\\s*=\\s*\"[^\"]*\")*)\\s*\\}" options:0 error:nil];
    return re;
}
static NSDictionary<NSString *, NSString *> *phAttrs(NSString *s) {
    static NSRegularExpression *re;
    if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"([a-z]+)\\s*=\\s*\"([^\"]*)\"" options:0 error:nil];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)])
        d[[s substringWithRange:[m rangeAtIndex:1]]] = [s substringWithRange:[m rangeAtIndex:2]];
    return d;
}
// the {argument} names in order of first use, each with its default (or "")
static NSArray<NSArray<NSString *> *> *snipArguments(NSString *body) {
    NSMutableArray *out = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    if ([body rangeOfString:@"{argument"].location == NSNotFound) return out;
    for (NSTextCheckingResult *m in [phRe() matchesInString:body options:0 range:NSMakeRange(0, body.length)]) {
        if (![[body substringWithRange:[m rangeAtIndex:1]] isEqual:@"argument"]) continue;
        NSDictionary *a = phAttrs([body substringWithRange:[m rangeAtIndex:2]]);
        NSString *n = a[@"name"] ?: @"argument";
        if ([seen containsObject:n]) {
            if (a[@"default"]) for (NSUInteger i = 0; i < out.count; i++) if ([out[i][0] isEqual:n] && ![out[i][1] length]) out[i] = @[n, a[@"default"]];
            continue;
        }
        [seen addObject:n]; [out addObject:@[n, a[@"default"] ?: @""]];
    }
    return out;
}
static NSDate *phNow(void) { return getenv("RF_NOW") ? [NSDate dateWithTimeIntervalSince1970:atof(getenv("RF_NOW"))] : [NSDate date]; }
static NSString *phDate(NSString *kind, NSDictionary *a) {
    NSDate *d = phNow();
    NSString *off = a[@"offset"];
    if (off.length) {
        static NSRegularExpression *re;
        if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"([+-]?)\\s*(\\d+)\\s*([mhdwMy])" options:0 error:nil];
        NSInteger mi = 0, h = 0, dd = 0, mo = 0, y = 0;   // NSDateComponents fields start undefined (NSIntegerMax), so add up here
        for (NSTextCheckingResult *m in [re matchesInString:off options:0 range:NSMakeRange(0, off.length)]) {
            NSInteger n = [off substringWithRange:[m rangeAtIndex:2]].integerValue;
            if ([[off substringWithRange:[m rangeAtIndex:1]] isEqual:@"-"]) n = -n;
            switch ([off characterAtIndex:[m rangeAtIndex:3].location]) {
                case 'm': mi += n; break; case 'h': h += n; break; case 'd': dd += n; break;
                case 'w': dd += 7 * n; break; case 'M': mo += n; break; case 'y': y += n; break;
            }
        }
        NSDateComponents *c = [NSDateComponents new];
        c.minute = mi; c.hour = h; c.day = dd; c.month = mo; c.year = y;
        d = [NSCalendar.currentCalendar dateByAddingComponents:c toDate:d options:0] ?: d;
    }
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = a[@"format"] ?: [kind isEqual:@"date"] ? @"yyyy-MM-dd" : [kind isEqual:@"time"] ? @"HH:mm" : @"yyyy-MM-dd HH:mm";
    return [f stringFromDate:d];
}
static NSString *expandSnippet(NSString *body, NSDictionary<NSString *, NSString *> *args) {
    if ([body rangeOfString:@"{"].location == NSNotFound) return body;
    NSMutableString *out = [NSMutableString string]; NSUInteger at = 0; NSString *clip = nil;
    NSMutableDictionary *vals = [NSMutableDictionary dictionary];   // one value per name: a default given anywhere counts
    for (NSArray *a in snipArguments(body)) vals[a[0]] = a[1];
    [vals addEntriesFromDictionary:args ?: @{}]; args = vals;
    for (NSTextCheckingResult *m in [phRe() matchesInString:body options:0 range:NSMakeRange(0, body.length)]) {
        [out appendString:[body substringWithRange:NSMakeRange(at, m.range.location - at)]];
        at = NSMaxRange(m.range);
        NSString *k = [body substringWithRange:[m rangeAtIndex:1]];
        NSDictionary *a = phAttrs([body substringWithRange:[m rangeAtIndex:2]]);
        if ([k isEqual:@"clipboard"]) [out appendString:clip ?: (clip = pbString() ?: @"")];
        else if ([k isEqual:@"uuid"]) [out appendString:NSUUID.UUID.UUIDString];
        else if ([k isEqual:@"argument"]) [out appendString:args[a[@"name"] ?: @"argument"] ?: @""];
        else if (![k isEqual:@"cursor"]) [out appendString:phDate(k, a)];
    }
    [out appendString:[body substringFromIndex:at]];
    return out;
}

// ↩ pastes into the app that had focus, ⌘↩ only copies. From a hotkey the launcher is already hidden, which is fine.
// A snippet with {argument}s first asks for each in a view (↩ moves on; an empty answer takes the default).
static void useSnippet(Snip *s, BOOL copyOnly) {
    NSArray<NSArray<NSString *> *> *want = snipArguments(s->body);
    NSMutableDictionary *got = [NSMutableDictionary dictionary];
    __block void (^ask)(void);
    void (^finish)(void) = ^{
        pbSet(expandSnippet(s->body, got));
        if (copyOnly) uiHide(); else uiHideAndPaste();
    };
    ask = ^{
        if (got.count == want.count) { finish(); dispatch_async(dispatch_get_main_queue(), ^{ ask = nil; }); return; }   // not inside itself
        NSArray<NSString *> *arg = want[got.count];
        View *v = [View new];
        v->title = s->name;
        v->placeholder = arg[1].length ? [NSString stringWithFormat:@"%@ (%@)", arg[0], arg[1]] : arg[0];
        v->hint = want.count > 1 ? [NSString stringWithFormat:@"%lu of %lu", (unsigned long)got.count + 1, (unsigned long)want.count] : nil;
        v->rows = ^NSArray<Cmd *> *(NSString *q) {
            NSString *val = q.length ? q : arg[1];
            Cmd *c = mkCmd(nil, val.length ? val : [NSString stringWithFormat:@"Type a value for “%@”", arg[0]], arg[0], @"¶", ^(BOOL alt) {
                got[arg[0]] = val; ask();
            });
            c->verb = got.count + 1 < want.count ? @"Next" : copyOnly ? @"Copy to Clipboard" : @"Paste Snippet";
            return @[c];
        };
        uiPush(v);
    };
    if (want.count) uiShow();   // from a hotkey the launcher is hidden: open it to ask
    ask();
}
// "Snippets file: 2 problems" (score 1, found by the module's name): a mistake in a file never hides silently.
static void problemsRow(NSString *what, NSArray<NSString *> *ps, NSString *path, NSString *type, const char *lq, NSMutableArray<Cmd *> *out) {
    if (!ps.count || !rfMatch([what stringByAppendingString:@" file problems"], type, lq)) return;
    Cmd *c = mkCmd(nil, [NSString stringWithFormat:@"%@ file: %lu problem%s", what, (unsigned long)ps.count, ps.count == 1 ? "" : "s"], ps[0], @"!", ^(BOOL alt) {
        View *v = [View new]; v->title = [what stringByAppendingString:@" file problems"]; v->placeholder = @"Filter problems";
        v->hint = path.stringByAbbreviatingWithTildeInPath;
        v->rows = ^NSArray<Cmd *> *(NSString *f) {
            NSMutableArray *r = [NSMutableArray array];
            for (NSString *p in ps) if (!f.length || [p localizedCaseInsensitiveContainsString:f]) [r addObject:mkCmd(nil, p, nil, @"!", ^(BOOL a) { uiPop(); })];
            return r;
        };
        uiPush(v);
    });
    c->type = type; c->verb = @"Show Problems"; c->score = 1;
    [out addObject:c];
}
static void commandRows(const char *module, const char *lq, NSMutableArray<Cmd *> *out);
static Cmd *snipRow(Snip *s, int score) {
    Cmd *c = mkCmd([@"snippets." stringByAppendingString:s->name], s->name, firstLine(s->body), @"¶", ^(BOOL alt) { useSnippet(s, alt); });
    c->type = @"Snippet"; c->verb = @"Paste Snippet"; c->altVerb = @"Copy to Clipboard"; c->score = score;
    return c;
}
static void snipSearch(NSString *q, const char *lq, NSMutableArray<Cmd *> *out) {
    if (!*lq) return;
    commandRows("snippets.", lq, out);
    for (Snip *s in snippets()) { int sc = rfMatch(s->name, s->keys, lq); if (sc) [out addObject:snipRow(s, sc)]; }
    problemsRow(@"Snippets", gSnipProblems, snippetsPath(), @"Snippet", lq, out);
}
#pragma mark - commands

@interface Link : NSObject { @public NSString *name, *keys, *target, *app; int line; BOOL isURL; }
@end
@implementation Link
@end
static NSArray<Link *> *parseLinks(NSString *txt, NSMutableArray<NSString *> *problems);
static Link *linkNamed(NSString *name);

// Create / Edit / Search. Their cids use a ':' ("snippets.:create") so they can't clash with a snippet's name.
static NSString *quicklinksPath(void) { return [cfgDir() stringByAppendingPathComponent:@"quicklinks"]; }
static NSString *const kSnipExample =
    @"# Snippets for rayfast. A line \"--- Name | keywords\" starts a snippet; the lines under it are its text.\n"
    @"# Type the name or a keyword in rayfast: ↩ pastes the snippet, ⌘↩ copies it.\n"
    @"# Placeholders: {date} {time} {datetime} {date format=\"d MMM\" offset=\"+1d\"} {clipboard} {uuid}, and\n"
    @"# {argument name=\"who\"} asks for a value first. A text line that starts with \"--- \" is written \"\\--- \".\n"
    @"# For example (remove the \"# \" to use it):\n"
    @"# --- Email signature | sig\n"
    @"# Best regards,\n"
    @"# Your Name\n";
static NSString *const kLinkExample =
    @"# Quicklinks for rayfast, one per line:  Name | keywords = target  (add \" @ App\" to open it in that app)\n"
    @"# The target is a URL or a file or folder (~/Projects). {query} is replaced by the words typed after the name,\n"
    @"# {query|default} when none are typed. Type the name in rayfast, ↩ opens it.\n"
    @"# For example (remove the \"# \" to use them):\n"
    @"# GitHub Search | gh = https://github.com/search?q={query}\n"
    @"# Projects = ~/Projects\n";
// Adds text to the end of a user file, first writing the commented example when the file doesn't exist yet.
static BOOL appendToFile(NSString *path, NSString *example, NSString *text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSMutableString *add = [NSMutableString string];
    if (!d) [add appendString:example];
    else if (d.length && ((const char *)d.bytes)[d.length - 1] != '\n') [add appendString:@"\n"];
    [add appendString:text];
    FILE *f = fopen(path.fileSystemRepresentation, "a");
    if (!f) return NO;
    BOOL ok = fputs(add.UTF8String, f) >= 0;
    return fclose(f) == 0 && ok;
}
// Opens a user file in the default text editor (the files have no extension, so a plain open may find no app).
// RF_DRYRUN=1 logs it to rfDataDir()/snippets-dryrun.log instead.
static void openForEditing(NSString *path, NSString *example) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) appendToFile(path, example, @"");
    uiHide();
    if (getenv("RF_DRYRUN")) {
        FILE *f = fopen([rfDataDir() stringByAppendingPathComponent:@"snippets-dryrun.log"].fileSystemRepresentation, "a");
        if (f) { fprintf(f, "open\t%s\n", path.fileSystemRepresentation); fclose(f); }
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFStringRef bid = LSCopyDefaultRoleHandlerForContentType(CFSTR("public.plain-text"), kLSRolesEditor);
    CFArrayRef apps = bid ? LSCopyApplicationURLsForBundleIdentifier(bid, NULL) : NULL;
#pragma clang diagnostic pop
    NSURL *u = [NSURL fileURLWithPath:path];
    LSLaunchURLSpec spec = {CFArrayGetCount(apps ?: (CFArrayRef)@[]) ? CFArrayGetValueAtIndex(apps, 0) : NULL, (__bridge CFArrayRef)@[u], NULL, 0, NULL};
    if (!spec.appURL || LSOpenFromURLSpec(&spec, NULL)) LSOpenCFURLRef((__bridge CFURLRef)u, NULL);
    if (apps) CFRelease(apps);
    if (bid) CFRelease(bid);
}
// "--- name" + the body, escaped so it reads back byte for byte (bar the trailing blank lines the format drops)
static NSString *snippetText(NSString *name, NSString *body) {
    body = [[body stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(\\\\*---)" options:NSRegularExpressionAnchorsMatchLines error:nil];
    body = [re stringByReplacingMatchesInString:body options:0 range:NSMakeRange(0, body.length) withTemplate:@"\\\\$1"];
    return [NSString stringWithFormat:@"\n--- %@\n%@\n", name, body];
}
// Create Snippet: the body is what's on the clipboard now, the view asks for the name ("Name | keywords" works too).
static void createSnippet(void) {
    NSString *clip = pbString();
    View *v = [View new];
    v->title = @"Create Snippet"; v->placeholder = @"Name for the new snippet";
    v->hint = @"The text comes from the clipboard";
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        Cmd *c;
        NSString *name = trim([q componentsSeparatedByString:@" | "][0]);
        if (![trim(clip ?: @"") length]) c = mkCmd(nil, @"Copy some text first", @"The new snippet's text is taken from the clipboard", @"!", ^(BOOL alt) { uiHide(); });
        else if (!name.length) c = mkCmd(nil, @"Type a name for the snippet", firstLine(clip), @"¶", ^(BOOL alt) {});
        else if (snipNamed(name)) c = mkCmd(nil, [NSString stringWithFormat:@"“%@” already exists", name], @"Pick another name", @"!", ^(BOOL alt) {});
        else {
            c = mkCmd(nil, [NSString stringWithFormat:@"Create “%@”", name], firstLine(clip), @"¶", ^(BOOL alt) {
                appendToFile(snippetsPath(), kSnipExample, snippetText(q, clip));
                uiHide();
            });
            c->verb = @"Create Snippet";
        }
        return @[c];
    };
    uiPush(v);
}
static void searchSnippets(void) {
    View *v = [View new];
    v->title = @"Search Snippets"; v->placeholder = @"Search snippets";
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        NSMutableArray<Cmd *> *r = [NSMutableArray array];
        const char *lq = q.lowercaseString.UTF8String;
        for (Snip *s in snippets()) { int sc = q.length ? rfMatch(s->name, s->keys, lq) : 1; if (sc) [r addObject:snipRow(s, sc)]; }
        [r sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(Cmd *a, Cmd *b) { return a->score > b->score ? NSOrderedAscending : a->score < b->score ? NSOrderedDescending : NSOrderedSame; }];
        if (!r.count) [r addObject:mkCmd(nil, snippets().count ? @"No matching snippet" : @"No snippets yet", @"Create Snippet makes one from the clipboard", @"¶", ^(BOOL alt) { createSnippet(); })];
        return r;
    };
    uiPush(v);
}
// Create Quicklink: the view takes one line in the file's own format; a URL on the clipboard fills in the target.
static void createQuicklink(void) {
    NSString *clip = trim(pbString() ?: @"");
    if ([clip containsString:@"\n"] || ![clip containsString:@"://"]) clip = nil;
    View *v = [View new];
    v->title = @"Create Quicklink"; v->placeholder = clip ? @"Name for the link on the clipboard" : @"Name = https://example.com/search?q={query}";
    v->hint = @"Name | keywords = URL or path, {query} for typed words";
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        NSString *line = [q containsString:@" = "] || !clip ? q : [NSString stringWithFormat:@"%@ = %@", q, clip];
        NSRange eq = [line rangeOfString:@" = "];
        NSMutableArray *problems = [NSMutableArray array];
        Link *k = q.length && eq.location != NSNotFound ? parseLinks(line, problems).firstObject : nil;
        Cmd *c;
        if (!q.length || eq.location == NSNotFound)
            c = mkCmd(nil, @"Type: Name = URL or path", clip ?: @"for example  Docs | d = https://developer.apple.com/search/?q={query}", @"↗", ^(BOOL alt) {});
        else if (!k) c = mkCmd(nil, [problems.firstObject ?: @"" stringByReplacingOccurrencesOfString:@"line 1: " withString:@""], @"Type: Name = URL or path", @"!", ^(BOOL alt) {});
        else if (linkNamed(k->name)) c = mkCmd(nil, [NSString stringWithFormat:@"“%@” already exists", k->name], @"Pick another name", @"!", ^(BOOL alt) {});
        else {
            c = mkCmd(nil, [NSString stringWithFormat:@"Create “%@”", k->name], k->app ? [NSString stringWithFormat:@"%@ in %@", k->target, k->app] : k->target, @"↗", ^(BOOL alt) {
                appendToFile(quicklinksPath(), kLinkExample, [line stringByAppendingString:@"\n"]);
                uiHide();
            });
            c->verb = @"Create Quicklink";
        }
        return @[c];
    };
    uiPush(v);
}
typedef struct { NSString *cid, *title, *keys, *glyph; void (*fn)(void); } SnipCommand;
static void editSnippets(void) { openForEditing(snippetsPath(), kSnipExample); }
static void editQuicklinks(void) { openForEditing(quicklinksPath(), kLinkExample); }
static const SnipCommand *snipCommands(int *n) {
    static SnipCommand cs[5];
    if (!cs[0].cid) {
        cs[0] = (SnipCommand){@"snippets.:create", @"Create Snippet", @"new add snippet clipboard", @"¶", createSnippet};
        cs[1] = (SnipCommand){@"snippets.:search", @"Search Snippets", @"snippet list", @"¶", searchSnippets};
        cs[2] = (SnipCommand){@"snippets.:edit", @"Edit Snippets", @"snippet file open", @"¶", editSnippets};
        cs[3] = (SnipCommand){@"quicklinks.:create", @"Create Quicklink", @"new add quicklink link bookmark", @"↗", createQuicklink};
        cs[4] = (SnipCommand){@"quicklinks.:edit", @"Edit Quicklinks", @"quicklink link file open", @"↗", editQuicklinks};
    }
    *n = 5; return cs;
}
static void commandRows(const char *module, const char *lq, NSMutableArray<Cmd *> *out) {
    int n; const SnipCommand *cs = snipCommands(&n);
    for (int i = 0; i < n; i++) {
        if (![cs[i].cid hasPrefix:@(module)]) continue;
        int sc = rfMatch(cs[i].title, cs[i].keys, lq);
        if (!sc) continue;
        void (*fn)(void) = cs[i].fn;
        Cmd *c = mkCmd(cs[i].cid, cs[i].title, nil, cs[i].glyph, ^(BOOL alt) { fn(); });
        c->score = sc; c->verb = @"Open Command";
        [out addObject:c];
    }
}
static BOOL commandRun(NSString *cid) {
    int n; const SnipCommand *cs = snipCommands(&n);
    for (int i = 0; i < n; i++) if ([cs[i].cid isEqual:cid]) {
        if (cs[i].fn != editSnippets && cs[i].fn != editQuicklinks) uiShow();   // from a hotkey: these need the launcher's view
        cs[i].fn();
        return YES;
    }
    return NO;
}

static BOOL snipRun(NSString *cid) {
    if (commandRun(cid)) return YES;
    Snip *s = [cid hasPrefix:@"snippets."] ? snipNamed([cid substringFromIndex:9]) : nil;
    if (!s) return NO;
    useSnippet(s, NO);
    return YES;
}

#pragma mark - import

// Raycast's "Export Snippets" / "Export Quicklinks" JSON: an array of objects (or an object holding one).
// The field names are from Raycast's docs as remembered, not checked against a real export, so a few spellings are taken.
static NSArray<NSDictionary *> *raycastItems(const char *path) {
    NSData *d = [NSData dataWithContentsOfFile:@(path)];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([j isKindOfClass:NSDictionary.class]) for (id v in [j allValues]) if ([v isKindOfClass:NSArray.class]) { j = v; break; }
    if (![j isKindOfClass:NSArray.class]) { fprintf(stderr, "%s: not a Raycast export (a JSON array)\n", path); return nil; }
    NSMutableArray *out = [NSMutableArray array];
    for (id o in j) if ([o isKindOfClass:NSDictionary.class]) [out addObject:o];
    return out;
}
static NSString *field(NSDictionary *o, NSArray<NSString *> *keys) {
    for (NSString *k in keys) if ([o[k] isKindOfClass:NSString.class] && [o[k] length]) return o[k];
    return nil;
}
static NSString *oneLine(NSString *s) {
    return trim([[s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "]);
}
// Appends what isn't there yet (names compare case-insensitively); prints one line per skip, then a count.
static int importSnippets(const char *path) {
    NSArray *items = raycastItems(path);
    if (!items) return 1;
    NSMutableSet *have = [NSMutableSet set];
    for (Snip *s in snippets()) [have addObject:s->name.lowercaseString];
    NSMutableString *add = [NSMutableString string]; int n = 0, skipped = 0;
    for (NSDictionary *o in items) {
        NSString *name = oneLine(field(o, @[@"name", @"title"]) ?: @""), *text = field(o, @[@"text", @"content", @"snippet"]);
        NSString *key = oneLine(field(o, @[@"keyword", @"keywords"]) ?: @""), *why = nil;
        if (!name.length || !text.length) why = @"no name or no text";
        else if ([name containsString:@" | "]) why = @"\" | \" in the name";
        else if ([have containsObject:name.lowercaseString]) why = @"already there";
        if (why) { printf("skipped \"%s\": %s\n", name.UTF8String, why.UTF8String); skipped++; continue; }
        [have addObject:name.lowercaseString];
        [add appendString:snippetText(key.length ? [NSString stringWithFormat:@"%@ | %@", name, key] : name, text)];
        n++;
    }
    if (n && !appendToFile(snippetsPath(), kSnipExample, add)) { fprintf(stderr, "can't write %s\n", snippetsPath().fileSystemRepresentation); return 1; }
    printf("imported %d snippet%s into %s, skipped %d\n", n, n == 1 ? "" : "s", snippetsPath().fileSystemRepresentation, skipped);
    return 0;
}

static int snipCli(int argc, const char **argv) {
    if (argc > 1 && !strcmp(argv[0], "import")) return importSnippets(argv[1]);
    NSString *cmd = argc > 0 ? @(argv[0]) : @"";
    if ([cmd isEqual:@"parse"] && argc > 1) {   // name<TAB>keywords<TAB>UTF-8 bytes of the body, then the problems
        NSMutableArray *problems = [NSMutableArray array];
        NSArray<Snip *> *ss = parseSnippetsFile(@(argv[1]), problems);
        for (Snip *s in ss) printf("%s\t%s\t%lu\n", s->name.UTF8String, s->keys.UTF8String, (unsigned long)strlen(s->body.UTF8String));
        for (NSString *p in problems) printf("problem: %s\n", p.UTF8String);
        return 0;
    }
    if ([cmd isEqual:@"body"] && argc > 2) {    // the body of one snippet, byte for byte
        for (Snip *s in parseSnippetsFile(@(argv[1]), nil)) if ([s->name isEqual:@(argv[2])]) { fputs(s->body.UTF8String, stdout); return 0; }
        return 1;
    }
    if ([cmd isEqual:@"rows"] && argc > 1) {    // root rows for a query from cfgDir(): title<TAB>type<TAB>subtitle<TAB>score
        NSMutableArray<Cmd *> *out = [NSMutableArray array];
        NSString *q = trim(@(argv[1]));
        snipSearch(q, q.lowercaseString.UTF8String, out);
        for (Cmd *c in out) printf("%s\t%s\t%s\t%d\n", c->title.UTF8String, c->type.UTF8String, (c->sub ?: @"").UTF8String, c->score);
        return 0;
    }
    if ([cmd isEqual:@"run"] && argc > 1) {     // what a hotkey bound to cmd:<cid> puts on the pasteboard (never pastes here)
        NSString *cid = @(argv[1]);
        Snip *s = [cid hasPrefix:@"snippets."] ? snipNamed([cid substringFromIndex:9]) : nil;
        if (!s) { fprintf(stderr, "no snippet for %s\n", argv[1]); return 1; }
        pbSet(expandSnippet(s->body, @{}));
        return 0;
    }
    if ([cmd isEqual:@"expand"] && argc > 1) {  // expand <text> [name=value…]: placeholders as a paste would fill them
        NSMutableDictionary *args = [NSMutableDictionary dictionary];
        for (int i = 2; i < argc; i++) { NSString *kv = @(argv[i]); NSRange eq = [kv rangeOfString:@"="]; if (eq.location != NSNotFound) args[[kv substringToIndex:eq.location]] = [kv substringFromIndex:NSMaxRange(eq)]; }
        fputs(expandSnippet(@(argv[1]), args).UTF8String, stdout);
        return 0;
    }
    if ([cmd isEqual:@"pb-get"]) { NSString *s = pbString(); if (!s) return 1; fputs(s.UTF8String, stdout); return 0; }
    if ([cmd isEqual:@"pb-set"] && argc > 1) { pbSet(@(argv[1])); return 0; }
    fprintf(stderr, "usage: rayfast --run snippets import <raycast.json> | parse <file> | body <file> <name> | rows <query> | run <cid> | expand <text> [name=value…] | pb-get | pb-set <text>\n");
    return 2;
}

#pragma mark - quicklinks

// cfgDir()/quicklinks, one link per line like the config: "Name | keywords = target", optionally " @ App" at the end.
// The target is a URL (any "scheme:") or a path ("~/…" or "/…"). {query} takes the words typed after the name
// (percent-encoded into a URL, raw into a path), {query|default} when none are typed. Blank lines and "# comments"
// are ignored; a line that doesn't read gives a "line N: …" problem and the rest still load.

static NSRegularExpression *queryRe(void) {
    static NSRegularExpression *re;
    if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"\\{query(?:\\|([^}]*))?\\}" options:0 error:nil];
    return re;
}
static NSArray<Link *> *parseLinks(NSString *txt, NSMutableArray<NSString *> *problems) {
    NSMutableArray<Link *> *out = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    if ([txt hasPrefix:@"﻿"]) txt = [txt substringFromIndex:1];
    txt = [[txt stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    static NSRegularExpression *scheme;
    if (!scheme) scheme = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z][A-Za-z0-9+.-]*:" options:0 error:nil];
    int line = 0;
    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        line++;
        NSString *l = trim(raw);
        if (!l.length || [l hasPrefix:@"#"]) continue;
        #define SKIP(...) { [problems addObject:[NSString stringWithFormat:@"line %d: " __VA_ARGS__]]; continue; }
        l = [NSString stringWithFormat:@" %@ ", l];   // so "= url" and "name =" still split
        NSRange eq = [l rangeOfString:@" = "];
        if (eq.location == NSNotFound) SKIP(@"needs \"Name = URL or path\", skipped", line)
        NSString *h = [l substringToIndex:eq.location], *t = trim([l substringFromIndex:NSMaxRange(eq)]), *app = nil;
        NSRange bar = [h rangeOfString:@" | "];
        NSString *name = trim(bar.location == NSNotFound ? h : [h substringToIndex:bar.location]);
        NSString *keys = bar.location == NSNotFound ? @"" : trim([h substringFromIndex:NSMaxRange(bar)]);
        if ([name hasSuffix:@" |"]) name = trim([name substringToIndex:name.length - 1]);
        NSRange at = [t rangeOfString:@" @ " options:NSBackwardsSearch];
        if (at.location != NSNotFound) { app = trim([t substringFromIndex:NSMaxRange(at)]); t = trim([t substringToIndex:at.location]); }
        else if ([t hasSuffix:@" @"]) SKIP(@"\"%@\": no app after \"@\", skipped", line, name)
        if (!name.length) SKIP(@"a quicklink needs a name before \" = \", skipped", line)
        if (!t.length) SKIP(@"\"%@\" has no URL or path, skipped", line, name)
        BOOL url = [scheme firstMatchInString:t options:0 range:NSMakeRange(0, t.length)] != nil;
        if (!url && ![t hasPrefix:@"/"] && ![t hasPrefix:@"~"]) SKIP(@"\"%@\": \"%@\" is not a URL (https://…) or a path (~/… or /…), skipped", line, name, t)
        if ([seen containsObject:name.lowercaseString]) SKIP(@"\"%@\" is already used above, skipped", line, name)
        #undef SKIP
        [seen addObject:name.lowercaseString];
        Link *k = [Link new]; k->name = name; k->keys = keys; k->target = t; k->app = app; k->line = line; k->isURL = url;
        [out addObject:k];
    }
    return out;
}
static NSArray<Link *> *parseLinksFile(NSString *path, NSMutableArray<NSString *> *problems) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return @[];
    NSString *txt = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!txt) { [problems addObject:@"the file is not UTF-8 text, nothing loaded"]; return @[]; }
    return parseLinks(txt, problems);
}
static BOOL linkNeedsQuery(Link *k) {   // has a {query} with no default
    for (NSTextCheckingResult *m in [queryRe() matchesInString:k->target options:0 range:NSMakeRange(0, k->target.length)])
        if ([m rangeAtIndex:1].location == NSNotFound) return YES;
    return NO;
}
// The target with {query} filled in: percent-encoded for a URL, raw for a path (then ~ expanded).
static NSURL *linkURL(Link *k, NSString *query) {
    static NSCharacterSet *unreserved;
    if (!unreserved) unreserved = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *t = k->target; NSMutableString *s = [NSMutableString string]; NSUInteger at = 0;
    for (NSTextCheckingResult *m in [queryRe() matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        [s appendString:[t substringWithRange:NSMakeRange(at, m.range.location - at)]];
        at = NSMaxRange(m.range);
        NSString *v = query.length ? query : [m rangeAtIndex:1].location != NSNotFound ? [t substringWithRange:[m rangeAtIndex:1]] : @"";
        [s appendString:k->isURL ? [v stringByAddingPercentEncodingWithAllowedCharacters:unreserved] : v];
    }
    [s appendString:[t substringFromIndex:at]];
    if (!k->isURL) return [NSURL fileURLWithPath:s.stringByExpandingTildeInPath];
    NSURL *u = [NSURL URLWithString:s];
    if (!u) {   // a hand-typed URL with spaces or non-ASCII in it: encode just those
        NSMutableCharacterSet *ok = NSCharacterSet.URLFragmentAllowedCharacterSet.mutableCopy;
        [ok addCharactersInString:@"#%"];
        u = [NSURL URLWithString:[s stringByAddingPercentEncodingWithAllowedCharacters:ok]];
    }
    return u;
}
// " @ App": a path to an .app, or a name found in the usual folders. nil when it isn't installed.
static NSString *linkApp(Link *k) {
    if (!k->app) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *a = [k->app hasSuffix:@".app"] ? k->app : [k->app stringByAppendingString:@".app"];
    if ([a containsString:@"/"]) { a = a.stringByExpandingTildeInPath; return [fm fileExistsAtPath:a] ? a : nil; }
    for (NSString *d in @[@"/Applications", @"/System/Applications", @"/Applications/Utilities", @"/System/Applications/Utilities", @"~/Applications", @"/System/Library/CoreServices/Applications"]) {
        NSString *p = [d.stringByExpandingTildeInPath stringByAppendingPathComponent:a];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}
// Opens through LaunchServices, like rfOpenApp. RF_DRYRUN=1 logs "link<TAB>url<TAB>app path" to
// rfDataDir()/snippets-dryrun.log instead; nothing opens.
static void openLink(Link *k, NSString *query) {
    NSURL *u = linkURL(k, query); NSString *app = linkApp(k);
    uiHide();
    if (!u) return;
    if (getenv("RF_DRYRUN")) {
        FILE *f = fopen([rfDataDir() stringByAppendingPathComponent:@"snippets-dryrun.log"].fileSystemRepresentation, "a");
        if (f) { fprintf(f, "link\t%s\t%s\n", u.absoluteString.UTF8String, (app ?: k->app ? @"?" : @"").UTF8String); fclose(f); }
        return;
    }
    if (app) {
        LSLaunchURLSpec spec = {(__bridge CFURLRef)[NSURL fileURLWithPath:app], (__bridge CFArrayRef)@[u], NULL, 0, NULL};
        if (!LSOpenFromURLSpec(&spec, NULL)) return;
    }
    LSOpenCFURLRef((__bridge CFURLRef)u, NULL);
}
// ↩ on a link: a {query} with no default and nothing typed asks for it first.
static void useLink(Link *k, NSString *query) {
    if (query.length || !linkNeedsQuery(k)) { openLink(k, query); return; }
    View *v = [View new];
    v->title = k->name; v->placeholder = @"Search for…"; v->hint = k->target;
    v->rows = ^NSArray<Cmd *> *(NSString *q) {
        Cmd *c = mkCmd(nil, q.length ? q : [NSString stringWithFormat:@"Type what to open “%@” with", k->name], q.length ? linkURL(k, q).absoluteString : k->target, @"↗", ^(BOOL alt) {
            if (q.length) openLink(k, q);
        });
        c->verb = @"Open Quicklink"; c->type = @"Quicklink";
        return @[c];
    };
    uiPush(v);
}

static NSArray<Link *> *gLinks; static NSArray<NSString *> *gLinkProblems;
static struct timespec gLinkMt; static off_t gLinkSize = -1;
static NSArray<Link *> *quicklinks(void) {   // re-read only when the file's mtime or size changes, like snippets()
    struct stat st; NSString *p = quicklinksPath();
    if (stat(p.fileSystemRepresentation, &st)) { gLinks = @[]; gLinkProblems = @[]; gLinkSize = -1; return gLinks; }
    if (gLinks && st.st_size == gLinkSize && st.st_mtimespec.tv_sec == gLinkMt.tv_sec && st.st_mtimespec.tv_nsec == gLinkMt.tv_nsec) return gLinks;
    if (getenv("RF_HEADLESS")) fprintf(stderr, "quicklinks: read %s\n", p.fileSystemRepresentation);
    NSMutableArray *problems = [NSMutableArray array];
    gLinks = parseLinksFile(p, problems); gLinkProblems = problems;
    gLinkMt = st.st_mtimespec; gLinkSize = st.st_size;
    return gLinks;
}
static Link *linkNamed(NSString *name) {
    for (Link *k in quicklinks()) if ([k->name caseInsensitiveCompare:name] == NSOrderedSame) return k;
    return nil;
}
static Cmd *linkRow(Link *k, NSString *query, int score) {
    NSString *sub = query.length || !linkNeedsQuery(k) ? (k->isURL ? linkURL(k, query).absoluteString : [linkURL(k, query).path stringByAbbreviatingWithTildeInPath]) : k->target;
    if (k->app) sub = [NSString stringWithFormat:@"%@ in %@", sub, k->app.lastPathComponent.stringByDeletingPathExtension];
    Cmd *c = mkCmd([@"quicklinks." stringByAppendingString:k->name], k->name, sub, @"↗", ^(BOOL alt) { useLink(k, query); });
    c->type = @"Quicklink"; c->verb = @"Open Quicklink"; c->score = score;
    return c;
}
// "gh rayfast": a link whose name or a keyword is the start of the query, followed by a space, gets the rest as its
// {query}. Otherwise links match by name and keywords like everything else.
static void linkSearch(NSString *q, const char *lq, NSMutableArray<Cmd *> *out) {
    if (!*lq) return;
    commandRows("quicklinks.", lq, out);
    NSString *lower = q.lowercaseString;
    for (Link *k in quicklinks()) {
        NSString *rest = nil; int sc = 0;
        if ([k->target rangeOfString:@"{query"].location != NSNotFound) {
            NSMutableArray *heads = [NSMutableArray arrayWithObject:k->name.lowercaseString];
            for (NSString *w in [k->keys.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) if (w.length) [heads addObject:w];
            for (NSString *h in heads) if (lower.length > h.length + 1 && [lower hasPrefix:h] && [lower characterAtIndex:h.length] == ' ') {
                rest = trim([q substringFromIndex:h.length]); sc = MAX(rfMatch(k->name, k->keys, h.UTF8String), 200) + 1; break;
            }
        }
        if (!rest) sc = rfMatch(k->name, k->keys, lq);
        if (sc) [out addObject:linkRow(k, rest, sc)];
    }
    problemsRow(@"Quicklinks", gLinkProblems, quicklinksPath(), @"Quicklink", lq, out);
}
static BOOL linkRun(NSString *cid) {
    if (commandRun(cid)) return YES;
    Link *k = [cid hasPrefix:@"quicklinks."] ? linkNamed([cid substringFromIndex:11]) : nil;
    if (!k) return NO;
    if (linkNeedsQuery(k)) uiShow();   // from a hotkey: open the launcher to ask
    useLink(k, nil);
    return YES;
}
// Raycast links carry {argument name="…" default="…"} (or the older {query}/{Query}): every one becomes our {query},
// keeping a default. openWith is an app name, a path or a bundle id (resolved to a path here, once).
static int importLinks(const char *path) {
    NSArray *items = raycastItems(path);
    if (!items) return 1;
    NSRegularExpression *arg = [NSRegularExpression regularExpressionWithPattern:@"\\{(?:argument((?:\\s+[a-z]+\\s*=\\s*\"[^\"]*\")*)\\s*|[Qq]uery)\\}" options:0 error:nil];
    NSMutableSet *have = [NSMutableSet set];
    for (Link *k in quicklinks()) [have addObject:k->name.lowercaseString];
    NSMutableString *add = [NSMutableString string]; int n = 0, skipped = 0;
    for (NSDictionary *o in items) {
        NSString *name = oneLine(field(o, @[@"name", @"title"]) ?: @""), *link = oneLine(field(o, @[@"link", @"url"]) ?: @"");
        NSString *app = oneLine(field(o, @[@"openWith", @"application", @"app"]) ?: @"");
        NSMutableString *t = [NSMutableString string]; NSUInteger at = 0;
        for (NSTextCheckingResult *m in [arg matchesInString:link options:0 range:NSMakeRange(0, link.length)]) {
            [t appendString:[link substringWithRange:NSMakeRange(at, m.range.location - at)]];
            at = NSMaxRange(m.range);
            NSString *def = [m rangeAtIndex:1].location == NSNotFound ? nil : phAttrs([link substringWithRange:[m rangeAtIndex:1]])[@"default"];
            [t appendString:def.length ? [NSString stringWithFormat:@"{query|%@}", def] : @"{query}"];
        }
        [t appendString:[link substringFromIndex:at]];
        if ([app containsString:@"."] && ![app containsString:@"/"] && ![app containsString:@" "] && ![app hasSuffix:@".app"])   // a bundle id
            app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:app].path ?: @"";
        NSString *h = [name containsString:@" = "] || [name containsString:@" | "] ? nil : name;
        NSString *line = [NSString stringWithFormat:@"%@ = %@%@", h ?: @"", t, app.length ? [@" @ " stringByAppendingString:app] : @""];
        NSMutableArray *problems = [NSMutableArray array];
        NSString *why = !name.length || !link.length ? @"no name or no link" : !h ? @"\" = \" or \" | \" in the name"
                      : [have containsObject:name.lowercaseString] ? @"already there"
                      : !parseLinks(line, problems).count ? [[problems.firstObject stringByReplacingOccurrencesOfString:@"line 1: " withString:@""] stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"\"%@\": ", name] withString:@""] : nil;
        if (why) { printf("skipped \"%s\": %s\n", name.UTF8String, why.UTF8String); skipped++; continue; }
        [have addObject:name.lowercaseString];
        [add appendFormat:@"%@\n", line];
        n++;
    }
    if (n && !appendToFile(quicklinksPath(), kLinkExample, add)) { fprintf(stderr, "can't write %s\n", quicklinksPath().fileSystemRepresentation); return 1; }
    printf("imported %d quicklink%s into %s, skipped %d\n", n, n == 1 ? "" : "s", quicklinksPath().fileSystemRepresentation, skipped);
    return 0;
}
static int linkCli(int argc, const char **argv) {
    if (argc > 1 && !strcmp(argv[0], "import")) return importLinks(argv[1]);
    NSString *cmd = argc > 0 ? @(argv[0]) : @"";
    if ([cmd isEqual:@"parse"] && argc > 1) {   // name<TAB>keywords<TAB>target<TAB>app, then the problems
        NSMutableArray *problems = [NSMutableArray array];
        for (Link *k in parseLinksFile(@(argv[1]), problems)) printf("%s\t%s\t%s\t%s\n", k->name.UTF8String, k->keys.UTF8String, k->target.UTF8String, (k->app ?: @"").UTF8String);
        for (NSString *p in problems) printf("problem: %s\n", p.UTF8String);
        return 0;
    }
    if ([cmd isEqual:@"url"] && argc > 2) {     // url <file> <name> [query]: what ↩ would open (and with which app); opens nothing
        for (Link *k in parseLinksFile(@(argv[1]), nil)) if ([k->name isEqual:@(argv[2])]) {
            NSURL *u = linkURL(k, argc > 3 ? @(argv[3]) : nil);
            printf("%s\t%s\n", u.absoluteString.UTF8String ?: "(bad url)", (linkApp(k) ?: k->app ? @"?" : @"").UTF8String);
            return 0;
        }
        return 1;
    }
    if ([cmd isEqual:@"rows"] && argc > 1) {    // root rows from cfgDir(): title<TAB>type<TAB>subtitle<TAB>score
        NSMutableArray<Cmd *> *out = [NSMutableArray array];
        NSString *q = trim(@(argv[1]));
        linkSearch(q, q.lowercaseString.UTF8String, out);
        for (Cmd *c in out) printf("%s\t%s\t%s\t%d\n", c->title.UTF8String, (c->type ?: @"").UTF8String, (c->sub ?: @"").UTF8String, c->score);
        return 0;
    }
    fprintf(stderr, "usage: rayfast --run quicklinks import <raycast.json> | parse <file> | url <file> <name> [query] | rows <query>\n");
    return 2;
}

static const RFModule snippetsModule = {"snippets", NULL, snipSearch, snipRun, snipCli};
static const RFModule quicklinksModule = {"quicklinks", NULL, linkSearch, linkRun, linkCli};
// two modules from one file (RF_MODULE defines one constructor per file)
__attribute__((constructor)) static void snipInit(void) { rfAddModule(&snippetsModule); rfAddModule(&quicklinksModule); }
