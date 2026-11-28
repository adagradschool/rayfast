// rf.h — interface between core.m (config, hotkeys, app launching, respawn) and ui.m (window, search, conversions).
#import <Cocoa/Cocoa.h>
#include <Carbon/Carbon.h>

@interface Binding : NSObject { @public UInt32 key, mods, hid; NSString *path; EventHotKeyRef ref; }
@end

// ---- core.m
extern NSMutableArray<Binding *> *gBinds;
extern Binding *gToggle;
extern NSString *gFiles;   // Search Files provider: "auto" (DigUp when installed, else Spotlight), "spotlight" or "digup"
extern uint64_t gHotkeyAt;
NSString *cfgDir(void);
NSString *cfgPath(void);
NSString *trim(NSString *s);
time_t mtimeOf(NSString *p);
BOOL isFKey(UInt16 k);
BOOL parseCombo(NSString *s, UInt32 *key, UInt32 *mods);
NSString *comboString(UInt32 key, UInt32 mods, BOOL pretty);
void rfRegister(Binding *b);
void rfUnregister(Binding *b);
void rfSaveConfig(void);
void rfReloadConfigIfChanged(void);
void rfOpenApp(NSString *path, BOOL fromHotkey);
void rfRespawn(void);
NSString *rfDataDir(void);                              // module state: ~/Library/Application Support/rayfast (or $RF_DATA_DIR), created on first use
NSString *rfSetting(NSString *key, NSString *def);      // "<module>.<name> = value" lines in the config (not loaded under --run: you get def)
void rfSetSetting(NSString *key, NSString *value);      // nil removes; saves the config

// ---- ui.m
void uiRun(void);       // starts AppKit, builds and pre-shows the hidden window, runs the event loop; never returns
void uiToggle(void);
void uiSnapshot(void);
void uiNoteOpen(NSString *path);   // count an app launch (launcher or hotkey) toward its ranking
int uiEval(int argc, const char **argv);

// ---- modules
// Each feature is its own .m file (the Makefile builds every *.m). It registers itself with RF_MODULE and hands ui.m
// rows to show. A module never draws and never needs to edit ui.m or core.m.
//
// The process re-execs itself ~4 s after every hide (see README, "Respawn after use"), so nothing a module keeps in
// memory survives: state lives on disk (rfDataDir(), cfgDir()), start() runs again after each respawn and has to be
// cheap (no framework loads, no big reads: do those lazily, when the user actually asks for the feature).
@interface Cmd : NSObject { @public
    NSString *cid;             // optional stable id "<module>.<name>". With one, ⌘K on the row binds a global hotkey
                               // (in the config: ctrl+opt+left = cmd:window.left-half), delivered to the module's run()
    NSString *title, *sub;
    NSString *glyph;           // one character for the icon tile (white on the accent colour; the window itself is grayscale)
    id icon;                   // or a CGImageRef, shown in colour in its own small layer
    NSString *type;            // right-hand label (default "Command")
    NSString *verb, *altVerb;  // footer labels for ↩ (default "Run Command") and ⌘↩ (default: none)
    int score;                 // rank among root results, higher first: use rfMatch()
    void (^run)(BOOL alt);     // ↩, or ⌘↩ with alt = YES. Main thread, launcher still open: finish with uiHide(),
                               // uiHideAndPaste(), uiPush() or uiRefresh()
    NSDictionary<NSString *, void (^)(void)> *keys;   // optional more actions on the selected row, by combo in config
                               // syntax ("cmd+shift+p", "ctrl+x"); checked before the launcher's own keys. Name them in the
                               // view's hint. After uiRefresh() the selection stays at the same position
}
@end
Cmd *mkCmd(NSString *cid, NSString *title, NSString *sub, NSString *glyph, void (^run)(BOOL alt));

// A View takes over the list, like Search Files does: its own placeholder and rows; esc (or ⌫ on an empty query) leaves it.
@interface View : NSObject { @public
    NSString *title, *placeholder, *hint;   // header above the rows, search box placeholder, footer status text
    NSArray<Cmd *> *(^rows)(NSString *q);   // on every keystroke: the rows for the trimmed query, filtered and in order
    void (^closed)(void);                   // optional: the view went away (esc, hide, another view)
    BOOL secure;                            // the query is a password: shown, snapshotted and copied only as bullets
}
@end

typedef struct {
    const char *name;                                                         // also the cid prefix: "window" owns "window.*"
    void (*start)(void);                                                      // at launch and after every respawn
    void (*search)(NSString *q, const char *lq, NSMutableArray<Cmd *> *out);  // root query (trimmed; lq = lowercased UTF-8): add matching rows with ->score set
    BOOL (*run)(NSString *cid);                                               // a hotkey bound to cmd:<cid> was pressed (launcher usually hidden)
    int (*cli)(int argc, const char **argv);                                  // `rayfast --run <name> args…`: headless entry for tests (no window, no hotkeys, no config)
} RFModule;
void rfAddModule(const RFModule *m);
#define RF_MODULE(m) __attribute__((constructor)) static void rfModuleInit(void) { rfAddModule(&(m)); }

int rfMatch(NSString *title, NSString *keywords, const char *lq);   // 0 = no match; same scale as app results (prefix > word start > substring > fuzzy)
NSPasteboard *rfPasteboard(void);   // the clipboard; tests set RF_PASTEBOARD=<name> to get a private one instead. Always use this, never generalPasteboard
void uiHide(void);
void uiShow(void);             // open the launcher if it is hidden (a hotkey command that needs its view: uiShow(), then uiPush())
void uiHideAndPaste(void);    // hide, then ⌘V into the app that had focus (needs Accessibility; without it the clipboard is simply left set)
void uiPush(View *v);         // show a view (one level: pushing replaces the current one)
void uiPop(void);
void uiRefresh(void);         // recompute the visible rows (async results arrived)
void uiBusy(int delta);       // +1 while work must outlive the launcher window (a running script): holds off the respawn; -1 when done
BOOL uiRunCommand(NSString *cid);
int uiCli(int argc, const char **argv);
