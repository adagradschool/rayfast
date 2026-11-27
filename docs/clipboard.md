### Clipboard history

rayfast remembers what you copy. Open **Clipboard History** (or give it a hotkey with `⌘K` on its row), type to
narrow it down, and press `↩` to paste an entry into the app you were in.

| key | |
|---|---|
| `↩` | Paste: put the entry back on the clipboard and paste it (without Accessibility it is just put back) |
| `⌘↩` | Copy: put it back on the clipboard only |
| `⌘⇧P` | Pin / unpin. Pinned entries sit at the top and are never dropped |
| `⌃X` | Delete the entry |

Rows are newest first, one per entry: the first line of the text, then the app it came from and its age
(`Safari · 2m`), and a type on the right.

| type | what's kept | row |
|---|---|---|
| Text | the text (up to 1 MB) | its first non-empty line |
| Link | a single `http(s)://` or `mailto:` | the link |
| Color | `#rgb`, `#rrggbb`, `#rrggbbaa` | the colour code |
| File | the paths of copied files (not their contents) | `report.pdf`, or `report.pdf + 2 more`; `↩` pastes the files themselves |
| Image | a PNG on disk (screenshots, copied pictures) | `Image 1280×720` with a small colour thumbnail; `↩` pastes the picture |

Typing matches every word anywhere in the entry, in any order, ignoring case (`q3 report` finds
`…/Q3 report.pdf`; `image 1280` finds pictures of that width). Copying something again moves it to the top
instead of repeating it.

**Settings** (in the config):

| | |
|---|---|
| `clipboard.max = 500` | entries kept (pins don't count); the oldest go first |
| `clipboard.imagemax = 20` | images over this many MB (as PNG) are not kept |
| `clipboard.ignore = com.example.app, …` | bundle ids whose copies are never recorded |
| `clipboard.enabled = off` | stop watching the clipboard altogether |

**Privacy.** Copies that password managers mark as concealed or transient (nspasteboard.org types) are
never written down. The history lives in `~/Library/Application Support/rayfast/clipboard/` (folder `0700`, files
`0600`): a log file plus `img/` for pictures. **Clear Clipboard History** deletes all of it, pins included,
after asking (Cancel is the selected row). `⌃X` takes the entry off the disk at once, text and picture alike.

**Cost.** Nothing is read at rest: the watcher is a 0.5 s timer with wide leeway that only compares a counter (no
measurable wakeups or CPU when idle; idle footprint unchanged). Each copy is one appended line, never a rewrite;
once the log passes 1 MB (and twice its last compacted size) a short-lived child trims it to `clipboard.max`, so the
history stays bounded even if you never open it.
Pictures are decoded and thumbnailed by a short-lived child process, so the resting rayfast never holds them.
Filtering 5000 entries takes about 5 ms; the view with 500 entries (50 of them pictures) costs about 1-2 MB while
open, and the respawn after hiding gives it all back.
