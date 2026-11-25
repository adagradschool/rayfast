# rayfast

A tiny native macOS launcher: open apps, bind global hotkeys to apps, and quick conversions
(math, units, currency, time zones). Raycast-style layout. Objective-C + AppKit, no Swift, no WebKit, no Node.

```
make            # build/rayfast.app
make run        # start it
make install    # copy to ~/Applications and start at login (LaunchAgent)
make uninstall
```

## Using it

| | |
|---|---|
| `⌘Space` | toggle the launcher (change `toggle` in the config) |
| type | fuzzy app search (`vsc` → Visual Studio Code), ranked by match quality plus how often and how recently you open each app (launcher or hotkey; opens count half as much every 14 days) |
| `↩` | open app / copy answer |
| `⌘K` on an app | record a global hotkey for it (`⌫` removes, `esc` cancels). Pressing an app's hotkey while it's frontmost hides it |
| `⌘,` | edit `~/.config/rayfast/config` |
| Search Files | always the last row (selected when nothing else matches). `↩` opens, `⌘↩` shows in Finder, `⇥` switches provider, `esc` goes back |

Conversions: `5 km to mi`, `72f`, `3 cups in ml`, `1 gib in mb`, `100 usd to inr`, `€50`, `20% of 150`,
`sqrt(2)*pi`, `time in nyc`, `london time`, `3pm pst to ist`, `noon tokyo to nyc`, `10am IST to CET`, `10 ist to cet`,
`ist to cet` (now), `1500 utc to jst`, `10am ind to amsterdam`, `9am pst to utc-3:30`, `10am ist to cet tomorrow`.
Time zones accept abbreviations (shown back as typed, switched to CEST/PDT etc. when daylight time applies), any
country or zone city by name, and unique prefixes (`ams`, `sing`).
### File search providers

Set `files =` in the config, or press `⇥` in the file results (the choice is saved), or run the
"Use DigUp/Spotlight for File Search" command:

- `spotlight`: file names in your home folder, through `/usr/bin/mdfind`. Skips `~/Library`, hidden folders, apps and
  dependency folders; names that start with the query first, then recently opened.
- `digup`: what's *in* your files (photos, PDFs, documents, recordings, video, code) through
  [DigUp](https://github.com/ARahim3/DigUp)'s on-device EmbeddingGemma model: "a penguin", "the pets clause in the
  lease", "where we talked about backoff". rayfast runs DigUp's bundled `digup search-service` helper for the
  launcher session and searches the folders you chose in DigUp (it reads DigUp's own settings). Keyword matches show
  at once, meaning matches replace them a moment later. The helper is a separate process (~250 MB while its
  model is loaded) and stops when the launcher hides, so rayfast's own footprint doesn't change.
- `auto` (default): DigUp once it's installed and has folders, otherwise Spotlight.

Exchange rates come from open.er-api.com (fetched by `/usr/bin/curl`, cached 6h in `~/Library/Caches`).

## Numbers

Measured on an M5 MacBook (60 Hz display) with `footprint` (Activity Monitor's "Memory") and QuickKey's
ScreenCaptureKit benchmark (keypress → first frame where the panel has settled), interleaved runs:

| | Raycast | QuickKey | rayfast |
|---|---|---|---|
| memory at rest | ~175–187 MiB | ~14 MiB | **~11–13 MiB** |
| memory while open | | | ~14 MiB |
| open after idle (median) | 95 ms | 52 ms | **50 ms** |
| rapid re-open (median) | 61 ms | 46 ms | 46–49 ms |
| slowest open | 127 ms | 78 ms | **61 ms** |

About 37 ms of every open is the window server (two 60 Hz frames from commit to scan-out) and ~3 ms is key
delivery; rayfast's own work is ~3 ms of it.

## How

- **Respawn after use.** Using a window fragments AppKit's heap (~10 MB that's never returned). Four seconds after
  the launcher hides, rayfast `execv()`s itself: same pid, hotkeys re-registered, memory back to its cold size.
- **Pre-shown, pre-rendered.** On startup (and after every respawn) the window is built, rendered and shown once
  invisibly off-screen, so the window server's first-show cost is paid up front. Every hide immediately re-renders
  the empty launcher, so a show is just "order this window in".
- **No view draws itself.** A window this size that updates through AppKit's `drawRect:` gets a fixed ~40 MB GPU
  pool from Core Animation (plus 64-bit float buffers when wide-gamut colours are drawn on a P3 display). rayfast
  paints each frame on the CPU into a pair of **grayscale IOSurfaces** (1 byte/px, ~2.8 MB for both) used directly
  as layer contents. The only colour (app icons, logo, caret) lives in tiny separate layers, and the caret blinks
  via a render-server animation, so blinking never repaints. The open window went from ~84 MB to ~14 MB.
- **No NSTextField.** The search box is a small `NSTextInputClient` view (IME, dead keys and emoji still work);
  NSTextField's TextKit field editor cost ~30 ms on cold opens.
- **Icon cache.** App icons are rendered once into 48×48 bitmaps in `~/Library/Caches/rayfast-icons.bin`, which is
  `mmap()`ed read-only: file-backed pages don't count toward the footprint, and IconServices only loads for apps
  that aren't cached yet (or have changed).
- **Global hotkeys** use Carbon's `RegisterEventHotKey` (no Accessibility permission). App launching goes through
  LaunchServices; networking stays out of process (`curl`), so CFNetwork never loads. File search runs
  `/usr/bin/mdfind` the same way, so the Spotlight/Metadata frameworks never load either.
- **`MallocSpaceEfficient=1`** (set by re-execing once at startup) trims ~1 MB of allocator slack.

Code: `core.m` (config, hotkeys, launching, respawn, `main`), `ui.m` (window, renderer, search, conversions),
`rf.h` (the interface between them).

## Testing hooks

`kill -USR1 <pid>` toggles the launcher. Environment variables: `RF_CONFIG_DIR` (another config dir),
`RF_DIGUP=/path/digup`, `RF_DIGUP_roots=a:b` and `RF_DIGUP_indexDir=…` (a DigUp helper, folders and index other than
DigUp's own; a missing path acts as "not installed"), `RF_NOHOTKEY=1` (register no hotkeys) with `RF_TOGGLE=hyper+9` (a private toggle), `RF_DEBUG=1` (log hotkey→commit
latency to stderr), `RF_SNAP=/path/x` (`kill -USR2` renders the window with the query in `/path/x.q` to
`/path/x.png`; `query|down|enter|cmdk|nopng` steps through it, and `@same` re-renders the current state). `rayfast --eval "5 km to mi"` runs the conversion engine from the command line.

`make test-app` builds a separately named copy (`rayfast-test`) so tests never touch the running instance.
`tests/lat.sh` measures resting memory and in-process latency, `tests/active.sh` the open window.
`tests/bench.sh`, `tests/breakdown.sh` and `tests/h2h.sh` drive QuickKey's ScreenCaptureKit benchmark (built from
`QuickKey/tests/RenderLatency.m` plus `tests/RenderLatency.patch`; set `$BENCH` to the binary).
`tests/e2e*.sh` type into the real UI with synthetic keystrokes, so run them with nothing important frontmost.

## License

MIT, see [LICENSE](LICENSE).
