#!/bin/zsh
# Script Commands: every checklist item of .conclave/lanes/scripts.md as headless assertions.
# Prints per-assertion PASS/FAIL/SKIP lines, then, last, exactly:
#   checklist: <passed>/<total>
#   idle: <footprint with the module> (base <footprint on conclave/base>)
# Only runs scripts this file writes into $RF_T. `run.sh quick` skips the idle measurements.
source ${0:A:h}/../mod.sh
zmodload zsh/datetime
# idle is measured paired: this branch without scripts.m ("base") alternates with the full build, because the absolute
# footprint drifts by 2-3 MB with machine state (first base number, conclave/base@89eaa5e on a quiet machine: 9.7 MB)
TOTAL=11
typeset -A ok      # item -> 1 while all its assertions pass, 0 after a FAIL or SKIP
for i in {1..$TOTAL}; do ok[$i]=1; done
check() {   # check <item> <description> <command…>: the command's exit status is the verdict
    local item=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then print -r -- "PASS $item: $desc"; else print -r -- "FAIL $item: $desc"; ok[$item]=0; fi
}
skip() { print -r -- "SKIP $1: $2"; ok[$1]=0; }
has() { grep -qF -- "$2" <<<"$1"; }           # has <text> <fixed string>
hasnt() { ! grep -qF -- "$2" <<<"$1"; }
script() {   # script <relative path> <body…>: an executable script in the test scripts folder
    local f=$RF_T/cfg/scripts/$1; shift
    mkdir -p ${f:h}; print -r -- "#!/bin/sh" > $f; for l in "$@"; do print -r -- "$l" >> $f; done; chmod +x $f
}
waitfor() { for i in {1..${2:-60}}; do eval "$1" && return 0; sleep 0.1; done; return 1; }   # waitfor <condition> [tenths]
fp_bytes() { footprint -f bytes $RF_PID 2>/dev/null | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p'; }
fp_start() {   # fp_start <binary> [n scripts]: idle footprint (bytes) of one fresh start, 3 s after rf_start
    local n=${2:-0} bin=$RF_BIN; RF_BIN=$1
    rf_dirs
    for j in {1..$n}; do script "gen/s$j.sh" "# @raycast.title Generated $j" "# @raycast.mode silent" "echo $j"; done
    rf_start; sleep 1.5; fp_bytes; rf_stop; RF_BIN=$bin
}
median() { local s=(${(on)@}); print $s[$(( (${#s} + 1) / 2 ))]; }
build_base() {   # every *.m but scripts.m, built like the Makefile does, in its own .app
    local d=$(mktemp -d ${TMPDIR:-/tmp}/rayfast-base.XXXXXX) srcs=($RF_ROOT/*.m)
    mkdir -p $d/rayfast.app/Contents/MacOS; cp $RF_ROOT/Info.plist $d/rayfast.app/Contents/
    BASE_BIN=$d/rayfast.app/Contents/MacOS/rayfast
    clang -fobjc-arc -Os -Wno-deprecated-declarations -mmacosx-version-min=13.0 ${srcs:#*/scripts.m} -o $BASE_BIN \
        -framework Cocoa -framework Carbon -framework QuartzCore -framework IOSurface -Wl,-dead_strip && strip -x $BASE_BIN
    codesign -s - -f $d/rayfast.app 2>/dev/null
}
mb() { printf "%.1f MB" $(($1 / 1048576.0)); }

PX=$(mktemp -d ${TMPDIR:-/tmp}/rayfast-px.XXXXXX)/px; clang -fobjc-arc -O1 ${0:A:h}/px.m -o $PX -framework Cocoa   # PNG maker/counter
rf_dirs; export RF_SCRIPTS_LOG=$RF_T/log
T=$RF_T

# ---- 1. discovery
script hello.sh '# @raycast.schemaVersion 1' '# @raycast.title Say Hello' '# @raycast.mode compact' \
    '# @raycast.packageName Greetings' '# @raycast.icon 👋' 'echo one; echo two'
script sub/nested.sh 'echo nested'
script sub/deeper/too-deep.sh 'echo too deep'
script .hidden.sh '# @raycast.title Hidden Thing' 'echo hidden'
script notexec.sh '# @raycast.title Not Executable' 'echo no'; chmod -x $T/cfg/scripts/notexec.sh
script slashes.js '// @rayfast.title Slash Comment Title' '// @raycast.mode silent'
script dashes.lua '-- @raycast.title Dash Comment Title'
rf_start
check 1 "start() reads nothing (no index before the first query)" test ! -e $T/data/scripts.plist
s=$(rf_snap 'say hello'); check 1 "found by title, package as subtitle, stable cid" has "$s" "> Say Hello | Greetings {scripts.hello.sh}"
s=$(rf_snap 'greetings'); check 1 "found by package name" has "$s" "Say Hello | Greetings"
s=$(rf_snap 'nested');    check 1 "subfolder script, title from file name" has "$s" "nested | Script Command {scripts.sub/nested.sh}"
s=$(rf_snap 'too-deep');  check 1 "two levels down is ignored" hasnt "$s" "scripts.sub/deeper"
s=$(rf_snap 'hidden thing'); check 1 "dotfiles ignored" hasnt "$s" "Hidden Thing"
s=$(rf_snap 'not executable'); check 1 "non-executables ignored" hasnt "$s" "Not Executable"
s=$(rf_snap 'slash comment'); check 1 "// comments and @rayfast. alias" has "$s" "Slash Comment Title"
s=$(rf_snap 'dash comment'); check 1 "-- comments" has "$s" "Dash Comment Title"
script added.sh '# @raycast.title Added While Running'; sleep 1.1
s=$(rf_snap 'added while'); check 1 "script added while running shows up" has "$s" "Added While Running"
script added.sh '# @raycast.title Renamed While Running'; sleep 1.1
s=$(rf_snap 'renamed while'); check 1 "script edited while running shows the new title" has "$s" "Renamed While Running"
rm $T/cfg/scripts/added.sh; sleep 1.1
s=$(rf_snap 'renamed while'); check 1 "deleted script disappears" hasnt "$s" "Renamed While Running"
# image icons: a path relative to the script, absolute or ~, decoded small into Cmd->icon; URLs and missing files keep
# the glyph tile. Cyan (no macOS accent colour is near it) counted in the window picture.
mkdir -p $T/cfg/scripts/images $T/img; $PX make $T/cfg/scripts/images/cyan.png 256 0 230 230; $PX make $T/img/abs.png 64 0 230 230
script iconrel.sh '# @raycast.title Relative Icon Row' '# @raycast.icon images/cyan.png'
script iconabs.sh '# @raycast.title Absolute Icon Row' "# @raycast.icon $T/img/abs.png"
script iconmiss.sh '# @raycast.title Missing Icon Row' '# @raycast.icon images/nope.png'
script iconurl.sh '# @raycast.title Url Icon Row' '# @raycast.icon https://example.invalid/i.png'
sleep 1.1
cyan() { rf_png $T/icon.png "$1"; $PX count $T/icon.png 0 230 230; }
n=$(cyan 'relative icon row'); check 1 "relative image path -> colour icon ($n px)" test ${n:-0} -ge 1000
n=$(cyan 'absolute icon row'); check 1 "absolute image path -> colour icon ($n px)" test ${n:-0} -ge 1000
n=$(cyan 'missing icon row');  check 1 "missing image -> glyph tile, no icon ($n px)" test ${n:-1} -eq 0
n=$(cyan 'url icon row');      check 1 "URL icon -> glyph tile, nothing fetched ($n px)" test ${n:-1} -eq 0
s=$(rf_snap 'url icon row'); check 1 "URL/missing icon rows still listed" has "$s" "Url Icon Row"

# ---- 3. compact
s=$(rf_snap 'say hello|enter'); check 3 "↩ keeps the launcher open on the run" has "$s" "# Say Hello"
waitfor 'grep -q "exit hello.sh" $T/log' 30
s=$(rf_snap '@same'); check 3 "last line of output shown" has "$s" "> two"
check 3 "says it finished" has "$s" "= Finished"
script fails.sh '# @raycast.title Failing Script' 'echo out; echo boom >&2; exit 3'
sleep 1.1; rf_snap 'failing script|enter' >/dev/null
waitfor 'grep -q "exit fails.sh" $T/log' 30
s=$(rf_snap '@same'); check 3 "non-zero exit shows the last stderr line" has "$s" "> boom"
check 3 "and says it failed" has "$s" "= Failed with exit code 3"

# ---- 4. fullOutput
script full.sh '# @raycast.title Full Output' '# @raycast.mode fullOutput' \
    'printf "line one\n\033[31mred line\033[0m\nline three\n"'
script long.sh '# @raycast.title Long Output' '# @raycast.mode fullOutput' 'seq 1 3000'
sleep 1.1; rf_snap 'full output|enter' >/dev/null
waitfor 'grep -q "exit full.sh" $T/log' 30
s=$(rf_snap '@same')
check 4 "one row per line" has "$s" "> line one"
check 4 "ANSI codes stripped" has "$s" "  red line"
check 4 "third line" has "$s" "  line three"
s=$(rf_snap '@same|down'); check 4 "arrow keys move through lines" has "$s" "> red line"
pbget() { RF_PASTEBOARD=rayfast-test-$$ $RF_BIN --run scripts pb-get 2>/dev/null; }   # the instance's private clipboard
s=$(rf_snap '@same|enter'); check 4 "↩ copies the line" test "$(pbget)" = "red line"
rf_snap 'full output|enter' >/dev/null; waitfor 'test $(grep -c "exit full.sh" $T/log) -ge 2' 30
rf_snap '@same|cmdenter' >/dev/null; check 4 "⌘↩ copies everything, without the colour codes" test "$(pbget)" = $'line one\nred line\nline three'

rf_snap 'long output|enter' >/dev/null; waitfor 'grep -q "exit long.sh" $T/log' 30
s=$(rf_snap '@same'); check 4 "long output capped with a note" has "$s" "showing the first 2000 of 3000 lines"
check 4 "capped at 2000 lines" eval 'has "$s" "  2000" && hasnt "$s" "  2001"'

# ---- 5. arguments
script args.sh '# @raycast.title Ping Host' '# @raycast.mode compact' \
    '# @raycast.argument1 { "type": "text", "placeholder": "host" }' \
    '# @raycast.argument2 { "type": "dropdown", "placeholder": "count", "data": [{"title": "One", "value": "1"}, {"title": "Two", "value": "2"}] }' \
    '# @raycast.argument3 { "type": "password", "placeholder": "secret", "optional": true }' \
    'echo "got $1 $2 [$3]"'
sleep 1.1
s=$(rf_snap 'ping host|enter'); check 5 "asks for argument 1 with its placeholder" has "$s" "[host]"
s=$(rf_snap '@same|enter'); check 5 "a required argument can't be left empty" eval 'has "$s" "[host]" && has "$s" "= host is required"'
s=$(rf_snap '@same|q=example.com|enter'); check 5 "dropdown lists its choices" eval 'has "$s" "[count]" && has "$s" "  Two"'
s=$(rf_snap '@same|down|enter|q=hunter2'); check 5 "optional argument says so" has "$s" "[secret (optional)]"
check 5 "password not echoed into the snapshot (field or rows)" eval 'hasnt "$s" hunter2 && has "$s" "? ••••••• "'
s=$(rf_snap '@same|enter')
waitfor 'grep -q "exit args.sh" $T/log' 30
s=$(rf_snap '@same'); check 5 "values passed as \$1..\$3" has "$s" "got example.com 2 [hunter2]"
check 5 "password never echoed into the log" eval "! grep -q hunter2 $T/log $T/err.log"
script onearg.sh '# @raycast.title Lookup' '# @raycast.argument1 { "type": "text", "placeholder": "word" }' 'echo "looked up $1"'
sleep 1.1; rf_snap 'lookup banana|enter' >/dev/null; waitfor 'grep -q "exit onearg.sh" $T/log' 30
s=$(rf_snap '@same'); check 5 "'title text' at the root passes text as argument 1" has "$s" "looked up banana"

# ---- 6. needsConfirmation
script confirm.sh '# @raycast.title Dangerous Thing' '# @raycast.needsConfirmation true' "touch $T/confirmed"
sleep 1.1
s=$(rf_snap 'dangerous thing|enter'); sleep 0.5
check 6 "↩ asks first" test ! -e $T/confirmed
s=$(rf_snap '@same|esc'); sleep 0.5; check 6 "esc cancels" test ! -e $T/confirmed
rf_snap 'dangerous thing|enter|enter' >/dev/null; sleep 0.5
check 6 "a double-tapped ↩ does not confirm (review f2)" test ! -e $T/confirmed
rf_snap '@same|enter' >/dev/null; waitfor "test -e $T/confirmed" 30
check 6 "↩ on the confirm view runs it" test -e $T/confirmed

# ---- 7. inline
script inline.sh '# @raycast.title Inline Clock' '# @raycast.mode inline' '# @raycast.refreshTime 1m' \
    "echo run >> $T/inline-runs; echo inline-value"
sleep 1.1; rf_snap 'inline clock' >/dev/null; sleep 1
s=$(rf_snap 'inline clock'); check 7 "subtitle is the first output line" has "$s" "Inline Clock | inline-value"
rf_snap 'inline clock' >/dev/null; sleep 0.5
check 7 "not re-run inside its refresh interval" test "$(wc -l < $T/inline-runs 2>/dev/null)" -eq 1
script tick.sh '# @raycast.title Inline Tick' '# @raycast.mode inline' '# @raycast.refreshTime 10s' \
    "echo run >> $T/tick-runs; printf '\033[1mtick %s\033[0m\nsecond line\n' \$(wc -l < $T/tick-runs)"
sleep 1.1; rf_snap 'inline tick' >/dev/null; waitfor "test -s $T/tick-runs" 30; sleep 0.3
s=$(rf_snap 'inline tick'); check 7 "first line only, ANSI stripped" has "$s" "Inline Tick | tick 1"
rf_snap 'say hello' >/dev/null; sleep 11   # past the interval, the launcher open but not showing it: no run
check 7 "never runs while not shown (no query names it)" test "$(wc -l < $T/tick-runs)" -eq 1
rf_snap 'inline tick' >/dev/null; waitfor "test \$(wc -l < $T/tick-runs) -ge 2" 30; sleep 0.3
s=$(rf_snap 'inline tick'); check 7 "refreshed once the interval has passed" has "$s" "Inline Tick | tick 2"
check 7 "last value kept on disk for after a respawn" grep -q "tick 2" $T/data/inline.plist
# left open on the row, no keystrokes: it refreshes by itself once the interval passes
waitfor "test \$(wc -l < $T/tick-runs) -ge 3" 150
check 7 "refreshes on its own while the launcher stays open on it" test "$(wc -l < $T/tick-runs)" -ge 3
sleep 0.3; s=$(rf_snap 'inline tick')
check 7 "the refreshed value is shown" has "$s" "Inline Tick | tick 3"
rf_snap 'inline tick|esc' >/dev/null; n=$(wc -l < $T/tick-runs); sleep 12
check 7 "no timer runs once the launcher is hidden" test "$(wc -l < $T/tick-runs)" -eq $n

# ---- 8. environment and safety
script env.sh '# @raycast.title Show Env' "# @raycast.currentDirectoryPath $T" \
    'read x; echo "stdin=$? cwd=$(pwd -P) path=$PATH"'
sleep 1.1; rf_snap 'show env|enter' >/dev/null; waitfor 'grep -q "exit env.sh" $T/log' 30
s=$(rf_snap '@same')
check 8 "cwd = currentDirectoryPath" has "$s" "cwd=${T:A}"
check 8 "stdin closed" has "$s" "stdin=1"
LOGIN_PATH=$(env -i HOME=$HOME USER=$USER $SHELL -lc 'print -r -- $PATH' 2>/dev/null)
check 8 "login-shell PATH, cached on disk" test -n "$(ls $T/data/*path* 2>/dev/null)"
check 8 "PATH has the login shell's first entry" has "$s" "path=${LOGIN_PATH%%:*}"
kill $RF_PID; waitfor "! kill -0 $RF_PID 2>/dev/null" 30
check 8 "SIGTERM still quits rayfast once no script runs" eval "! kill -0 $RF_PID 2>/dev/null"
kill -9 $RF_PID 2>/dev/null   # (only if it ignored SIGTERM: our own test instance)
rf_stop

# ---- 8 (timeout and no orphans: a fresh instance with a 2 s timeout)
rf_dirs; export RF_SCRIPTS_LOG=$RF_T/log; T=$RF_T
print "scripts.timeout = 2" > $T/cfg/config
script hang.sh '# @raycast.title Hang Forever' '# @raycast.mode silent' "sleep 300 & echo \$! > $T/child; sleep 300"
rf_start
rf_snap 'hang forever|enter' >/dev/null; waitfor "test -s $T/child" 30; CHILD=$(<$T/child)
waitfor 'grep -q "exit hang.sh" $T/log' 50
check 8 "timeout kills the script's whole process group" eval "! kill -0 $CHILD 2>/dev/null"
script hang2.sh '# @raycast.title Hang Again' '# @raycast.mode silent' "echo \$\$ > $T/child2; sleep 300"
print "scripts.timeout = 600" > $T/cfg/config
sleep 1.1; rf_snap 'hang again|enter' >/dev/null; waitfor "test -s $T/child2" 30; CHILD2=$(<$T/child2)
kill $RF_PID; wait $RF_PID 2>/dev/null; sleep 0.3
check 8 "nothing left running after rayfast quits" eval "! kill -0 $CHILD2 2>/dev/null"
kill -9 $CHILD2 2>/dev/null   # (only if the check above failed: it's our own test script)
# a crash (SIGKILL) can't clean up: the next start reaps what it left, and nothing else
script hang3.sh '# @raycast.title Hang Crash' '# @raycast.mode silent' "sleep 300 & echo \$! > $T/child3b; echo \$\$ > $T/child3; sleep 300"
rf_start
rf_snap 'hang crash|enter' >/dev/null; waitfor "test -s $T/child3 -a -s $T/child3b" 30; CHILD3=$(<$T/child3) CHILD3B=$(<$T/child3b)
check 8 "running groups are listed on disk" grep -q "^$CHILD3 " $T/data/running
kill -9 $RF_PID; wait $RF_PID 2>/dev/null; sleep 0.3
check 8 "(a SIGKILLed rayfast leaves its script running)" kill -0 $CHILD3
/usr/bin/perl -e 'setpgrp(0, 0); sleep 300' & DECOY=$!; sleep 0.3   # its own group: a "reused" pid with another start time
print "$DECOY 12345" >> $T/data/running
rf_start; waitfor "! kill -0 $CHILD3 2>/dev/null && ! kill -0 $CHILD3B 2>/dev/null" 5
check 8 "the next start kills what a crash left running" eval "! kill -0 $CHILD3 2>/dev/null && ! kill -0 $CHILD3B 2>/dev/null"
check 8 "a recorded pid now owned by another process is left alone" kill -0 $DECOY
check 8 "the list is gone once reaped" test ! -e $T/data/running
kill $DECOY; kill -9 $CHILD3 $CHILD3B 2>/dev/null   # ours; the kill -9 only if the check failed
rf_stop

# ---- 8 (review c1, w1: a slow login shell never blocks the launcher; a daemon holding stdout never holds the run)
rf_dirs; export RF_SCRIPTS_LOG=$RF_T/log; T=$RF_T
print -r -- $'#!/bin/sh\nexec /bin/sleep 12' > $T/slowshell; chmod +x $T/slowshell
script slowpath.sh '# @raycast.title Slow Path' 'echo ran'
SHELL=$T/slowshell rf_start
t0=$EPOCHREALTIME; rf_snap 'slow path|enter' >/dev/null; t1=$EPOCHREALTIME
check 8 "↩ with a 12 s login shell answers at once (< 1 s)" test $(( t1 - t0 < 1 )) -eq 1
waitfor 'grep -q "exit slowpath.sh" $T/log' 90
check 8 "…and the script runs once the 5 s login-shell guard gives up" eval "(( EPOCHREALTIME - t0 < 8 ))"
s=$(rf_snap '@same'); check 8 "…with the fallback PATH" has "$s" "ran"
rf_stop
rf_dirs; export RF_SCRIPTS_LOG=$RF_T/log; T=$RF_T
script daemon.sh '# @raycast.title Daemon Starter' \
    "/usr/bin/perl -e 'setpgrp(0, 0); sleep 20' & echo \$! > $T/daemon" 'sleep 0.2; echo started'
rf_start
rf_snap 'daemon starter|enter' >/dev/null; sleep 2.5; s=$(rf_snap '@same')
check 8 "a daemon that keeps stdout open doesn't keep the run going" has "$s" "= Finished"
check 8 "…and its output is shown" has "$s" "started"
kill $(<$T/daemon) 2>/dev/null   # ours: it left the script's group on purpose
rf_stop

# ---- 2. silent (a fresh instance: it waits out a respawn)
rf_dirs; export RF_SCRIPTS_LOG=$RF_T/log; T=$RF_T
script quiet.sh '# @raycast.title Quiet Job' '# @raycast.mode silent' "echo begun > $T/quiet; sleep 6; echo done >> $T/quiet"
rf_start
rf_snap 'quiet job|enter' >/dev/null
waitfor "test -s $T/quiet" 30; check 2 "↩ runs it" test -s $T/quiet
sleep 5   # the launcher hid at once; a respawn would be due now
check 2 "no respawn while it runs" test "$(grep -c '^start' $T/log)" -eq 1
waitfor "grep -q done $T/quiet" 50; sleep 4.6
check 2 "the run finished" grep -q done $T/quiet
check 2 "hid at once, respawned after the run" test "$(grep -c '^start' $T/log)" -eq 2
rf_stop

# ---- 9. hotkeys
rf_dirs; export RF_SCRIPTS_LOG=$RF_T/log; T=$RF_T
script hk/silent.sh '# @raycast.title Hotkey Silent' '# @raycast.mode silent' "touch $T/hk-silent"
script hk/compact.sh '# @raycast.title Hotkey Compact' 'echo from-hotkey'
rf_start   # no query first: the hotkey is the first thing that touches the folder
rf_snap '|cmd=scripts.hk/silent.sh' >/dev/null; waitfor "test -e $T/hk-silent" 30
check 9 "cmd:scripts.<rel> runs a silent script without a query" test -e $T/hk-silent
check 9 "silent via hotkey ran as silent" grep -q "run hk/silent.sh silent" $T/log
rf_snap '|cmd=scripts.hk/compact.sh' >/dev/null; waitfor 'grep -q "exit hk/compact.sh" $T/log' 30
s=$(rf_snap '@same'); check 9 "other modes open the launcher on the result" eval 'has "$s" "# Hotkey Compact" && has "$s" "> from-hotkey"'
rf_stop

# ---- 10. create / reveal
rf_dirs; export RF_SCRIPTS_LOG=$RF_T/log RF_DRYRUN=1; T=$RF_T
rf_start
TN=${T//\/\//\/}   # $TMPDIR ends in /, so $T has a // that the app's paths don't
s=$(rf_snap 'create script command|enter'); check 10 "Create Script Command writes a template" test -x $T/cfg/scripts/my-script.sh
check 10 "the template is commented Raycast metadata" grep -q '^# @raycast.title My Script$' $T/cfg/scripts/my-script.sh
check 10 "dry run: no editor opened, says what it would open" grep -q "dry-run: open -t $TN/cfg/scripts/my-script.sh" $T/err.log
rf_snap 'create script command|enter' >/dev/null
check 10 "a second one never overwrites the first" eval "test -x $T/cfg/scripts/my-script-2.sh && grep -q '@raycast.title My Script 2' $T/cfg/scripts/my-script-2.sh"
sleep 1.1; s=$(rf_snap 'my script 2'); check 10 "the new script is a command at once" has "$s" "My Script 2 | My Scripts {scripts.my-script-2.sh}"
s=$(rf_snap 'reveal scripts folder|enter'); check 10 "Reveal Scripts Folder (dry run)" grep -q "^reveal $TN/cfg/scripts$" $T/log
check 10 "dry run: Finder not opened, says what it would open" grep -q "dry-run: open $TN/cfg/scripts$" $T/err.log
rf_stop; unset RF_DRYRUN

# ---- 11. idle cost with 200 scripts
if [[ $1 == quick ]]; then skip 11 "idle with 200 scripts (quick run)"; else
    make -C $RF_ROOT -s && build_base
    B=() M0=() M200=() D=()
    for k in {1..5}; do
        b=$(fp_start $BASE_BIN); m0=$(fp_start $RF_BIN); m200=$(fp_start $RF_BIN 200)
        B+=($b) M0+=($m0) M200+=($m200) D+=($(( m200 - m0 )))
        print "  idle pair $k: base $(mb $b), module $(mb $m0), module + 200 scripts $(mb $m200)"
    done
    rm -rf ${BASE_BIN:h:h:h:h}
    I0=$(median $M0); IB=$(median $B); DD=$(median $D)
    print "  median: base $(mb $IB), module $(mb $I0), 200 scripts adds $(( DD / 1048576.0 )) MB"
    check 11 "200 scripts cost nothing at idle (median paired difference < 0.1 MB)" test $(( DD / 1048576.0 < 0.1 )) -eq 1
    rf_dirs; for j in {1..200}; do script "gen/s$j.sh" "# @raycast.title Generated $j" "echo $j"; done
    RF_CONFIG_DIR=$RF_T/cfg RF_DATA_DIR=$RF_T/data $RF_BIN --run scripts list >/dev/null 2>&1   # cold: reads every head
    MS=$(RF_CONFIG_DIR=$RF_T/cfg RF_DATA_DIR=$RF_T/data $RF_BIN --run scripts list 2>&1 >/dev/null | sed -n 's/scan \(.*\) ms/\1/p')
    print "  first query after a respawn: scan of 200 scripts $MS ms"
    check 11 "first query after a respawn < 5 ms" test $(( MS < 5 )) -eq 1
    # the same with every script carrying its own image icon, in the app (the window renders at start, so CoreGraphics
    # is warm as it is for a user): a first instance decodes the tiles, a fresh one (= a respawn) maps them
    rf_stop; rf_dirs; export RF_SCRIPTS_LOG=$RF_T/log; mkdir -p $RF_T/cfg/scripts/gen/img; $PX make $RF_T/img.png 256 0 230 230
    for j in {1..200}; do cp $RF_T/img.png $RF_T/cfg/scripts/gen/img/s$j.png
        script "gen/s$j.sh" "# @raycast.title Generated $j" "# @raycast.icon img/s$j.png" "echo $j"; done
    # Pass mark: the icons' share of that query (logged by search() as "query T ms (icons I)") < 2 ms, median of 3
    # respawns. Not the whole query: 200 matching rows alone take 5.6-19.6 ms in the app on a loaded machine (s8), so a
    # total-time mark would measure the machine, not the icons.
    rf_start; rf_snap 'generated' >/dev/null; COLD=$(sed -n 's/.*(icons \(.*\))/\1/p' $RF_T/log | tail -1)
    IC=() TT=()
    for k in 1 2 3; do
        kill $RF_PID; wait $RF_PID 2>/dev/null; : > $RF_T/log
        rf_start; rf_snap 'generated' >/dev/null; l=$(grep -m1 'query .* (icons ' $RF_T/log)
        TT+=($(print -r -- $l | sed -n 's/.*query \([0-9.]*\) ms.*/\1/p')) IC+=($(print -r -- $l | sed -n 's/.*(icons \([0-9.]*\)).*/\1/p'))
    done
    print "  first query 'generated' after a respawn, 200 matches each with a 256 px PNG icon: icons ${IC[*]} ms of ${TT[*]} ms (first time ever: icons $COLD ms, decoding)"
    check 11 "200 image icons add < 2 ms to the first query after a respawn (median of 3)" test $(( $(median ${IC:-99}) < 2 )) -eq 1
    rf_stop
fi

rm -rf ${PX:h}
passed=0; for i in {1..$TOTAL}; do (( ok[$i] )) && (( passed++ )); done
print "checklist: $passed/$TOTAL"
if [[ $1 == quick ]]; then print "idle: (skipped) (base skipped)"; else print "idle: $(mb $I0) (base $(mb $IB))"; fi
