#!/bin/zsh
# usage: tests/active.sh [--env X=1 ...] -> footprint breakdown while the window is on screen with real queries
cd "$(dirname "$0")/.."; T=${TMPDIR:-/tmp}/rayfast-test; mkdir -p $T/cfg; printf 'toggle = hyper+f13\n' > $T/cfg/config
pkill -x rayfast-test; sleep 0.3
open -n --env RF_NOHOTKEY=1 --env RF_CONFIG_DIR=$T/cfg --env RF_SNAP=$T/snap "$@" build/rayfast-test.app; sleep 1.5
P=$(pgrep -x rayfast-test)
for q in "" "s" "sa" "ma" "100 usd to eur" "time in nyc" "5 km to mi" "c" "te"; do echo "$q|nopng" > $T/snap.q; kill -USR2 $P; sleep 0.35; done
sleep 0.5
footprint $P | sed -n '2p;5,16p'
kill -USR1 $P; sleep 0.3; pkill -x rayfast-test
