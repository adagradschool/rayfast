#!/bin/zsh
# usage: tests/bench.sh <rayfast|quickkey> <trials> <pause-seconds>   (needs the patched ScreenCaptureKit bench binary in $BENCH)
# Runs QuickKey's end-to-end render-latency benchmark against the rayfast-test copy (hyper+9) or QuickKey (⌥Space).
cd "$(dirname "$0")/.."; T=${TMPDIR:-/tmp}/rayfast-test; mkdir -p $T/cfg; printf 'toggle = hyper+f13\n' > $T/cfg/config
BENCH=${BENCH:?set BENCH to a RenderLatency binary built from QuickKey/tests/RenderLatency.m with the BENCH_KEY patch}
if [ "$1" = quickkey ]; then $BENCH $2 $3 QuickKey 1.15 2>&1; exit; fi
pkill -x rayfast-test; sleep 0.3
open -n --env RF_NOHOTKEY=1 --env RF_TOGGLE=hyper+9 --env RF_CONFIG_DIR=$T/cfg "${@:4}" build/rayfast-test.app; sleep 3
BENCH_KEY=25 $BENCH $2 $3 rayfast-test 1.15 2>&1
pkill -x rayfast-test
