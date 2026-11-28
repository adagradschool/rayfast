#!/bin/zsh
# The review lane's reproductions: one check per finding in docs/review.md. A check PASSES when the finding is fixed.
# Every instance is headless (tests/mod.sh), every system action runs with RF_DRYRUN=1, and every process acted on is
# one this script started. Prints, last:  open findings: <harm> harm, <crash> crash, <wrong> wrong
cd ${0:A:h:h:h}
source tests/mod.sh
export RF_DRYRUN=1
typeset -A open; open=(harm 0 crash 0 wrong 0)
H=$(mktemp -d ${TMPDIR:-/tmp}/rayfast-review.XXXXXX)
KIDS=()
trap 'for p in $KIDS; do kill -9 $p 2>/dev/null; done; rf_stop; rm -rf $H' EXIT
finding() {   # $1 id, $2 severity, $3 text, then the command that succeeds once it is fixed
    local id=$1 sev=$2 d=$3; shift 3
    if "$@"; then print -r -- "  fixed $id ($sev) $d"; else print -r -- "  OPEN  $id ($sev) $d"; open[$sev]=$((open[$sev]+1)); fi
}
dlog() { cat $RF_T/data/dryrun.log 2>/dev/null; }
# a snapshot that may take long: waits up to $2 s, prints the seconds it took (99 = never came)
slow_snap() {
    rm -f $RF_T/snap.txt; print -r -- "$1" > $RF_T/snap.q
    local t0=$EPOCHREALTIME; kill -USR2 $RF_PID
    while [[ ! -f $RF_T/snap.txt ]] && (( EPOCHREALTIME - t0 < $2 )); do sleep 0.1; done
    [[ -f $RF_T/snap.txt ]] && printf '%.1f' $((EPOCHREALTIME - t0)) || print 99
}
zmodload zsh/datetime

# s1 (harm) sys.m:194/:203 Kill Process: every refresh (the hint after ↩, the reload 300 ms later) puts the selection
# back on the first row, so a second ↩ (or a ↩ just after the reload) signals a different process than the one chosen.
s1() {
    # a copied /bin/sleep is killed by code signing on arm64: build a tiny one
    print -r -- '#include <unistd.h>
int main(void) { sleep(120); }' > $H/p.c; clang -o $H/rfrevproc $H/p.c || return 1
    local i; for i in 1 2 3; do $H/rfrevproc & KIDS+=($!); done
    rf_start
    rf_snap "|cmd=system.kill-process|q=rfrevproc|down|down|enter|enter" >/dev/null
    local pids=(${(f)"$(dlog | sed -n 's/^system\.kill\.\([0-9]*\).*/\1/p')"})
    rf_stop
    print -r -- "    s1: ↩ ↩ on the third row signalled: ${pids[*]}"
    (( ${#pids} >= 1 )) && [[ ${(u)#pids} == 1 ]]   # fixed: both presses hit the one chosen process (or the 2nd hits none)
}
finding s1 harm "Kill Process: selection jumps to row 1 after ↩, a second ↩ kills another process" s1

# s2 (harm) sys.m:28 Toggle Hidden Files runs `killall Finder` on one ↩ (or a hotkey) with no confirm view: Finder
# copies and moves in progress are cancelled, its windows close.
s2() {
    rf_start
    local s; s=$(rf_snap "toggle hidden files|enter")
    local l=$(dlog); rf_stop
    [[ -z $l && $s == *'# Toggle Hidden Files?'* ]]
}
finding s2 harm "Toggle Hidden Files kills Finder with no confirmation" s2

# c1 (crash: hang) scripts.m:161 the 5 s guard on the login shell is queued on pathQueue, the serial queue that is
# blocked reading that same shell, so it can never fire; ↩ on a script then blocks the main thread (dispatch_sync,
# scripts.m:179) for as long as the user's login shell takes, forever if it never exits.
c1() {
    rf_dirs; mkdir -p $RF_T/cfg/scripts
    print -r -- $'#!/bin/sh\nexec /bin/sleep 12' > $H/slowshell; chmod +x $H/slowshell
    print -r -- $'#!/bin/sh\n# @raycast.title RvHello\n# @raycast.mode compact\necho hi' > $RF_T/cfg/scripts/rvhello.sh
    chmod +x $RF_T/cfg/scripts/rvhello.sh
    SHELL=$H/slowshell rf_start
    local t; t=$(slow_snap "rvhello|enter|nopng" 20)
    rf_stop
    print -r -- "    c1: ↩ on a script with a 12 s login shell blocked the launcher for ${t} s (guard: 5 s)"
    (( t <= 6 ))
}
finding c1 crash "a slow login shell hangs the main thread past the 5 s guard" c1

# w1 (wrong) scripts.m:228 output is read until EOF, and only the script's process group is killed on timeout: a
# background child that leaves the group but keeps stdout open (a daemon) keeps the run "Running…" and holds uiBusy,
# so rayfast never respawns again.
w1() {
    rf_dirs; mkdir -p $RF_T/cfg/scripts
    print -r -- $'#!/bin/sh\n# @raycast.title RvDaemon\n# @raycast.mode compact\n/usr/bin/perl -e \'setpgrp(0,0); sleep 10\' &\necho started' > $RF_T/cfg/scripts/rvdaemon.sh
    chmod +x $RF_T/cfg/scripts/rvdaemon.sh
    rf_start
    rf_snap "rvdaemon|enter" >/dev/null; sleep 3
    local s; s=$(rf_snap "@same|nopng"); rf_stop
    print -r -- "    w1: 3 s after a script that exits at once: $(print -r -- $s | grep '^=')"
    [[ $s == *'= Finished'* ]]
}
[[ -x /usr/bin/perl ]] && finding w1 wrong "a daemonised child holding stdout keeps the run (and uiBusy) open" w1 || print "  SKIP w1 (no /usr/bin/perl)"


# ---- clip.m (session 2) ----
PB=rayfast-test-$$
clip() { RF_PASTEBOARD=$PB RF_DATA_DIR=$RF_T/data $RF_BIN --run clipboard "$@"; }
hist() { cat $RF_T/data/clipboard/history 2>/dev/null; }

# k1 (harm) clip.m:207 ⌃X "delete" only appends a D record that repeats the text: the deleted entry stays on disk,
# now twice, until a compaction that only runs when superseded records outnumber live ones (clip.m:104).
k1() {
    rf_start
    local t; for t in rva1 rva2 rva3 rvsecret-123; do clip pb-set $t; sleep 0.9; done
    rf_snap "|cmd=clipboard.history|q=rvsecret|key=ctrl+x" >/dev/null; rf_snap "esc|esc" >/dev/null
    rf_snap "|cmd=clipboard.history" >/dev/null; rf_snap "esc" >/dev/null   # reopening doesn't compact either
    local listed=$(clip list | grep -c rvsecret) ondisk=$(hist | grep -c rvsecret); rf_stop
    print -r -- "    k1: after ⌃X and reopening: listed $listed, copies of the text still on disk $ondisk"
    (( listed == 0 && ondisk == 0 ))
}
finding k1 harm "deleting a clipboard entry leaves its text on disk (twice)" k1

# k2 (harm) clip.m:273 "Clear Clipboard History" deletes the whole history, pins included, on one ↩ with no confirm
# view; the query "clear" or "delete" puts it on the first row.
k2() {
    rf_start
    clip pb-set rvkeep; sleep 0.9
    local s; s=$(rf_snap "delete|enter")
    local left=$(hist | grep -c rvkeep); rf_stop
    print -r -- "    k2: 'delete' ↩: entries left $left"
    (( left == 1 ))
}
finding k2 harm "'delete' ↩ wipes the whole clipboard history with no confirmation" k2

# k3 (harm) sys.m:254 copyText() puts a generated password on the clipboard with no concealed type, so clip.m:149
# writes it to the history file (and labels it with whatever app was frontmost).
k3() {
    rf_start
    rf_snap "password 24|enter" >/dev/null; sleep 1.2
    local n=$(clip list | wc -l | tr -d ' '); rf_stop
    print -r -- "    k3: entries in history after 'password 24' ↩: $n"
    (( n == 0 ))
}
finding k3 harm "a generated password is written to the clipboard history" k3

# k4 (crash) clip.m:31/:56 the bundle id comes from the copying app (org.nspasteboard.source) and is written unescaped;
# a source of " " makes sscanf's trailing %n skip past the newline, the meta length goes negative, and reading the
# history crashes. Every later open of Clipboard History crashes again until the file is removed. ("\n" in it instead
# desyncs the log: every entry after it disappears, and the next compaction deletes them.)
k4() {
    rf_start
    clip pb-set rvbefore; sleep 1.1
    clip pb-set rvhello "org.nspasteboard.source= "; sleep 1.1
    clip list >/dev/null 2>&1; local cli=$?
    rf_snap "|cmd=clipboard.history" >/dev/null 2>&1; sleep 0.3
    local alive=1; kill -0 $RF_PID 2>/dev/null || alive=0
    rf_stop
    print -r -- "    k4: after a copy tagged source=' ': list exit $cli, instance alive after opening history: $alive"
    (( cli == 0 && alive == 1 ))
}
finding k4 crash "a copy whose source tag is whitespace crashes Clipboard History, every time" k4

# wn1 (wrong) win.m:293/:96 window.gap is used unchecked: a typo (gap = 2000, nan, inf) gives every layout a negative,
# NaN or off-screen frame (maximize with gap 2000 -> 2000,2025,-2560,-3125: the window leaves the screen).
wn1() {
    local g r bad=0
    for g in 2000 nan inf 449; do
        for c in maximize center left-half make-larger; do
            r=$($RF_BIN --run window geom $c 100,100,800,600 0,25,1440,875 $g)
            # inside the visible frame, positive size, no nan
            print -r -- $r | awk -F, '{ ok = ($1 >= 0 && $2 >= 25 && $3 > 0 && $4 > 0 && $1 + $3 <= 1440 && $2 + $4 <= 900 && $0 !~ /nan|inf/); exit !ok }' \
                || { print -r -- "    wn1: $c gap $g -> $r"; bad=1; }
        done
    done
    (( !bad ))
}
finding wn1 wrong "window.gap unchecked: gap 2000/nan/inf sends windows off screen or to NaN" wn1

# k5 (cost, not counted) clip.m:142 every new copy is loaded into the resting process before the 1 MB cap is checked;
# a 100 MB copy left rayfast at ~100 MB until the next hide (it didn't respawn while hidden). Fixed when the instance
# is back near its idle footprint 10 s after the copy (clipboard@7d19f27 asks for a respawn after a big read: ~4.5 s).
k5() {
    head -c 100000000 /dev/zero | tr '\0' x > $H/big
    rf_start; sleep 1.5
    local a=$(rf_footprint); clip pb-set-file $H/big; sleep 3
    local b=$(rf_footprint); sleep 7
    local c=$(rf_footprint); rf_stop; rm -f $H/big
    kb() { local n=${1%% *}; case $1 in *GB) print $(( n * 1048576 ));; *MB) print $(( n * 1024 ));; *) print $(( n ));; esac }
    local st=OPEN; (( $(kb $c) < $(kb $a) + 5120 )) && st=fixed
    print -r -- "  $st k5 (cost) idle footprint $a -> $b at 3 s -> $c at 10 s after a 100 MB text copy (not stored: over the cap)"
}
k5

# u1 (crash) ui.m rowKey: every key press looked up the selected row's Cmd->keys; on a row that isn't a module's
# (an app, a conversion) or with no rows, that read a field of nil: typing anything in the real launcher was a SIGSEGV.
u1() {
    rf_start
    rf_snap "1+1|key=s" >/dev/null; rf_snap "zzzznothingmatches|key=s" >/dev/null; rf_snap "|key=s" >/dev/null
    local ok=1; kill -0 $RF_PID 2>/dev/null || ok=0
    rf_stop; (( ok ))
}
finding u1 crash "a key press on a row that is not a module's (or on no row) crashes the launcher" u1

print -r -- "open findings: $open[harm] harm, $open[crash] crash, $open[wrong] wrong"
