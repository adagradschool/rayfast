### Script Commands

Every executable file in `~/.config/rayfast/scripts` (and one level of subfolders) is a launcher command. The format
is Raycast's [Script Commands](https://github.com/raycast/script-commands), so existing ones work unchanged: copy them
in, `chmod +x`, and they show up on the next keystroke. Metadata is read from comment lines near the top (`#`, `//`
or `--`; `@rayfast.` works as well as `@raycast.`):

```sh
#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Ping Host
# @raycast.mode compact
# @raycast.packageName Network
# @raycast.icon 🌐
# @raycast.argument1 { "type": "text", "placeholder": "host" }
# @raycast.argument2 { "type": "dropdown", "placeholder": "count", "data": [{"title": "One", "value": "1"}, {"title": "Five", "value": "5"}] }
ping -c "$2" "$1" | tail -1
```

A file without metadata still works: its title is the file name, its mode `compact`.

| `@raycast.` | |
|---|---|
| `title` | the row's title (searched together with `packageName`, the row's subtitle) |
| `mode silent` | `↩` runs it and hides the launcher at once |
| `mode compact` | the launcher stays open and shows the last line of output; a failure shows the last error line and its exit code |
| `mode fullOutput` | every line of output as a row (colour codes stripped, first 2000 lines): type to filter, `↩` copies the line, `⌘↩` all of it |
| `mode inline` + `refreshTime 1m` | the row's subtitle is the script's first line of output, re-run once per interval (`10s` minimum, `m`, `h`, `d`) while the launcher shows it, even with no typing, and never in the background. `↩` runs it now |
| `argument1`…`3` | asked for in order before the run, passed as `$1`…`$3`. `text`, `password` (shown as dots, never logged) or `dropdown` (its `data` choices); `"optional": true` may be left empty. A script with exactly one text argument also takes it straight from the search box: `define serendipity` runs "Define" with `serendipity` |
| `needsConfirmation true` | `↩` asks first (`↩` runs, `esc` cancels; a double-tapped `↩` doesn't confirm) |
| `currentDirectoryPath ~/src` | the working directory (default: the script's folder) |
| `icon` | an emoji or single character for the row's tile, or an image file (`images/vpn.png` next to the script, an absolute path or `~/…`; PNG, JPEG, ICNS, …), shown in colour. URLs are never fetched: those rows keep the plain tile |

Scripts run out of process with your login shell's `PATH` (so Homebrew tools are found; resolved once a day and
cached), stdin closed, in their own process group. A run that takes longer than `scripts.timeout` seconds (default 60)
is killed with everything it started, and quitting rayfast stops any script still running. A `silent` run keeps
going after the launcher hides.

Arguments reach the script as its command line, as the format requires, so other processes can read them with `ps`
while it runs, passwords included. For a real secret, have the script read it from the Keychain instead
(`security find-generic-password -s my-service -w`).

`⌘K` on a script binds a global hotkey to it (`cmd:scripts.<path in the folder>` in the config): a silent script
just runs; the others open the launcher on their result, or on their argument or confirmation step.

| Command | |
|---|---|
| Create Script Command | writes a commented template (`my-script.sh`, `my-script-2.sh`, …) into the folder and opens it in your text editor |
| Reveal Scripts Folder | opens the folder in Finder (creating it if needed) |

Settings: `scripts.dir = ~/bin/rf:~/work/scripts` (several folders, `:`-separated; new scripts go in the first),
`scripts.timeout = 60`. With hundreds of scripts nothing is read until you type: the folder is stat'ed on the first
query (about 1.4 ms for 200 scripts) and only changed files are re-read.
