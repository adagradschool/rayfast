# Review: rayfast modules

Skeptic's findings against `conclave/base`, most severe first. Each one has a reproduction in `tests/review/run.sh`
(headless, dry run, only processes the test started) that **fails while the finding is open**. Severity: `harm`,
`crash`, `wrong`, `weak-test`, `cost`, `fit`.

Session 1 (2026-11-26, base b6b2f7d): `rf.h`, the module seam in `ui.m`, `sys.m`, `scripts.m`. Every exec traced (list at
the end). Session 2 (base d13dcd1): `clip.m`, `snip.m`; s1-w1 re-checked: all still open. Session 3 (base d13dcd1,
unchanged): `win.m` read and fixed here (its lane is paused), and every suite mutation-tested (`tests/review/mutate.sh`).
Session 4 (base b43d8f2, unchanged): `run.sh` on base + conclave/{system,scripts,clipboard} tips merged (clean, warning-free):
**every harm/crash/wrong finding fixed there; on base itself they stay open until the Dean merges those three branches.**
s1 settled: the repro is right and so is system's fix; base fails s1 only because system's note-row fix isn't merged.
Read what landed since d13dcd1 (clip.m images + compaction child, sys.m emoji picker + hotkey routing, scripts.m reaper
and poll-based readers): nothing new above `fit`. Two notes below ([n2](#n2), [n3](#n3)).

| id | sev | where | status |
|---|---|---|---|
| [s1](#s1) | harm | sys.m:194, ui.m refresh | fixed system@010d118 (not on base b43d8f2); seam half on base f26b61b |
| [s2](#s2) | harm | sys.m:28 | fixed system@010d118 (not on base b43d8f2) |
| [c1](#c1) | crash | scripts.m:161, :179 | fixed scripts@31ab24c (not on base) |
| [w1](#w1) | wrong | scripts.m:226-236 | fixed scripts@31ab24c (not on base) |
| [k1](#k1) | harm | clip.m:207 | fixed clipboard@af9b922 (not on base) |
| [k2](#k2) | harm | clip.m:273, :281 | fixed clipboard@af9b922 (not on base) |
| [k3](#k3) | harm | sys.m:254 (+ clip.m:149) | fixed system@010d118 (not on base b43d8f2) |
| [k4](#k4) | crash | clip.m:31, :56 | fixed clipboard@af9b922 (not on base) |
| [k5](#k5) | cost | clip.m:142 | fixed clipboard@af9b922 (not on base): 106 MB for ~4.5 s, then 9.8 MB |
| [wn1](#wn1) | wrong | win.m:293, :96 | fixed review@6f3fc43 |
| [wn2](#wn2) | fit | win.m:299 | fixed review@6f3fc43 |
| [f1](#f1) | fit | sys.m:53 | fixed system@010d118 (not on base b43d8f2) |
| [f2](#f2) | fit | sys.m:150, scripts.m:375 | fixed system@010d118 + scripts@31ab24c (not on base) |
| [f3](#f3) | fit | snip.m:205 | open |
| [n1](#n1) | note | scripts.m:207 | document |
| [p1](#p1) | cost | sys.m:81, :25 | private API list |
| [n2](#n2) | note | sys.m emojiRows | open (system) |
| [n3](#n3) | note | clip.m compactTo | open (clipboard) |

## s1

**harm. Kill Process: after ↩ the selection jumps to the first row, so the next ↩ signals a different process.**
`killProc()` calls `setHint()` → `uiRefresh()` at once, and reloads `ps` 300 ms later → `uiRefresh()` again.
`-[R refresh]` (ui.m, end of `refresh`) always puts `sel` on the first non-header row. Filter "chrome", arrow down to the
fifth helper, ↩: the selection is now on the first helper. A double-tapped ↩, or a ↩ that lands just after the 300 ms
reload while the user is arrowing, TERMs (⌘↩: KILLs) a process the user never selected. Same with no filter, except
there row 1 is the harmless sort switch.

Repro: `s1` starts three identical processes, opens the view on them, presses `down|down|enter|enter` (dry run):
the log shows two different pids signalled (`31035 30543` in the session-1 run).

Fix (sys.m, smallest): remember the pid that was just signalled and keep the selection on it. That needs a seam
(`uiRefresh` that keeps the selected row, as `rowKey` already does for `Cmd->keys`). Without one: drop the
immediate `uiRefresh()` in `setHint()` (set the hint only), and in the 300 ms reload, skip refreshing when the list
is filtered. Also check the pid still has the same name (`proc_name()`) just before `kill()`, since the snapshot
can be minutes old and pids get reused.

## s2

**harm. Toggle Hidden Files runs `killall Finder` on a single ↩ or hotkey, with no confirm view.** Finder copies and
moves in progress are cancelled and its windows reopen. Typing "hid" then ↩ is enough.

Repro: `s2` (dry run): `toggle hidden files|enter` acts at once, no `# Toggle Hidden Files?` view.

Fix: set `confirm` to 1 for `hidden-files` with the consequence "Finder relaunches: copies in progress stop", or
ask Finder to quit politely (`osascript -e 'quit app "Finder"'` then `open -a Finder`), which refuses while a copy
runs, instead of `killall`.

## c1

**crash (hang). The 5 s guard on the login shell can never fire; a slow login shell freezes the launcher.**
`resolveLoginPath()` runs on the serial `pathQueue()` and schedules its guard with
`dispatch_after(…, pathQueue(), …)`: the guard waits behind the very block that is blocked in `read()`. The first ↩
on a script calls `loginPath()` → `dispatch_sync(pathQueue())` **on the main thread**, so the launcher is frozen
for as long as `$SHELL -l` takes: forever if a `.zprofile` waits on something (an unreachable network mount in
PATH, a `gpg`/`ssh-add` prompt with no tty, a hung `brew shellenv`). Once a day (the cache's age), or after any
respawn without a cached file.

Repro: `c1` with `SHELL` = a 12 s shell: ↩ on a script blocks the snapshot for 12.2 s (guard says 5).

Fix: schedule the guard on a global queue (`dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)`), and in
`runScript()` don't `dispatch_sync` on the main thread: if the PATH isn't resolved yet, use the fallback
(`getenv("PATH")` or the stale cache) for this run.

## w1

**wrong. A child that leaves the script's process group but keeps stdout open keeps the run "Running…" and holds
`uiBusy` forever.** Output is read until EOF on both pipes (scripts.m:226), and only after that does it `waitpid` and
signal the group. The timeout (scripts.m:218) only kills the group, so it can't reach the child: the pipe stays
open, the view never finishes, and `uiBusy(1)` is never undone, so rayfast never respawns again (the 10 MB idle
promise is gone until quit). A script that starts a daemon (anything that calls `setsid`/`setpgrp` but doesn't
close its inherited stdout) is enough.

Repro: `w1`: a script that backgrounds `perl -e 'setpgrp(0,0); sleep 10'` and echoes "started" is still `Running…`
3 s later.

Fix: `waitpid` on its own (a `DISPATCH_SOURCE_TYPE_PROC` exit source, or a thread), and when the script itself has
exited, give the pipes a short grace (e.g. 1 s), then close them and finish. That also makes the timeout work.

## k1

**harm. Deleting a clipboard entry (⌃X) leaves its text on disk, now twice.** `mark()` appends a `D` record that
carries the full text; the original `E` record stays. The file is only rewritten by `loadHistory()` when superseded
records outnumber live ones two to one, or the cap dropped something (clip.m:104). The user deletes the password they
copied by mistake and it stays in `~/Library/Application Support/rayfast/clipboard/history` (and in Time Machine) indefinitely.

Repro: `k1` copies 4 entries, deletes `rvsecret-123` with ⌃X, closes and reopens the view: `list` no longer shows it,
the file still holds it twice.

Fix: after a `D`, compact at once (`compactTo(readHistory(maxEntries(), NULL))`: a few ms for 500 entries, and only on
an explicit delete). The `D` record is then never needed on disk; `clearHistory()` should also unlink `history.tmp`.

## k2

**harm. "Clear Clipboard History" wipes the whole history, pins included, on one ↩ with no confirm view.** Its
keywords put it first for `clear`, `clear clip` and `delete` (measured: it is row 1 for all three). From a hotkey
(`run()`, clip.m:281) it clears with no UI at all. Raycast asks first.

Repro: `k2`: `delete|enter` leaves 0 entries.

Fix: a confirm view like sys.m's (`# Clear Clipboard History?`, "Removes N entries, pins included"), Cancel selected
(see f2); drop "delete" from the keywords so the word doesn't land on it.

## k3

**harm. A generated password goes into the clipboard history.** sys.m's `password 24` row copies through
`copyText()` (sys.m:254), which sets only the string type, so clip.m's watcher stores it like any copy, labelled
with whatever app was frontmost (it said `com.google.Chrome` here). Password managers mark such copies
`org.nspasteboard.ConcealedType` precisely so history tools skip them; clip.m honours that, sys.m doesn't set it.

Repro: `k3`: `password 24|enter`, then the history holds 1 entry, the password.

Fix (sys.m, owner system): for the password row, declare `org.nspasteboard.ConcealedType` along with the string
(`[pb declareTypes:@[NSPasteboardTypeString, @"org.nspasteboard.ConcealedType"] owner:nil]` then `setString` for both).
Same for any future row that copies a secret.

## k4

**crash. A copy whose source tag is whitespace crashes Clipboard History, then every later open of it.** The
bundle id is taken from the copying app's `org.nspasteboard.source` string (clip.m:145) and written into the record
header unescaped (clip.m:31). With `" "` and no app name, the header ends in spaces + tab + newline; the format
`"%c %ld %lu %c %n"` skips that whitespace *past the newline into the payload*, so `nl - b - used` is negative and
`initWithBytes:length:` gets a huge length: SIGTRAP. The record stays in the file, so opening the history crashes
every time until the user finds and deletes the file. A tag with `\n` in it instead desyncs the parser at that
record: everything after it vanishes from the view, and the next compaction deletes it from disk. Any app can set
that tag.

Repro: `k4`: `pb-set rvhello org.nspasteboard.source=' '`: `list` exits 133, the instance dies when the view opens.

Fix: keep only `[A-Za-z0-9.-]` of the bundle id (and tabs/newlines out of the app name, as already done for `\n`);
in `readHistory()`, parse the header within `[b, nl)` only (copy it to a NUL-terminated buffer, or check
`b + used <= nl` and skip the record otherwise).

## k5

**cost. Every new copy is loaded into the resting process before the 1 MB cap is checked.** `stringForType:`
(clip.m:142) materialises the whole text; it is then rejected as too big, but the pages stay: a hidden rayfast
doesn't respawn (respawn follows a hide), so it sits at the bigger footprint until the user next opens and closes it.

Measured (`k5`): idle 11 MB → **107 MB** after one 100 MB text copy, still 106 MB 5 s later.

Fix: after a poll that read more than, say, 256 KB (stored or not), call `rfRespawn()` (rf.h) when the launcher
isn't open; `RF_CLIP_SEEN` already survives the exec, so nothing is recorded twice.

## wn1

**wrong (fixed). `window.gap` was used unchecked.** A typo in the config (`window.gap = 2000`, `nan`, `inf`) gave
every layout a negative, NaN or off-screen frame: `maximize` with gap 2000 on a 1440×900 screen was
`2000,2025,-2560,-3125`, so the window left the screen; nan gave `nan,nan,nan,nan` straight into `AXValueCreate`.
Fixed in win.m (review@6f3fc43): `gapIn()` makes the gap 0 unless positive and caps it at an eighth of that screen's
shorter side, applied per screen (next display uses the target screen's cap). Repro `wn1` (16 geom calls), plus
`gap-nan`, `gap-neg`, `gap-huge` in tests/windows item 1.

## wn2

**fit (fixed). The 1 s AX timeout was only on the app element.** `AXUIElementSetMessagingTimeout` is per element and
not inherited, so the ~9 calls on the window element (`wGet`, `wPos`, `wSize`, `wFull`, settable check) kept the
6 s default each: an app that stalls mid-move could freeze the launcher's main thread for up to ~54 s. Now set on
the window element too. Found by reading (no headless repro: it needs an app that hangs between two AX calls).

## f3

**fit. Pasting a snippet replaces the clipboard and doesn't put it back** (snip.m:205; same for clipboard history's
own ↩). Raycast restores the previous clipboard after its paste. Here the user's last copy is gone, and with clip.m
the history gains one entry per snippet pasted. Fix: save the string before `pbSet`, restore it ~0.5 s after
`uiHideAndPaste()` (and `noteSeen`-style skip so the history ignores both writes); or document it.

## f1

**fit. sys.m:53 `spawnArgv()` spawns `osascript`, `pmset`, `/bin/sh` … without `POSIX_SPAWN_CLOEXEC_DEFAULT`**, so they
inherit every descriptor rayfast has open (scripts.m does it right). Fix: a `posix_spawnattr_t` with that flag, as
in scripts.m:201.

## f2

**fit. A confirm view is one row that is already selected**, so the ↩ that opened it plus one more ↩ restarts,
shuts down, logs out, empties the Trash or quits every app; a double-tap does it. Same in scripts'
`needsConfirmation`. Consider putting Cancel first (scripts already has a Cancel row: make it the selected one), or
ignoring ↩ for ~300 ms after the view opens.

## n1

**note. Script arguments, passwords included, are passed as argv** (scripts.m:207), as Raycast's format requires, so
any process can read them with `ps` while the script runs. Nothing to fix in code; docs/scripts.md should say it
(and suggest reading secrets from the Keychain with `security find-generic-password` inside the script).

## p1

**cost: private and undocumented calls.**

| where | what | if Apple removes it |
|---|---|---|
| sys.m:81 | `dlopen` login.framework (private), `dlsym SACLockScreenImmediate` | Lock Screen silently does nothing (no feedback: `lock` is NULL and the row just hides) |
| sys.m:25 | runs `Mission Control.app/Contents/MacOS/Mission Control 1` for Show Desktop | nothing happens, or Mission Control opens |
| win.m:315 | `dlsym _AXUIElementGetWindow` (private, used by Rectangle, yabai) | Restore says "Nothing to restore"; every other command works |
| sys.m:21-23 | AppleEvents `aevtrlgo`/`aevtrrst`/`aevtrsdn` to loginwindow | documented in Apple's tech notes; low risk |

Lock Screen should say when it couldn't lock (row hint or `NSBeep`), not just hide.

## n2

**note. sys.m emoji rows: a non-UTF-8 line in `emoji.idx` puts nil into a dictionary/array (`byBase[base]`, `@[name, …]`)
and throws.** The file is rayfast's own (written to a temp file and renamed, header checked against the OS build), so only
disk corruption or a hand edit gets there. Smallest fix: `if (!base || !name) continue;` in both loops of `emojiRows`.

## n3

**note. clip.m `compactTo` unlinks every file in `img/` not named in the live log, including an ingest child's
`<hash>.png.tmp` and a just-renamed `<hash>.png` whose `E` record isn't appended yet.** A compaction racing an image copy
(a ⌃X delete now compacts at once) loses that one image: the entry lists, but ↩ just hides (putBack checks the file).
Not reproduced (a sub-millisecond window). Fix: skip names ending `.tmp` and files younger than a few seconds.

## Every exec (session 1)

| where | how | what reaches it |
|---|---|---|
| sys.m:53 `spawnArgv` | `posix_spawn` of a fixed argv from the static table | nothing user-typed; volume is an `int` printed with `%d` (sys.m:264) |
| sys.m:28, :32 | `/bin/sh -c` with constant strings | nothing user-typed |
| sys.m:178 | `popen("/bin/ps …")` constant | nothing |
| sys.m:200 | `kill(pid)` from the `ps` snapshot, uid checked | see s1 (selection, stale pid) |
| sys.m:91, :274 | `NSRunningApplication terminate/forceTerminate` | bundle id from the running list or a hotkey cid; self excluded |
| scripts.m:156 | `$SHELL -l -c /usr/bin/env`, clean env | `$SHELL` (see c1) |
| scripts.m:209 | `posix_spawn(script path, args)`, no shell | args as argv, never through a shell: no injection |
| scripts.m:458 | `/usr/bin/open [-t] path` | the scripts folder or a new file in it |

| snip.m:313, :622 | `LSOpenFromURLSpec` / `LSOpenCFURLRef` (no shell) | a quicklink target; `{query}` percent-encoded (RFC 3986 unreserved only) into URLs, raw into paths |
| snip.m:308 | `LSOpenFromURLSpec` with the default text editor | the snippets/quicklinks file path |
| clip.m | none | clip.m runs nothing |

No shell or AppleScript injection found in sys.m, scripts.m, clip.m or snip.m: nothing a user types or a file contains is
interpolated into a shell or `osascript -e` string.

## Mutation test (session 3)

`tests/review/mutate.sh` breaks one guarded line, rebuilds, runs the owner's suite, restores it (never a dry-run guard).
Unmutated on base d13dcd1: clipboard 8/10, system 8/9, scripts 11/11, snippets 11/11, windows 9/10 (item 10's
dylib count, the known brittle check). **9 of 9 mutants caught**, so no `weak-test` finding:

| mutant | breaks | suite |
|---|---|---|
| c-perm | history log created 0644 | clipboard 8 → 7 (store permissions) |
| c-conc | ConcealedType copies stored | clipboard 8 → 7 |
| c-ign | `clipboard.ignore` ignored | clipboard 8 → 7 |
| s-uid | another user's process signalled | system 8 → 7 (pid 1 refusal) |
| s-conf | destructive rows skip the confirm view | system 8 → 6 (19 checks) |
| p-conf | `needsConfirmation` ignored | scripts 11 → 10 |
| p-sec | password argument in clear | scripts 11 → 10 |
| n-enc | quicklink `{query}` not percent-encoded | snippets 11 → 10 |
| w-prune | restore file never pruned | windows 9 → 7 |

The gaps are what the suites don't try, not what they check weakly: none of the open harm/crash findings above
(s1, s2, k1-k4, c1, w1) was caught by its lane's suite.

## Cleared in session 4 (landed since d13dcd1)

- scripts.m `reapLeftovers`: kills a recorded group only if its leader is the very process started (pid + start time +
  pgid) or the leader is gone (a pgid can't be reused while any member lives). Can't hit a stranger.
- scripts.m readers: run ends 0.5 s after the script exits even if a daemon holds stdout; the 300 ms ↩ guard on confirms.
- sys.m hotkey routing: a cid from a kill/confirm row opens the view, never acts; `system.set-volume.N` clamps 0..100.
- clip.m: headers parsed from a NUL-terminated copy, bid/app sanitised; ⌃X compacts at once; Clear asks with Cancel
  selected; image files 0600 in a 0700 dir, decoded only in a child; a big text read triggers a respawn (k5).
- sys.m emoji index: tmp + rename, mapped read-only, every `memchr` bounded by the map's end (but see n2).

## Cleared in session 3 (win.m)

- No exec, no shell: AX calls and `CGWindowListCreateDescriptionFromArray` only. Test and dry-run instances never reach
  AX (`RF_DRYRUN`/`RF_HEADLESS`/`RF_NOHOTKEY` all short-circuit `winApply`); `--run window real` refuses any window not
  titled `rayfast-test-window`. Acts only on the frontmost app's focused window, never on rayfast itself.
- Restore file (`window-restore.tsv`, rfDataDir): keyed `pid:CGWindowID`, owner pid re-checked, dead entries pruned on
  every write: bounded by open windows. `_AXUIElementGetWindow` is `dlsym`'d (p1 row added): without it only restore
  is lost.
- A hung frontmost app costs at most ~3 s (three 1 s app-element calls, then "No window to move").

## Cleared in session 2

- clip.m store permissions: dir 0700, log and compaction temp file 0600 (`O_CREAT` mode), rename atomic; concealed /
  transient / auto-generated types never reach disk (only rayfast's own copies miss the tag: k3).
- clip.m growth: capped by `clipboard.max` (default 500) with compaction; entries over 1 MB are refused (but see k5).
- snip.m: parsers work on NSString line ranges (no byte arithmetic); malformed lines become "line N" problems; non-UTF-8
  is refused with a problem row. Quicklink `{query}` can't escape into the scheme or host (a target must already start with a
  scheme, `/` or `~`). Every open/paste path honours `RF_DRYRUN` and `rfPasteboard()`. A path quicklink like
  `~/Downloads/{query}` opens whatever the user types, apps and `.command` files included: same as double-clicking,
  user-typed, not a finding.
