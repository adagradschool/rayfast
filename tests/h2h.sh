#!/bin/zsh
# head-to-head: interleaved rounds of Raycast (⌘Space), QuickKey (⌥Space) and rayfast-test (hyper+9)
setopt nullglob
cd "$(dirname "$0")/.."; out=${TMPDIR:-/tmp}/rayfast-test/h2h; mkdir -p $out; rm -f $out/*.log
BENCH=${BENCH:?set BENCH to a RenderLatency binary built from QuickKey/tests/RenderLatency.m with the BENCH_KEY patch}
for r in 1 2; do
  $BENCH 8 0.4 Raycast 1.15 >> $out/raycast-rapid.log 2>&1; tests/bench.sh rayfast 8 0.4 >> $out/rayfast-rapid.log; tests/bench.sh quickkey 8 0.4 >> $out/quickkey-rapid.log
  tests/bench.sh rayfast 4 6.2 >> $out/rayfast-idle.log; $BENCH 4 6.2 Raycast 1.15 >> $out/raycast-idle.log 2>&1; tests/bench.sh quickkey 4 6.2 >> $out/quickkey-idle.log
done
for f in raycast-rapid quickkey-rapid rayfast-rapid raycast-idle quickkey-idle rayfast-idle; do
  python3 - $out/$f.log $f <<'PY'
import re,sys,statistics as st
t=open(sys.argv[1]).read()
v=sorted(float(x) for x in re.findall(r'trial \d+: ([\d.]+) ms',t)); bad=len(re.findall(r'Incomplete|Unusable',t))
if not v: print(f"{sys.argv[2]:15s} no data ({bad} failed)"); sys.exit()
print(f"{sys.argv[2]:15s} n={len(v):2d} median {st.median(v):5.1f}  mean {st.mean(v):5.1f}  min {v[0]:5.1f}  max {v[-1]:6.1f}  <46ms {sum(x<46 for x in v)}/{len(v)}  failed {bad}")
PY
done
