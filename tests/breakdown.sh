#!/bin/zsh
# usage: tests/breakdown.sh <trials> <pause> [--env X=1 ...]
# End-to-end latency split into: key delivery, rayfast work, compositor+display (QuickKey's ScreenCaptureKit bench).
cd "$(dirname "$0")/.."; T=${TMPDIR:-/tmp}/rayfast-test; mkdir -p $T/cfg; printf 'toggle = hyper+9\n' > $T/cfg/config
BENCH=${BENCH:?set BENCH to a RenderLatency binary built from QuickKey/tests/RenderLatency.m with the BENCH_KEY patch}
pkill -x rayfast-test; sleep 0.3; rm -f $T/err.log
open -n --env RF_NOHOTKEY=1 --env RF_TOGGLE=hyper+9 --env RF_DEBUG=1 --env RF_CONFIG_DIR=$T/cfg "${@:3}" --stderr $T/err.log build/rayfast-test.app; sleep 3
BENCH_ABS=1 BENCH_KEY=25 $BENCH $1 $2 rayfast-test 1.15 > $T/bench.log 2>&1; pkill -x rayfast-test
python3 - $T <<'PY'
import re,sys,statistics as st
T=sys.argv[1]; b=open(T+"/bench.log").read(); e=open(T+"/err.log").read()
starts=[int(x) for x in re.findall(r'start=(\d+)',b)]; trials=[float(x) for x in re.findall(r'trial \d+: ([\d.]+) ms',b)]
shows=[(int(h),int(c)) for h,c in re.findall(r'hk=(\d+) committed=(\d+)',e)]
t=lambda x: x*125/3/1e6; rows=[]
for s,tr in zip(starts,trials):
    m=[(h,c) for h,c in shows if h>s and h-s<3*24e6]
    if m: h,c=m[0]; rows.append((t(h-s),t(c-h),tr-t(c-s),tr))
if not rows: print("no data:", b[-300:]); sys.exit()
med=lambda i: st.median(r[i] for r in rows)
print(f"n={len(rows)}  deliver {med(0):.1f}  app {med(1):.1f}  compositor {med(2):.1f}  TOTAL median {med(3):.1f} ms (min {min(r[3] for r in rows):.1f})")
PY
