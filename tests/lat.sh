#!/bin/zsh
# usage: tests/lat.sh [--env X=1 ...] -> resting footprint and in-process open latency (first, reopen within 4 s, after respawn)
mkdir -p ${TMPDIR:-/tmp}/rayfast-test; cd "$(dirname "$0")/.."
SP=${TMPDIR:-/tmp}/rayfast-test
pkill -x rayfast-test; sleep 0.3; rm -f $SP/err.log
open -n --env RF_NOHOTKEY=1 --env RF_DEBUG=1 --env RF_TOGGLE=hyper+f13 "$@" --stderr $SP/err.log build/rayfast-test.app; sleep 2; P=$(pgrep -x rayfast-test)
fp() { footprint $P | sed -n 's/.*Footprint: \([0-9.]* [KMG]*B\).*/\1/p'; }
a=$(fp)
K='tell application "System Events" to key code 105 using {command down, option down, control down, shift down}'
osascript -e "$K"; sleep 0.7; osascript -e "$K"; sleep 1; osascript -e "$K"; sleep 0.7; osascript -e "$K"; sleep 6
b=$(fp); osascript -e "$K"; sleep 0.7; osascript -e "$K"; sleep 0.5
echo "idle $a | after-respawn $b | opens(first, reopen, after-respawn): $(grep shown $SP/err.log | sed -e 's/.*in //' -e 's/  hk=.*//' | tr '\n' ' ')"
