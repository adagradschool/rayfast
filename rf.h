// rf.h — interface between core.m (config, hotkeys, app launching, respawn) and ui.m (window, search, conversions).
#import <Foundation/Foundation.h>
#include <Carbon/Carbon.h>

@interface Binding : NSObject { @public UInt32 key, mods, hid; NSString *path; EventHotKeyRef ref; }
@end

// ---- core.m
extern NSMutableArray<Binding *> *gBinds;
extern Binding *gToggle;
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

// ---- ui.m
void uiRun(void);       // starts AppKit, builds and pre-shows the hidden window, runs the event loop; never returns
void uiToggle(void);
void uiSnapshot(void);
void uiNoteOpen(NSString *path);   // count an app launch (launcher or hotkey) toward its ranking
int uiEval(int argc, const char **argv);
