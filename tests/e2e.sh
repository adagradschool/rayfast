#!/bin/zsh
# end-to-end via real (synthetic) keyboard events: hyper+F13 opens, type a query, Enter copies the answer
mkdir -p ${TMPDIR:-/tmp}/rayfast-test; cd "$(dirname "$0")/.."
SP=${TMPDIR:-/tmp}/rayfast-test
key() { osascript -e "tell application \"System Events\" to $1"; }
pkill -x rayfast-test; sleep 0.3
open -n --env RF_NOHOTKEY=1 --env RF_TOGGLE=hyper+f13 "$@" build/rayfast-test.app; sleep 1.2; P=$(pgrep -x rayfast-test)
fp() { footprint $P 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]*B\).*/\1/p'; }
echo "idle: $(fp)"
for round in 1 2; do
  echo "old" | pbcopy
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  key 'key code 105 using {command down, option down, control down, shift down}'
  sleep 0.4
  key 'keystroke "2+3*4"'; sleep 0.3
  echo "round $round shown: $(fp)"
  key 'key code 36'; sleep 0.4
  echo "  clipboard after Enter: $(pbpaste)"
  sleep 5; echo "  after respawn: $(fp)  pid $(pgrep -x rayfast-test)"
done
