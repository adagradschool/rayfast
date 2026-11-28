#!/bin/zsh
# Clipboard history checklist (lane file items 1-10), headless. Prints, last:
#   checklist: <passed>/10
#   idle: <footprint> (base <footprint>)
# Never touches the real clipboard: the instance and the helper both use the private pasteboard rayfast-test-$$.
cd ${0:A:h:h:h}
source tests/mod.sh
PB=rayfast-test-$$
typeset -A ok
clip() { RF_PASTEBOARD=$PB RF_DATA_DIR=$RF_T/data $RF_BIN --run clipboard "$@"; }
fail() { print -r -- "FAIL $1: $2"; ok[$1]=0; diag; }
# Twice in full runs a copy was never recorded (s5 pin g, s6 'after tags'); neither reproduced alone (3/3) or under 4x
# parallel load (12/12); both runs were on a Mac dropping in and out of sleep. On a failure, show whether the copy is
# on the pasteboard at all (pb) and what the log's tail holds, to tell a lost write from a lost append.
diag() { print -r -- "  diag: pid $RF_PID alive=$(kill -0 $RF_PID 2>/dev/null && print 1 || print 0) pb=[$(clip pb-get 2>&1 | head -c 60)] records=$(clip records) tail=[$(tail -c 160 $RF_T/data/clipboard/history 2>/dev/null | tr '\n\t' '| ')]"; }
pass() { [[ ${ok[$1]} == 0 ]] || ok[$1]=1; }
fpkb() { print $(( $(footprint -f bytes $RF_PID | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p' | head -1) / 1024 )); }
# Test instances keep their icon cache in their data dir: an empty one loads IconServices at start (+3.5 MB), so
# every start here gets a warmed copy (the first start ever fills it).
ICONS=${TMPDIR:-/tmp}/rayfast-clipboard-icons.bin
start() {
    rf_dirs; [[ -s $ICONS ]] && cp $ICONS $RF_T/data/icons.bin
    rf_start
    [[ -s $ICONS ]] || { sleep 2; cp $RF_T/data/icons.bin $ICONS 2>/dev/null; }
}
base_build() {   # conclave/base, built once per base commit in $TMPDIR
    local B=${TMPDIR:-/tmp}/rf-clipboard-base rev=$(git rev-parse conclave/base)
    if [[ $(cat $B/.rev 2>/dev/null) != $rev ]]; then
        rm -rf $B; mkdir -p $B; git archive conclave/base | tar -x -C $B && make -C $B -s >/dev/null 2>&1 && print $rev > $B/.rev
    fi
}
idle() {   # "<mine> <base>": median footprint (KB) 3 s after start, 5 starts each, interleaved with conclave/base built
    # in $TMPDIR. Per-start footprint is bimodal (~10.0 / ~12.4 MB, libmalloc reclaim timing) for both, so only an
    # interleaved comparison means anything (system lane's idle_ab, tests/system/run.sh).
    local B=${TMPDIR:-/tmp}/rf-clipboard-base mine=$RF_BIN a=() b=() i w
    base_build
    for i in 1 2 3 4 5; do for w in base mine; do
        RF_BIN=$mine; [[ $w == base ]] && RF_BIN=$B/build/rayfast.app/Contents/MacOS/rayfast
        start; sleep 3; if [[ $w == base ]]; then b+=($(fpkb)); else a+=($(fpkb)); fi; rf_stop
    done; done
    RF_BIN=$mine
    a=(${(on)a}); b=(${(on)b})
    print -u2 "  idle samples: mine $a; base $b"
    print "$a[3] $b[3]"
}
[[ $1 == --idle ]] && { make -s >/dev/null; idle; exit; }
respawn() { kill -USR1 $RF_PID; sleep 0.3; kill -USR1 $RF_PID; sleep 5; }   # show, hide, wait out the 4 s re-exec

make -s >/dev/null || { print "build failed"; exit 1; }

# ---- 1. watcher: polls changeCount, records new copies, survives respawn without re-recording
start
clip pb-set "first copy"; sleep 1.2
[[ $(clip list) == *"first copy"* ]] || fail 1 "copy not recorded"
respawn
[[ $(clip list | grep -c "first copy") == 1 ]] || fail 1 "respawn re-recorded the current item"
clip pb-set "after respawn"; sleep 1.2
[[ $(clip list) == *"after respawn"* ]] || fail 1 "watcher dead after respawn"
w=$(top -l 2 -s 10 -pid $RF_PID -stats idlew,cpu | tail -1)
print "  idle wakeups/10s, cpu: $w"
(( ${${${=w}[1]}%+} <= 30 )) || fail 1 "too many wakeups: $w"
pass 1

# ---- 2. text store: append-only, dedupe to top, caps
clip pb-set "dup"; sleep 1; clip pb-set "other"; sleep 1; clip pb-set "dup"; sleep 1
[[ $(clip list | head -1) == *$'\t'dup ]] || fail 2 "duplicate not on top"
(( $(clip list | grep -c $'\tdup$') == 1 )) || fail 2 "duplicate repeated"
s1=$(stat -f %z $RF_T/data/clipboard/history 2>/dev/null); i1=$(stat -f %i $RF_T/data/clipboard/history 2>/dev/null)
clip pb-set "one more"; sleep 1
i2=$(stat -f %i $RF_T/data/clipboard/history 2>/dev/null); s2=$(stat -f %z $RF_T/data/clipboard/history 2>/dev/null)
[[ -n $i1 && $i1 == $i2 && $s2 -gt $s1 ]] || fail 2 "store not appended in place"
head -c 1100000 /dev/zero | tr '\0' x > $RF_T/big; clip pb-set-file $RF_T/big; sleep 1
[[ $(clip list | head -1) == *"one more" ]] || fail 2 "1 MB entry stored"
# any app writes the source tag: whitespace or a newline in it must not break the log (review k4)
clip pb-set "ws tag" "org.nspasteboard.source= "; sleep 1
clip pb-set "nl tag" $'org.nspasteboard.source=a\n\tb'; sleep 1
clip pb-set "after tags"; sleep 1
l=$(clip list 2>&1); rc=$?
[[ $rc == 0 && $l == *$'\tws tag'* && $l == *$'\tnl tag'* && $(print -r -- $l | head -1) == *$'\tafter tags' ]] || fail 2 "odd source tags broke the log ($rc): $l"
[[ $(clip rows "tag") == *"ws tag | "* ]] && kill -0 $RF_PID || fail 2 "odd source tags broke the view"
# a huge copy (read to learn it is over the cap) must not stay resident: the hidden process re-execs (review k5)
head -c 60000000 /dev/zero | tr '\0' x > $RF_T/huge; clip pb-set-file $RF_T/huge; rm -f $RF_T/huge; sleep 1.5
a=$(fpkb); sleep 5; b=$(fpkb); print "  60 MB copy: footprint $a KB just after, $b KB 5 s later"
(( b < 20000 )) || fail 2 "a 60 MB copy stays resident: $a -> $b KB"   # resident it would be ~70 MB
[[ $(clip list | head -1) == *$'\tafter tags' ]] || fail 2 "the big copy was stored or re-recorded after the re-exec"
pass 2

# ---- 3. privacy
clip pb-set "secret-pw" org.nspasteboard.ConcealedType; sleep 1
clip pb-set "transient" org.nspasteboard.TransientType; sleep 1
clip pb-set "autogen" org.nspasteboard.AutoGeneratedType; sleep 1
[[ $(clip list) != *secret-pw* && $(clip list) != *transient* && $(clip list) != *autogen* ]] || fail 3 "concealed/transient entry stored"
[[ $(stat -f %Lp $RF_T/data/clipboard) == 700 && $(stat -f %Lp $RF_T/data/clipboard/history) == 600 ]] || fail 3 "store permissions"
[[ $(rf_snap 'clear clipboard history') == *"> Clear Clipboard History"* ]] || fail 3 "no Clear Clipboard History command"
[[ $(rf_snap 'delete') != *"> Clear Clipboard History"* ]] || fail 3 "'delete' lands on Clear Clipboard History"
v=$(rf_snap 'clear clipboard history|enter')
[[ $v == *"Clear Clipboard History?"* && $v == *"> Cancel"* && $v == *"pins included"* && -n $(clip list) ]] || fail 3 "Clear did not ask first: $v"
rf_snap 'clear clipboard history|enter|enter' >/dev/null; sleep 0.3
[[ -n $(clip list) ]] || fail 3 "↩ ↩ on Clear wiped the history"
[[ $(rf_snap '|cmd=clipboard.clear') == *"Clear Clipboard History?"* && -n $(clip list) ]] || fail 3 "the Clear hotkey did not ask first"
rf_snap 'clear clipboard history|enter|down|enter' >/dev/null; sleep 0.3
[[ -z $(clip list) && ! -e $RF_T/data/clipboard/history ]] || fail 3 "Clear Clipboard History left entries"
rf_stop
rf_dirs; print "clipboard.enabled = off" > $RF_T/cfg/config; start
clip pb-set "while off"; sleep 1.2
[[ -z $(clip list) ]] || fail 3 "recorded while clipboard.enabled = off"
rf_stop
rf_dirs; print "clipboard.ignore = com.example.other, com.example.Ignored" > $RF_T/cfg/config; start
clip pb-set "from ignored app" org.nspasteboard.source=com.example.ignored; sleep 1
clip pb-set "from other app" org.nspasteboard.source=com.example.fine; sleep 1
[[ $(clip list) != *"from ignored app"* ]] || fail 3 "ignored app recorded"
[[ $(clip list) == *"com.example.fine"*"from other app"* ]] || fail 3 "source app not attributed: $(clip list)"
pass 3
rf_stop

# ---- 2 (cont). clipboard.max drops the oldest; the view's open compacts the log
rf_dirs; print "clipboard.max = 5" > $RF_T/cfg/config; start
for i in 1 2 3 4 5 6 7; do clip pb-set "cap $i"; sleep 1; done
clip pb-set "cap 3"; sleep 1   # a duplicate: 8 records, 7 distinct
rf_snap 'clipboard history|enter' >/dev/null
l=$(clip list)
[[ $(print -r -- $l | wc -l | tr -d ' ') == 5 && $l != *"cap 1"* && $l != *"cap 2"* && $l == *"cap 3"* ]] || fail 2 "clipboard.max = 5 kept: $l"
[[ $(clip records) == 5 ]] || fail 2 "log not compacted to 5 records: $(clip records)"
[[ $(stat -f %Lp $RF_T/data/clipboard/history) == 600 ]] || fail 2 "compacted log permissions"
pass 2
rf_stop

# ---- 2 (cont). a user who never opens the view: past 1 MB the log is compacted by a short-lived child
rf_dirs; print "clipboard.max = 5" > $RF_T/cfg/config
mkdir -p -m 700 $RF_T/data/clipboard
awk -v t=$(date +%s) 'BEGIN { p = sprintf("%400s", ""); gsub(/ /, "x", p)
    for (i = 0; i < 3000; i++) { s = i " " p; printf "E %d %d t -\t\n%s\n", t, length(s), s } }' > $RF_T/data/clipboard/history
chmod 600 $RF_T/data/clipboard/history
start
clip pb-set "after the big log"; sleep 2
sz=$(stat -f %z $RF_T/data/clipboard/history)
(( sz < 20000 )) || fail 2 "1.2 MB log not compacted without the view: $sz bytes, $(clip records) records"
[[ $(clip list | head -1) == *"after the big log"* && $(clip records) == 5 ]] || fail 2 "auto-compaction lost the new entry: $(clip list | head -2)"
clip pb-set "and one more"; sleep 1
[[ $(clip records) == 6 && $(stat -f %Lp $RF_T/data/clipboard/history) == 600 ]] || fail 2 "append after auto-compaction: $(clip records) records"
pass 2
rf_stop

# ---- 4. view: rows, filter, speed
start
clip pb-set $'  \n  line one  \nline two' org.nspasteboard.source=com.apple.TextEdit; sleep 1
clip pb-set "#ff8800"; sleep 1; clip pb-set "https://example.com/x"; sleep 1
v=$(rf_snap 'clipboard history|enter')
[[ $v == *"> https://example.com/x | "*" · now"*"#ff8800"*"line one | "* ]] || fail 4 "view rows: $v"
r=$(clip rows "")
[[ $r == *"https://example.com/x | "*" · now | Link"* && $r == *"#ff8800 | "*"| Color"* && $r == *"line one | TextEdit · now | Text"* ]] || fail 4 "row types/subtitles: $r"
[[ $(rf_snap 'clipboard history|enter|q=TWO line') == *"> line one"* ]] || fail 4 "multi-word case-insensitive filter"
[[ $(rf_snap 'clipboard history|enter|q=line zzz') != *"line one"* ]] || fail 4 "filter keeps rows missing a word"
[[ $(rf_snap '|cmd=clipboard.history') == *"> https://example.com/x"* ]] || fail 4 "hotkey (cmd=clipboard.history) does not open the view"
t=$(clip bench-filter 5000 2>/dev/null); print "  filter 5000: ${t:-n/a} ms"
[[ -n $t ]] && (( t < 10 )) || fail 4 "5000-entry filter not under 10 ms"
pass 4

# ---- 5. paste back
r0=$(clip records)
rf_snap 'clipboard history|enter|down|down|enter' >/dev/null; sleep 0.8
[[ $(clip pb-get) == $'  \n  line one  \nline two' ]] || fail 5 "↩ did not put the entry on the pasteboard: $(clip pb-get)"
[[ $(clip list | head -1) == *"line one"* ]] || fail 5 "pasted entry not moved to the top"
[[ $(clip records) == $((r0+1)) ]] || fail 5 "own write recorded as a new copy ($r0 -> $(clip records) records)"
clip pb-set "zzz"; sleep 1
rf_snap 'clipboard history|enter|down|cmdenter' >/dev/null; sleep 0.3
[[ $(clip pb-get) == *"line one"* ]] || fail 5 "⌘↩ did not copy"
pass 5

rf_stop

# ---- 6. pins: ⌘⇧P pins/unpins; pinned sort first, survive the cap and a respawn
rf_dirs; print "clipboard.max = 3" > $RF_T/cfg/config; start
for i in a b c; do clip pb-set "pin $i"; sleep 1; done
v=$(rf_snap 'clipboard history|enter|down|down|key=cmd+shift+p')   # rows: c b a -> pin "pin a"
[[ $v == *"# Clipboard History"$'\n'"  pin a | Pinned · "*"> pin b"* ]] || fail 6 "pinned row not first, or selection moved: $v"
[[ $v == *"⌘⇧P"* ]] || fail 6 "hint does not name the pin key"
for i in d e f g; do clip pb-set "pin $i"; sleep 1; done
rf_snap 'clipboard history|enter' >/dev/null   # opening compacts to the cap
l=$(clip list)
[[ $(print -r -- $l | head -1) == "P "*"pin a" && $l == *"pin g"*"pin f"*"pin e"* && $l != *"pin d"* ]] || fail 6 "pin lost to the cap or order wrong: $l"
respawn
[[ $(clip list | head -1) == "P "*"pin a" ]] || fail 6 "pin did not survive respawn"
v=$(rf_snap 'clipboard history|enter|key=cmd+shift+p')
[[ $v == *"> pin g"* && $v != *"pin a | Pinned"* ]] || fail 6 "unpin: $v"
pass 6

# ---- 7. delete one entry (⌃X); the next row takes the selection; a later copy of it is recorded again
v=$(rf_snap 'clipboard history|enter|down|key=ctrl+x')
[[ $v != *"pin f"* && $v == *"> pin e"* ]] || fail 7 "delete: $v"
[[ $(clip list) != *"pin f"* ]] || fail 7 "deleted entry still stored"
(( $(grep -a -c "pin f" $RF_T/data/clipboard/history) == 0 )) || fail 7 "deleted text still in the log file (review k1)"
[[ $v == *"⌃X"* ]] || fail 7 "hint does not name the delete key"
respawn; [[ $(clip list) != *"pin f"* ]] || fail 7 "deleted entry back after respawn"
clip pb-set "pin f"; sleep 1
[[ $(clip list | head -1) == *"pin f" ]] || fail 7 "copy after delete not recorded"
pass 7
rf_stop

# ---- 8. files are stored as paths (row = file name, ↩ puts the file reference back); links get a Link type
start
mkdir -p $RF_T/docs; touch "$RF_T/docs/Q3 report.pdf" $RF_T/docs/b.txt
clip pb-set-files "$RF_T/docs/Q3 report.pdf"; sleep 1
clip pb-set-files $RF_T/docs/b.txt "$RF_T/docs/Q3 report.pdf"; sleep 1
clip pb-set "https://example.org/page"; sleep 1
[[ $(clip list) == *"- f "*$'\t'"$RF_T/docs/Q3 report.pdf"* ]] || fail 8 "file not stored as its path: $(clip list)"
r=$(clip rows "")
[[ $r == *"https://example.org/page | "*"| Link"* ]] || fail 8 "link type: $r"
[[ $r == *"b.txt + 1 more | "*"| File"* && $r == *"Q3 report.pdf | "*"| File"* ]] || fail 8 "file rows: $r"
r=$(clip rows "q3 report"); [[ $r == *"Q3 report.pdf | "* && $r != *example.org* ]] || fail 8 "filter by file name: $r"
rf_snap 'clipboard history|enter|down|down|enter' >/dev/null; sleep 0.3
[[ $(clip pb-get-files) == "$RF_T/docs/Q3 report.pdf" ]] || fail 8 "↩ did not put the file back: $(clip pb-get-files)"
[[ $(clip records) == 4 ]] || fail 8 "own file write recorded as a new copy: $(clip records) records"
rf_snap 'clipboard history|enter|down|down|cmdenter' >/dev/null; sleep 0.3
[[ $(clip pb-get-files) == "$RF_T/docs/b.txt"$'\n'"$RF_T/docs/Q3 report.pdf" ]] || fail 8 "two files not put back: $(clip pb-get-files)"
pass 8
rf_stop

# ---- 9. images: PNG files on disk (converted by a child), "Image W×H" rows with a colour thumbnail, ↩ puts the PNG back
ICNS=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources
start; D=$RF_T/data/clipboard
sips -s format png -z 720 1280 $ICNS/AirDrop.icns --out $RF_T/a.png >/dev/null 2>&1
sips -s format tiff -z 300 400 $ICNS/Actions.icns --out $RF_T/b.tiff >/dev/null 2>&1
clip pb-set-data public.png $RF_T/a.png; sleep 1.5
l=$(clip list | head -1); h=${${l#*$'\t'}%% *}
[[ $l == "- i "*$'\t'*" 1280x720" && -n $h ]] || fail 9 "png not stored: $l"
cmp -s $D/img/$h.png $RF_T/a.png || fail 9 "stored PNG differs from the copied one"
[[ $(stat -f %Lp $D/img) == 700 && $(stat -f %Lp $D/img/$h.png) == 600 ]] || fail 9 "image permissions"
[[ $(stat -f %z $D/img/$h.thumb 2>/dev/null) == 9216 && $(LC_ALL=C tr -d '\0' < $D/img/$h.thumb | wc -c) -gt 2000 ]] || fail 9 "no 48x48 thumbnail"
clip pb-set-data public.tiff $RF_T/b.tiff; sleep 1.5
l=$(clip list | head -1); h2=${${l#*$'\t'}%% *}
[[ $l == "- i "*" 400x300" && $(sips -g pixelWidth $D/img/$h2.png 2>/dev/null) == *"pixelWidth: 400"* ]] || fail 9 "tiff not stored as png: $l"
r=$(clip rows "")
[[ $r == "Image 400×300 | "*"now | Image | thumb"$'\n'"Image 1280×720 | "*"| Image | thumb"* ]] || fail 9 "image rows: $r"
[[ $(clip rows "image 1280") == "Image 1280×720"* && $(clip rows "image 1280" | wc -l | tr -d ' ') == 1 ]] || fail 9 "filter by Image W×H"
[[ $(clip rows "$h") != *Image* ]] || fail 9 "the hash is searchable"
clip pb-set-data public.png $RF_T/a.png; sleep 1.5
(( $(clip list | grep -c " 1280x720$") == 1 )) && [[ $(clip list | head -1) == *" 1280x720" ]] || fail 9 "same image twice not deduped to the top"
clip pb-set "zzz"; sleep 1
r0=$(clip records)
rf_snap 'clipboard history|enter|down|enter' >/dev/null; sleep 0.5
clip pb-get-data public.png $RF_T/out.png; cmp -s $RF_T/out.png $RF_T/a.png || fail 9 "↩ did not put the PNG back"
[[ $(clip records) == $((r0+1)) && $(clip list | head -1) == *" 1280x720" ]] || fail 9 "own image write recorded as a copy or not moved up"
[[ -z $(ps -A -o ppid=,stat= | awk -v p=$RF_PID '$1==p && $2~/Z/') ]] || fail 9 "ingest child left a zombie"
rf_snap 'clipboard history|enter|key=ctrl+x' >/dev/null; sleep 0.3
[[ ! -e $D/img/$h.png && ! -e $D/img/$h.thumb && $(clip list) != *1280x720* ]] || fail 9 "deleted image left its files"
rf_snap 'clear clipboard history|enter|down|enter' >/dev/null; sleep 0.3
[[ ! -e $D/img/$h2.png ]] || fail 9 "Clear left image files"
rf_stop
rf_dirs; print "clipboard.imagemax = 0.1" > $RF_T/cfg/config; start   # 0.1 MB: the 200 KB PNG is over the cap
clip pb-set-data public.png $RF_T/a.png; sleep 1.5
[[ -z $(clip list) && -z $(ls $RF_T/data/clipboard/img 2>/dev/null) ]] || fail 9 "image over clipboard.imagemax stored"
pass 9
rf_stop

# ---- 10. memory: 500 entries (50 images) open within 3 MB of base's open launcher; the respawn after hiding goes back to idle
SEED=${TMPDIR:-/tmp}/rf-clipboard-seed500   # built once with this binary: a text record per entry, every 10th an image
if [[ ! -s $SEED/clipboard/history || $(ls $SEED/clipboard/img 2>/dev/null | wc -l) -ne 100 ]]; then
    rm -rf $SEED; mkdir -p $SEED/src $SEED/clipboard
    sips -s format png -z 720 1280 $ICNS/AirDrop.icns --out $SEED/src/base.png >/dev/null 2>&1
    now=$(date +%s)
    for i in {1..500}; do
        if (( i % 10 == 0 )); then
            sips -z $((300 + i)) $((500 + i)) $SEED/src/base.png --out $SEED/src/$i.png >/dev/null 2>&1
            RF_DATA_DIR=$SEED $RF_BIN --run clipboard add-image $SEED/src/$i.png
        else
            p="entry $i: some copied text from a document, with a few more words to make it look real ${(l:$((i % 200)):: :)}tail $i"
            printf 'E %d %d t com.apple.TextEdit\tTextEdit\n%s\n' $((now - (500 - i) * 60)) ${#p} "$p" >> $SEED/clipboard/history
        fi
    done
    rm -rf $SEED/src
fi
B=${TMPDIR:-/tmp}/rf-clipboard-base; base_build
mine=$RF_BIN; oi=() oo=() oa=() bi=() bo=() ba=()
for r in 1 2 3; do for w in base mine; do   # interleaved: footprint drifts and is bimodal
    RF_BIN=$mine; [[ $w == base ]] && RF_BIN=$B/build/rayfast.app/Contents/MacOS/rayfast
    rf_dirs; cp -R $SEED/clipboard $RF_T/data/; start; sleep 3; i0=$(fpkb)
    if [[ $w == base ]]; then rf_step ''; else rf_step 'clipboard history|enter'; fi   # base: its plain open launcher
    sleep 0.5; o=$(fpkb)
    [[ $w == mine ]] && { [[ $(head -3 $RF_T/snap.txt) == *"> Image 1000×800"* && $(cat $RF_T/snap.txt) == *"= 500 entries"* ]] || fail 10 "view with 500 entries: $(head -3 $RF_T/snap.txt)"; }
    kill -USR1 $RF_PID; sleep 7; a=$(fpkb)   # hide, then the ~4 s respawn
    if [[ $w == base ]]; then bi+=($i0) bo+=($o) ba+=($a); else oi+=($i0) oo+=($o) oa+=($a); fi
    rf_stop
done; done
RF_BIN=$mine
oo=(${(on)oo}) bo=(${(on)bo}) oa=(${(on)oa}) ba=(${(on)ba}); idl=(${(on)oi} ${(on)bi}); idl=(${(on)idl})
print "  open: mine $oo (500 entries, 50 images) vs base $bo; after respawn: mine $oa, base $ba; idle before: mine $oi, base $bi"
(( oo[2] - bo[2] <= 3072 )) || fail 10 "open view $oo[2] KB > base open $bo[2] KB + 3 MB"
(( oa[2] <= idl[-1] + 300 )) || fail 10 "respawn did not return to idle: $oa[2] KB vs idle up to $idl[-1] KB"
pass 10

# ---- idle
m=($(idle))
n=0; for k in ${(k)ok}; do (( ok[$k] )) && (( n++ )); done
print "checklist: $n/10"
print "idle: $m[1] KB (base $m[2] KB)"
