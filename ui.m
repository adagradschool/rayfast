// rayfast UI: the launcher window, app search, and the conversion engine. Config/hotkeys live in core.m.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#include "rf.h"
#include <malloc/malloc.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <mach/mach_time.h>
#include <fcntl.h>
#include <math.h>
#include <ctype.h>

#pragma mark - paths

static NSString *usagePath(void) { return [cfgDir() stringByAppendingPathComponent:@"usage"]; }
static NSString *ratesPath(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/rayfast-rates.json"]; }

#pragma mark - number formatting
static NSString *fmtNumSig(double v, int maxFrac, int sig, BOOL group);

// Formats v with up to maxFrac decimals (more for tiny values), optional thousands grouping.
static NSString *fmtNum(double v, int maxFrac, BOOL group) { return fmtNumSig(v, maxFrac, 0, group); }
static NSString *fmtNumSig(double v, int maxFrac, int sig, BOOL group) {
    if (isnan(v) || isinf(v)) return nil;
    double a = fabs(v);
    if (a != 0 && (a >= 1e15 || a < 1e-9)) return [NSString stringWithFormat:@"%.6g", v];
    int dec = maxFrac;
    if (a != 0 && a < 1) { int need = (int)-floor(log10(a)) + 3; if (need > dec) dec = need; }
    if (sig && a >= 1) { int intDigits = (int)floor(log10(a)) + 1; if (sig - intDigits < dec) dec = sig - intDigits > 0 ? sig - intDigits : 0; }
    if (dec > 12) dec = 12;
    char buf[64], out[96];
    snprintf(buf, sizeof buf, "%.*f", dec, v);
    char *dot = strchr(buf, '.');
    if (dot && !(maxFrac == 2 && a >= 1)) { char *e = buf + strlen(buf) - 1; while (e > dot && *e == '0') *e-- = 0; if (e == dot) *e = 0; }
    if (!strcmp(buf, "-0")) strcpy(buf, "0");
    if (!group) return @(buf);
    char *s = buf, *o = out;
    if (*s == '-') *o++ = *s++;
    size_t intLen = strcspn(s, ".");
    for (size_t i = 0; i < intLen; i++) { if (i && (intLen - i) % 3 == 0) *o++ = ','; *o++ = s[i]; }
    strcpy(o, s + intLen);
    return @(out);
}

#pragma mark - math expression evaluator

typedef struct { const char *s; int err; } P;
static double pExpr(P *p);
static void pWs(P *p) { while (*p->s == ' ') p->s++; }
static double pUnary(P *p);
static double pPrimary(P *p) {
    pWs(p);
    char c = *p->s;
    if (c == '(') { p->s++; double v = pExpr(p); pWs(p); if (*p->s == ')') p->s++; else p->err = 1; return v; }
    if (isdigit((unsigned char)c) || c == '.') { char *e; double v = strtod(p->s, &e); if (e == p->s) p->err = 1; p->s = e; return v; }
    if (isalpha((unsigned char)c)) {
        char id[16]; int n = 0;
        while (isalpha((unsigned char)*p->s) && n < 15) id[n++] = *p->s++;
        id[n] = 0;
        if (!strcmp(id, "pi")) return M_PI;
        if (!strcmp(id, "e")) return M_E;
        if (!strcmp(id, "tau")) return 2 * M_PI;
        static const struct { const char *n; double (*f)(double); } fns[] = {
            {"sqrt", sqrt}, {"sin", sin}, {"cos", cos}, {"tan", tan}, {"asin", asin}, {"acos", acos}, {"atan", atan},
            {"ln", log}, {"log", log10}, {"log2", log2}, {"exp", exp}, {"abs", fabs}, {"floor", floor}, {"ceil", ceil},
            {"round", round}, {"cbrt", cbrt}};
        for (size_t i = 0; i < sizeof fns / sizeof *fns; i++)
            if (!strcmp(id, fns[i].n)) return fns[i].f(pUnary(p));
        p->err = 1; return 0;
    }
    p->err = 1; return 0;
}
static double pPostfix(P *p) {
    double v = pPrimary(p);
    for (;;) {
        pWs(p);
        if (*p->s == '!') { p->s++; v = tgamma(v + 1); continue; }
        if (*p->s == '%') {
            p->s++; const char *save = p->s; pWs(p);
            if (!strncmp(p->s, "of ", 3) || !strncmp(p->s, "of(", 3)) { p->s += 2; return v / 100 * pUnary(p); }
            p->s = save; v /= 100; continue;
        }
        return v;
    }
}
static double pPower(P *p) {
    double b = pPostfix(p); pWs(p);
    if (*p->s == '^') { p->s++; return pow(b, pUnary(p)); }
    if (p->s[0] == '*' && p->s[1] == '*') { p->s += 2; return pow(b, pUnary(p)); }
    return b;
}
static double pUnary(P *p) {
    pWs(p);
    if (*p->s == '-') { p->s++; return -pUnary(p); }
    if (*p->s == '+') { p->s++; return pUnary(p); }
    return pPower(p);
}
static double pTerm(P *p) {
    double v = pUnary(p);
    for (;;) {
        pWs(p);
        if (*p->s == '*' && p->s[1] != '*') { p->s++; v *= pUnary(p); }
        else if (*p->s == '/') { p->s++; v /= pUnary(p); }
        else if (*p->s == '(') { v *= pUnary(p); }            // 2(3+4)
        else return v;
    }
}
static double pExpr(P *p) {
    double v = pTerm(p);
    for (;;) {
        pWs(p);
        if (*p->s == '+') { p->s++; v += pTerm(p); }
        else if (*p->s == '-') { p->s++; v -= pTerm(p); }
        else return v;
    }
}
// Evaluates a whole string (commas stripped). Returns NO unless fully consumed.
static BOOL evalExpr(const char *src, double *out) {
    char buf[256]; size_t n = 0;
    for (const char *s = src; *s && n < sizeof buf - 1; s++) if (*s != ',' && *s != '_') buf[n++] = *s;
    buf[n] = 0;
    while (n && buf[n - 1] == ' ') buf[--n] = 0;
    if (!n) return NO;
    P p = {buf, 0};
    double v = pExpr(&p); pWs(&p);
    if (p.err || *p.s || isnan(v)) return NO;
    *out = v; return YES;
}

#pragma mark - units

enum { D_LEN = 1, D_MASS, D_TEMP, D_VOL, D_AREA, D_DATA, D_TIME, D_SPEED, D_ANGLE, D_PRESS, D_ENERGY };
typedef struct { const char *names, *disp, *def; int dim; double f, off; } Unit;
static const Unit UNITS[] = {
    {"mm|millimeter|millimeters|millimetre|millimetres", "mm", "in", D_LEN, 1e-3, 0},
    {"cm|centimeter|centimeters|centimetre|centimetres", "cm", "in", D_LEN, 1e-2, 0},
    {"m|meter|meters|metre|metres", "m", "ft", D_LEN, 1, 0},
    {"km|kms|kilometer|kilometers|kilometre|kilometres", "km", "mi", D_LEN, 1e3, 0},
    {"um|µm|micron|microns|micrometer|micrometers", "µm", "mm", D_LEN, 1e-6, 0},
    {"nm|nanometer|nanometers", "nm", "µm", D_LEN, 1e-9, 0},
    {"in|inch|inches|\"", "in", "cm", D_LEN, 0.0254, 0},
    {"ft|foot|feet|'", "ft", "m", D_LEN, 0.3048, 0},
    {"yd|yard|yards", "yd", "m", D_LEN, 0.9144, 0},
    {"mi|mile|miles", "mi", "km", D_LEN, 1609.344, 0},
    {"nmi|nautical mile|nautical miles", "nmi", "km", D_LEN, 1852, 0},
    {"ly|light year|light years|lightyear|lightyears", "ly", "km", D_LEN, 9.4607304725808e15, 0},
    {"mg|milligram|milligrams", "mg", "g", D_MASS, 1e-6, 0},
    {"g|gram|grams|gm|gms", "g", "oz", D_MASS, 1e-3, 0},
    {"kg|kgs|kilo|kilos|kilogram|kilograms", "kg", "lb", D_MASS, 1, 0},
    {"t|tonne|tonnes|metric ton|metric tons", "t", "lb", D_MASS, 1e3, 0},
    {"oz|ounce|ounces", "oz", "g", D_MASS, 0.028349523125, 0},
    {"lb|lbs|pound|pounds", "lb", "kg", D_MASS, 0.45359237, 0},
    {"st|stone|stones", "st", "kg", D_MASS, 6.35029318, 0},
    {"ton|tons|short ton|short tons", "ton", "t", D_MASS, 907.18474, 0},
    {"c|°c|celsius|degc|deg c", "°C", "°F", D_TEMP, 1, 273.15},
    {"f|°f|fahrenheit|degf|deg f", "°F", "°C", D_TEMP, 5.0 / 9, 459.67 * 5 / 9},
    {"k|kelvin", "K", "°C", D_TEMP, 1, 0},
    {"ml|milliliter|milliliters|millilitre|millilitres", "ml", "fl oz", D_VOL, 1e-3, 0},
    {"cl|centiliter|centiliters", "cl", "ml", D_VOL, 1e-2, 0},
    {"dl|deciliter|deciliters", "dl", "ml", D_VOL, 1e-1, 0},
    {"l|liter|liters|litre|litres", "l", "gal", D_VOL, 1, 0},
    {"m3|cubic meter|cubic meters|cubic metre", "m³", "l", D_VOL, 1e3, 0},
    {"gal|gallon|gallons", "gal", "l", D_VOL, 3.785411784, 0},
    {"qt|quart|quarts", "qt", "l", D_VOL, 0.946352946, 0},
    {"pt|pint|pints", "pt", "ml", D_VOL, 0.473176473, 0},
    {"cup|cups", "cup", "ml", D_VOL, 0.2365882365, 0},
    {"floz|fl oz|fluid ounce|fluid ounces", "fl oz", "ml", D_VOL, 0.0295735295625, 0},
    {"tbsp|tablespoon|tablespoons", "tbsp", "ml", D_VOL, 0.01478676478125, 0},
    {"tsp|teaspoon|teaspoons", "tsp", "ml", D_VOL, 0.00492892159375, 0},
    {"m2|sqm|sq m|square meter|square meters|square metre|square metres", "m²", "ft²", D_AREA, 1, 0},
    {"km2|sq km|square kilometer|square kilometers", "km²", "mi²", D_AREA, 1e6, 0},
    {"cm2|sq cm|square centimeter|square centimeters", "cm²", "in²", D_AREA, 1e-4, 0},
    {"ft2|sqft|sq ft|square foot|square feet", "ft²", "m²", D_AREA, 0.09290304, 0},
    {"in2|sq in|square inch|square inches", "in²", "cm²", D_AREA, 0.00064516, 0},
    {"yd2|sq yd|square yard|square yards", "yd²", "m²", D_AREA, 0.83612736, 0},
    {"mi2|sq mi|square mile|square miles", "mi²", "km²", D_AREA, 2589988.110336, 0},
    {"ac|acre|acres", "acre", "ha", D_AREA, 4046.8564224, 0},
    {"ha|hectare|hectares", "ha", "acre", D_AREA, 1e4, 0},
    {"bit|bits", "bit", "B", D_DATA, 0.125, 0},
    {"b|byte|bytes", "B", "bit", D_DATA, 1, 0},
    {"kb|kilobyte|kilobytes", "KB", "KiB", D_DATA, 1e3, 0},
    {"mb|megabyte|megabytes", "MB", "MiB", D_DATA, 1e6, 0},
    {"gb|gigabyte|gigabytes", "GB", "GiB", D_DATA, 1e9, 0},
    {"tb|terabyte|terabytes", "TB", "TiB", D_DATA, 1e12, 0},
    {"pb|petabyte|petabytes", "PB", "TB", D_DATA, 1e15, 0},
    {"kib|kibibyte|kibibytes", "KiB", "KB", D_DATA, 1024, 0},
    {"mib|mebibyte|mebibytes", "MiB", "MB", D_DATA, 1048576, 0},
    {"gib|gibibyte|gibibytes", "GiB", "GB", D_DATA, 1073741824, 0},
    {"tib|tebibyte|tebibytes", "TiB", "TB", D_DATA, 1099511627776.0, 0},
    {"ns|nanosecond|nanoseconds", "ns", "ms", D_TIME, 1e-9, 0},
    {"ms|millisecond|milliseconds", "ms", "s", D_TIME, 1e-3, 0},
    {"s|sec|secs|second|seconds", "s", "min", D_TIME, 1, 0},
    {"min|mins|minute|minutes", "min", "h", D_TIME, 60, 0},
    {"h|hr|hrs|hour|hours", "h", "min", D_TIME, 3600, 0},
    {"d|day|days", "days", "h", D_TIME, 86400, 0},
    {"wk|wks|week|weeks", "weeks", "days", D_TIME, 604800, 0},
    {"mo|month|months", "months", "days", D_TIME, 2629746, 0},
    {"yr|yrs|year|years", "years", "days", D_TIME, 31556952, 0},
    {"m/s|mps|meters per second", "m/s", "km/h", D_SPEED, 1, 0},
    {"km/h|kmh|kph|kmph|kilometers per hour", "km/h", "mph", D_SPEED, 1 / 3.6, 0},
    {"mph|mi/h|miles per hour", "mph", "km/h", D_SPEED, 0.44704, 0},
    {"kn|kt|knot|knots", "kn", "km/h", D_SPEED, 1852.0 / 3600, 0},
    {"ft/s|fps|feet per second", "ft/s", "m/s", D_SPEED, 0.3048, 0},
    {"deg|degree|degrees|°", "°", "rad", D_ANGLE, 1, 0},
    {"rad|radian|radians", "rad", "°", D_ANGLE, 57.29577951308232, 0},
    {"pa|pascal|pascals", "Pa", "psi", D_PRESS, 1, 0},
    {"kpa|kilopascal|kilopascals", "kPa", "psi", D_PRESS, 1e3, 0},
    {"bar|bars", "bar", "psi", D_PRESS, 1e5, 0},
    {"psi", "psi", "bar", D_PRESS, 6894.757293168, 0},
    {"atm|atmosphere|atmospheres", "atm", "kPa", D_PRESS, 101325, 0},
    {"j|joule|joules", "J", "cal", D_ENERGY, 1, 0},
    {"kj|kilojoule|kilojoules", "kJ", "kcal", D_ENERGY, 1e3, 0},
    {"cal|calorie|calories", "cal", "J", D_ENERGY, 4.184, 0},
    {"kcal|kilocalorie|kilocalories", "kcal", "kJ", D_ENERGY, 4184, 0},
    {"wh|watt hour|watt hours", "Wh", "kJ", D_ENERGY, 3600, 0},
    {"kwh|kilowatt hour|kilowatt hours", "kWh", "MJ", D_ENERGY, 3.6e6, 0},
    {"mj|megajoule|megajoules", "MJ", "kWh", D_ENERGY, 1e6, 0},
};
#define NUNITS ((int)(sizeof UNITS / sizeof *UNITS))

static int findUnit(const char *s) {
    size_t n = strlen(s);
    if (!n) return -1;
    for (int i = 0; i < NUNITS; i++) {
        const char *p = UNITS[i].names;
        while (*p) {
            const char *bar = strchr(p, '|'); size_t len = bar ? (size_t)(bar - p) : strlen(p);
            if (len == n && !memcmp(p, s, n)) return i;
            if (!bar) break;
            p = bar + 1;
        }
    }
    // display names too (e.g. "°f", "ft²")
    for (int i = 0; i < NUNITS; i++) if (!strcasecmp(UNITS[i].disp, s)) return i;
    return -1;
}

#pragma mark - currency

static int gNRates; static char gRateCode[256][4]; static double gRate[256]; static time_t gRatesTime;
static BOOL gFetching;

static void loadRates(void) {
    NSData *d = [NSData dataWithContentsOfFile:ratesPath()];
    if (!d) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSDictionary *r = [j isKindOfClass:NSDictionary.class] ? j[@"rates"] : nil;
    if (![r isKindOfClass:NSDictionary.class]) return;
    gNRates = 0;
    for (NSString *k in r) {
        if (gNRates >= 256 || k.length != 3) continue;
        strlcpy(gRateCode[gNRates], k.lowercaseString.UTF8String, 4);
        gRate[gNRates++] = [r[k] doubleValue];
    }
    gRatesTime = [j[@"time_last_update_unix"] longValue];
}
static double rateOf(const char *code) {
    for (int i = 0; i < gNRates; i++) if (!strcmp(gRateCode[i], code)) return gRate[i];
    return 0;
}
static const char *COMMON_CUR = "usd eur gbp inr jpy cny cad aud chf sgd hkd krw mxn brl rub nzd sek nok dkk pln try zar aed sar thb idr myr php vnd ils czk huf twd ars clp cop egp ngn pkr bdt";
static const struct { const char *n, *c; } CUR_ALIAS[] = {
    {"$", "usd"}, {"dollar", "usd"}, {"dollars", "usd"}, {"bucks", "usd"}, {"€", "eur"}, {"euro", "eur"}, {"euros", "eur"},
    {"£", "gbp"}, {"quid", "gbp"}, {"pound sterling", "gbp"}, {"sterling", "gbp"}, {"¥", "jpy"}, {"yen", "jpy"},
    {"₹", "inr"}, {"rs", "inr"}, {"rupee", "inr"}, {"rupees", "inr"}, {"yuan", "cny"}, {"rmb", "cny"}, {"won", "krw"},
    {"franc", "chf"}, {"francs", "chf"}, {"peso", "mxn"}, {"pesos", "mxn"}, {"real", "brl"}, {"reais", "brl"},
    {"ruble", "rub"}, {"rubles", "rub"}, {"baht", "thb"}, {"dirham", "aed"}, {"dirhams", "aed"}, {"lira", "try"},
    {"₩", "krw"}, {"₽", "rub"}, {"₺", "try"}, {"₱", "php"}, {"₪", "ils"}, {"c$", "cad"}, {"a$", "aud"}, {"s$", "sgd"}};

// Resolves a currency name/code into out (lowercase 3 letters). Works even before rates load.
static BOOL findCur(const char *s, char out[4]) {
    for (size_t i = 0; i < sizeof CUR_ALIAS / sizeof *CUR_ALIAS; i++)
        if (!strcmp(CUR_ALIAS[i].n, s)) { strcpy(out, CUR_ALIAS[i].c); return YES; }
    if (strlen(s) != 3) return NO;
    for (int i = 0; i < 3; i++) if (!islower((unsigned char)s[i])) return NO;
    if (gNRates ? rateOf(s) > 0 : strstr(COMMON_CUR, s) != NULL) { strcpy(out, s); return YES; }
    return NO;
}
static void (^gRatesUpdated)(void);
static void ratesArrived(int status, NSString *tmp) {
    gFetching = NO;
    if (status != 0) return;
    rename(tmp.fileSystemRepresentation, ratesPath().fileSystemRepresentation);
    loadRates();
    if (gRatesUpdated) gRatesUpdated();
}
// Fetches out-of-process with /usr/bin/curl so no networking stack is ever loaded into rayfast.
static void fetchRates(BOOL wait) {
    if (gFetching) return;
    gFetching = YES;
    NSString *tmp = [ratesPath() stringByAppendingString:@".tmp"];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/curl"];
    t.arguments = @[@"-sfL", @"-m", @"10", @"-o", tmp, @"https://open.er-api.com/v6/latest/USD"];
    if (!wait) t.terminationHandler = ^(NSTask *tt) {
        int st = tt.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{ ratesArrived(st, tmp); });
    };
    if (![t launchAndReturnError:nil]) { gFetching = NO; return; }
    if (wait) { [t waitUntilExit]; ratesArrived(t.terminationStatus, tmp); }
}
static BOOL ratesStale(void) { return !gNRates || time(NULL) - mtimeOf(ratesPath()) > 6 * 3600; }
static NSString *localCurrency(void) {
    NSString *c = [NSLocale.currentLocale objectForKey:NSLocaleCurrencyCode];
    return c ? c.lowercaseString : @"usd";
}

#pragma mark - results

enum { K_HEADER, K_APP, K_CALC, K_INFO, K_ACTION, K_FILE };
@interface App : NSObject { @public NSString *name, *path; char lname[128]; double uses; id icon; /* CGImageRef */ BOOL file, dir; }
@end
@implementation App
@end
// K_CALC renders as a two-sided card: lhs/lhsCap  →  title/sub
@interface Item : NSObject { @public int kind; NSString *title, *sub, *copy, *glyph, *lhs, *lhsCap; App *app; SEL action; }
@end
@implementation Item
@end
static Item *mkItem(int kind, NSString *title, NSString *sub, NSString *copy, NSString *glyph) {
    Item *i = [Item new]; i->kind = kind; i->title = title; i->sub = sub; i->copy = copy; i->glyph = glyph; return i;
}
static Item *mkCalc(NSString *lhs, NSString *lhsCap, NSString *rhs, NSString *rhsCap, NSString *copy) {
    Item *i = mkItem(K_CALC, rhs, rhsCap, copy, nil); i->lhs = lhs; i->lhsCap = lhsCap; return i;
}

#pragma mark - unit / currency query

typedef struct { int u; char cur[4]; } USpec;
static BOOL resolveUnit(const char *s, USpec *o) {
    o->u = findUnit(s); o->cur[0] = 0;
    if (o->u >= 0) return YES;
    return findCur(s, o->cur);
}
static BOOL parseQty(const char *s, double *v, USpec *o) {
    // currency symbol prefix: "$100", "€ 20"
    static const char *syms[] = {"c$", "a$", "s$", "$", "€", "£", "¥", "₹", "₩", "₽", "₺", "₱", "₪"};
    for (size_t i = 0; i < sizeof syms / sizeof *syms; i++) {
        size_t l = strlen(syms[i]);
        if (!strncmp(s, syms[i], l) && evalExpr(s + l, v)) { o->u = -1; findCur(syms[i], o->cur); return YES; }
    }
    size_t n = strlen(s);
    char pre[256];
    for (size_t i = 1; i < n && i < sizeof pre; i++) {
        const char *suf = s + i; while (*suf == ' ') suf++;
        if (!*suf) break;
        if (!resolveUnit(suf, o)) continue;
        memcpy(pre, s, i); pre[i] = 0;
        if (evalExpr(pre, v)) return YES;
    }
    return NO;
}
static NSString *unitLong(int u, double v) {
    NSString *best = nil;
    NSArray *names = [@(UNITS[u].names) componentsSeparatedByString:@"|"];
    for (NSString *n in names) if (n.length > best.length) best = n;
    if (fabs(v) == 1 && [best hasSuffix:@"s"] && [names containsObject:[best substringToIndex:best.length - 1]])
        best = [best substringToIndex:best.length - 1];
    if (best.length < 3) return @(UNITS[u].disp);
    return [best.capitalizedString stringByReplacingOccurrencesOfString:@" Per " withString:@" per "];
}
static NSString *curName(const char *code) {
    NSString *n = [[NSLocale localeWithLocaleIdentifier:@"en_US"] displayNameForKey:NSLocaleCurrencyCode value:@(code).uppercaseString];
    return n ?: @(code).uppercaseString;
}
static NSString *unitDisp(USpec *u) { return u->u >= 0 ? @(UNITS[u->u].disp) : @(u->cur).uppercaseString; }

static Item *unitQuery(NSString *q) {
    NSString *left = q, *right = nil;
    for (NSString *sep in @[@" to ", @" -> ", @" → ", @" as ", @" in ", @" into ", @" = "]) {
        NSRange r = [q rangeOfString:sep options:NSBackwardsSearch];
        if (r.location != NSNotFound) { left = [q substringToIndex:r.location]; right = trim([q substringFromIndex:NSMaxRange(r)]); break; }
    }
    double v; USpec from, to;
    if (!parseQty(trim(left).UTF8String, &v, &from)) return nil;
    if (right) { if (!resolveUnit(right.UTF8String, &to)) return nil; }
    else if (from.u >= 0) { to.u = findUnit(UNITS[from.u].def); to.cur[0] = 0; }
    else {
        to.u = -1; NSString *lc = localCurrency();
        if ([lc isEqual:@(from.cur)]) lc = [lc isEqual:@"usd"] ? @"eur" : @"usd";
        strlcpy(to.cur, lc.UTF8String, 4);
    }
    if ((from.u < 0) != (to.u < 0)) return nil;
    double out; int frac = 4;
    NSString *lcap, *rcap;
    if (from.u >= 0) {
        if (UNITS[from.u].dim != UNITS[to.u].dim) return nil;
        double base = v * UNITS[from.u].f + UNITS[from.u].off;
        out = (base - UNITS[to.u].off) / UNITS[to.u].f;
        lcap = unitLong(from.u, v); rcap = unitLong(to.u, out);
    } else {
        if (!gNRates) loadRates();
        if (ratesStale()) fetchRates(NO);
        if (!gNRates) { Item *i = mkCalc(q, @"Currency", @"…", @"Fetching exchange rates", nil); i->kind = K_INFO; return i; }
        double rf = rateOf(from.cur), rt = rateOf(to.cur);
        if (!rf || !rt) return nil;
        out = v / rf * rt; frac = 2;
        char date[32]; struct tm tm; localtime_r(&gRatesTime, &tm); strftime(date, sizeof date, "%b %-d", &tm);
        lcap = curName(from.cur); rcap = [NSString stringWithFormat:@"%@  ·  %s rates", curName(to.cur), date];
    }
    int sig = from.u >= 0 ? 8 : 0;
    NSString *t = fmtNumSig(out, frac, sig, YES);
    if (!t) return nil;
    return mkCalc([NSString stringWithFormat:@"%@ %@", fmtNum(v, from.u >= 0 ? 6 : 2, YES), unitDisp(&from)], lcap,
                  [NSString stringWithFormat:@"%@ %@", t, unitDisp(&to)], rcap, fmtNumSig(out, frac, sig, NO));
}

static Item *mathQuery(NSString *q) {
    const char *s = q.UTF8String;
    if (!strpbrk(s, "+-*/^%()!")) {
        BOOL alpha = NO; for (const char *c = s; *c; c++) if (isalpha((unsigned char)*c)) alpha = YES;
        if (!alpha) return nil;              // bare number: nothing to show
    }
    double v;
    if (!evalExpr(s, &v)) return nil;
    NSString *t = fmtNum(v, 10, YES);
    if (!t) return nil;
    return mkCalc(q, @"Expression", t, @"Result", fmtNum(v, 10, NO));
}

#pragma mark - timezone query

// Abbreviations people type ("10am IST to CET"). They're shown back as typed, switched to the
// standard/daylight variant that actually applies on the date (CET in winter, CEST in summer).
static NSDictionary<NSString *, NSString *> *tzAbbrs(void) {
    static NSDictionary *m;
    if (!m) m = @{
        @"pst": @"America/Los_Angeles", @"pdt": @"America/Los_Angeles", @"pt": @"America/Los_Angeles",
        @"est": @"America/New_York", @"edt": @"America/New_York", @"et": @"America/New_York",
        @"cst": @"America/Chicago", @"cdt": @"America/Chicago", @"ct": @"America/Chicago",
        @"mst": @"America/Denver", @"mdt": @"America/Denver", @"mt": @"America/Denver",
        @"akst": @"America/Anchorage", @"akdt": @"America/Anchorage", @"hst": @"Pacific/Honolulu",
        @"ist": @"Asia/Kolkata", @"gmt": @"GMT", @"utc": @"UTC", @"bst": @"Europe/London",
        @"wet": @"Europe/Lisbon", @"west": @"Europe/Lisbon", @"cet": @"Europe/Paris", @"cest": @"Europe/Paris",
        @"eet": @"Europe/Athens", @"eest": @"Europe/Athens", @"msk": @"Europe/Moscow", @"gst": @"Asia/Dubai",
        @"pkt": @"Asia/Karachi", @"npt": @"Asia/Kathmandu", @"ict": @"Asia/Bangkok", @"wib": @"Asia/Jakarta",
        @"sgt": @"Asia/Singapore", @"hkt": @"Asia/Hong_Kong", @"jst": @"Asia/Tokyo", @"kst": @"Asia/Seoul",
        @"aest": @"Australia/Sydney", @"aedt": @"Australia/Sydney", @"acst": @"Australia/Adelaide",
        @"awst": @"Australia/Perth", @"nzst": @"Pacific/Auckland", @"nzdt": @"Pacific/Auckland",
        @"brt": @"America/Sao_Paulo", @"art": @"America/Argentina/Buenos_Aires",
        @"sast": @"Africa/Johannesburg", @"eat": @"Africa/Nairobi", @"wat": @"Africa/Lagos"};
    return m;
}
static NSString *tzAbbrOn(NSString *abbr, NSTimeZone *tz, NSDate *d) {
    static NSDictionary *dst;
    if (!dst) dst = @{@"pst": @"pdt", @"est": @"edt", @"cst": @"cdt", @"mst": @"mdt", @"akst": @"akdt", @"wet": @"west",
                      @"cet": @"cest", @"eet": @"eest", @"aest": @"aedt", @"nzst": @"nzdt"};
    BOOL summer = [tz isDaylightSavingTimeForDate:d];
    if (summer && dst[abbr]) abbr = dst[abbr];
    if (!summer) for (NSString *k in dst) if ([dst[k] isEqual:abbr]) abbr = k;
    return abbr.uppercaseString;
}
// Cities, regions and nicknames, plus overrides for countries that span several zones.
static NSDictionary<NSString *, NSString *> *tzPlaces(void) {
    static NSDictionary *m;
    if (!m) m = @{
        @"pacific": @"America/Los_Angeles", @"eastern": @"America/New_York", @"central": @"America/Chicago", @"mountain": @"America/Denver",
        @"sf": @"America/Los_Angeles", @"san francisco": @"America/Los_Angeles", @"bay area": @"America/Los_Angeles", @"la": @"America/Los_Angeles",
        @"seattle": @"America/Los_Angeles", @"portland": @"America/Los_Angeles", @"san diego": @"America/Los_Angeles", @"vegas": @"America/Los_Angeles",
        @"las vegas": @"America/Los_Angeles", @"california": @"America/Los_Angeles",
        @"nyc": @"America/New_York", @"ny": @"America/New_York", @"boston": @"America/New_York",
        @"dc": @"America/New_York", @"washington": @"America/New_York", @"miami": @"America/New_York", @"atlanta": @"America/New_York",
        @"philadelphia": @"America/New_York", @"austin": @"America/Chicago", @"dallas": @"America/Chicago", @"houston": @"America/Chicago",
        @"texas": @"America/Chicago", @"arizona": @"America/Phoenix", @"hawaii": @"Pacific/Honolulu",
        @"usa": @"America/New_York", @"us": @"America/New_York", @"united states": @"America/New_York", @"america": @"America/New_York",
        @"canada": @"America/Toronto", @"brazil": @"America/Sao_Paulo", @"mexico": @"America/Mexico_City", @"russia": @"Europe/Moscow",
        @"australia": @"Australia/Sydney", @"indonesia": @"Asia/Jakarta", @"spain": @"Europe/Madrid", @"portugal": @"Europe/Lisbon",
        @"uk": @"Europe/London", @"england": @"Europe/London", @"britain": @"Europe/London", @"scotland": @"Europe/London",
        @"europe": @"Europe/Paris", @"holland": @"Europe/Amsterdam", @"tel aviv": @"Asia/Jerusalem", @"saudi": @"Asia/Riyadh",
        @"uae": @"Asia/Dubai", @"abu dhabi": @"Asia/Dubai",
        @"ind": @"Asia/Kolkata", @"mumbai": @"Asia/Kolkata", @"bombay": @"Asia/Kolkata", @"delhi": @"Asia/Kolkata", @"new delhi": @"Asia/Kolkata",
        @"bangalore": @"Asia/Kolkata", @"bengaluru": @"Asia/Kolkata", @"chennai": @"Asia/Kolkata", @"hyderabad": @"Asia/Kolkata",
        @"pune": @"Asia/Kolkata", @"gurgaon": @"Asia/Kolkata", @"noida": @"Asia/Kolkata", @"beijing": @"Asia/Shanghai", @"shenzhen": @"Asia/Shanghai",
        @"korea": @"Asia/Seoul", @"nz": @"Pacific/Auckland", @"bay": @"America/Los_Angeles"};
    return m;
}
// Every country, by its English name, from the system's zone table (first zone listed; tzPlaces overrides).
static NSDictionary<NSString *, NSString *> *tzCountries(void) {
    static NSMutableDictionary *m;
    if (m) return m;
    m = [NSMutableDictionary dictionary];
    NSString *tab = [NSString stringWithContentsOfFile:@"/usr/share/zoneinfo/zone.tab" encoding:NSUTF8StringEncoding error:nil];
    NSLocale *en = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    for (NSString *line in [tab componentsSeparatedByString:@"\n"]) {
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if (f.count < 3 || [line hasPrefix:@"#"]) continue;
        NSString *name = [en localizedStringForCountryCode:f[0]].lowercaseString;
        if (name && !m[name]) m[name] = f[2];
    }
    return m;
}
static NSString *tzCity(NSTimeZone *tz) {
    NSString *n = [tz.name.lastPathComponent stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    return [n isEqual:@"Kolkata"] ? @"India" : n;
}

// A resolved zone and how to label it: the abbreviation as typed, a country's name, or (nil) the zone's city.
typedef struct { NSTimeZone *tz; NSString *abbr, *name; BOOL exact; } TZRef;

static TZRef tzFind(NSString *s, BOOL allowPrefix) {
    TZRef r = {0};
    s = trim(s);
    if (!s.length) return r;
    r.exact = YES;
    if ([s isEqual:@"local"] || [s isEqual:@"here"] || [s isEqual:@"me"]) { r.tz = NSTimeZone.localTimeZone; return r; }
    NSString *n;
    if ((n = tzAbbrs()[s])) { r.tz = [NSTimeZone timeZoneWithName:n]; r.abbr = s; return r; }
    // utc+5:30, gmt-3, utc +1
    const char *c = s.UTF8String; int hh = 0, mm = 0; char sign = 0, rest[8] = "";
    if ((!strncmp(c, "utc", 3) || !strncmp(c, "gmt", 3)) &&
        sscanf(c + 3, " %c%2d%7s", &sign, &hh, rest) >= 2 && (sign == '+' || sign == '-') &&
        (!rest[0] || sscanf(rest, ":%2d", &mm) == 1 || sscanf(rest, "%2d", &mm) == 1) && hh <= 14 && mm < 60) {
        int secs = (hh * 3600 + mm * 60) * (sign == '-' ? -1 : 1);
        r.tz = [NSTimeZone timeZoneForSecondsFromGMT:secs];
        r.name = mm ? [NSString stringWithFormat:@"UTC%c%d:%02d", sign, hh, mm] : [NSString stringWithFormat:@"UTC%c%d", sign, hh];
        return r;
    }
    NSDictionary *countries = tzCountries();
    if ((n = tzPlaces()[s] ?: countries[s])) {
        r.tz = [NSTimeZone timeZoneWithName:n];
        if (countries[s]) r.name = s.capitalizedString;
        return r;
    }
    NSString *u = [s stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    for (NSString *name in NSTimeZone.knownTimeZoneNames) {
        NSString *l = name.lowercaseString;
        if ([l isEqual:u] || [l.lastPathComponent isEqual:u]) { r.tz = [NSTimeZone timeZoneWithName:name]; return r; }
    }
    // Unique-enough prefix ("ams", "sing", "netherl"): the shortest name that starts with it.
    r.exact = NO;
    if (!allowPrefix || s.length < 3) return r;
    __block NSString *best = nil, *bestZone = nil;
    void (^consider)(NSString *, NSString *) = ^(NSString *cand, NSString *zone) {
        if ([cand hasPrefix:s] && (!best || cand.length < best.length || (cand.length == best.length && [cand compare:best] < 0))) { best = cand; bestZone = zone; }
    };
    [tzPlaces() enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *z, BOOL *stop) { if (k.length > 3) consider(k, z); }];
    [countries enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *z, BOOL *stop) { consider(k, z); }];
    for (NSString *name in NSTimeZone.knownTimeZoneNames)
        consider([name.lastPathComponent.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@" "], name);
    if (!best) return r;
    r.tz = [NSTimeZone timeZoneWithName:tzPlaces()[best] ?: countries[best] ?: bestZone];
    if (countries[best] && !tzPlaces()[best]) r.name = best.capitalizedString;
    return r;
}
static NSString *tzLabel(TZRef r, NSDate *d) { return r.abbr ? tzAbbrOn(r.abbr, r.tz, d) : r.name ?: tzCity(r.tz); }
// The label plus the zone's abbreviation when it has a real one: "New York (EST)", but not "India (GMT+5:30)".
static NSString *tzLabelLong(TZRef r, NSDate *d) {
    NSString *a = r.abbr || [r.name hasPrefix:@"UTC"] ? nil : [r.tz abbreviationForDate:d];
    return a && ![a hasPrefix:@"GMT+"] && ![a hasPrefix:@"GMT-"] ? [NSString stringWithFormat:@"%@ (%@)", tzLabel(r, d), a] : tzLabel(r, d);
}

// Parses "3pm", "3:30 pm", "15:00", "noon", "midnight", "now" (h = -1). With `loose`, also a bare hour ("10")
// or 24-hour digits ("1500", "930"); only used when both zones were named exactly, so "5 km to mi" stays a unit query.
static BOOL parseClock(NSString *str, int *h, int *m, BOOL loose) {
    str = trim(str);
    if ([str isEqual:@"now"]) { *h = -1; *m = 0; return YES; }
    if ([str isEqual:@"noon"]) { *h = 12; *m = 0; return YES; }
    if ([str isEqual:@"midnight"]) { *h = 0; *m = 0; return YES; }
    const char *c = str.UTF8String; int i = 0, hh = 0, mm = 0;
    if (!isdigit((unsigned char)c[0])) return NO;
    while (isdigit((unsigned char)c[i]) && i < 4) hh = hh * 10 + (c[i++] - '0');
    int nd = i;
    if (nd > 2) { if (!loose || c[i]) return NO; mm = hh % 100; hh /= 100; *h = hh; *m = mm; return hh < 24 && mm < 60; }
    BOOL colon = NO;
    if (c[i] == ':' || c[i] == '.') {
        colon = YES; i++;
        if (!isdigit((unsigned char)c[i]) || !isdigit((unsigned char)c[i + 1])) return NO;
        mm = (c[i] - '0') * 10 + (c[i + 1] - '0'); i += 2;
    }
    while (c[i] == ' ') i++;
    int ap = 0;
    if (!strcmp(c + i, "am") || !strcmp(c + i, "a") || !strcmp(c + i, "a.m.")) ap = 1;
    else if (!strcmp(c + i, "pm") || !strcmp(c + i, "p") || !strcmp(c + i, "p.m.")) ap = 2;
    else if (!strcmp(c + i, "h") || !strcmp(c + i, "hrs")) { if (!colon && !loose) return NO; }
    else if (c[i]) return NO;
    if (!colon && !ap && !loose) return NO;
    if (ap) { if (hh < 1 || hh > 12) return NO; hh %= 12; if (ap == 2) hh += 12; }
    else if (hh > 23) return NO;
    if (mm > 59) return NO;
    *h = hh; *m = mm; return YES;
}
static NSString *fmtDay(NSDate *d, NSTimeZone *tz) {
    time_t t = (time_t)d.timeIntervalSince1970 + [tz secondsFromGMTForDate:d];
    struct tm tm; gmtime_r(&t, &tm); char b[32]; strftime(b, sizeof b, "%a, %b %-d", &tm); return @(b);
}
static NSString *fmtClock(NSDate *d, NSTimeZone *tz) {
    time_t t = (time_t)d.timeIntervalSince1970 + [tz secondsFromGMTForDate:d];
    struct tm tm; gmtime_r(&t, &tm);
    char b[16]; strftime(b, sizeof b, "%-I:%M %p", &tm);
    return @(b);
}
static Item *tzResult(NSDate *d, TZRef a, TZRef b, BOOL isNow) {
    long diff = ([b.tz secondsFromGMTForDate:d] - [a.tz secondsFromGMTForDate:d]) / 60;
    NSString *off = diff ? [NSString stringWithFormat:@"%c%ld%@", diff < 0 ? '-' : '+', labs(diff) / 60,
                                  labs(diff) % 60 ? [NSString stringWithFormat:@":%02ld", labs(diff) % 60] : @""] : @"same time";
    NSString *lhs = isNow ? @"Now" : fmtClock(d, a.tz);
    NSString *lcap = isNow ? [NSString stringWithFormat:@"%@ · %@", tzLabel(a, d), fmtClock(d, a.tz)] : tzLabel(a, d);
    NSString *rcap = [NSString stringWithFormat:@"%@  ·  %@  ·  %@", tzLabelLong(b, d), fmtDay(d, b.tz), off];
    return mkCalc(lhs, lcap, fmtClock(d, b.tz), rcap, fmtClock(d, b.tz));
}
static Item *tzQuery(NSString *q) {
    TZRef local = {NSTimeZone.localTimeZone, nil, nil, YES};
    while (q.length && strchr("?!.", [q characterAtIndex:q.length - 1])) q = trim([q substringToIndex:q.length - 1]);
    int dayOff = 0;
    for (NSString *w in @[@"tomorrow", @"today", @"yesterday"]) {
        int d = [w isEqual:@"tomorrow"] ? 1 : [w isEqual:@"yesterday"] ? -1 : 0;
        if ([q hasSuffix:[@" " stringByAppendingString:w]]) { q = [q substringToIndex:q.length - w.length - 1]; dayOff = d; }
        else if ([q hasPrefix:[w stringByAppendingString:@" "]]) { q = [q substringFromIndex:w.length + 1]; dayOff = d; }
    }
    for (NSString *pre in @[@"time in ", @"now in ", @"time at ", @"current time in ", @"what time is it in ", @"what's the time in "])
        if ([q hasPrefix:pre]) { TZRef z = tzFind([q substringFromIndex:pre.length], YES); return z.tz ? tzResult(NSDate.date, local, z, YES) : nil; }
    if ([q hasSuffix:@" time"]) {
        TZRef z = tzFind([q substringToIndex:q.length - 5], NO);
        if (z.tz) return tzResult(NSDate.date, local, z, YES);
    }
    NSString *left = q, *right = nil;
    for (NSString *sep in @[@" to ", @" in ", @" into ", @" -> ", @" → ", @" = "]) {
        NSRange r = [q rangeOfString:sep options:NSBackwardsSearch];
        if (r.location != NSNotFound) { left = [q substringToIndex:r.location]; right = [q substringFromIndex:NSMaxRange(r)]; break; }
    }
    TZRef b = right ? tzFind(right, YES) : local;
    if (!b.tz) return nil;
    NSArray *w = [trim(left) componentsSeparatedByString:@" "];
    NSUInteger n = w.count;
    // "10am ist", "10 am ist", "ist 10am": the clock is the first or last 1–2 words, the zone is the rest
    for (int pass = 0; pass < 2; pass++) {
        for (NSUInteger k = 1; k <= MIN(2u, n); k++) {
            NSRange cr = pass == 0 ? NSMakeRange(0, k) : NSMakeRange(n - k, k);
            NSRange zr = pass == 0 ? NSMakeRange(k, n - k) : NSMakeRange(0, n - k);
            if (pass == 1 && !zr.length) continue;
            NSString *clock = [[w subarrayWithRange:cr] componentsJoinedByString:@" "];
            NSString *zone = [[w subarrayWithRange:zr] componentsJoinedByString:@" "];
            if (!zone.length && !right) continue;
            TZRef a = zone.length ? tzFind(zone, YES) : local;
            if (!a.tz) continue;
            int h, m;
            BOOL namedExactly = zone.length && a.exact && (!right || b.exact);
            if (!parseClock(clock, &h, &m, NO) && !(namedExactly && parseClock(clock, &h, &m, YES))) continue;
            NSDate *d = NSDate.date;
            if (h >= 0) {
                NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
                cal.timeZone = a.tz;
                NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:d];
                c.hour = h; c.minute = m; c.day += dayOff;
                d = [cal dateFromComponents:c];
            }
            return tzResult(d, a, b, NO);
        }
    }
    // "ist to cet": what time is it in both, right now (exact names only, so "usd to inr" doesn't land here)
    if (right && b.exact) { TZRef a = tzFind(left, NO); if (a.tz) return tzResult(NSDate.date, a, b, YES); }
    return nil;
}

static Item *convertQuery(NSString *raw) {
    NSString *q = trim(raw.lowercaseString);
    q = [[q stringByReplacingOccurrencesOfString:@"×" withString:@"*"] stringByReplacingOccurrencesOfString:@"÷" withString:@"/"];
    if (!q.length) return nil;
    Item *it;
    if ((it = tzQuery(q))) return it;
    if ((it = unitQuery(q))) return it;
    return mathQuery(q);
}

#pragma mark - UI (Raycast-style layout: search bar / sectioned list / action footer)

static const CGFloat W = 750, H = 474, SH = 56, FT = 40, RH = 40, HH = 30, CH = 104;
static const int MAXAPPS = 40;

@interface Panel : NSPanel
@end
static void needsRender(void);
// A one-line text input that implements NSTextInputClient itself. NSTextField would build a full TextKit
// field editor, which was ~30 ms of a cold first show; this keeps IME / dead keys / emoji working without it.
static NSString *gPlaceholder = @"Search for apps and conversions…";
@interface QueryView : NSView <NSTextInputClient> {
@public
    NSMutableString *text; NSRange sel; NSString *marked;
    void (^onChange)(void);
}
@property (nonatomic) NSString *stringValue;
@end
@implementation QueryView
- (instancetype)initWithFrame:(NSRect)f { if ((self = [super initWithFrame:f])) { text = [NSMutableString string]; } return self; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (NSString *)stringValue { return [text copy]; }
- (void)setStringValue:(NSString *)s { [text setString:s ?: @""]; sel = NSMakeRange(text.length, 0); marked = nil; needsRender(); }
- (NSDictionary *)attrs { return @{NSFontAttributeName: [NSFont systemFontOfSize:18], NSForegroundColorAttributeName: NSColor.labelColor}; }
- (void)changed { needsRender(); if (onChange) onChange(); }
// Drawn by R's renderer into the window surface (this view never draws itself, so it gets no backing store).
- (CGFloat)caretX {
    NSString *shown = marked ? [text stringByReplacingCharactersInRange:sel withString:marked] : text;
    return [[shown substringToIndex:sel.location + marked.length] sizeWithAttributes:self.attrs].width;
}
- (void)drawContent {
    NSDictionary *a = self.attrs;
    NSString *shown = marked ? [text stringByReplacingCharactersInRange:sel withString:marked] : text;
    if (!shown.length) {
        [gPlaceholder drawAtPoint:NSMakePoint(0, 1) withAttributes:@{NSFontAttributeName: a[NSFontAttributeName], NSForegroundColorAttributeName: NSColor.placeholderTextColor}];
    }
    CGFloat x0 = [[shown substringToIndex:sel.location] sizeWithAttributes:a].width;
    if (sel.length && !marked) {
        CGFloat x1 = [[shown substringToIndex:NSMaxRange(sel)] sizeWithAttributes:a].width;
        [NSColor.selectedTextBackgroundColor setFill];
        NSRectFill(NSMakeRect(x0, 2, x1 - x0, 22));
    }
    [shown drawAtPoint:NSMakePoint(0, 1) withAttributes:a];
    if (marked.length) {   // underline the IME composition
        CGFloat xm = [[shown substringToIndex:sel.location + marked.length] sizeWithAttributes:a].width;
        [NSColor.labelColor setFill]; NSRectFill(NSMakeRect(x0, 24, xm - x0, 1));
    }
}
- (void)keyDown:(NSEvent *)e { [self interpretKeyEvents:@[e]]; }
- (void)replace:(NSRange)r with:(NSString *)s {
    if (r.location == NSNotFound) r = sel;
    if (r.location > text.length) r = NSMakeRange(text.length, 0);
    if (NSMaxRange(r) > text.length) r.length = text.length - r.location;
    [text replaceCharactersInRange:r withString:s];
    sel = NSMakeRange(r.location + s.length, 0);
}
// NSTextInputClient
- (void)insertText:(id)s replacementRange:(NSRange)rr {
    NSString *str = [s isKindOfClass:NSAttributedString.class] ? [s string] : s;
    marked = nil;
    [self replace:rr with:str];
    [self changed];
}
- (void)setMarkedText:(id)s selectedRange:(NSRange)sr replacementRange:(NSRange)rr {
    NSString *str = [s isKindOfClass:NSAttributedString.class] ? [s string] : s;
    if (rr.location != NSNotFound) { [self replace:rr with:@""]; }
    else if (sel.length) { [self replace:sel with:@""]; }
    marked = str.length ? str : nil;
    needsRender();
}
- (void)unmarkText { if (marked) { NSString *m = marked; marked = nil; [self replace:sel with:m]; [self changed]; } }
- (BOOL)hasMarkedText { return marked != nil; }
- (NSRange)markedRange { return marked ? NSMakeRange(sel.location, marked.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return sel; }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)r actualRange:(NSRangePointer)ar {
    r = NSIntersectionRange(r, NSMakeRange(0, text.length));
    if (ar) *ar = r;
    return [[NSAttributedString alloc] initWithString:[text substringWithRange:r]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)p { return text.length; }
- (NSRect)firstRectForCharacterRange:(NSRange)r actualRange:(NSRangePointer)ar {
    CGFloat x = [[text substringToIndex:MIN(sel.location, text.length)] sizeWithAttributes:self.attrs].width;
    return [self.window convertRectToScreen:[self convertRect:NSMakeRect(x, 0, 2, 26) toView:nil]];
}
- (void)doCommandBySelector:(SEL)s {
    NSUInteger n = text.length;
    if (s == @selector(deleteBackward:)) {
        if (sel.length) [self replace:sel with:@""];
        else if (sel.location) { NSRange r = [text rangeOfComposedCharacterSequenceAtIndex:sel.location - 1]; [self replace:r with:@""]; }
    } else if (s == @selector(deleteForward:)) {
        if (sel.length) [self replace:sel with:@""];
        else if (sel.location < n) [self replace:[text rangeOfComposedCharacterSequenceAtIndex:sel.location] with:@""];
    } else if (s == @selector(deleteWordBackward:)) {
        NSUInteger i = sel.location;
        while (i && [text characterAtIndex:i - 1] == ' ') i--;
        while (i && [text characterAtIndex:i - 1] != ' ') i--;
        [self replace:NSMakeRange(i, NSMaxRange(sel) - i) with:@""];
    } else if (s == @selector(deleteToBeginningOfLine:)) {
        [self replace:NSMakeRange(0, NSMaxRange(sel)) with:@""];
    } else if (s == @selector(moveLeft:)) {
        sel = NSMakeRange(sel.length ? sel.location : (sel.location ? [text rangeOfComposedCharacterSequenceAtIndex:sel.location - 1].location : 0), 0);
    } else if (s == @selector(moveRight:)) {
        sel = NSMakeRange(sel.length ? NSMaxRange(sel) : (sel.location < n ? NSMaxRange([text rangeOfComposedCharacterSequenceAtIndex:sel.location]) : n), 0);
    } else if (s == @selector(moveToBeginningOfLine:) || s == @selector(moveWordLeft:)) { sel = NSMakeRange(0, 0);
    } else if (s == @selector(moveToEndOfLine:) || s == @selector(moveWordRight:)) { sel = NSMakeRange(n, 0);
    } else return;
    [self changed];
}
- (void)selectAll:(id)x { sel = NSMakeRange(0, text.length); needsRender(); }
- (void)copy:(id)x { if (sel.length) { [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:[text substringWithRange:sel] forType:NSPasteboardTypeString]; } }
- (void)cut:(id)x { if (sel.length) { [self copy:x]; [self replace:sel with:@""]; [self changed]; } }
- (void)paste:(id)x {
    NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!s) return;
    s = [[s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    [self replace:sel with:s]; [self changed];
}
@end

@interface ListView : NSView { @public CGFloat off; }
- (void)clickAt:(NSPoint)p;
- (void)scrollBy:(NSEvent *)e;
@end
@interface Footer : NSView
@end
@interface Chrome : NSView
@end
// The window's only layer-backed view. It never draws: its layer shows an IOSurface that R renders into
// on the CPU (grayscale, 1 byte/px), plus tiny colour layers for icons, logo and caret. Drawing through
// AppKit's normal path instead makes Core Animation spin up a ~40 MB GPU pool for any window this size.
@interface Canvas : NSView
@end

@interface R : NSObject <NSApplicationDelegate, NSWindowDelegate> {
@public
    Panel *panel; QueryView *field; ListView *list; Footer *footer; Chrome *chrome; Canvas *canvas;
    IOSurfaceRef surf[2]; int cur; CGFloat scale; BOOL dirty;
    BOOL prepared; time_t cfgSeen;   // prepared: surface already holds the empty-launcher frame
    BOOL shown;                      // logically visible (tracked explicitly; the hide/show path owns it)
    CALayer *base, *caret, *logo; NSMutableArray<CALayer *> *iconLayers;
    NSMutableArray<App *> *apps; NSArray<Item *> *rows; int sel;
    App *recording; BOOL hiding;
    BOOL fileMode, searching; NSString *fileQuery; NSArray<Item *> *fileRows; NSTask *mdTask; int fileGen;   // file search
    BOOL dig; NSString *fileNote; NSTask *dgTask; NSFileHandle *dgIn;                                     // DigUp provider
    BOOL setupMode; NSTask *installTask; NSString *setupNote;                                            // DigUp setup
    double lastScan;
}
- (BOOL)handleKey:(NSEvent *)e;
- (void)activateSelected;
- (Binding *)bindingFor:(NSString *)path;
- (void)makePanel;
- (void)render;
- (void)preShow;
- (void)scanApps;
@end
static R *gR;
static NSString *digupBinary(void);
static NSArray<NSString *> *digupPref(NSString *key);

static CGFloat rowHeight(Item *it) { return it->kind == K_HEADER ? HH : (it->kind == K_CALC || it->kind == K_INFO) ? CH : RH; }

@implementation Panel
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)sendEvent:(NSEvent *)e {
    if (e.type == NSEventTypeKeyDown && [gR handleKey:e]) return;
    [super sendEvent:e];
}
@end

// Window background: rounded, hairline border, separator under the search bar and above the footer.
@implementation Chrome
- (void)drawContent {
    NSRect b = self.bounds;
    [NSColor.windowBackgroundColor setFill]; NSRectFill(b);   // the surface is opaque; the layer's cornerRadius rounds it
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:12 yRadius:12];
    [NSColor.windowBackgroundColor setFill]; [p fill];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setStroke]; p.lineWidth = 1; [p stroke];
    [NSColor.separatorColor setFill];
    NSRectFillUsingOperation(NSMakeRect(0, H - SH, W, 1), NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(0, FT, W, 1), NSCompositingOperationSourceOver);
    [[NSColor.labelColor colorWithAlphaComponent:0.03] setFill];   // footer tint
    NSBezierPath *f = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.5, 0.5, W - 1, FT + 12) xRadius:12 yRadius:12];
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSMakeRect(0, 0, W, FT)); [f fill]; [NSGraphicsContext restoreGraphicsState];
}
@end

static NSMutableArray *gIconSlots;   // [App, NSRect in list coords] for the icons visible in the last render
// Icon cache: 48x48 premultiplied BGRA bitmaps in one file, mmap()ed read-only. File-backed clean pages don't count
// toward the footprint, and IconServices (slow to load, heavy caches) only runs for apps not cached yet.
#define ICON_PX 48
#define ICON_BYTES (ICON_PX * ICON_PX * 4)
typedef struct { char path[500]; uint32_t mtime; uint8_t px[ICON_BYTES]; } IconRec;
static const uint8_t *gIconMap; static size_t gIconMapLen; static NSMutableDictionary<NSString *, NSNumber *> *gIconIndex;
static NSString *iconCachePath(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/rayfast-icons.bin"]; }
static void mapIconCache(void) {
    if (gIconMap) { munmap((void *)gIconMap, gIconMapLen); gIconMap = NULL; }
    gIconIndex = [NSMutableDictionary dictionary];
    int fd = open(iconCachePath().fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return;
    struct stat st; fstat(fd, &st);
    size_t n = (size_t)st.st_size / sizeof(IconRec);
    if (n) {
        gIconMapLen = n * sizeof(IconRec);
        gIconMap = mmap(NULL, gIconMapLen, PROT_READ, MAP_PRIVATE, fd, 0);
        if (gIconMap == MAP_FAILED) gIconMap = NULL;
        for (size_t i = 0; gIconMap && i < n; i++) gIconIndex[@(((const IconRec *)gIconMap)[i].path)] = @(i);   // later entries win
    }
    close(fd);
}
static CGImageRef iconImage(const uint8_t *px, BOOL copy) {
    static CGColorSpaceRef cs; if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDataRef d = copy ? CFDataCreate(NULL, px, ICON_BYTES) : CFDataCreateWithBytesNoCopy(NULL, px, ICON_BYTES, kCFAllocatorNull);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData(d);
    CGImageRef img = CGImageCreate(ICON_PX, ICON_PX, 8, 32, ICON_PX * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, dp, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp); CFRelease(d);
    return img;
}
static id iconFor(App *a) {
    if (a->icon) return a->icon;
    if (a->file) {
        NSImage *im = [NSWorkspace.sharedWorkspace iconForFile:a->path];
        NSRect r = NSMakeRect(0, 0, ICON_PX, ICON_PX);
        return a->icon = (__bridge id)[im CGImageForProposedRect:&r context:nil hints:nil];
    }
    if (!gIconIndex) mapIconCache();
    struct stat st; uint32_t mt = stat(a->path.fileSystemRepresentation, &st) ? 0 : (uint32_t)st.st_mtime;
    NSNumber *idx = gIconIndex[a->path];
    if (idx) {
        const IconRec *r = (const IconRec *)gIconMap + idx.unsignedLongValue;
        if (r->mtime == mt) return a->icon = CFBridgingRelease(iconImage(r->px, NO));
    }
    // miss: render through IconServices once, append to the cache file
    IconRec *r = calloc(1, sizeof(IconRec));
    strlcpy(r->path, a->path.fileSystemRepresentation, sizeof r->path);
    r->mtime = mt;
    static CGColorSpaceRef cs; if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(r->px, ICON_PX, ICON_PX, 8, ICON_PX * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:c flipped:NO];
    [[NSWorkspace.sharedWorkspace iconForFile:a->path] drawInRect:NSMakeRect(0, 0, ICON_PX, ICON_PX)];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(c);
    FILE *f = fopen(iconCachePath().fileSystemRepresentation, "ab");
    if (f) { fwrite(r, sizeof *r, 1, f); fclose(f); }
    a->icon = CFBridgingRelease(iconImage(r->px, YES));
    free(r);
    return a->icon;
}

static NSDictionary *attrs(CGFloat size, NSFontWeight w, NSColor *c) {
    static NSMutableParagraphStyle *ps;
    if (!ps) { ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail; }
    return @{NSFontAttributeName: [NSFont systemFontOfSize:size weight:w], NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps};
}
static void drawCentered(NSString *s, NSDictionary *a, NSRect r) {
    NSSize z = [s sizeWithAttributes:a];
    CGFloat w = MIN(z.width, r.size.width);
    [s drawWithRect:NSMakeRect(NSMidX(r) - w / 2, r.origin.y, w, z.height) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:a];
}
// keycap: small rounded chip with a glyph, drawn right-aligned ending at x. Returns left edge.
static CGFloat drawKeycap(NSString *g, CGFloat x, CGFloat midY) {
    NSDictionary *a = attrs(11, NSFontWeightMedium, NSColor.secondaryLabelColor);
    NSSize z = [g sizeWithAttributes:a];
    CGFloat w = MAX(20, z.width + 10);
    NSRect r = NSMakeRect(x - w, midY - 10, w, 20);
    [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5] fill];
    [g drawAtPoint:NSMakePoint(NSMidX(r) - z.width / 2, NSMidY(r) - z.height / 2) withAttributes:a];
    return x - w;
}
static CGFloat drawLabelRTL(NSString *s, NSDictionary *a, CGFloat x, CGFloat midY) {
    NSSize z = [s sizeWithAttributes:a];
    [s drawAtPoint:NSMakePoint(x - z.width, midY - z.height / 2) withAttributes:a];
    return x - z.width;
}

@implementation Canvas
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect lf = gR->list.frame;
    if (NSPointInRect(p, lf)) [gR->list clickAt:NSMakePoint(p.x - lf.origin.x, NSMaxY(lf) - p.y)];
}
- (void)scrollWheel:(NSEvent *)e { [gR->list scrollBy:e]; }
@end
static void needsRender(void) {
    if (!gR || gR->dirty) return;
    gR->dirty = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ if (gR->dirty) [gR render]; });   // skipped if rendered synchronously meanwhile
}

@implementation ListView
- (BOOL)isFlipped { return YES; }
- (CGFloat)yOf:(int)idx { CGFloat y = 6; for (int i = 0; i < idx; i++) y += rowHeight(gR->rows[i]); return y; }
- (CGFloat)contentHeight { return [self yOf:(int)gR->rows.count] + 6; }
- (void)reveal {
    if (gR->sel < 0 || gR->sel >= (int)gR->rows.count) { off = 0; return; }
    CGFloat y = [self yOf:gR->sel], h = rowHeight(gR->rows[gR->sel]), vh = self.bounds.size.height;
    if (gR->sel > 0 && gR->rows[gR->sel - 1]->kind == K_HEADER) y -= HH;      // keep the section header in view
    if (y < off + 6) off = MAX(0, y - 6);
    else if (y + h > off + vh - 6) off = y + h - vh + 6;
}
- (void)scrollBy:(NSEvent *)e {
    CGFloat d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12;
    off = MAX(0, MIN(off - d, [self contentHeight] - self.bounds.size.height));
    needsRender();
}
- (void)drawContent {
    [gIconSlots removeAllObjects];
    NSDictionary *hdr = attrs(12, NSFontWeightMedium, NSColor.secondaryLabelColor);
    NSDictionary *ttl = attrs(14, NSFontWeightRegular, NSColor.labelColor);
    NSDictionary *sub = attrs(13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSDictionary *acc = attrs(13, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    NSDictionary *big = attrs(22, NSFontWeightMedium, NSColor.labelColor);
    NSDictionary *cap = attrs(12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSDictionary *gly = attrs(13, NSFontWeightSemibold, NSColor.whiteColor);
    CGFloat y = 6 - off, vh = self.bounds.size.height;
    NSArray<Item *> *rows = gR->rows;
    for (int i = 0; i < (int)rows.count; i++) {
        Item *it = rows[i];
        CGFloat h = rowHeight(it);
        if (y + h < 0 || y > vh) { y += h; continue; }
        if (it->kind == K_HEADER) {
            [it->title drawAtPoint:NSMakePoint(20, y + 11) withAttributes:hdr];
            y += h; continue;
        }
        NSRect row = NSMakeRect(8, y, W - 16, h);
        if (i == gR->sel) {
            [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:row xRadius:8 yRadius:8] fill];
        }
        if (it->kind == K_CALC || it->kind == K_INFO) {
            // two-sided card:  lhs   (→)   rhs
            CGFloat mid = NSMidX(row), half = row.size.width / 2;
            [[NSColor.labelColor colorWithAlphaComponent:0.10] setFill];
            NSRectFillUsingOperation(NSMakeRect(mid - 0.5, y + 14, 1, h - 28), NSCompositingOperationSourceOver);
            NSRect circ = NSMakeRect(mid - 14, y + h / 2 - 14, 28, 28);
            [(i == gR->sel ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor) setFill];
            [[NSBezierPath bezierPathWithOvalInRect:circ] fill];
            [[NSColor.labelColor colorWithAlphaComponent:0.15] setStroke];
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circ, 0.5, 0.5)] stroke];
            drawCentered(@"→", attrs(14, NSFontWeightMedium, NSColor.secondaryLabelColor), NSMakeRect(circ.origin.x, circ.origin.y + 5, 28, 18));
            NSRect L = NSMakeRect(row.origin.x + 24, y + 26, half - 56, 30), Rr = NSMakeRect(mid + 32, y + 26, half - 56, 30);
            drawCentered(it->lhs ?: @"", big, L);
            drawCentered(it->title ?: @"", big, Rr);
            drawCentered(it->lhsCap ?: @"", cap, NSOffsetRect(L, 0, 36));
            drawCentered(it->sub ?: @"", cap, NSOffsetRect(Rr, 0, 36));
            y += h; continue;
        }
        NSRect ic = NSMakeRect(20, y + 8, 24, 24);
        if (it->app) {
            if (y + 8 >= 0 && y + 32 <= vh) [gIconSlots addObject:@[it->app, [NSValue valueWithRect:ic]]];   // icons are colour: own layers
        } else {
            [NSColor.controlAccentColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(ic, 1, 1) xRadius:6 yRadius:6] fill];
            if ([it->glyph isEqual:@"⌕"]) {   // Search Files: a drawn magnifier (the text glyph renders tiny)
                [NSColor.whiteColor set];
                NSBezierPath *g = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(ic.origin.x + 6.5, ic.origin.y + 6.5, 8.5, 8.5)];
                [g moveToPoint:NSMakePoint(ic.origin.x + 13.8, ic.origin.y + 13.8)]; [g lineToPoint:NSMakePoint(ic.origin.x + 17.5, ic.origin.y + 17.5)];
                g.lineWidth = 2; g.lineCapStyle = NSLineCapStyleRound; [g stroke];
            } else drawCentered(it->glyph ?: @"", gly, NSMakeRect(ic.origin.x, ic.origin.y + 3, 24, 18));
        }
        // right accessory: hotkey chips for bound apps, otherwise the item type
        CGFloat right = W - 24;
        Binding *b = it->app ? [gR bindingFor:it->app->path] : nil;
        if (b) {
            NSString *c = comboString(b->key, b->mods, YES);
            NSMutableArray *parts = [NSMutableArray array];
            NSString *glyphs = @"⌃⌥⇧⌘";
            NSUInteger k = 0;
            while (k < c.length && [glyphs rangeOfString:[c substringWithRange:NSMakeRange(k, 1)]].location != NSNotFound) { [parts addObject:[c substringWithRange:NSMakeRange(k, 1)]]; k++; }
            [parts addObject:[c substringFromIndex:k]];
            for (NSString *pt in parts.reverseObjectEnumerator) right = drawKeycap(pt, right, y + h / 2) - 4;
        } else {
            right = drawLabelRTL(it->kind == K_APP ? @"Application" : it->kind == K_FILE ? (it->glyph ?: it->app->dir ? @"Folder" : @"File") : @"Command", acc, right, y + h / 2) - 12;
        }
        NSSize ts = [it->title sizeWithAttributes:ttl];
        CGFloat tw = MIN(ts.width, right - 56);
        [it->title drawWithRect:NSMakeRect(56, y + (h - ts.height) / 2, tw, ts.height) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:ttl];
        if (it->sub.length && 56 + tw + 10 < right) {
            NSSize ss = [it->sub sizeWithAttributes:sub];
            [it->sub drawWithRect:NSMakeRect(56 + tw + 10, y + (h - ss.height) / 2, right - (56 + tw + 10), ss.height) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:sub];
        }
        y += h;
    }
}
- (void)clickAt:(NSPoint)p {
    CGFloat y = 6 - off;
    for (int i = 0; i < (int)gR->rows.count; i++) {
        CGFloat h = rowHeight(gR->rows[i]);
        if (p.y >= y && p.y < y + h) {
            if (gR->rows[i]->kind == K_HEADER) return;
            gR->sel = i; needsRender();
            [gR activateSelected];
            return;
        }
        y += h;
    }
}
@end

@implementation Footer
- (void)drawContent {
    CGFloat mid = FT / 2;
    NSDictionary *lbl = attrs(12, NSFontWeightMedium, NSColor.labelColor);
    NSDictionary *dim = attrs(12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    // left: status (the colour logo mark is its own small layer)
    Item *it = (gR->sel >= 0 && gR->sel < (int)gR->rows.count) ? gR->rows[gR->sel] : nil;
    NSString *status = gR->recording ? @"Recording hotkey…" : gFetching ? @"Updating exchange rates…"
                     : gR->searching ? (gR->dig ? (gR->fileRows.count ? @"Searching by meaning…" : @"Searching…") : @"Searching files…") : nil;
    if (!status && gR->fileMode) status = gR->dig ? @"⇥  Spotlight" : digupBinary() && digupPref(@"roots").count ? @"⇥  DigUp" : @"⇥  Search inside files with DigUp";
    if (status) [status drawAtPoint:NSMakePoint(40, mid - 8) withAttributes:dim];
    // right: primary action ↩ | secondary action ⌘K
    CGFloat x = W - 14;
    if (gR->recording) {
        x = drawKeycap(@"esc", x, mid) - 6; x = drawLabelRTL(@"Cancel", dim, x, mid) - 12;
        x = drawKeycap(@"⌫", x, mid) - 6; drawLabelRTL(@"Remove Hotkey", dim, x, mid);
        return;
    }
    if (!it) return;
    if (it->kind == K_APP) {
        x = drawKeycap(@"K", x, mid) - 3; x = drawKeycap(@"⌘", x, mid) - 6;
        x = drawLabelRTL([gR bindingFor:it->app->path] ? @"Change Hotkey" : @"Set Hotkey", dim, x, mid) - 10;
        [[NSColor.labelColor colorWithAlphaComponent:0.15] setFill]; NSRectFillUsingOperation(NSMakeRect(x, mid - 7, 1, 14), NSCompositingOperationSourceOver); x -= 10;
    }
    if (it->kind == K_FILE) {
        x = drawKeycap(@"↩", x, mid) - 3; x = drawKeycap(@"⌘", x, mid) - 6;
        x = drawLabelRTL(@"Show in Finder", dim, x, mid) - 10;
        [[NSColor.labelColor colorWithAlphaComponent:0.15] setFill]; NSRectFillUsingOperation(NSMakeRect(x, mid - 7, 1, 14), NSCompositingOperationSourceOver); x -= 10;
    }
    NSString *primary = it->kind == K_APP ? @"Open Application" : it->kind == K_CALC ? @"Copy Answer" : it->kind == K_ACTION ? @"Run Command" : it->kind == K_FILE ? @"Open" : nil;
    if (primary) { x = drawKeycap(@"↩", x, mid) - 6; drawLabelRTL(primary, lbl, x, mid); }
}
@end

static int scoreMatch(const char *name, const char *q) {
    if (!*q) return 0;
    int len = (int)strlen(name);
    const char *p = strstr(name, q);
    if (p == name) return 1000 - len;
    if (p && (p[-1] == ' ' || p[-1] == '-' || p[-1] == '.')) return 800 - len;
    if (p) return 600 - len;
    // subsequence with word-start bonuses (e.g. "vsc" -> "visual studio code")
    int s = 300 - len; const char *n = name; BOOL prevHit = NO;
    for (const char *c = q; *c; c++) {
        if (*c == ' ') continue;
        const char *f = n;
        while (*f && *f != *c) f++;
        if (!*f) return 0;
        BOOL wordStart = (f == name || f[-1] == ' ' || f[-1] == '-');
        s += wordStart ? 20 : (prevHit && f == n ? 8 : -3);
        prevHit = YES; n = f + 1;
    }
    return s;
}

@implementation R

- (Binding *)bindingFor:(NSString *)path {
    for (Binding *b in gBinds) if ([b->path isEqual:path]) return b;
    return nil;
}

#pragma mark apps

// Usage file: app path -> [score, last opened (CFAbsoluteTime)]. Every open adds 1 to the score, and the score halves
// every 14 days, so what you open now outranks what you opened a lot last month. (Old files held plain counts.)
static const double USAGE_HALF_LIFE = 14 * 86400;
static NSDictionary *loadUsage(void) { return [NSDictionary dictionaryWithContentsOfFile:usagePath()] ?: @{}; }
static double usageScore(id rec, double now) {
    if ([rec isKindOfClass:NSNumber.class]) return [rec doubleValue];   // legacy count: treat as opened just now
    if (![rec isKindOfClass:NSArray.class] || [rec count] < 2) return 0;
    return [rec[0] doubleValue] * exp2(-MAX(0, now - [rec[1] doubleValue]) / USAGE_HALF_LIFE);
}

static void scanDir(NSMutableArray *out, NSMutableSet *seen, const char *dir, int depth) {
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        size_t n = strlen(e->d_name);
        char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        if (n > 4 && !strcmp(e->d_name + n - 4, ".app")) {
            NSString *name = [[NSString alloc] initWithBytes:e->d_name length:n - 4 encoding:NSUTF8StringEncoding];
            if (!name || [seen containsObject:name]) continue;
            [seen addObject:name];
            App *a = [App new]; a->name = name; a->path = @(p);
            strlcpy(a->lname, name.lowercaseString.UTF8String, sizeof a->lname);
            [out addObject:a];
        } else if (depth > 0 && (e->d_type == DT_DIR || e->d_type == DT_LNK)) scanDir(out, seen, p, depth - 1);
    }
    closedir(d);
}
- (void)scanApps {
    NSMutableDictionary *old = [NSMutableDictionary dictionary];
    for (App *a in apps) old[a->path] = a;
    NSMutableArray *out = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    char ua[PATH_MAX]; snprintf(ua, sizeof ua, "%s/Applications", NSHomeDirectory().fileSystemRepresentation);
    scanDir(out, seen, "/Applications", 2);
    scanDir(out, seen, "/System/Applications", 1);
    scanDir(out, seen, ua, 2);
    scanDir(out, seen, "/System/Library/CoreServices/Applications", 0);
    if (![seen containsObject:@"Finder"]) {
        App *a = [App new]; a->name = @"Finder"; a->path = @"/System/Library/CoreServices/Finder.app"; strcpy(a->lname, "finder"); [out addObject:a];
    }
    NSDictionary *usage = loadUsage();
    double now = CFAbsoluteTimeGetCurrent();
    for (NSUInteger i = 0; i < out.count; i++) {
        App *a = out[i], *o = old[a->path];
        if (o) { out[i] = o; continue; }
        a->uses = usageScore(usage[a->path], now);
    }
    apps = out;
    lastScan = CFAbsoluteTimeGetCurrent();
}

#pragma mark lifecycle

- (void)snapshot {
    NSString *snapBase = @(getenv("RF_SNAP"));
    if (!shown) [self show];
    NSString *q = [NSString stringWithContentsOfFile:[snapBase stringByAppendingString:@".q"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    q = [q stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSArray *parts = [q componentsSeparatedByString:@"|"];           // "query|down|down|cmdk|enter"
    if (![parts[0] isEqual:@"@same"]) {   // "@same" re-renders the current state (e.g. after async file results)
        [self leaveFileMode]; setupMode = NO;
        field.stringValue = parts[0];
        [self refresh];
    }
    for (NSString *p in [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]) {
        if ([p isEqual:@"down"]) [self moveSel:1];
        if ([p isEqual:@"cmdk"]) [self startRecording];
        if ([p isEqual:@"enter"]) [self activateSelected];
        if ([p isEqual:@"tab"] && fileMode) [self switchProvider];
        if ([p hasPrefix:@"q="]) { field.stringValue = [p substringFromIndex:2]; [self refresh]; }   // type, staying in file mode
    }
    if ([parts containsObject:@"nopng"]) return;
    [self render];
    IOSurfaceRef s = surf[cur];
    size_t pw = IOSurfaceGetWidth(s), ph = IOSurfaceGetHeight(s);
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB), gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    CGContextRef out = CGBitmapContextCreate(NULL, pw, ph, 8, 0, rgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    CGContextRef g = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), pw, ph, 8, IOSurfaceGetBytesPerRow(s), gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGImageRef gi = CGBitmapContextCreateImage(g);
    CGContextDrawImage(out, CGRectMake(0, 0, pw, ph), gi);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    CGContextScaleCTM(out, scale, scale);
    for (CALayer *l in [iconLayers arrayByAddingObject:logo]) if (!l.hidden && l.contents) CGContextDrawImage(out, l.frame, (__bridge CGImageRef)l.contents);
    if (!caret.hidden) { CGContextSetFillColorWithColor(out, caret.backgroundColor); CGContextFillRect(out, caret.frame); }
    CGImageRef img = CGBitmapContextCreateImage(out);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[snapBase stringByAppendingString:@".png"] atomically:YES];
    CGImageRelease(img); CGImageRelease(gi); CGContextRelease(g); CGContextRelease(out); CGColorSpaceRelease(rgb); CGColorSpaceRelease(gray);
}

- (void)makePanel {
    panel = [[Panel alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                     styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                       backing:NSBackingStoreBuffered defer:YES];
    panel.level = NSStatusWindowLevel;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
    panel.delegate = self;
    canvas = [[Canvas alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    canvas.wantsLayer = YES;
    panel.contentView = canvas;
    CALayer *root = canvas.layer;
    root.cornerRadius = 12; root.masksToBounds = YES;
    base = [CALayer layer]; base.frame = root.bounds; base.anchorPoint = CGPointZero; base.position = CGPointZero;
    base.actions = @{@"contents": NSNull.null};
    [root addSublayer:base];
    iconLayers = [NSMutableArray array];
    logo = [CALayer layer]; logo.frame = CGRectMake(16, FT / 2 - 8, 16, 16); logo.cornerRadius = 4; logo.masksToBounds = YES;
    logo.contents = [self logoImage];
    [root addSublayer:logo];
    caret = [CALayer layer]; caret.backgroundColor = NSColor.controlAccentColor.CGColor; caret.cornerRadius = 1;
    caret.actions = @{@"position": NSNull.null, @"bounds": NSNull.null, @"hidden": NSNull.null};
    [root addSublayer:caret];
    chrome = [[Chrome alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    field = [[QueryView alloc] initWithFrame:NSMakeRect(20, H - SH + 15, W - 40, 26)];
    __weak R *ws = self;
    field->onChange = ^{ R *s = ws; if (s && !s->recording) { s->setupMode = NO; [s refresh]; } };   // typing leaves the setup screen
    [canvas addSubview:field];   // in the window for keyboard focus only; it never draws
    list = [[ListView alloc] initWithFrame:NSMakeRect(0, FT + 1, W, H - SH - FT - 1)];
    footer = [[Footer alloc] initWithFrame:NSMakeRect(0, 0, W, FT)];
}
- (id)logoImage {
    NSImage *im = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:NSColor.systemPinkColor endingColor:NSColor.systemOrangeColor];
        [g drawInRect:r angle:-45];
        drawCentered(@"r", attrs(11, NSFontWeightHeavy, NSColor.whiteColor), NSMakeRect(0, 0.5, 16, 14));
        return YES;
    }];
    return (__bridge id)[im CGImageForProposedRect:NULL context:nil hints:@{NSImageHintCTM: [NSAffineTransform transform]}];
}
static void drawView(NSView *v, CGContextRef c) {
    NSRect f = v.frame;
    CGContextSaveGState(c);
    CGContextClipToRect(c, f);
    CGContextTranslateCTM(c, f.origin.x, f.origin.y);
    if (v.isFlipped) { CGContextTranslateCTM(c, 0, f.size.height); CGContextScaleCTM(c, 1, -1); }
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:c flipped:v.isFlipped];
    [(id)v drawContent];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(c);
}
// Paint everything gray into the back surface, then swap it in and position the colour layers.
- (void)render {
    if (!panel) return;
    dirty = NO;
    CGFloat sc = panel.backingScaleFactor ?: 2;
    if (sc != scale || !surf[0]) {
        for (int i = 0; i < 2; i++) if (surf[i]) CFRelease(surf[i]);
        scale = sc;
        for (int i = 0; i < 2; i++)
            surf[i] = IOSurfaceCreate((__bridge CFDictionaryRef)@{
                (id)kIOSurfaceWidth: @(W * sc), (id)kIOSurfaceHeight: @(H * sc), (id)kIOSurfaceBytesPerElement: @1,
                (id)kIOSurfacePixelFormat: [NSNumber numberWithUnsignedInt:'L008']});
        base.contentsScale = sc;
    }
    IOSurfaceRef s = surf[cur ^= 1];
    IOSurfaceLock(s, 0, NULL);
    static CGColorSpaceRef gray; if (!gray) gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    CGContextRef c = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), 8,
                                           IOSurfaceGetBytesPerRow(s), gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextScaleCTM(c, sc, sc);
    [panel.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:c flipped:NO];
        [chrome drawContent];
        [NSGraphicsContext restoreGraphicsState];
        drawView(field, c); drawView(list, c); drawView(footer, c);
    }];
    CGContextRelease(c);
    IOSurfaceUnlock(s, 0, NULL);

    [CATransaction begin]; [CATransaction setDisableActions:YES];
    base.contents = (__bridge id)s;
    NSRect lf = list.frame;
    NSUInteger n = 0;
    for (NSArray *slot in gIconSlots) {
        if (n == iconLayers.count) {
            CALayer *l = [CALayer layer]; l.actions = @{@"contents": NSNull.null, @"position": NSNull.null, @"bounds": NSNull.null, @"hidden": NSNull.null};
            [iconLayers addObject:l]; [canvas.layer insertSublayer:l above:base];
        }
        CALayer *l = iconLayers[n++];
        NSRect r = [slot[1] rectValue];   // list coords (flipped)
        l.frame = CGRectMake(lf.origin.x + r.origin.x, NSMaxY(lf) - NSMaxY(r), r.size.width, r.size.height);
        l.contents = iconFor(slot[0]);
        l.hidden = NO;
    }
    for (; n < iconLayers.count; n++) iconLayers[n].hidden = YES;
    BOOL showCaret = !recording && !field->sel.length;
    caret.hidden = !showCaret;
    if (showCaret) {
        caret.frame = CGRectMake(NSMinX(field.frame) + field.caretX, NSMaxY(field.frame) - 24, 2, 22);
        // blink runs in the render server (no redraws); re-armed each render so the caret is solid while typing
        CAKeyframeAnimation *blink = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        blink.values = @[@1, @0]; blink.keyTimes = @[@0, @0.5, @1]; blink.calculationMode = kCAAnimationDiscrete;
        blink.duration = 1.06; blink.repeatCount = HUGE_VALF; blink.removedOnCompletion = NO;
        blink.beginTime = [caret convertTime:CACurrentMediaTime() fromLayer:nil] + 0.5;
        [caret addAnimation:blink forKey:@"blink"];
    }
    [CATransaction commit];
}
// The launcher always opens in this state: empty query, fresh config and app list, frame already rendered.
- (void)resetToIdle {
    rfReloadConfigIfChanged(); cfgSeen = mtimeOf(cfgPath());
    if (!apps || CFAbsoluteTimeGetCurrent() - lastScan > 30) [self scanApps];
    recording = nil;
    [self leaveFileMode];
    setupMode = NO; setupNote = nil;
    field.stringValue = @"";
    [self refresh];
    [self render];
}
- (BOOL)idleIsFresh { return prepared && mtimeOf(cfgPath()) == cfgSeen && CFAbsoluteTimeGetCurrent() - lastScan <= 30; }
// Run once at startup (and after every respawn): render and show the window once, invisibly and off-screen,
// so the window server's ~20 ms first-show cost is paid before anyone presses the hotkey.
- (void)preShow {
    [self resetToIdle];
    panel.alphaValue = 0;
    [panel setFrameOrigin:NSMakePoint(-20000, -20000)];
    [panel orderFront:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [panel orderOut:nil]; panel.alphaValue = 1;
        prepared = YES;
        malloc_zone_pressure_relief(NULL, 0);
    });
}
- (void)toggleLauncher { if (shown) [self hide]; else [self show]; }
- (NSPoint)homeOrigin {
    NSScreen *scr = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(NSEvent.mouseLocation, s.frame, NO)) scr = s;
    NSRect sf = scr.frame;
    return NSMakePoint(round(NSMidX(sf) - W / 2), round(NSMaxY(sf) - sf.size.height * 0.24 - H));
}
- (void)show {
    if (!panel) [self makePanel];
    if (![self idleIsFresh]) [self resetToIdle];   // normally already done when the window last hid
    prepared = NO;
    shown = YES;
    NSPoint o = [self homeOrigin];
    if (!NSEqualPoints(panel.frame.origin, o)) [panel setFrameOrigin:o];
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:field];
    if (getenv("RF_DEBUG")) {   // hotkey→commit latency; tests/breakdown.sh lines these up with screen captures
        [CATransaction flush];
        uint64_t now = mach_absolute_time(); mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        fprintf(stderr, "[%d] shown in %.1f ms  hk=%llu committed=%llu\n", getpid(), (now - gHotkeyAt) * tb.numer / tb.denom / 1e6, gHotkeyAt, now);
    }
}
// Hiding keeps the window for an instant re-open and re-renders its empty state right away. A few seconds
// later the process re-execs itself, dropping the heap that using the window fragmented.
- (void)hide {
    if (hiding || !shown) return;
    hiding = YES; shown = NO;
    recording = nil;
    [self digupStop];       // before the respawn: the helper is this launcher session's child
    [panel orderOut:nil];   // also hands keyboard focus back to the previous app
    hiding = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ if (!shown && panel) { [self resetToIdle]; prepared = YES; } });
    static int gen; int my = ++gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (my == gen && !shown && !gFetching) rfRespawn();
    });
}
- (void)windowDidResignKey:(NSNotification *)n { if (shown) [self hide]; }

- (void)redraw { needsRender(); }

- (void)refresh {
    prepared = NO;
    NSString *q = field.stringValue;
    NSMutableArray<Item *> *out = [NSMutableArray array];
    const char *lq = trim(q.lowercaseString).UTF8String;
    if (setupMode) {
        BOOL installed = digupBinary() != nil;
        Item *card = mkCalc(@"Search inside files", @"photos, PDFs, documents, recordings, video",
                            @"DigUp", installed ? @"installed · choose its folders to finish" : @"free, on-device · 9 MB app + 865 MB model", nil);
        card->kind = K_INFO;
        [out addObject:mkItem(K_HEADER, setupNote ?: @"Set Up DigUp", nil, nil, nil)];
        [out addObject:card];
        Item *go = installed ? mkItem(K_ACTION, @"Open DigUp to Choose Folders", @"then Search Files uses it", nil, @"⌕")
                 : installTask.running ? mkItem(K_ACTION, @"Installing…", @"from github.com/ARahim3/DigUp", nil, @"⌕")
                 : mkItem(K_ACTION, @"Install DigUp", @"from github.com/ARahim3/DigUp · then pick folders in it", nil, @"⌕");
        go->action = installed ? @selector(openDigup) : installTask.running ? NULL : @selector(installDigup);
        [out addObject:go];
        Item *no = mkItem(K_ACTION, @"Not Now", @"Search Files keeps using Spotlight", nil, @"✦"); no->action = @selector(cancelSetup);
        [out addObject:no];
        rows = out; sel = 2; list->off = 0;
        [self redraw];
        return;
    }
    if (fileMode) {
        [self searchFiles:trim(q)];
        NSString *src = dig ? @"DigUp" : @"Spotlight";
        NSString *hdr = fileNote ?: !*lq ? src : searching && !fileRows.count ? @"Searching…" : fileRows.count ? src : @"No Files Found";
        [out addObject:mkItem(K_HEADER, hdr, nil, nil, nil)];
        [out addObjectsFromArray:fileRows ?: @[]];
    } else if (!*lq) {
        // empty query: most-used apps
        NSArray *top = [apps sortedArrayUsingComparator:^NSComparisonResult(App *a, App *b) {
            return a->uses != b->uses ? (a->uses > b->uses ? NSOrderedAscending : NSOrderedDescending) : [a->name localizedCaseInsensitiveCompare:b->name];
        }];
        [out addObject:mkItem(K_HEADER, @"Suggestions", nil, nil, nil)];
        for (NSUInteger i = 0; i < MIN(8u, top.count); i++) { Item *it = mkItem(K_APP, ((App *)top[i])->name, nil, nil, nil); it->app = top[i]; [out addObject:it]; }
    } else {
        Item *c = convertQuery(q);
        if (c) { [out addObject:mkItem(K_HEADER, @"Calculator", nil, nil, nil)]; [out addObject:c]; }
        NSMutableArray *scored = [NSMutableArray array];
        for (App *a in apps) {
            int s = scoreMatch(a->lname, lq);
            if (s > 0) [scored addObject:@[@(s + MIN(a->uses, 30) * 12), a]];
        }
        [scored sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) { return [y[0] compare:x[0]]; }];
        BOOL header = NO;
        for (NSUInteger i = 0; i < MIN((NSUInteger)MAXAPPS, scored.count); i++) {
            if (!header) { [out addObject:mkItem(K_HEADER, @"Results", nil, nil, nil)]; header = YES; }
            App *a = scored[i][1];
            Item *it = mkItem(K_APP, a->name, nil, nil, nil); it->app = a;
            [out addObject:it];
        }
        const struct { const char *t, *s, *kw; SEL sel; } acts[] = {
            {"Edit Config", "rayfast", "rayfast config settings hotkeys preferences", @selector(openConfig)},
            {"Quit", "rayfast", "quit rayfast exit", @selector(quit)},
            {"Use DigUp for File Search", "rayfast", "digup file search provider contents meaning", @selector(useDigupForFiles)},
            {"Use Spotlight for File Search", "rayfast", "spotlight file search provider names", @selector(useSpotlightForFiles)},
            {"Set Up DigUp", "search inside files", "set up setup digup install search inside files contents", @selector(showDigupSetup)}};
        for (size_t i = 0; i < sizeof acts / sizeof *acts; i++) {
            if (strlen(lq) < 3 || !strstr(acts[i].kw, lq)) continue;
            if (acts[i].sel == @selector(useDigupForFiles) && (!digupBinary() || [gFiles isEqual:@"digup"])) continue;
            if (acts[i].sel == @selector(useSpotlightForFiles) && [gFiles isEqual:@"spotlight"]) continue;
            if (acts[i].sel == @selector(showDigupSetup) && digupBinary() && digupPref(@"roots").count) continue;   // already set up
            if (!header) { [out addObject:mkItem(K_HEADER, @"Results", nil, nil, nil)]; header = YES; }
            Item *it = mkItem(K_ACTION, @(acts[i].t), @(acts[i].s), nil, @"✦"); it->action = acts[i].sel;
            [out addObject:it];
        }
        // fallback, like Raycast's: always last, so it's the selected row when nothing else matched
        NSString *tq = trim(q);
        if (tq.length > 32) tq = [[tq substringToIndex:31] stringByAppendingString:@"…"];
        [out addObject:mkItem(K_HEADER, [NSString stringWithFormat:@"Use “%@” with…", tq], nil, nil, nil)];
        Item *fs = mkItem(K_ACTION, @"Search Files", wantDigup() ? @"DigUp" : @"Spotlight", nil, @"⌕"); fs->action = @selector(enterFileMode);
        [out addObject:fs];
    }
    rows = out;
    sel = -1;
    for (int i = 0; i < (int)rows.count; i++) if (rows[i]->kind != K_HEADER) { sel = i; break; }
    list->off = 0;
    [self redraw];
}
#pragma mark file search
static NSString *const DIGUP_ID = @"com.abdurrahim.DigUp";
// nil when DigUp isn't installed: everything DigUp-related then hides itself and file search is Spotlight's.
static NSString *digupBinary(void) {
    NSArray *candidates = getenv("RF_DIGUP") ? @[@(getenv("RF_DIGUP"))]   // tests (a missing path = not installed)
        : @[@"/Applications/DigUp.app/Contents/Helpers/digup", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DigUp.app/Contents/Helpers/digup"]];
    for (NSString *p in candidates) if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    return nil;
}
// DigUp's own settings (its folders, skipped folders and types, index location), read from its preferences so
// rayfast searches exactly what DigUp indexes. Lists are plist arrays or ":"-joined paths, as DigUp reads them.
static id digupPrefValue(NSString *key) {
    const char *env = getenv([@"RF_DIGUP_" stringByAppendingString:key].UTF8String);   // tests: RF_DIGUP_roots, RF_DIGUP_indexDir
    if (env) return @(env);
    CFPreferencesAppSynchronize((__bridge CFStringRef)DIGUP_ID);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)DIGUP_ID));
}
static NSString *digupPrefString(NSString *key) { id v = digupPrefValue(key); return [v isKindOfClass:NSString.class] ? [v stringByExpandingTildeInPath] : nil; }
static NSArray<NSString *> *digupPref(NSString *key) {
    id v = digupPrefValue(key);
    NSArray *list = [v isKindOfClass:NSArray.class] ? v : [v isKindOfClass:NSString.class] && [v length] ? [v componentsSeparatedByString:@":"] : @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id x in list) if ([x isKindOfClass:NSString.class] && [x length]) [out addObject:[x stringByExpandingTildeInPath]];
    return out;
}
static BOOL wantDigup(void) {
    if ([gFiles isEqual:@"spotlight"] || !digupBinary()) return NO;
    return [gFiles isEqual:@"digup"] || digupPref(@"roots").count > 0;   // auto: only once DigUp has folders to search
}
// Spotlight via /usr/bin/mdfind, out of process like curl: the Metadata framework never loads into rayfast.
- (void)enterFileMode {
    fileMode = YES; fileQuery = nil; fileRows = nil; fileNote = nil;
    dig = wantDigup();
    gPlaceholder = dig ? @"Describe what's in the file…" : @"Search files…";
    if (dig) [self digupStart];   // index open + encoder warming while you type
    [self refresh];
}
// ⇥ in file results: the other provider, remembered in the config
- (void)switchProvider {
    if (!digupBinary() || (!dig && !digupPref(@"roots").count)) { [self showDigupSetup]; return; }   // not set up yet: offer it
    gFiles = dig ? @"spotlight" : @"digup";
    rfSaveConfig();
    NSString *q = field.stringValue;
    [self leaveFileMode];
    [self enterFileMode];
    field.stringValue = q;
    [self refresh];
}
- (void)setFilesProvider:(NSString *)f { gFiles = f; rfSaveConfig(); [self refresh]; }
- (void)useDigupForFiles { [self setFilesProvider:@"digup"]; }
- (void)useSpotlightForFiles { [self setFilesProvider:@"spotlight"]; }
- (void)leaveFileMode {
    fileGen++; [mdTask terminate]; mdTask = nil;
    fileMode = searching = NO; fileQuery = nil; fileRows = nil; fileNote = nil;
    gPlaceholder = @"Search for apps and conversions…";
}
- (void)searchFiles:(NSString *)q {
    if ([q isEqual:fileQuery]) return;
    fileQuery = q;
    int my = ++fileGen;
    [mdTask terminate]; mdTask = nil;
    if (!q.length) { fileRows = nil; searching = NO; return; }
    searching = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{   // debounce typing
        if (my != fileGen || !fileMode) return;
        if (dig) [self runDigup:q gen:my]; else [self runMdfind:q gen:my];
    });
}
// Lower is better: name starts with the query, then a word in the name does, then anywhere.
static int fileNameRank(NSString *name, NSArray<NSString *> *words) {
    NSString *l = name.lowercaseString; int r = 0;
    for (NSString *w in words) {
        NSRange f = [l rangeOfString:w];
        if (f.location == 0) continue;
        unichar p = f.location != NSNotFound ? [l characterAtIndex:f.location - 1] : 0;
        r += (p == ' ' || p == '-' || p == '_' || p == '.') ? 1 : 2;
    }
    return r;
}
- (void)runMdfind:(NSString *)q gen:(int)my {
    NSMutableArray *terms = [NSMutableArray array], *words = [NSMutableArray array];
    for (NSString *w in [q.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (!w.length) continue;
        [words addObject:w];
        NSMutableString *e = [NSMutableString string];
        for (NSUInteger i = 0; i < w.length; i++) {
            unichar ch = [w characterAtIndex:i];
            if (ch == '"' || ch == '\\' || ch == '*' || ch == '\'') [e appendString:@"\\"];
            [e appendFormat:@"%C", ch];
        }
        [terms addObject:[NSString stringWithFormat:@"kMDItemFSName == \"*%@*\"cd", e]];
    }
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/mdfind"];
    t.arguments = @[@"-onlyin", NSHomeDirectory(), @"-attr", @"kMDItemLastUsedDate", [terms componentsJoinedByString:@" && "]];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe; t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil]) { searching = NO; [self refresh]; return; }
    mdTask = t;
    NSString *home = NSHomeDirectory();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // read at most 2 MB (a one-letter query can match most of the disk), then stop mdfind
        NSMutableData *buf = [NSMutableData data]; NSFileHandle *fh = pipe.fileHandleForReading; NSData *chunk;
        while ((chunk = fh.availableData).length) { [buf appendData:chunk]; if (buf.length > (2 << 20)) { [t terminate]; break; } }
        NSString *out = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
        NSMutableArray *hits = [NSMutableArray array];
        NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss Z"; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSRange a = [line rangeOfString:@"   kMDItemLastUsedDate = " options:NSBackwardsSearch];
            NSString *path = a.location == NSNotFound ? line : [line substringToIndex:a.location];
            if (!path.length || ![path hasPrefix:home]) continue;
            NSString *rel = [path substringFromIndex:home.length];
            if ([rel hasPrefix:@"/Library/"] || [rel containsString:@"/."] || [rel containsString:@"/node_modules/"] || [rel containsString:@"/vendor/"] ||
                [rel containsString:@"/site-packages/"] || [rel containsString:@"/Pods/"] ||
                [rel containsString:@".app/"] || [rel hasSuffix:@".app"]) continue;
            NSDate *used = a.location == NSNotFound ? nil : [df dateFromString:[line substringFromIndex:NSMaxRange(a)]];
            [hits addObject:@[@(fileNameRank(path.lastPathComponent, words)), @(-(used ? used.timeIntervalSince1970 : 0)), @(path.length), path]];
        }
        [hits sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) {
            for (int i = 0; i < 3; i++) { NSComparisonResult r = [x[i] compare:y[i]]; if (r) return r; }
            return NSOrderedSame;
        }];
        if (hits.count > 50) [hits removeObjectsInRange:NSMakeRange(50, hits.count - 50)];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (my != fileGen || !fileMode) return;
            NSMutableArray *rowsOut = [NSMutableArray array];
            for (NSArray *h in hits) {
                NSString *path = h[3];
                App *f = [App new]; f->file = YES; f->path = path; f->name = path.lastPathComponent;
                BOOL isDir = NO; [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir]; f->dir = isDir;
                Item *it = mkItem(K_FILE, f->name, path.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath, nil, nil);
                it->app = f;
                [rowsOut addObject:it];
            }
            fileRows = rowsOut; searching = NO; mdTask = nil;
            [self refresh];
        });
    });
}
#pragma mark DigUp setup
// One screen, one key: ↩ installs DigUp from its GitHub release (signature and developer team checked) and opens it;
// DigUp's own onboarding then downloads its model and asks which folders to read. rayfast's `files = auto` switches
// to DigUp by itself once it has folders. Already installed but not set up: ↩ just opens DigUp.
static const char *DIGUP_INSTALL_SH =
    "log=\"$HOME/Library/Caches/rayfast-digup-install.log\"; exec >\"$log\" 2>&1; set -u\n"
    "fail() { echo \"FAILED: $1\"; osascript -e \"display notification \\\"$1. Details: ~/Library/Caches/rayfast-digup-install.log\\\" with title \\\"rayfast couldn't install DigUp\\\"\"; exit 1; }\n"
    "api=$(curl -fsSL -m 20 https://api.github.com/repos/ARahim3/DigUp/releases/latest) || fail \"GitHub couldn't be reached\"\n"
    "url=$(printf '%s' \"$api\" | grep -o 'https://github.com/ARahim3/DigUp/releases/download/[^\"]*\\.dmg' | head -1)\n"
    "[ -n \"$url\" ] || fail \"No DigUp download in its latest release\"\n"
    "tmp=$(mktemp -d); mnt=\"$tmp/mnt\"; mkdir \"$mnt\"\n"
    "trap 'hdiutil detach \"$mnt\" -quiet 2>/dev/null; rm -rf \"$tmp\"' EXIT\n"
    "echo \"downloading $url\"; curl -fsSL -m 600 -o \"$tmp/DigUp.dmg\" \"$url\" || fail \"The download failed\"\n"
    "hdiutil attach -nobrowse -readonly -mountpoint \"$mnt\" \"$tmp/DigUp.dmg\" >/dev/null || fail \"The disk image didn't open\"\n"
    "app=\"$mnt/DigUp.app\"; [ -d \"$app\" ] || fail \"No DigUp.app in the disk image\"\n"
    "codesign --verify --deep --strict \"$app\" || fail \"DigUp's signature didn't verify\"\n"
    "codesign -dv \"$app\" 2>&1 | grep -qx 'TeamIdentifier=AXJ3D85GPJ' || fail \"The app isn't signed by DigUp's developer\"\n"
    "dest=\"${RF_DIGUP_DEST:-/Applications}\"; [ -w \"$dest\" ] || { dest=\"$HOME/Applications\"; mkdir -p \"$dest\"; }\n"
    "rm -rf \"$dest/DigUp.app\"; ditto \"$app\" \"$dest/DigUp.app\" || fail \"DigUp couldn't be copied to $dest\"\n"
    "echo \"installed to $dest\"; [ -n \"${RF_DIGUP_NOOPEN:-}\" ] || open \"$dest/DigUp.app\"\n";
- (void)showDigupSetup {
    [self leaveFileMode];
    setupMode = YES; setupNote = nil;
    [self refresh];
}
- (void)installDigup {
    if (installTask.running) return;
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    t.arguments = @[@"-c", @(DIGUP_INSTALL_SH)];
    t.standardInput = t.standardOutput = t.standardError = NSFileHandle.fileHandleWithNullDevice;
    __weak R *ws = self;
    t.terminationHandler = ^(NSTask *ended) {   // survives a hide/respawn (the script carries on, and notifies on failure)
        int st = ended.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            R *s = ws; if (!s) return;
            s->installTask = nil;
            s->setupNote = st ? @"Install failed: see ~/Library/Caches/rayfast-digup-install.log" : @"Installed: DigUp is opening to choose folders";
            if (s->setupMode && s->shown) [s refresh];
        });
    };
    if (![t launchAndReturnError:nil]) { setupNote = @"Couldn't start the installer"; [self refresh]; return; }
    installTask = t;
    setupNote = @"Downloading DigUp (9 MB)… it opens when it's ready";
    [self refresh];
}
- (void)openDigup {
    [self hide];
    NSString *bin = digupBinary();
    NSString *app = bin.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:app]];
}
- (void)cancelSetup { setupMode = NO; [self refresh]; }

#pragma mark DigUp
// DigUp (github.com/ARahim3/DigUp) searches files by what's in them with an on-device embedding model. Its app ships
// a `digup search-service` helper that speaks JSON lines over stdin/stdout: rayfast runs it as a child process for the
// launcher session (like mdfind and curl, nothing of it loads into rayfast) and stops it on hide, before respawning.
// Each query goes out twice: keyword-only at once (prefix-matching the last word), then by meaning after a pause.
- (BOOL)digupStart {
    if (dgTask.running) return YES;
    NSString *bin = digupBinary();
    if (!bin) return NO;
    NSMutableArray *args = [NSMutableArray arrayWithObject:@"search-service"];
    [args addObjectsFromArray:digupPref(@"roots")];                       // the folders DigUp indexes: results are limited to them
    for (NSString *f in digupPref(@"excludedFolders")) [args addObjectsFromArray:@[@"--exclude", f]];
    for (NSString *t in digupPref(@"excludedTypes")) [args addObjectsFromArray:@[@"--exclude-ext", t]];
    for (NSString *f in digupPref(@"codeRoots")) [args addObjectsFromArray:@[@"--code-root", f]];
    for (NSString *f in digupPref(@"codeExcludedFolders")) [args addObjectsFromArray:@[@"--code-exclude", f]];
    NSString *dir = digupPrefString(@"indexDir");
    if (dir.length) [args addObjectsFromArray:@[@"--index", dir]];
    [args addObjectsFromArray:@[@"--encoder-idle", @"60"]];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:bin];
    t.arguments = args;
    NSPipe *in = [NSPipe pipe], *out = [NSPipe pipe];
    t.standardInput = in; t.standardOutput = out; t.standardError = NSFileHandle.fileHandleWithNullDevice;
    __weak R *wself = self;
    t.terminationHandler = ^(NSTask *ended) {   // crashed, killed, or DigUp was updated/removed: don't leave "Searching…" up
        dispatch_async(dispatch_get_main_queue(), ^{ [wself digupEnded:ended]; });
    };
    if (![t launchAndReturnError:nil]) return NO;
    dgTask = t; dgIn = in.fileHandleForWriting;
    NSMutableData *buf = [NSMutableData data];
    __weak R *ws = self;
    out.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) { h.readabilityHandler = nil; return; }
        [buf appendData:d];
        const char *b = buf.bytes; NSUInteger start = 0;
        for (NSUInteger i = 0; i < buf.length; i++) {
            if (b[i] != '\n') continue;
            id msg = [NSJSONSerialization JSONObjectWithData:[buf subdataWithRange:NSMakeRange(start, i - start)] options:0 error:nil];
            if ([msg isKindOfClass:NSDictionary.class]) dispatch_async(dispatch_get_main_queue(), ^{ [ws digupReply:msg]; });
            start = i + 1;
        }
        [buf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    };
    [self digupSend:@{@"op": @"prewarm"}];
    return YES;
}
- (void)digupEnded:(NSTask *)ended {
    if (ended != dgTask) return;   // a helper we stopped on purpose
    dgTask = nil; dgIn = nil;
    if (fileMode && dig && searching) { searching = NO; fileRows = fileRows ?: @[]; fileNote = @"DigUp's helper stopped: type again to retry, or ⇥ for Spotlight"; [self refresh]; }
}
- (void)digupSend:(NSDictionary *)req {
    if (!dgTask.running) return;
    NSMutableData *d = [[NSJSONSerialization dataWithJSONObject:req options:0 error:nil] mutableCopy];
    [d appendBytes:"\n" length:1];
    [dgIn writeData:d error:nil];   // SIGPIPE is ignored (uiRun), so a dead helper is just an error here
}
- (void)digupStop {
    if (!dgTask) return;
    [self digupSend:@{@"op": @"quit"}];
    [dgIn closeFile];
    NSTask *t = dgTask; dgTask = nil; dgIn = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (t.running) [t terminate]; });
}
- (void)runDigup:(NSString *)q gen:(int)my {
    if (!digupPref(@"roots").count) { searching = NO; fileRows = @[]; fileNote = @"DigUp has no folders yet: choose some in DigUp"; [self refresh]; return; }
    if (![self digupStart]) { searching = NO; fileRows = @[]; fileNote = @"DigUp's search helper didn't start"; [self refresh]; return; }
    [self digupSend:@{@"op": @"search", @"q": q, @"limit": @40, @"meaning": @NO, @"prefix_last": @YES, @"id": @(my * 2)}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (my == fileGen && fileMode && dig) [self digupSend:@{@"op": @"search", @"q": q, @"limit": @40, @"meaning": @YES, @"id": @(my * 2 + 1)}];
    });
}
static NSString *digupWhere(NSDictionary *h) {
    NSString *seg = h[@"segment"]; id l = h[@"loc"], le = h[@"loc_end"];
    if (![l isKindOfClass:NSNumber.class]) l = nil;
    double loc = [l doubleValue], end = [le isKindOfClass:NSNumber.class] ? [le doubleValue] : loc;
    if (!l && ![seg isEqual:@"ocr"]) return nil;
    if ([seg isEqual:@"page"] || [seg isEqual:@"page_image"]) return [NSString stringWithFormat:@"p. %d", (int)loc];
    if ([seg isEqual:@"audio"] || [seg isEqual:@"frame"]) { int t = (int)loc; return t >= 3600 ? [NSString stringWithFormat:@"%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60] : [NSString stringWithFormat:@"%d:%02d", t / 60, t % 60]; }
    if ([seg isEqual:@"chunk"]) return [NSString stringWithFormat:@"part %d", (int)loc];
    if ([seg isEqual:@"lines"]) return [NSString stringWithFormat:@"lines %d–%d", (int)loc, (int)end];
    if ([seg isEqual:@"cells"]) return [NSString stringWithFormat:@"cells %d–%d", (int)loc, (int)end];
    if ([seg isEqual:@"ocr"]) return @"text in image";
    return nil;
}
- (void)digupReply:(NSDictionary *)msg {
    if (![msg[@"id"] isKindOfClass:NSNumber.class]) return;   // {"event":"ready"}, and replies to requests sent without an id (prewarm, quit)
    int id_ = [msg[@"id"] intValue], my = id_ / 2;
    if (my != fileGen || !fileMode || !dig) return;   // an older query, or the user moved on
    BOOL byMeaning = id_ % 2;
    if ([msg[@"error"] isKindOfClass:NSString.class]) { fileNote = [@"DigUp: " stringByAppendingString:msg[@"error"]]; searching = NO; fileRows = fileRows ?: @[]; [self refresh]; return; }
    static NSDictionary *kinds;
    if (!kinds) kinds = @{@"screenshot": @"Screenshot", @"image": @"Image", @"pdf": @"PDF", @"doc": @"Document",
                          @"audio": @"Audio", @"video": @"Video", @"code": @"Code"};
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *h in [msg[@"hits"] isKindOfClass:NSArray.class] ? msg[@"hits"] : @[]) {
        if (![h isKindOfClass:NSDictionary.class]) continue;
        NSString *path = h[@"path"];
        if (![path isKindOfClass:NSString.class]) continue;
        App *f = [App new]; f->file = YES; f->path = path; f->name = path.lastPathComponent;
        NSMutableArray *bits = [NSMutableArray arrayWithObject:path.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath];
        NSString *where = digupWhere(h); if (where) [bits addObject:where];
        NSString *ex = [h[@"excerpt"] isKindOfClass:NSString.class] ? trim([[[h[@"excerpt"] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
                    stringByReplacingOccurrencesOfString:@"«" withString:@""] stringByReplacingOccurrencesOfString:@"»" withString:@""]) : nil;
        if (ex.length) [bits addObject:[NSString stringWithFormat:@"“%@”", ex]];
        Item *it = mkItem(K_FILE, f->name, [bits componentsJoinedByString:@"  ·  "], nil, ([h[@"kind"] isKindOfClass:NSString.class] ? kinds[h[@"kind"]] : nil));
        it->app = f;
        [out addObject:it];
    }
    if ([msg[@"warning"] isKindOfClass:NSString.class]) fileNote = [@"DigUp: " stringByAppendingString:msg[@"warning"]];
    if (byMeaning || out.count || !fileRows.count) fileRows = out;   // keep keyword hits up until meaning results land
    searching = !byMeaning;
    [self refresh];
}
- (void)revealSelected {
    if (sel < 0 || sel >= (int)rows.count || rows[sel]->kind != K_FILE) return;
    NSURL *u = [NSURL fileURLWithPath:rows[sel]->app->path];
    [self hide];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[u]];
}
- (void)openConfig { [self hide]; [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:cfgPath()]]; }
- (void)quit { [NSApp terminate:nil]; }

- (void)activateSelected {
    if (sel < 0 || sel >= (int)rows.count) return;
    Item *it = rows[sel];
    switch (it->kind) {
    case K_APP: { App *a = it->app; [self hide]; rfOpenApp(a->path, NO); break; }
    case K_CALC:
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:it->copy ?: it->title forType:NSPasteboardTypeString];
        [self hide]; break;
    case K_ACTION: { SEL s = it->action; if (s) [self performSelector:s withObject:nil afterDelay:0]; break; }
    case K_FILE: { NSURL *u = [NSURL fileURLWithPath:it->app->path]; [self hide]; [NSWorkspace.sharedWorkspace openURL:u]; break; }
    default: break;
    }
}
- (void)moveSel:(int)d {
    int n = (int)rows.count;
    if (!n || sel < 0) return;
    int i = sel;
    for (int step = 0; step < n; step++) {
        i = (i + d + n) % n;
        if (rows[i]->kind != K_HEADER) break;
    }
    sel = i;
    [list reveal];
    [self redraw];
}
- (void)startRecording {
    if (sel < 0 || sel >= (int)rows.count || rows[sel]->kind != K_APP) return;
    recording = rows[sel]->app;
    Binding *b = [self bindingFor:recording->path];
    Item *it = mkCalc(recording->name, b ? [@"Current: " stringByAppendingString:comboString(b->key, b->mods, YES)] : @"No hotkey yet",
                      @"Press keys…", @"Use ⌘ ⌥ or ⌃ (or an F-key)", nil);
    it->kind = K_INFO;
    rows = @[mkItem(K_HEADER, @"Set Hotkey", nil, nil, nil), it]; sel = 1; list->off = 0;
    [self redraw];
}
- (void)finishRecording:(NSEvent *)e {
    NSEventModifierFlags f = e.modifierFlags;
    UInt32 mods = (f & NSEventModifierFlagCommand ? cmdKey : 0) | (f & NSEventModifierFlagOption ? optionKey : 0) |
                  (f & NSEventModifierFlagControl ? controlKey : 0) | (f & NSEventModifierFlagShift ? shiftKey : 0);
    UInt16 k = e.keyCode;
    App *a = recording;
    Binding *b = [self bindingFor:a->path];
    if (k == 53) { recording = nil; [self refresh]; return; }                  // esc
    if (k == 51 && !mods) {                                                     // backspace: remove
        if (b) { rfUnregister(b); [gBinds removeObject:b]; rfSaveConfig(); }
        recording = nil; [self refresh]; return;
    }
    if (!(mods & (cmdKey | optionKey | controlKey)) && !isFKey(k)) { NSBeep(); return; }
    if (k == gToggle->key && mods == gToggle->mods) { NSBeep(); return; }
    for (Binding *o in [gBinds copy]) if (o != b && o->key == k && o->mods == mods) { rfUnregister(o); [gBinds removeObject:o]; }
    if (!b) { b = [Binding new]; b->path = a->path; [gBinds addObject:b]; }
    b->key = k; b->mods = mods;
    rfRegister(b);
    rfSaveConfig();
    recording = nil;
    [self refresh];
}
- (BOOL)handleKey:(NSEvent *)e {
    if (recording) { [self finishRecording:e]; return YES; }
    NSEventModifierFlags m = e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift);
    switch (e.keyCode) {
    case 53: if (setupMode) [self cancelSetup]; else if (fileMode) { [self leaveFileMode]; [self refresh]; } else [self hide]; return YES;   // esc backs out first
    case 36: case 76: if (m == NSEventModifierFlagCommand) [self revealSelected]; else [self activateSelected]; return YES;
    case 51: if (fileMode && !m && !field.stringValue.length) { [self leaveFileMode]; [self refresh]; return YES; } break;
    case 48: if (fileMode && !m) { [self switchProvider]; return YES; } break;   // ⇥ switches file search provider
    case 125: [self moveSel:1]; return YES;
    case 126: [self moveSel:-1]; return YES;
    }
    if (m == NSEventModifierFlagControl && e.keyCode == 45) { [self moveSel:1]; return YES; }
    if (m == NSEventModifierFlagControl && e.keyCode == 35) { [self moveSel:-1]; return YES; }
    if (m == NSEventModifierFlagCommand) {
        switch (e.keyCode) {
        case 40: [self startRecording]; return YES;                                     // ⌘K
        case 43: [self openConfig]; return YES;                                         // ⌘,
        case 9: return [NSApp sendAction:@selector(paste:) to:nil from:self];           // ⌘V
        case 8: return [NSApp sendAction:@selector(copy:) to:nil from:self];            // ⌘C
        case 7: return [NSApp sendAction:@selector(cut:) to:nil from:self];             // ⌘X
        case 0: return [NSApp sendAction:@selector(selectAll:) to:nil from:self];       // ⌘A
        case 51: field.stringValue = @""; [self refresh]; return YES;                  // ⌘⌫
        }
    }
    return NO;
}
@end

#pragma mark - entry points (called by core.m)

void uiRun(void) {
    signal(SIGPIPE, SIG_IGN);   // writing to a DigUp helper that exited must not kill rayfast
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyAccessory;
    gR = [R new];
    gIconSlots = [NSMutableArray array];
    app.delegate = gR;
    __weak R *ws = gR;
    gRatesUpdated = ^{ R *s = ws; if (s && s->shown && !s->recording) [s refresh]; };
    dispatch_async(dispatch_get_main_queue(), ^{ [gR makePanel]; [gR scanApps]; [gR preShow]; });
    [app run];
}
void uiToggle(void) { [gR toggleLauncher]; }
void uiSnapshot(void) { [gR snapshot]; }
void uiNoteOpen(NSString *path) {
    double now = CFAbsoluteTimeGetCurrent();
    NSMutableDictionary *u = [NSMutableDictionary dictionary];
    [loadUsage() enumerateKeysAndObjectsUsingBlock:^(NSString *k, id rec, BOOL *stop) {
        double s = usageScore(rec, now);
        if (s >= 0.05) u[k] = @[@(s), @(now)];   // re-based to now; forgotten after ~2 months unused
    }];
    double s = usageScore(u[path], now) + 1;
    u[path] = @[@(s), @(now)];
    [u writeToFile:usagePath() atomically:YES];
    if (gR) for (App *a in gR->apps) if ([a->path isEqual:path]) a->uses = s;
}
int uiEval(int argc, const char **argv) {   // rayfast --eval "5 km to mi" ...
    loadRates();
    if (ratesStale()) fetchRates(YES);
    for (int i = 2; i < argc; i++) {
        Item *it = convertQuery(@(argv[i]));
        if (!it) { printf("%-24s → (none)\n", argv[i]); continue; }
        printf("%-24s → %s [%s]  →  %s [%s]\n", argv[i], it->lhs.UTF8String, it->lhsCap.UTF8String, it->title.UTF8String, it->sub.UTF8String);
    }
    return 0;
}
