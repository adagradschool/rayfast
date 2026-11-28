#!/bin/zsh
# Helpers for module tests: `source tests/mod.sh`, then
#   rf_start                  build, then start a headless instance: no window on screen, no hotkeys, no paste, its own
#                             empty config and data folders (put files into $RF_T/cfg or $RF_T/data first with rf_dirs)
#   rf_snap 'query|down|enter'  drive it (steps as in the README's "Testing hooks") and print the rows as text
#   rf_png out.png 'query'    the same, as a picture
#   (its clipboard is the private pasteboard named rayfast-test-$$, see rfPasteboard() in rf.h)
#   rf_footprint              its memory footprint, e.g. "10 MB"
#   rf_stop
RF_ROOT=${${(%):-%x}:A:h:h}
RF_BIN=$RF_ROOT/build/rayfast.app/Contents/MacOS/rayfast
rf_dirs() { [[ -n $RF_T ]] || { RF_T=$(mktemp -d ${TMPDIR:-/tmp}/rayfast-mod.XXXXXX); mkdir -p $RF_T/cfg $RF_T/data; } }
rf_start() {
    make -C $RF_ROOT -s >/dev/null || return 1
    rf_dirs
    RF_HEADLESS=1 RF_NOHOTKEY=1 RF_NOPASTE=1 RF_PASTEBOARD=rayfast-test-$$ RF_CONFIG_DIR=$RF_T/cfg RF_DATA_DIR=$RF_T/data RF_SNAP=$RF_T/snap $RF_BIN 2>$RF_T/err.log &
    RF_PID=$!
    sleep 1.5
}
rf_step() {   # $1 = steps, writes $RF_T/snap.txt (and .png unless the steps end in |nopng)
    rm -f $RF_T/snap.txt; print -r -- "$1" > $RF_T/snap.q
    kill -USR2 $RF_PID
    for i in {1..60}; do [[ -f $RF_T/snap.txt ]] && break; sleep 0.05; done
    sleep 0.05
}
rf_snap() { rf_step "$1|nopng"; cat $RF_T/snap.txt; }
rf_png() { rf_step "$2"; sleep 0.3; cp $RF_T/snap.png "$1"; }
rf_footprint() { footprint $RF_PID | sed -n 's/.*Footprint: \([0-9.]* [KMG]*B\).*/\1/p'; }
rf_stop() { kill $RF_PID 2>/dev/null; wait $RF_PID 2>/dev/null; rm -rf $RF_T; RF_T=; RF_PID=; }
