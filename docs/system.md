### System commands

Type what you want the Mac to do and press `↩`. `⌘K` on any of them records a global hotkey.
`⌘K` on `set volume 40` binds that level; on a utility (`base64 hello`) or an info row (`battery`) the hotkey opens the
launcher on it: type the argument (`hello`) and `↩` copies, while `uuid`, `password`, `lorem` and `epoch` answer at once.

| | |
|---|---|
| power | Sleep, Sleep Displays, Lock Screen, Start Screen Saver, Log Out, Restart, Shut Down |
| desktop | Show Desktop, Toggle Dark Mode, Toggle Hidden Files (restarts Finder), Empty Trash, Eject All Disks |
| sound | Volume Up, Volume Down, Toggle Mute, `set volume 40` (or `volume 40`) |
| network | Toggle Wi-Fi |
| apps | `quit safari`, `force quit safari`, `close safari`, Quit All Applications |
| processes | Kill Process: every process with pid, CPU and memory, filtered as you type (name or pid) |

Keywords work too: `reboot`, `power off`, `logout`, `hibernate`, `appearance`, `quieter`.

Log Out, Restart, Shut Down, Empty Trash, Eject All Disks, Quit All Applications and Toggle Hidden Files (it relaunches
Finder) ask first: `↩` again does it, `esc` doesn't. A double-tapped `↩` only opens the question. The question says what will happen ("Empty Trash: 214 items, 3.1 GB", "3 open apps will be asked to
quit first"). From a hotkey they open the launcher on that question rather than acting blind.

Kill Process: `↩` sends TERM (asks the process to quit), `⌘↩` sends KILL. The top row switches the sort between CPU and
memory. After each `↩` a note takes the chosen row's place and its selection, so pressing `↩` again never hits a
different process. A process that has exited since the list was taken gets nothing. Other users' processes are listed
but refused, with the owner's name.

Everything runs as a short-lived child (`pmset`, `osascript`, `networksetup`), so none of it loads anything into
rayfast. Dark mode, Empty Trash, Eject and Log Out/Restart/Shut Down go through `osascript`: macOS asks once for
permission to control System Events, Finder or loginwindow.

Not there, because macOS has no public way to do them: Do Not Disturb / Focus, Bluetooth on/off, display brightness.

### Utilities

Answers computed from what you type, like the calculator's. `↩` copies the answer.

| type | get |
|---|---|
| `uuid` | a new UUID |
| `password 24` | a random 24-character password (`password` alone: 20), copied as concealed so clipboard history skips it |
| `lorem 50` | 50 words of lorem ipsum |
| `base64 hello` / `unbase64 aGVsbG8=` | encoded / decoded |
| `url encode a b&c` / `url decode a%20b` | percent-encoded / decoded |
| `sha256 abc`, `sha1 abc`, `md5 abc` | the hex digest |
| `epoch` | Unix time now |
| `1717171717` (or `epoch 1717171717000`) | that time as a date, local and UTC |
| `color #ff8800` (or just `#ff8800`) | rgb and hsl, with a swatch |
| `wc some text` | words, characters, lines |

They stay out of the calculator's way: a query the calculator answers never shows one.

### System info

Nothing is looked up until you ask.

| type | see |
|---|---|
| `battery` | charge, charging or not, time left |
| `ip` | local addresses; the Public IP row asks api.ipify.org only when you press `↩` on it |
| `disk` | free space on the startup disk |
| `uptime` | time since boot |
| `wifi` | Wi-Fi status (macOS hides the network name from apps without Location access) |

### Emoji

`emoji` → Search Emoji. Type a name or a word (`grinning`, `thumbs`, `heart`, `lol`, `flag japan`); `↩` pastes it into
the app you were in, `⌘↩` copies it. The ones you used come first. `⌘K` on an emoji gives it its own hotkey.

`emoji.skin = 3` in the config picks a skin tone for the emoji that take one (1 light … 5 dark; default none).

The names come from macOS itself (the emoji font and its Unicode names, country names for flags), written once to
a 40 KB file the first time you open the picker and rebuilt after a macOS update. Nothing is bundled and nothing is
kept in memory while the picker is closed. Not there: emoji made of several joined ones (families, professions, the
rainbow flag) and keycaps.

Cost: nothing at rest (no start-up work, no extra libraries, idle footprint unchanged; the picker adds 17 KB to the
binary). Opening it the first time takes about 20 ms to write the name file.
