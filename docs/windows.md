### Window management

Type a layout (`left half`, `max`, `next display`) or a keyword (`tile`, `snap`, `split`, `resize`) and press `↩`: the
window you were in moves. `⌘K` on any of them records a global hotkey, which moves the frontmost window without
opening the launcher.

| | |
|---|---|
| halves | Left, Right, Top, Bottom Half. Left/Right again cycle: half → two thirds → third → half |
| quarters | Top Left, Top Right, Bottom Left, Bottom Right Quarter |
| thirds | First, Center, Last Third; First, Last Two Thirds |
| whole screen | Maximize, Almost Maximize (90%, centred), Toggle Fullscreen |
| keep the size | Center; Move to Next / Previous Display (a window on a layout keeps it, anything else keeps its place, scaled) |
| sizes | Center Half, Reasonable Size (60%, centred), Make Larger / Smaller (10% of the screen per step, around the centre) |
| Restore | back to the frame the window had before rayfast first moved it (remembered across restarts) |

Layouts use the screen without the menu bar and Dock. Neighbours share edges exactly, so a left and a right half
never leave a gap or overlap. Displays are ordered left to right for Next/Previous, which wrap around.

`window.gap = 8` in the config puts 8 pt between windows and around the screen edges (default 0).

Windows that won't resize are only moved. Windows with a minimum size keep the edge the layout touches. Full-screen
windows are left alone (Toggle Fullscreen takes them out). When a command can't act (full screen, no window, nothing
to restore) the launcher opens on one line saying why; ↩ closes it. Moving another app's window needs Accessibility: until
it's on, running a command shows how to turn it on, with a row that opens the right Settings pane.

Cost: nothing at rest (no start-up work, no extra libraries, idle footprint unchanged). Moving a window takes about
1 ms (median of 25 commands on a test window, max 5 ms).
