#!/bin/zsh
# footprint after N query refreshes while on screen
cd "$(dirname "$0")/.."; T=${TMPDIR:-/tmp}/rayfast-test; mkdir -p $T/cfg; printf 'toggle = hyper+f13\n' > $T/cfg/config
pkill -x rayfast-test; sleep 0.3
open -n --env RF_NOHOTKEY=1 --env RF_CONFIG_DIR=$T/cfg --env RF_SNAP=$T/snap "$@" build/rayfast-test.app; sleep 1.5; P=$(pgrep -x rayfast-test)
g() { footprint $P | awk '/Footprint:/{printf "%s%s ", $5,$6} /graphics\)|IOSurface/{printf "[%s%s %s] ", $1,$2,$NF}'; echo; }
echo "|nopng" > $T/snap.q; kill -USR2 $P; sleep 0.25; echo "show:      $(g)"; sleep 2; echo "show+2s:   $(g)"
echo "s|nopng" > $T/snap.q; kill -USR2 $P; sleep 0.25; echo "1 query:   $(g)"
for q in a b c d e; do echo "$q|nopng" > $T/snap.q; kill -USR2 $P; sleep 0.25; done; echo "6 queries: $(g)"
sleep 3; echo "+3s idle:  $(g)"
pkill -x rayfast-test
