## Snippets

Pieces of text you paste often, kept in one plain file, `~/.config/rayfast/snippets`. Type a snippet's name or one of
its keywords in the launcher: ↩ pastes it into the app you were in, ⌘↩ only copies it. ⌘K on a snippet binds it to a
hotkey (`cmd:snippets.<name>`).

```
# comments and blank lines are fine before the first snippet
--- Email signature | sig mail
Best regards,
Shivam

--- Meeting note | mn
Notes from {date format="EEEE d MMMM"}:
{cursor}
```

| Line | Means |
|---|---|
| `--- name` | starts a snippet; everything below it, up to the next `--- name`, is its text |
| `--- name \| words` | the snippet is also found by these words |
| `\--- …` | a text line that really starts with `--- ` (one backslash is removed) |

Blank lines at the end of a snippet are dropped, so separate snippets however you like. A lone `---` (a markdown
rule) is ordinary text. Names are unique, ignoring case. The file is read the first time you search after it
changes, never at launch. A mistake (no name, no text, a repeated name) skips only that snippet, and a
"Snippets file: N problems" row (search `snippets`) lists what was skipped and where.

### Commands

| Command | Does |
|---|---|
| Create Snippet | asks for a name (`Name \| keywords` works) and saves what's on the clipboard as the new snippet's text |
| Search Snippets | lists every snippet, filtered as you type; ↩ pastes, ⌘↩ copies |
| Edit Snippets | opens the file in your default text editor |

They work before the file exists: the first Create or Edit writes it with a commented example at the top. Each can
take a hotkey with ⌘K (`cmd:snippets.:create`, `cmd:snippets.:search`, `cmd:snippets.:edit`; the colon keeps them
apart from your snippets' names).

### Placeholders

| Placeholder | Becomes |
|---|---|
| `{date}` `{time}` `{datetime}` | `2026-01-02`, `03:04`, `2026-01-02 03:04` |
| `{date format="dd/MM/yy"}` | any [date format pattern](https://unicode.org/reports/tr35/tr35-dates.html#Date_Field_Symbol_Table) |
| `{date offset="+2d"}` | shifted by `m` minutes, `h` hours, `d` days, `w` weeks, `M` months, `y` years; `"-1w +3h"` combines |
| `{clipboard}` | the clipboard's text |
| `{uuid}` | a new UUID |
| `{argument name="who" default="team"}` | asks for a value before pasting (↩ on an empty box takes the default); the same name used twice asks once |
| `{cursor}` | removed. The caret stays at the end of the paste: moving it would mean typing arrow keys |

Anything else in braces is pasted as typed.

Raycast's text expansion (type `;sig` in any app and it turns into the snippet) is out of scope: it needs a global
key tap, which costs memory all day and the Input Monitoring permission. Use a hotkey on the snippet instead.

## Quicklinks

Links you open often, one per line in `~/.config/rayfast/quicklinks`. **Create Quicklink** takes a name and the URL
on the clipboard (or a whole `Name = target` line), **Edit Quicklinks** opens the file; both write a commented example
first when the file is new (`cmd:quicklinks.:create`, `cmd:quicklinks.:edit` for hotkeys).

```
# Name | keywords = target
GitHub Search | gh = https://github.com/search?q={query}
Projects = ~/Projects
```

```
# Name | keywords = target [@ App]
GitHub Search | gh = https://github.com/search?q={query}
Apple Docs | ad = https://developer.apple.com/search/?q={query|swiftui} @ Safari
Projects = ~/Projects
Notes = ~/Notes/{query}.md @ TextEdit
```

| Part | Means |
|---|---|
| `Name \| keywords` | what you type to find it (keywords are optional) |
| `= target` | a URL (`https:`, `file:`, `mailto:`, any `scheme:`) or a path (`~/…`, `/…`) |
| `{query}` | the words typed after the name: `gh rayfast` opens the GitHub search for "rayfast". Percent-encoded in a URL, as typed in a path |
| `{query\|default}` | the same, with a value for when nothing is typed |
| `@ App` | open it in that app (a name like `Safari`, or a path to the `.app`); without it, the default app |

Type a link's name (or a keyword) then the query: ↩ opens it. A link with a bare `{query}` and nothing typed asks for
the query first. ⌘K binds a link to a hotkey (`cmd:quicklinks.<name>`); one that needs a query opens the launcher to
ask. Blank lines and `# comments` are ignored; a line that doesn't read (no ` = `, a target that is neither a URL nor
a path, a repeated name) is skipped and listed under "Quicklinks file: N problems" (search `quicklinks`).

## Importing from Raycast

```
rayfast --run snippets import ~/Downloads/snippets.json
rayfast --run quicklinks import ~/Downloads/quicklinks.json
```

Reads the JSON that Raycast's "Export Snippets" / "Export Quicklinks" commands write and appends what isn't there yet
(a name already in your file is skipped and reported). Raycast's `{argument name="…" default="…"}` and `{query}` in a
link become `{query}` / `{query|default}`; an `openWith` bundle id is turned into the app's path. Snippet placeholders
use the same syntax as Raycast, except `{selection}` and `{snippet …}`, which are left as typed.

*Unverified:* the field names (`name`, `text`, `keyword` for snippets; `name`, `link`, `openWith` for quicklinks) are
from Raycast's documentation as remembered offline, not from a real export. A few other spellings are accepted too
(`title`, `content`, `url`, `application`).
