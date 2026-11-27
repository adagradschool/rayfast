#!/bin/zsh
# Window-management lane measurement: every checklist item of .conclave/lanes/windows.md as headless assertions.
# Prints, last: "checklist: <passed>/<total>" and "idle: <footprint> (base <footprint>)".
# Nothing here moves a window or asks for a permission.
cd ${0:A:h:h:h}
source tests/mod.sh
make -s >/dev/null || exit 1
B=$RF_BIN
BASE_B=10158776   # conclave/base@89eaa5e, median of 5 starts, bytes (STATE-windows.md)
TOTAL=10; PASS=0; typeset -A ok
fail=0
eq() {   # eq <label> <expected> <actual>
    if [[ $2 == $3 ]]; then (( VERBOSE )) && print "  ok   $1"; else print "  FAIL $1: want $2 got $3"; fail=1; fi
}
g() { $B --run window geom "$@"; }
item() {   # item <n> <description>: runs function t<n>, counts it if no assertion failed
    fail=0; t$1; if (( fail )); then print "FAIL $1. $2"; else print "pass $1. $2"; (( PASS++ )); fi
}
# frames: "x,y,w,h" in AX coordinates (top-left origin, primary display's top-left is 0,0)
M=0,25,1440,875            # 1440x900 primary, 25 pt menu bar
t1() {
    # one display: halves, quarters, thirds, maximize, and no 1-px gap or overlap between neighbours
    W=100,100,500,400
    eq left-half      0,25,720,875    $(g left-half $W $M)
    eq right-half     720,25,720,875  $(g right-half $W $M)
    eq top-half       0,25,1440,437   $(g top-half $W $M)
    eq bottom-half    0,462,1440,438  $(g bottom-half $W $M)
    eq top-left       0,25,720,437    $(g top-left $W $M)
    eq top-right      720,25,720,437  $(g top-right $W $M)
    eq bottom-left    0,462,720,438   $(g bottom-left $W $M)
    eq bottom-right   720,462,720,438 $(g bottom-right $W $M)
    eq first-third    0,25,480,875    $(g first-third $W $M)
    eq center-third   480,25,480,875  $(g center-third $W $M)
    eq last-third     960,25,480,875  $(g last-third $W $M)
    eq first-2/3      0,25,960,875    $(g first-two-thirds $W $M)
    eq last-2/3       480,25,960,875  $(g last-two-thirds $W $M)
    eq maximize       0,25,1440,875   $(g maximize $W $M)
    eq almost-max     72,68,1296,788  $(g almost-maximize $W $M)
    eq center         470,262,500,400 $(g center $W $M)
    eq center-half    360,25,720,875  $(g center-half $W $M)
    eq reasonable     288,200,864,525 $(g reasonable-size $W $M)
    eq larger         28,56,644,488   $(g make-larger $W $M)
    eq smaller        172,144,356,312 $(g make-smaller $W $M)
    eq larger-clamped 0,25,1440,875   $(g make-larger 0,25,1400,870 $M)
    eq smaller-floor  100,100,200,150 $(g make-smaller 100,100,200,150 $M)
    eq center-big     0,25,1440,875   $(g center 0,0,3000,2000 $M)
    eq one-display-next 100,100,500,400 $(g next-display $W $M)
    eq restore-not-geom n/a           $(g restore $W $M)
    eq fullscreen-not-geom n/a        $(g toggle-fullscreen $W $M)
    # odd sizes: neighbours share edges exactly
    O=0,25,1441,877
    eq odd-left  0,25,720,877   $(g left-half $W $O)
    eq odd-right 720,25,721,877 $(g right-half $W $O)
    eq odd-top   0,25,1441,438  $(g top-half $W $O)
    eq odd-bot   0,463,1441,439 $(g bottom-half $W $O)
    eq odd-t1 0,25,480,877   $(g first-third $W $O)
    eq odd-t2 480,25,480,877 $(g center-third $W $O)
    eq odd-t3 960,25,481,877 $(g last-third $W $O)
    # gap 10: 10 pt at the screen edges and between neighbours
    eq gap-left  10,35,705,855  $(g left-half $W $M 10)
    eq gap-right 725,35,705,855 $(g right-half $W $M 10)
    eq gap-tl    10,35,705,422  $(g top-left $W $M 10)
    eq gap-br    725,467,705,423 $(g bottom-right $W $M 10)
    eq gap-max   10,35,1420,855 $(g maximize $W $M 10)
    # a gap typo never leaves the screen: nan/negative -> 0, huge -> an eighth of the shorter side (review wn1)
    eq gap-nan   0,25,1440,875   $(g maximize $W $M nan)
    eq gap-neg   0,25,1440,875   $(g maximize $W $M -5)
    eq gap-huge  109,134,1222,657 $(g maximize $W $M 2000)
    # Cocoa -> AX conversion (primary height 900)
    eq ax-primary   0,25,1440,875     $($B --run window ax 900 0,0,1440,875)
    eq ax-right     1440,-180,1920,1080 $($B --run window ax 900 1440,0,1920,1080)
    eq ax-above     0,-1080,1920,1080 $($B --run window ax 900 0,900,1920,1080)
    eq ax-negative  -1920,-155,1920,1055 $($B --run window ax 900 -1920,0,1920,1055)
    # two displays side by side: 1920x1080 to the right (menu bar only on primary here)
    R=1440,-180,1920,1080; S2="$M;$R"
    eq side-left-on-2   1440,-180,960,1080 $(g left-half 1600,0,400,300 $S2)
    eq side-right-on-1  720,25,720,875     $(g right-half 100,100,400,300 $S2)
    eq side-mostly-on-2 2400,-180,960,1080 $(g right-half 1400,100,400,300 $S2)   # 40 pt on 1, 360 on 2
    eq side-next        1440,-180,960,1080 $(g next-display 0,25,720,875 $S2)     # left half stays left half
    eq side-prev        0,25,720,875       $(g previous-display 1440,-180,960,1080 $S2)
    eq side-next-wrap   0,25,720,875       $(g next-display 1440,-180,960,1080 $S2)
    eq side-next-scaled 1573,-87,667,494   $(g next-display 100,100,500,400 $S2)
    # a display above the primary
    A=0,-1080,1920,1080; S3="$M;$A"
    eq above-max     0,-1080,1920,1080 $(g maximize 100,-900,400,300 $S3)
    eq above-bottom  0,-540,1920,540   $(g bottom-half 100,-900,400,300 $S3)
    eq above-next    0,25,1440,875     $(g next-display 0,-1080,1920,1080 $S3)
    # negative origin: a display to the left of the primary, with its own menu bar
    N=-1920,-155,1920,1055; S4="$N;$M"
    eq neg-left   -1920,-155,960,1055 $(g left-half -1500,0,400,300 $S4)
    eq neg-right  -960,-155,960,1055  $(g right-half -1500,0,400,300 $S4)
    eq neg-next   0,25,720,875        $(g next-display -1920,-155,960,1055 $S4)
    eq neg-prev   -1920,-155,960,1055 $(g previous-display 0,25,720,875 $S4)
    # three displays: next/previous go left to right and wrap
    S5="$N;$M;$R"
    eq three-next-1 0,25,1440,875     $(g next-display -1920,-155,1920,1055 $S5)
    eq three-next-2 1440,-180,1920,1080 $(g next-display 0,25,1440,875 $S5)
    eq three-next-3 -1920,-155,1920,1055 $(g next-display 1440,-180,1920,1080 $S5)
    eq three-prev-1 1440,-180,1920,1080 $(g previous-display -1920,-155,1920,1055 $S5)
    # the Dock on each edge (70 pt) and a notch menu bar (MacBook 1512x982, 37 pt)
    eq dock-left   70,25,685,875   $(g left-half $W 70,25,1370,875)
    eq dock-left-r 755,25,685,875  $(g right-half $W 70,25,1370,875)
    eq dock-right  685,25,685,875  $(g right-half $W 0,25,1370,875)
    eq dock-bottom 0,427,1440,403  $(g bottom-half $W 0,25,1440,805)
    eq notch-top   0,37,1512,472   $(g top-half $W 0,37,1512,945)
    eq notch-bl    0,509,756,473   $(g bottom-left $W 0,37,1512,945)
    eq window-offscreen 0,25,720,875 $(g left-half 5000,5000,100,100 $M)   # nearest screen
}
t2() {
    # cycling: half -> two thirds -> third -> half, read from the present frame (a few points of slack)
    eq cyc-l1 0,25,960,875  $(g left-half 0,25,720,875 $M)
    eq cyc-l2 0,25,480,875  $(g left-half 0,25,960,875 $M)
    eq cyc-l3 0,25,720,875  $(g left-half 0,25,480,875 $M)
    eq cyc-l-slack 0,25,960,875 $(g left-half 1,26,718,874 $M)
    eq cyc-r1 480,25,960,875 $(g right-half 720,25,720,875 $M)
    eq cyc-r2 960,25,480,875 $(g right-half 480,25,960,875 $M)
    eq cyc-r3 720,25,720,875 $(g right-half 960,25,480,875 $M)
    eq cyc-gap 10,35,943,855 $(g left-half 10,35,705,855 $M 10)
    eq no-cyc-top 0,25,1440,437 $(g top-half 0,25,1440,437 $M)
}
t3() {
    local list=$($B --run window list) n=0 bad=0 t k
    eq count 24 $(print -r -- $list | wc -l | tr -d ' ')
    eq unique-glyphs 24 $(print -r -- $list | cut -f2 | LC_ALL=C sort -u | wc -l | tr -d ' ')
    for k in tile snap split resize; do eq "keyword-$k" 1 $(( $(print -r -- $list | cut -f4 | grep -c $k) > 0 )); done
    rf_start
    for t in ${(f)"$(print -r -- $list | cut -f3)"}; do
        rf_snap "$t" | grep -q "^> $t | Window Management {window." || { print "  FAIL root row for '$t'"; fail=1; }
    done
    eq tile-many 1 $(( $(rf_snap tile | grep -c '{window\.') >= 10 ))
    rf_stop
    # glyphs and the "Window" type label are checked by eye in rf_png pictures (NOTES-windows.md)
}
ap() { $B --run window apply "$@"; }
t4() {
    # the apply sequence on a simulated window (`apply` = geom + what real apps do to a set position/size)
    local W=100,100,500,400 S2="$M;1440,-180,1920,1080"
    eq order        "pos 0,25 size 720,875 pos 0,25 -> 0,25,720,875"        "$(ap left-half $W $M)"
    eq eui-off-on   "eui 0 pos 0,25 size 720,875 pos 0,25 eui 1 -> 0,25,720,875" "$(ap left-half $W $M 0 eui)"
    eq min-right    "pos 720,25 size 720,875 pos 540,25 -> 540,25,900,875"   "$(ap right-half $W $M 0 min=900:300)"
    eq min-left     "pos 0,25 size 720,875 pos 0,25 -> 0,25,900,875"         "$(ap left-half $W $M 0 min=900:300)"
    eq min-centre   "pos 480,25 size 480,875 pos 420,25 -> 420,25,600,875"   "$(ap center-third $W $M 0 min=600:300)"
    eq min-bottom   "pos 0,462 size 1440,438 pos 0,300 -> 0,300,1440,600"    "$(ap bottom-half $W $M 0 min=300:600)"
    eq fixed-move   "pos 720,25 pos 940,25 -> 940,25,500,400"                "$(ap right-half $W $M 0 fixed)"
    eq full-alone   "-> The window is in full screen: left alone"            "$(ap left-half $W $M 0 full)"
    eq full-toggle  "fullscreen 0 -> 100,100,500,400"                        "$(ap toggle-fullscreen $W $M 0 full)"
    eq full-enter   "fullscreen 1 -> 100,100,500,400"                        "$(ap toggle-fullscreen $W $M)"
    eq clamp-cross  "pos 1440,-180 size 1920,1080 pos 1440,-180 -> 1440,-180,1920,1080" "$(ap maximize 1600,0,400,300 $S2 0 clamp)"
    eq clamp-next   "pos 1440,-180 size 960,1080 pos 1440,-180 -> 1440,-180,960,1080"   "$(ap next-display 0,25,720,875 $S2 0 clamp)"
    eq gap-apply    "pos 10,35 size 705,855 pos 10,35 -> 10,35,705,855"      "$(ap left-half $W $M 10)"
    # the shipped paths, as a test instance runs them: always a dry run, acting on the frontmost app's pid,
    # from the launcher (row + enter) and from a hotkey (cmd=<cid>); the launcher itself is never the target
    # The Pope may switch apps meanwhile: sample the front app before and after and retry (up to 3 times) until
    # it held still across the run, so a real app switch never reads as a wrong target.
    local front front2 log try
    for try in 1 2 3; do
        front=$(lsappinfo info -only pid $(lsappinfo front) | sed -n 's/.*=\([0-9]*\).*/\1/p')
        RF_DRYRUN=1 RF_AXTRUST=1 rf_start
        rf_snap 'Left Half|enter' >/dev/null; rf_snap '|cmd=window.maximize' >/dev/null; rf_snap '|cmd=window.nope' >/dev/null
        log=$(cat $RF_T/data/dryrun.log 2>/dev/null)
        front2=$(lsappinfo info -only pid $(lsappinfo front) | sed -n 's/.*=\([0-9]*\).*/\1/p')
        [[ $front == $front2 && $log == *pid=$front* ]] && break
        (( try < 3 )) || break
        print "  (front app changed during the run: $front -> $front2, retry $try)"
        rf_stop
    done
    eq launcher-row "window.left-half pid=$front gap=0" "$(print -r -- $log | sed -n 1p | tr '\t' ' ')"
    eq hotkey-cid   "window.maximize pid=$front gap=0"  "$(print -r -- $log | sed -n 2p | tr '\t' ' ')"
    eq unknown-cid  2 $(print -r -- $log | wc -l | tr -d ' ')
    eq not-self     1 $(( front != RF_PID ))
    rf_stop
    # a command that can't act (full screen, no window, nothing to restore) says so in the launcher, from a row
    # and from a hotkey, instead of only on stderr (RF_WINFAIL makes the dry run fail with that reason)
    local why="The window is in full screen: left alone" out
    RF_DRYRUN=1 RF_AXTRUST=1 RF_WINFAIL=$why rf_start
    out=$(rf_snap 'Left Half|enter')
    eq says-header  1 $(print -r -- $out | grep -c '^# Left Half')
    eq says-why     1 $(print -r -- $out | grep -c "^> $why")
    out=$(rf_snap '|cmd=window.maximize')
    eq says-hotkey  1 $(print -r -- $out | grep -c "^> $why")
    rf_snap '|cmd=window.maximize|enter' >/dev/null   # ↩ on the reason only closes (snapshots can't see hidden)
    eq says-no-retry 3 $(wc -l < $RF_T/data/dryrun.log | tr -d ' ')
    rf_stop
}
t5() {   # Accessibility missing (forced with RF_AXTRUST=0): the rows still show; running one explains instead of failing
    local out
    RF_DRYRUN=1 RF_AXTRUST=0 rf_start
    eq row-still-there 1 $(rf_snap 'Left Half' | grep -c '^> Left Half | Window Management {window.left-half}')
    out=$(rf_snap 'Left Half|enter')
    eq view-header 1 $(print -r -- $out | grep -c '^# Window Management needs Accessibility')
    eq view-open   1 $(print -r -- $out | grep -c '^> Open Accessibility Settings')
    eq view-hint   1 $(print -r -- $out | grep -c '^= System Settings → Privacy & Security → Accessibility')
    eq not-moved   "" "$(cat $RF_T/data/dryrun.log 2>/dev/null)"
    rf_snap 'Left Half|enter|enter' >/dev/null
    eq opens-pane "window.permission open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" "$(tr '\t' ' ' < $RF_T/data/dryrun.log 2>/dev/null)"
    out=$(rf_snap '|cmd=window.maximize')   # from a hotkey: the launcher opens on the same view
    eq hotkey-view 1 $(print -r -- $out | grep -c '^# Window Management needs Accessibility')
    eq hotkey-not-moved 1 $(wc -l < $RF_T/data/dryrun.log | tr -d ' ')
    rf_stop
}
t6() {   # restore: the frame before rayfast first moved a window, on disk (each `apply` is a fresh process, as after a respawn)
    local S=$(mktemp ${TMPDIR:-/tmp}/rf-winrestore.XXXXXX) W=100,100,500,400; rm -f $S
    ap left-half $W $M 0 store=$S,id=1:7 >/dev/null
    eq remembered   "1:7 100,100,500,400" "$(tr '\t' ' ' < $S)"
    ap right-half 0,25,720,875 $M 0 store=$S,id=1:7 >/dev/null
    eq first-kept   "1:7 100,100,500,400" "$(tr '\t' ' ' < $S)"
    eq restore      "pos 100,100 size 500,400 pos 100,100 -> 100,100,500,400" "$(ap restore 720,25,720,875 $M 0 store=$S,id=1:7)"
    eq forgotten    "" "$(cat $S)"
    eq nothing      "-> Nothing to restore" "$(ap restore 100,100,500,400 $M 0 store=$S,id=1:7)"
    ap maximize 0,25,1440,875 $M 0 store=$S,id=1:7 >/dev/null
    eq no-op-not-kept "" "$(cat $S)"                        # already there: nothing moved, nothing to remember
    ap toggle-fullscreen $W $M 0 store=$S,id=1:7 >/dev/null
    eq full-not-kept  "" "$(cat $S)"
    ap left-half $W $M 0 store=$S,id=1:7 >/dev/null; ap left-half 50,60,300,200 $M 0 store=$S,id=2:9 >/dev/null
    eq two-windows  2 $(wc -l < $S | tr -d ' ')
    eq other-window "pos 50,60 size 300,200 pos 50,60 -> 50,60,300,200" "$(ap restore 0,25,720,875 $M 0 store=$S,id=2:9)"
    ap left-half 10,30,200,200 $M 0 store=$S,id=3:4,live=3:4 >/dev/null   # 1:7's window is gone: pruned on write
    eq pruned       "3:4 10,30,200,200" "$(tr '\t' ' ' < $S)"
    eq restore-min  "pos 10,30 size 200,200 pos 10,30 -> 10,30,300,200" "$(ap restore 0,25,720,875 $M 0 store=$S,id=3:4,min=300:100)"
    eq no-id        "" "$(ap left-half $W $M 0 store=$S >/dev/null; cat $S)"   # no window id: nothing kept
    # liveness as the shipped path checks it: the pid must run and own that window number
    eq dead-pid     0 $($B --run window alive 999999:1)
    eq no-window    0 $($B --run window alive $$:0)
    local L=$(mktemp ${TMPDIR:-/tmp}/rf-firstwin.XXXXXX) K
    clang -fobjc-arc -framework Foundation -framework CoreGraphics tests/windows/firstwin.m -o $L && K=$($L)
    eq live-window  1 $($B --run window alive $K)
    eq wrong-owner  0 $($B --run window alive $$:${K#*:})
    rm -f $L
    rm -f $S
}
t7() {   # next/previous display with 1, 2 and 3 displays: geometry covered in t1; repeated here as its own item
    eq one   100,100,500,400 $(g next-display 100,100,500,400 $M)
    eq two   1440,-180,960,1080 $(g next-display 0,25,720,875 "$M;1440,-180,1920,1080")
    eq three-wrap -1920,-155,1920,1055 $(g next-display 1440,-180,1920,1080 "-1920,-155,1920,1055;$M;1440,-180,1920,1080")
}
t8() {   # window.gap from the config, read when a command runs (geometry with a gap: t1 and t4)
    rf_dirs; print "window.gap = 12" > $RF_T/cfg/config
    RF_DRYRUN=1 RF_AXTRUST=1 rf_start
    rf_snap '|cmd=window.left-half' >/dev/null
    eq gap-setting "gap=12" "$(sed -n 1p $RF_T/data/dryrun.log 2>/dev/null | sed 's/.* //')"
    rf_stop
}
CMDS=(left-half left-half left-half right-half top-half bottom-half top-left top-right bottom-left bottom-right first-third
      center-third last-third first-two-thirds last-two-thirds maximize almost-maximize center center-half reasonable-size
      make-larger make-smaller next-display previous-display restore)   # all but toggle-fullscreen (a Space switch is seen)
LAT=()
t9() {   # the real AX path on our own helper window (transparent, click-through, never activated; targeted by pid)
    local H=$(mktemp ${TMPDIR:-/tmp}/rf-winhelper.XXXXXX) F=$(mktemp ${TMPDIR:-/tmp}/rf-winhp.XXXXXX) D=$(mktemp -d ${TMPDIR:-/tmp}/rf-windata.XXXXXX)
    local HP out start trimmed=() l n w gt i
    clang -fobjc-arc -framework AppKit tests/windows/helper.m -o $H || { fail=1; return; }
    if [[ -n $WIN_UNTRUSTED || $($B --run window real 1 maximize 2>/dev/null) == untrusted ]]; then   # WIN_UNTRUSTED=1 plays an untrusted runner
        print "  SKIP 9: this test process is not trusted for Accessibility (System Settings > Privacy & Security > Accessibility)"
        fail=1; rm -rf $H $F $D; return
    fi
    $H > $F & HP=$!
    for i in {1..60}; do [[ -s $F ]] && break; sleep 0.05; done
    out=$(RF_DATA_DIR=$D $B --run window real $HP $CMDS 2>&1)
    eq refuses-other-windows 2 $($B --run window real $$ maximize 2>/dev/null; print $?)
    kill $HP 2>/dev/null; wait $HP 2>/dev/null
    start=$(print -r -- $out | sed -n 's/^start //p')
    eq ran ${#CMDS} $(print -r -- $out | grep -vc '^start ')
    # each edge within 1 pt of the geometry: AppKit trims a resize that would end exactly on the Dock's top by 1 pt
    # (a move gets there; NOTES-windows.md), so a window can come out 1 pt short at the bottom
    within() { local -a x=(${(s:,:)1}) y=(${(s:,:)2}); local k; for k in 1 2 3 4; do (( x[k] - y[k] <= 1 && y[k] - x[k] <= 1 )) || return 1; done; }
    for l in ${(f)"$(print -r -- $out | grep -v '^start ')"}; do
        n=${${(s: :)l}[1]} w=${${(s: :)l}[2]} gt=${${(s: :)l}[3]}
        [[ $n == restore ]] && w=$start
        if within $w $gt; then [[ $w != $gt ]] && trimmed+=$n; else print "  FAIL real $n: want $w got $gt"; fail=1; fi
        LAT+=${${(s: :)l}[4]}
    done
    print "  real window: ${#CMDS} commands, within 1 pt of the geometry; trimmed by the app: ${trimmed:-none}"
    rm -rf $H $F $D
}
t10() {   # idle: nothing at start (no AX, no new libraries), footprint within 0.3 MB of base; hotkey-to-moved latency
    # the footprint is bimodal per start (~0.8 MB apart, base too), so a median of 5 can land in different modes for
    # the two builds; the pass mark compares the low mode (min of the 5 interleaved starts). The idle line stays the median.
    eq idle-within-0.3MB 1 $(( $(mn $mine) <= $(mn $base) + 314573 ))
    libs() {   # dylibs loaded by a started instance after a window search ($1 = binary)
        local T=$(mktemp -d ${TMPDIR:-/tmp}/rf-winlibs.XXXXXX) P; mkdir -p $T/cfg $T/data
        DYLD_PRINT_LIBRARIES=1 RF_HEADLESS=1 RF_NOHOTKEY=1 RF_NOPASTE=1 RF_PASTEBOARD=rayfast-test-$$ RF_CONFIG_DIR=$T/cfg RF_DATA_DIR=$T/data RF_SNAP=$T/snap $1 2>$T/err.log &
        P=$!; sleep 1.5; print -r -- 'left half|nopng' > $T/snap.q; kill -USR2 $P
        for i in {1..60}; do [[ -f $T/snap.txt ]] && break; sleep 0.05; done
        sleep 0.5; kill $P; wait $P 2>/dev/null
        grep -c 'dyld.*<' $T/err.log; rm -rf $T
    }
    # min of 3 interleaved: some starts (base too) pull in a ~90-library system batch (AppIntents, CallKit, EventKit...)
    local lm=() lb=() k
    for k in 1 2 3; do lm+=$(libs $B); lb+=$(libs $BD/build/rayfast.app/Contents/MacOS/rayfast); done
    eq same-libraries-as-base $(print -l $lb | sort -n | head -1) $(print -l $lm | sort -n | head -1)
    if (( ${#LAT} )); then
        local p50=$(print -l $LAT | sort -n | sed -n "$(( (${#LAT} + 1) / 2 ))p") mx=$(print -l $LAT | sort -n | tail -1)
        print "  apply latency (in-process, AX open + set + read back): median $p50 ms, max $mx ms over ${#LAT} commands"
        eq latency-under-20ms 1 $(( p50 < 20 ))
    else
        # Latency needs a trusted process (item 9's run). Untrusted, item 10 is judged on what it can see (idle, libraries)
        # and points at the recorded number instead of failing a second time for item 9's SKIP.
        print "  SKIP latency: needs Accessibility (item 9); last measured median 1.0 ms, max 5.1 ms (NOTES-windows.md, s5)"
    fi
}

# ONLY=<n> runs one item (not item 10) and stops: for working on it, not a measurement
if (( ONLY )); then VERBOSE=1 item $ONLY "(only)"; exit $fail; fi

# idle first (item 10 checks it): 3 s after start, median of 5, interleaved with "base" (this branch without win.m,
# built in $TMPDIR) so machine load hits both alike; every instance gets the same warmed private icon cache
BD=$(mktemp -d ${TMPDIR:-/tmp}/rf-winbase.XXXXXX)
git archive HEAD | tar -x -C $BD; rm -f $BD/win.m; make -C $BD -s >/dev/null 2>&1 || exit 1
ICONS=$(mktemp ${TMPDIR:-/tmp}/rf-winicons.XXXXXX)
rf_start; rf_snap a >/dev/null; sleep 1; cp $RF_T/data/icons.bin $ICONS 2>/dev/null; rf_stop
fp() { rf_dirs; cp $ICONS $RF_T/data/icons.bin 2>/dev/null; rf_start; sleep 3; footprint -f bytes $RF_PID | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p'; rf_stop; }
mine=(); base=()
for i in 1 2 3 4 5; do
    mine+=$(fp)
    base+=$(RF_ROOT=$BD RF_BIN=$BD/build/rayfast.app/Contents/MacOS/rayfast fp)
done
med() { print -l $@ | sort -n | sed -n 3p; }
mn() { print -l $@ | sort -n | sed -n 1p; }

item 1 "geometry, pure, all display layouts"
item 2 "cycling left/right halves"
item 3 "root commands, keywords, glyphs, type Window"
item 4 "applying to a window"
item 5 "permission view"
item 6 "restore"
item 7 "next/previous display, 1-3 displays"
item 8 "gap setting"
item 9 "real-window test"
item 10 "idle cost"

rm -rf $BD $ICONS
print "idle samples (bytes): mine $mine | base $base | mins $(mn $mine) vs $(mn $base) | base cached on conclave/base@89eaa5e: $BASE_B"
print "checklist: $PASS/$TOTAL"
printf "idle: %.2f MB (base %.2f MB)\n" $(( $(med $mine) / 1048576.0 )) $(( $(med $base) / 1048576.0 ))
