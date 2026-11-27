#!/bin/zsh
# The system lane's measurement: every checklist item in .conclave/lanes/system.md as headless assertions.
# Everything runs with RF_DRYRUN=1 (actions go to $RF_T/data/dryrun.log) except item 4's kill, which only ever
# targets a /bin/sleep this script started. Prints, last:  checklist: P/T  and  idle: X (base Y).
# `tests/system/run.sh idle` measures only the idle line.
cd ${0:A:h:h:h}
source tests/mod.sh
export RF_DRYRUN=1
PB=rayfast-test-$$
fails=0; passed=0; total=9
ok()   { print -r -- "  ok   $1"; }
bad()  { print -r -- "  FAIL $1"; fails=$((fails+1)); }
skip() { print -r -- "  SKIP $1"; fails=$((fails+1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi }
item() { [[ -n $CUR ]] && done_item; CUR=$1; fails=0; print -r -- "[$1] $2"; }
done_item() { (( fails == 0 )) && passed=$((passed+1)); CUR=; }
cli() { RF_DATA_DIR=$RF_T/data RF_PASTEBOARD=$PB $RF_BIN --run "$@" 2>/dev/null; }
log() { cat $RF_T/data/dryrun.log 2>/dev/null; }
clearlog() { rm -f $RF_T/data/dryrun.log; }
has() { [[ $1 == *$2* ]]; }
# downs from the selected row to the row carrying {cid}, or -1
downs() {
    local snap=$1 cid=$2 n=0 started=0
    while IFS= read -r l; do
        [[ $l == '#'* || $l == '?'* || $l == '='* ]] && continue
        [[ $l == '>'* ]] && started=1
        (( started )) || continue
        [[ $l == *"{$cid}"* ]] && { print $n; return; }
        n=$((n+1))
    done <<< "$snap"
    print -1
}
# rf_snap "<q>|down…|<steps>" reaching the row {cid} first
on_row() {
    local q=$1 cid=$2 steps=$3 s n
    s=$(rf_snap "$q"); n=$(downs "$s" $cid)
    (( n < 0 )) && { print -r -- "NOROW"; return 1; }
    local p=$q; repeat $n p="$p|down"
    rf_snap "$p${steps:+|$steps}"
}

# Idle footprint in KB, 3 s after start, median of 5 starts, measured interleaved with conclave/base (built from
# `git archive` in $TMPDIR) so both see the same machine: the footprint moves by ~2.5 MB with machine state alone
# (CoreServices, MALLOC_SMALL), on base too. Each start gets a copy of one warm icon cache, as a real instance has.
fp_kb() { local b=$(footprint -f bytes $RF_PID | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p'); print $((b/1024)); }
idle_ab() {   # sets IDLE and BASE_KB
    local B=${TMPDIR:-/tmp}/rf-system-base rev=$(git rev-parse conclave/base) mine=$RF_BIN warm=${TMPDIR:-/tmp}/rf-system-icons.$$ a=() b=()
    if [[ $(cat $B/.rev 2>/dev/null) != $rev ]]; then
        rm -rf $B; mkdir -p $B; git archive conclave/base | tar -x -C $B && make -C $B -s >/dev/null && print $rev > $B/.rev
    fi
    rf_start; sleep 3; cp $RF_T/data/icons.bin $warm 2>/dev/null; rf_stop
    for i in 1 2 3 4 5; do
        for which in base mine; do
            RF_BIN=$mine; [[ $which == base ]] && RF_BIN=$B/build/rayfast.app/Contents/MacOS/rayfast
            rf_dirs; cp $warm $RF_T/data/icons.bin 2>/dev/null; rf_start; sleep 1.5
            if [[ $which == base ]]; then b+=($(fp_kb)); else a+=($(fp_kb)); fi; rf_stop
        done
    done
    RF_BIN=$mine; rm -f $warm
    [[ -n $VERBOSE ]] && print -u2 "idle samples: mine $a, base $b"
    IDLE=${${(on)a}[3]}; BASE_KB=${${(on)b}[3]}
}
[[ $1 == idle ]] && { idle_ab; print "idle: $IDLE KB (base $BASE_KB KB)"; exit; }

rf_start || { print "build failed"; exit 1; }

# ---- 1. system commands at the root
item 1 "system commands at the root (dry-run)"
typeset -A Q=(
    sleep system.sleep  'sleep displays' system.sleep-displays  'lock screen' system.lock-screen
    'screen saver' system.screen-saver  'log out' system.log-out  restart system.restart  'shut down' system.shut-down
    'empty trash' system.empty-trash  'show desktop' system.show-desktop  'dark mode' system.dark-mode
    'hidden files' system.hidden-files  eject system.eject-all  wifi system.wifi  'volume up' system.volume-up
    'volume down' system.volume-down  mute system.mute)
for q cid in ${(kv)Q}; do has "$(rf_snap $q)" "{$cid}" || bad "'$q' shows {$cid}"; done
(( fails )) || ok "all ${#Q} commands found by name"
# keywords, not just titles
for q cid in hibernate system.sleep  reboot system.restart  'power off' system.shut-down  logout system.log-out  appearance system.dark-mode  'wi-fi' system.wifi  quieter system.volume-down; do
    has "$(rf_snap $q)" "{$cid}" || bad "keyword '$q' finds {$cid}"
done
L=$(cli system list)
check "list: every command typed System with an argv" test "$(print -r -- $L | awk -F'\t' '$2!="System"||$4==""' | wc -l | tr -d ' ')" = 0
check "list: has ${#Q} commands or more" test "$(print -r -- $L | grep -c '^system\.')" -ge ${#Q}
for q cid in sleep system.sleep  'sleep displays' system.sleep-displays  'dark mode' system.dark-mode  mute system.mute  'show desktop' system.show-desktop; do
    clearlog; on_row $q $cid enter >/dev/null
    has "$(log)" "$cid	" || bad "'$q' ↩ logs $cid"
done
has "$(log)" "Mission Control" || bad "show desktop runs Mission Control"
check "'set volume 40' row" has "$(rf_snap 'set volume 40')" "{system.set-volume.40}"
clearlog; on_row 'set volume 40' system.set-volume.40 enter >/dev/null
check "'set volume 40' ↩ sets 40" has "$(log)" "output volume 40"
clearlog; cli system do system.restart >/dev/null
check "cli 'do system.restart' is dry" has "$(log)" "system.restart	"
check "nothing outside the data dir: no log in cwd" test ! -e dryrun.log

# ---- 2. destructive ones confirm first
item 2 "destructive commands confirm, naming the consequence"
for q cid in 'log out' system.log-out  restart system.restart  'shut down' system.shut-down  'empty trash' system.empty-trash  eject system.eject-all  'hidden files' system.hidden-files; do
    clearlog; s=$(on_row $q $cid enter)
    [[ -z $(log) ]] || bad "'$q' ↩ alone does nothing"
    [[ $s == *'# '* && $s == *'{'$cid'.confirm}'* ]] || bad "'$q' ↩ opens a confirm view"
    clearlog; on_row $q $cid 'enter|enter' >/dev/null
    [[ -z $(log) ]] || bad "'$q' a double-tapped ↩ doesn't confirm (review f2)"
    clearlog; on_row $q $cid enter >/dev/null; sleep 0.35; rf_snap '@same|enter' >/dev/null
    has "$(log)" "$cid	" || bad "'$q' ↩, then ↩ again acts"
    clearlog; on_row $q $cid 'enter|esc' >/dev/null
    [[ -z $(log) ]] || bad "'$q' ↩ esc cancels"
done
mkdir -p $RF_T/trash/a; print -n 1234567 > $RF_T/trash/x; print -n 12 > $RF_T/trash/a/y
rf_stop; rf_dirs; mkdir -p $RF_T/trash/a; print -n 1234567 > $RF_T/trash/x; print -n 12 > $RF_T/trash/a/y
RF_TRASH=$RF_T/trash rf_start; sleep 0.2
s=$(on_row 'empty trash' system.empty-trash enter); sleep 0.5; s=$(rf_snap '@same')
check "empty trash names count and size ($(print -r -- $s | grep confirm))" has "$s" "2 items"
check "restart names open apps" has "$(on_row restart system.restart enter)" "app"
check "hidden files names the Finder relaunch (review s2)" has "$(on_row 'hidden files' system.hidden-files enter)" "Finder relaunches"
(( fails )) || ok "confirm views"

# ---- 3. quit applications
item 3 "quit applications"
s=$(rf_snap 'quit finder')
check "'quit finder' row" has "$s" "{system.quit.com.apple.finder}"
check "'force quit finder' row" has "$(rf_snap 'force quit finder')" "{system.force-quit.com.apple.finder}"
check "'quit all' row" has "$(rf_snap 'quit all')" "{system.quit-all}"
check "'finder' alone shows no quit row" eval '! has "$(rf_snap finder)" "{system.quit."'
clearlog; on_row 'quit finder' system.quit.com.apple.finder enter >/dev/null
check "'quit finder' ↩ is dry" has "$(log)" "system.quit.com.apple.finder	"
clearlog; s=$(on_row 'quit all' system.quit-all enter)
check "'quit all' confirms first" test -z "$(log)"
check "'quit all' confirm view" has "$s" "{system.quit-all.confirm}"
check "… names the apps it quits" eval 'print -r -- "$s" | grep "{system.quit-all.confirm}" | grep -q " app"'
clearlog; on_row 'quit all' system.quit-all enter >/dev/null; sleep 0.35; rf_snap '@same|enter' >/dev/null
check "'quit all' ↩ ↩ terminates (dry), sparing Finder" eval 'has "$(log)" "system.quit-all	terminate" && ! has "$(log)" "com.apple.finder"'
clearlog; on_row 'quit finder' system.quit.com.apple.finder cmdenter >/dev/null
check "⌘↩ on 'quit finder' force quits (dry)" has "$(log)" "system.force-quit.com.apple.finder	forceTerminate"
clearlog; on_row 'close finder' system.quit.com.apple.finder enter >/dev/null
check "'close' prefix works too" has "$(log)" "system.quit.com.apple.finder	terminate"
clearlog; cli system hotkey system.quit.com.apple.finder >/dev/null
check "hotkey quit.<bundle id> (dry)" has "$(log)" "system.quit.com.apple.finder	terminate"

# ---- 4. kill process (real, but only ever against sleeps this script started: ↩ is pressed only after a snap
# showed our own pid's row selected)
item 4 "kill process view"
rf_stop; unset RF_DRYRUN; rf_start
/bin/sleep 600 >/dev/null 2>&1 & SP=$!; /bin/sleep 600 >/dev/null 2>&1 & SP2=$!
trap 'kill -9 $SP $SP2 2>/dev/null; rf_stop' EXIT
KP="kill process"; n=$(downs "$(rf_snap $KP)" system.kill-process); repeat $n KP="$KP|down"; KP="$KP|enter"
s=$(rf_snap $KP)
check "'kill process' opens a view" has "$s" "# Kill Process"
check "unfiltered: sort switch on top" eval 'print -r -- "$s" | grep "^>" | grep -q "{system.kill.sort}"'
check "sorted by CPU, switches to memory" has "$(rf_snap "$KP|enter")" "Sorted by memory"
s=$(rf_snap "$KP|q=$SP")
check "view lists our sleep ($SP)" has "$s" "{system.kill.$SP}"
check "rows show cpu and memory" eval 'print -r -- "$s" | grep "{system.kill.$SP}" | grep -q "% CPU · "'
check "name filter: 'sleep' lists it" has "$(rf_snap "$KP|q=sleep")" "{system.kill.$SP}"
s=$(rf_snap "$KP|q=launchd")
check "launchd shown but not yours" eval 'print -r -- "$s" | grep "{system.kill.1}" | grep -q "not yours"'
# select a pid's row, prove it is the selected one, then ↩ (TERM) / ⌘↩ (KILL). Never a blind ↩ here: a pid query
# prefixes other pids (session 2: a blind 'q=1|enter' TERMed this script's own shell, pid 1968).
killrow() {   # $1 pid, $2 enter|cmdenter
    local s n p; s=$(rf_snap "$KP|q=$1"); n=$(downs "$s" system.kill.$1)
    (( n < 0 )) && return 1
    p="$KP|q=$1"; repeat $n p="$p|down"
    print -r -- "$(rf_snap $p)" | grep '^>' | grep -q "{system.kill.$1}" || return 1
    rf_snap "$p|$2"
}
check "a typed pid's own row comes first" eval 'rf_snap "$KP|q=1" | grep "^>" | grep -q "{system.kill.1}"'
check "↩ on pid 1 refuses clearly" has "$(killrow 1 enter)" "not yours to kill"
dead() { local st=$(ps -o stat= -p $1); [[ -z $st || $st == Z* ]]; }
s=$(killrow $SP enter); sleep 0.5
check "↩ stopped our sleep" dead $SP
check "footer says so" has "$s" "Sent TERM to sleep ($SP)"
st=-1; dead $SP && { wait $SP 2>/dev/null; st=$?; }
check "it died of TERM (status $st)" test $st = 143
killrow $SP2 cmdenter >/dev/null; sleep 0.5
st=-1; dead $SP2 && { wait $SP2 2>/dev/null; st=$?; }
check "⌘↩ sent KILL (status $st)" test $st = 137
kill -9 $SP $SP2 2>/dev/null
rf_stop; export RF_DRYRUN=1; rf_start
# review s1 (dry run): a refresh after ↩ put the selection on the first row, so a second ↩ signalled another process.
TW=rftwin$$   # three sleeps that ps lists under one name of their own (argv[0])
(exec -a $TW /bin/sleep 600) & T1=$!; (exec -a $TW /bin/sleep 600) & T2=$!; (exec -a $TW /bin/sleep 600) & T3=$!; sleep 0.2
trap 'kill -9 $T1 $T2 $T3 2>/dev/null; rf_stop' EXIT
clearlog; s=$(rf_snap "$KP|q=$TW|down|down|enter|enter"); sleep 0.5; s=$(rf_snap '@same|enter')
check "repeated ↩ after a kill signals one pid only ($(log | cut -f2 | tr '\n' ' '))" test "$(log | cut -f2 | sort -u | wc -l | tr -d ' ')" = 1
check "after ↩ the selection rests on the note row" eval 'print -r -- "$s" | grep "^>" | grep -q "{system.kill.note}"'
s=$(rf_snap "$KP|q=$T3"); kill -9 $T3; wait $T3 2>/dev/null; clearlog
s=$(rf_snap "@same|enter")
check "a pid that exited since the list was taken gets nothing" eval '[[ -z $(log) && $s == *"already exited"* ]]'
kill -9 $T1 $T2 2>/dev/null

# ---- 5. emoji picker
item 5 "emoji picker"
check "'emoji' row" has "$(rf_snap emoji)" "{emoji.search}"
check "root search builds no emoji index" test ! -e $RF_T/data/emoji.idx
b=$(cli emoji build); n=${b%% emoji*}; kb=${${b#*, }%% bytes*}; ms=${${b##*bytes, }%% ms}
check "index from the system: $b (pass: >= 1300 emoji, < 64 KB, < 100 ms)" eval '(( n >= 1300 && kb < 65536 && ms < 100 ))'
rm -f $RF_T/data/emoji.idx
check "'heart' puts ❤️ first" has "$(cli emoji search heart | head -1)" "❤"
check "'flag germany' finds 🇩🇪" has "$(cli emoji search 'flag germany' | head -1)" "🇩🇪"
s=$(on_row emoji emoji.search 'enter|q=grinning')
check "'grinning' finds 😀" has "$s" "😀"
check "keyword 'thumbs' finds 👍" has "$(on_row emoji emoji.search 'enter|q=thumbs')" "👍"
on_row emoji emoji.search 'enter|q=grinning|enter' >/dev/null
check "↩ puts 😀 on the pasteboard" has "$(cli util pb-get)" "😀"
check "recent first" has "$(on_row emoji emoji.search enter | sed -n 3p)" "😀"
check "the view built its index on first use" test -s $RF_T/data/emoji.idx
on_row emoji emoji.search 'enter|q=fire|cmdenter' >/dev/null
check "⌘↩ copies 🔥" has "$(cli util pb-get)" "🔥"
rf_stop; rf_dirs; print 'emoji.skin = 3' > $RF_T/cfg/config; rf_start
on_row emoji emoji.search 'enter|q=thumbs up|enter' >/dev/null
check "emoji.skin = 3 gives 👍🏽" has "$(cli util pb-get)" "👍🏽"
check "recents keep the base emoji" has "$(sed -n 1p $RF_T/data/emoji-recent)" "👍"
rf_stop; rf_start

# ---- 6. hotkeys
item 6 "every command has a cid and run() works"
L=$(cli system list); bad_run=0
for cid in $(print -r -- $L | cut -f1); do clearlog; cli system hotkey $cid >/dev/null || bad_run=1; done
check "run() accepts every listed cid" test $bad_run = 0
clearlog; cli system hotkey system.sleep >/dev/null
check "hotkey sleep acts (dry)" has "$(log)" "system.sleep	"
clearlog; cli system hotkey system.restart >/dev/null
check "hotkey restart only confirms" eval '! has "$(log)" "system.restart	"'
clearlog; s=$(rf_snap 'x|esc|cmd=system.restart')
check "hotkey restart opens the launcher on its confirm view" has "$s" "{system.restart.confirm}"
check "… without acting" test -z "$(log)"
clearlog; rf_snap 'x|esc|cmd=system.mute' >/dev/null
check "hotkey mute acts in the instance" has "$(log)" "system.mute	"
# ⌘K binds any row with a cid, so every cid a row carries must do something as a hotkey (session 6)
clearlog; rf_snap 'x|esc|cmd=system.set-volume.40' >/dev/null
check "hotkey set-volume.40 sets 40 (dry)" has "$(log)" "output volume 40"
check "hotkey info.uptime opens on the uptime row" has "$(rf_snap 'x|esc|cmd=system.info.uptime')" "{system.info.uptime}"
check "hotkey info.ip.<if> opens on the ip rows" has "$(rf_snap 'x|esc|cmd=system.info.ip.en0')" "{system.info.public-ip}"
clearlog; s=$(rf_snap 'x|esc|cmd=system.empty-trash.confirm')
check "hotkey on a confirm row opens that confirm, no act" eval 'has "$s" "{system.empty-trash.confirm}" && [[ -z $(log) ]]'
check "hotkey on a kill-view row opens the view" has "$(rf_snap 'x|esc|cmd=system.kill.sort')" "# Kill Process"
check "hotkey util.uuid opens on a fresh uuid" eval '[[ $(rf_snap "x|esc|cmd=util.uuid" | grep "{util.uuid}") =~ "[0-9A-F]{8}-[0-9A-F]{4}-" ]]'
check "hotkey util.base64 takes the text typed" has "$(rf_snap 'x|esc|cmd=util.base64|q=hello')" "aGVsbG8="
check "hotkey util.url-encode takes the text typed" has "$(rf_snap 'x|esc|cmd=util.url-encode|q=a b')" "a%20b"

# ---- 7. small utilities
item 7 "utilities at the root"
u() { rf_snap "$1" | grep '{util\.' | head -1; }
check "uuid"     eval '[[ $(u uuid) =~ "[0-9A-F]{8}-[0-9A-F]{4}-" ]]'
check "lorem 50" eval '[[ $(u "lorem 50" | wc -w) -ge 50 ]]'
check "password 24" eval '[[ -n $(u "password 24") ]]'
check "base64"   has "$(u 'base64 hello')" "aGVsbG8="
check "unbase64" has "$(u 'unbase64 aGVsbG8=')" "hello"
check "url encode" has "$(u 'url encode a b&c')" "a%20b%26c"
check "url decode" has "$(u 'url decode a%20b')" "a b"
check "sha256"   has "$(u 'sha256 abc')" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
check "epoch → date" has "$(u 1717171717)" "2024"
check "color"    has "$(u 'color #ff8800')" "255, 136, 0"
check "wc"       has "$(u 'wc hello big world')" "3 words"
on_row 'base64 hello' util.base64 enter >/dev/null
check "↩ copies" test "$(cli util pb-get)" = "aGVsbG8="
on_row 'password 24' util.password enter >/dev/null
check "↩ on a password marks it concealed, so clipboard history skips it (review k3)" eval '[[ $(cli util pb-get | tr -d "\n" | wc -c) -eq 24 ]] && cli util pb-types | grep -qx org.nspasteboard.ConcealedType'
on_row 'base64 hello' util.base64 enter >/dev/null
check "… and nothing else is" eval '! cli util pb-types | grep -q Concealed'
for q in '5 km to mi' '72f' '20% of 150' 'sqrt(2)*pi' '100 usd to inr' 'time in nyc'; do
    has "$(rf_snap $q)" "{util." && bad "silent when the calculator answers '$q'"
done

# ---- 8. system info
item 8 "system info rows"
for q in battery ip disk uptime wifi; do has "$(rf_snap $q)" "{system.info." || bad "'$q' info row"; done
check "disk says free" has "$(rf_snap disk)" "free"
check "'ip' lists a local IPv4 address" eval '[[ $(rf_snap ip | grep "{system.info.ip.") =~ "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" ]]'
check "uptime says min" has "$(rf_snap uptime)" " min"
rf_snap battery >/dev/null; sleep 1
check "battery answers from pmset (async)" eval 'rf_snap battery | grep "{system.info.battery}" | grep -Eq "%|No battery"'
rf_snap wifi >/dev/null; sleep 1
check "wifi answers (async)" eval 'rf_snap wifi | grep "{system.info.wifi}" | grep -vq "…"'
clearlog; on_row ip system.info.public-ip enter >/dev/null
check "public IP only on ↩, through curl (dry)" has "$(log)" "system.info.public-ip	/usr/bin/curl"
check "nothing asked, nothing shown: 'zip' has no info row" eval '! has "$(rf_snap zip)" "{system.info."'
on_row uptime system.info.uptime enter >/dev/null
check "↩ copies the answer" has "$(cli util pb-get)" " min"

# ---- 9. idle cost
item 9 "idle cost unchanged"
check "no Foundation tables built at file scope (only nil pointers)" eval '! grep -Eq "^static (NSArray|NSDictionary|NSMutable|NSString)[^(]*=" sys.m'
check "no module start(): nothing runs at launch" test "$(grep -c '^static const RFModule k[A-Za-z]* = {"[a-z]*", NULL,' sys.m)" = "$(grep -c '^static const RFModule' sys.m)"
rf_stop
idle_ab
check "idle $IDLE KB within 300 KB of base $BASE_KB" test $IDLE -le $((BASE_KB+300))
done_item

print "checklist: $passed/$total"
print "idle: $IDLE KB (base $BASE_KB KB)"
