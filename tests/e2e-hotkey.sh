#!/bin/zsh
# isolated config: open launcher (hyper+F13), type, ⌘K-record hyper+F14 for Calculator, then use that hotkey
mkdir -p ${TMPDIR:-/tmp}/rayfast-test; cd "$(dirname "$0")/.."
SP=${TMPDIR:-/tmp}/rayfast-test; mkdir -p $SP/cfg; printf "toggle = hyper+f13\n" > $SP/cfg/config
k() { osascript -e "tell application \"System Events\" to $1"; }
HY='using {command down, option down, control down, shift down}'
pkill -x rayfast-test; pkill -x Calculator; sleep 0.3
open -n --env RF_CONFIG_DIR=$SP/cfg "$@" build/rayfast-test.app; sleep 1.5
k "key code 105 $HY"; sleep 0.4
k 'keystroke "calcul"'; sleep 0.3
k 'keystroke "k" using command down'; sleep 0.3
k "key code 107 $HY"; sleep 0.4          # F14 → recorded
echo "config now:"; grep -v '^#' $SP/cfg/config | grep .
k 'key code 53'; sleep 5                  # esc, then let it respawn
echo "resting: $(footprint $(pgrep -x rayfast-test) | sed -n 's/.*Footprint: \([0-9.]* [KMG]*B\).*/\1/p')"
k "key code 107 $HY"; sleep 1.5
echo "Calculator running: $(pgrep -x Calculator >/dev/null && echo yes || echo no), frontmost: $(osascript -e 'tell application "System Events" to name of first process whose frontmost is true')"
k "key code 107 $HY"; sleep 0.8
echo "after 2nd press frontmost: $(osascript -e 'tell application "System Events" to name of first process whose frontmost is true')"
echo "resting still: $(footprint $(pgrep -x rayfast-test) | sed -n 's/.*Footprint: \([0-9.]* [KMG]*B\).*/\1/p')"
pkill -x Calculator
