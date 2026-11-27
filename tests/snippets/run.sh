#!/bin/zsh
# Snippets + quicklinks lane: every checklist item in .conclave/lanes/snippets.md as headless assertions.
# Prints PASS/FAIL/SKIP per assertion, then exactly "checklist: a/b" and "idle: X (base Y)".
#   tests/snippets/run.sh          everything
#   tests/snippets/run.sh noidle   skip the 5-start footprint median (fast iteration)
emulate -L zsh; setopt extendedglob; zmodload zsh/datetime
source ${0:A:h:h}/mod.sh
B=$RF_BIN
make -C $RF_ROOT -s >/dev/null || { print "build failed"; exit 1; }
T=$(mktemp -d ${TMPDIR:-/tmp}/rf-snip.XXXXXX)
typeset -A ITEM   # item -> 1 pass / 0 fail / 2 skip
for i in {1..11}; do ITEM[$i]=1; done
ok()   { print "PASS $1: $2"; }
bad()  { print "FAIL $1: $2"; ITEM[$1]=0; }
skip() { print "SKIP $1: $2"; ITEM[$1]=0; }
check() { local n=$1 d=$2; shift 2; if "$@" >/dev/null 2>&1; then ok $n $d; else bad $n $d; fi; }
eq() { [[ "$1" == "$2" ]] || { print -r -- "    got:  ${(q+)1}" >&2; print -r -- "    want: ${(q+)2}" >&2; return 1; } }
pb() { RF_PASTEBOARD=rayfast-test-$$ $B --run snippets pb-get; }
pbset() { RF_PASTEBOARD=rayfast-test-$$ $B --run snippets pb-set "$1"; }
parse() { $B --run snippets parse "$1"; }
body() { $B --run snippets body "$1" "$2"; }

# ---------- 1. snippet file format + parser
f=$T/empty; : > $f
check 1 "empty file: nothing, no problems" eq "$(parse $f)" ""
printf -- '--- Sig | sig mail\r\nBest,\r\nS\r\n\r\n--- Two\r\nx\r\n' > $f
check 1 "CRLF: two snippets, keywords" eq "$(parse $f)" $'Sig\tsig mail\t7\nTwo\t\t1'
check 1 "CRLF: body has no CR" eq "$(body $f Sig)" $'Best,\nS'
printf -- '# comment\n\n--- A\nline1\nlast line, no newline' > $f
check 1 "missing trailing newline" eq "$(body $f A)" $'line1\nlast line, no newline'
printf -- '--- Ünïcødé 名前 🙂 | émoji\nこんにちは\n' > $f
check 1 "unicode name + keywords" eq "$(parse $f)" $'Ünïcødé 名前 🙂\témoji\t15'
check 1 "unicode body by unicode name" eq "$(body $f 'Ünïcødé 名前 🙂')" 'こんにちは'
{ print -- '--- Big'; for i in {1..16384}; do print -r -- 'abcdefghijklmnopqrstuvwxyz0123456789 the quick brown fox jumps over'; done; print -- '--- After'; print after; } > $f
st=$EPOCHREALTIME; out=$(parse $f); el=$(( (EPOCHREALTIME - st) * 1000 ))
check 1 "1 MB body parsed whole (1114111 bytes)" eq "$out" $'Big\t\t1114111\nAfter\t\t5'
check 1 "1 MB body parses in < 500 ms (took ${el%.*} ms)" test ${el%.*} -lt 500
printf -- '--- Dup\none\n--- dup\ntwo\n--- Other\nthree\n' > $f
check 1 "duplicate names: first kept, problem noted" eq "$(parse $f)" $'Dup\t\t3\nOther\t\t5\nproblem: line 3: "dup" is already used above, skipped'
printf -- '--- Delims\n---\n\\--- not a header\n\\\\--- one backslash kept\n--- x not ---\n---- four\n' > $f
check 1 "bodies containing the delimiter" eq "$(body $f Delims)" $'---\n--- not a header\n\\--- one backslash kept'
check 1 "  ...next header still starts a snippet" eq "$(parse $f | cut -f1)" $'Delims\nx not ---'
printf -- 'stray text\n--- \nnameless body\n--- Empty\n\n   \n--- Fine\nok\n' > $f
check 1 "mistakes become problems, rest loads" eq "$(parse $f)" $'Fine\t\t2\nproblem: line 1: text before the first "--- name" line, ignored\nproblem: line 2: a snippet needs a name after "--- ", skipped\nproblem: line 4: "Empty" has no text, skipped'
printf -- '--- A\nkeep  \ntrailing   \n\n\t\n\n' > $f
check 1 "trailing blank lines dropped, trailing spaces of last line kept" eq "$(body $f A; print -n .)" $'keep  \ntrailing   .'
printf -- '\xef\xbb\xbf--- Bom\nx\n' > $f
check 1 "UTF-8 BOM ignored" eq "$(parse $f)" $'Bom\t\t1'
printf -- '--- Bad\n\xff\xfe\x80\n' > $f
check 1 "not UTF-8: a problem, no crash" eq "$(parse $f)" 'problem: the file is not UTF-8 text, nothing loaded'
# fuzz 1: random bytes and random line soup never crash
crash=0
for i in {1..40}; do
    head -c $((RANDOM % 4000)) /dev/urandom > $f; parse $f >/dev/null 2>&1; (( $? > 1 )) && crash=1
    : > $f; for j in {1..$((RANDOM % 40))}; do
        case $((RANDOM % 7)) in 0) print -rn -- '--- ';; 1) print -rn -- '\---';; 2) print -rn -- '| ';; 3) print -rn -- $'\r';; 4) print -rn -- '#';; 5) print -rn -- ' ';; esac >> $f
        print -r -- "w$((RANDOM % 5)) ${(l:$((RANDOM % 3)):: :)}" >> $f
    done; parse $f >/dev/null 2>&1; (( $? > 1 )) && crash=1
done
check 1 "fuzz: 80 random files, no crash" test $crash = 0
# fuzz 2: random snippets written with the escaping rule come back byte for byte
names=('Sig' 'Ünï' '名前' 'a b c' '🙂 face' 'x|y' 'dash - name' '#hash')
lines=('plain' '---' '--- looks like a header' '\--- has backslash' '\\---x' '  indented' '' 'tab	in' 'ends with |' '名前 🙂' '#not a comment')
fuzzok=1
for round in {1..15}; do
    : > $f; typeset -A want; want=()
    for k in {1..$((RANDOM % 6 + 1))}; do
        n="${names[RANDOM % $#names + 1]} $round-$k"; b=""
        for j in {1..$((RANDOM % 6 + 1))}; do b+="${lines[RANDOM % $#lines + 1]}"$'\n'; done
        b="${b%%$'\n'#}"; [[ -n ${b//[[:space:]]/} ]] || b="z"; b="${b%%[[:space:]]#}"   # what the parser keeps
        want[$n]=$b
        print -r -- "--- $n" >> $f
        for l in "${(@f)b}"; do [[ $l == (\\#)---* ]] && l="\\$l"; print -r -- "$l" >> $f; done
        (( RANDOM % 2 )) && print >> $f
    done
    for n in ${(k)want}; do got=$(body $f "$n"; print -n .); [[ "${got%.}" == "$want[$n]" ]] || { fuzzok=0; print -r -- "    round $round: ${(q+)n}: ${(q+)got%.} != ${(q+)want[$n]}" >&2; }; done
    [[ $(parse $f | grep -c '^problem') == 0 ]] || fuzzok=0
done
check 1 "fuzz: 15 random files round-trip every body" test $fuzzok = 1

# ---------- 2-6, 9-10: the snippets module in a headless instance
rf_dirs
cat > $RF_T/cfg/snippets <<'EOF'
# test snippets
--- Email signature | sig
Best regards,
Shivam

--- Greeting | hello
Hi {argument name="who"}, it is {date format="yyyy"}.
EOF
export RF_DRYRUN=1
rf_start
sleep 0.5
check 2 "nothing read in start()" eq "$(grep -c 'snippets: read' $RF_T/err.log)" 0
check 2 "found by keyword at the root" grep -qF 'Email signature | Best regards, {snippets.Email signature}' =(rf_snap 'sig')
check 2 "found by name" grep -qF 'Email signature |' =(rf_snap 'email sig')
check 2 "file read once" eq "$(grep -c 'snippets: read' $RF_T/err.log)" 1
touch -t 202001010000 $RF_T/cfg/snippets; rf_snap 'sig' >/dev/null
check 2 "re-read when mtime changes" eq "$(grep -c 'snippets: read' $RF_T/err.log)" 2
check 2 "type label Snippet" grep -q $'^Email signature\tSnippet' =(RF_CONFIG_DIR=$RF_T/cfg $B --run snippets rows sig)
pbset before; rf_snap 'sig|enter' >/dev/null
check 3 "↩ puts the body on the pasteboard" eq "$(pb)" $'Best regards,\nShivam'
pbset before; rf_snap 'sig|cmdenter' >/dev/null
check 3 "⌘↩ copies" eq "$(pb)" $'Best regards,\nShivam'
exp() { pbset CLIP; RF_PASTEBOARD=rayfast-test-$$ TZ=UTC RF_NOW=1767323045 $B --run snippets expand "$1"; }   # 2026-01-02 03:04:05 UTC
check 4 "{date} {time}" eq "$(exp '{date} {time}')" '2026-01-02 03:04'
check 4 "{datetime}" eq "$(exp '{datetime}')" '2026-01-02 03:04'
check 4 "{date format=…}" eq "$(exp '{date format="dd/MM/yy"}')" '02/01/26'
check 4 "{date offset=+2d}" eq "$(exp '{date offset="+2d" format="yyyy-MM-dd"}')" '2026-01-04'
check 4 "{clipboard}" eq "$(exp 'x{clipboard}y')" 'xCLIPy'
check 4 "{uuid}" grep -qE '^[0-9A-F-]{36}$' =(exp '{uuid}')
check 4 "{cursor} removed" eq "$(exp 'a{cursor}b')" 'ab'
check 4 "unknown placeholders kept" eq "$(exp '{nope} {date')" '{nope} {date'
check 4 "{argument} default, shared by name" eq "$(exp '{argument name="a"}-{argument name="a" default="x"}-{argument name="b"}')" 'x-x-'
check 4 "{argument} from the cli" eq "$(pbset CLIP; RF_PASTEBOARD=rayfast-test-$$ $B --run snippets expand '{argument name="who"}!' who=Ann)" 'Ann!'
pbset before
check 4 "{argument} opens a view asking for it" grep -qF '[who]' =(rf_snap 'hello|enter')
rf_snap '@same|esc' >/dev/null
check 4 "  ...esc leaves without pasting" eq "$(pb)" before
rf_snap 'hello|enter' >/dev/null; rf_snap '@same|q=Bob|enter' >/dev/null
check 4 "{argument} asks first" grep -q '^Hi Bob, it is 20' =(pb)
rf_snap '@same|esc|cmd=snippets.greeting' >/dev/null; rf_snap '@same|q=Zed|enter' >/dev/null
check 4 "  ...also from a hotkey (opens the launcher to ask)" grep -q '^Hi Zed, it is 20' =(pb)
check 5 "docs say text expansion is out of scope" grep -qi 'expan.*out of scope\|out of scope.*expan' $RF_ROOT/docs/snippets.md
pbset 'from the clipboard'
rf_snap 'create snippet|enter' >/dev/null; rf_snap '@same|q=Clipped|enter' >/dev/null
check 6 "Create Snippet writes name + clipboard body" eq "$(body $RF_T/cfg/snippets Clipped)" 'from the clipboard'
check 6 "  ...and it's searchable" grep -qF 'Clipped | from the clipboard' =(rf_snap 'clipped')
rf_snap 'edit snippets|enter' >/dev/null
check 6 "Edit Snippets opens the file (dry run)" grep -qF "${RF_T//\/\///}/cfg/snippets" $RF_T/data/snippets-dryrun.log
check 6 "Search Snippets lists all" eq "$(rf_snap 'search snippets|enter' | grep -c '{snippets\.')" 3
rf_snap 'search snippets|enter|q=greet' > $T/sv
check 6 "  ...and filters (in its own view)" eq "$(grep -c '{snippets\.' $T/sv)/$(grep -c '^# Search Snippets' $T/sv)" 1/1
rf_snap '@same|esc' >/dev/null
check 6 "Create Snippet refuses a name in use" grep -qF 'already exists' =(rf_snap 'create snippet|enter|q=greeting')
rf_snap '@same|esc' >/dev/null
pbset $'--- tricky\n\\--- two\n---\nend'
rf_snap 'create snippet|enter' >/dev/null; rf_snap '@same|q=Tricky|enter' >/dev/null   # (a step can't type "|": keywords are the parser's)
check 6 "Create Snippet escapes header-like lines, body reads back as copied" eq "$(body $RF_T/cfg/snippets Tricky)" $'--- tricky\n\\--- two\n---\nend'
check 6 "  ...file still has no problems" eq "$(parse $RF_T/cfg/snippets | grep -c '^problem')" 0
pbset '   '
check 6 "Create Snippet with no text on the clipboard says so" grep -qF 'Copy some text first' =(rf_snap 'create snippet|enter')
rf_snap '@same|esc' >/dev/null
check 6 "commands have hotkey cids" grep -qF '{snippets.:search}' =(rf_snap 'search snippets')
rf_snap '@same|cmd=snippets.:search' >/dev/null
check 6 "  ...Search Snippets from a hotkey opens its view" grep -q '^# Search Snippets' =(rf_snap '@same')
rf_snap '@same|esc' >/dev/null
pbset x; rf_snap 'esc|cmd=snippets.email SIGNATURE' >/dev/null
check 9 "cmd=snippets.<name> (a hotkey) sets the pasteboard, name case-insensitive" eq "$(pb)" $'Best regards,\nShivam'
check 9 "snippet cid from the cli" eq "$(pbset x; RF_PASTEBOARD=rayfast-test-$$ RF_CONFIG_DIR=$RF_T/cfg $B --run snippets run 'snippets.Email signature'; pb)" $'Best regards,\nShivam'
rf_stop
rf_dirs; rf_start
check 10 "first run: Create Snippet with no file" grep -qF 'Create Snippet' =(rf_snap 'create snip')
check 10 "first run: Create Quicklink with no file" grep -qF 'Create Quicklink' =(rf_snap 'create quick')
pbset 'hello there'
rf_snap 'create snippet|enter' >/dev/null; rf_snap '@same|q=First|enter' >/dev/null
check 10 "Create Snippet writes a commented example file first" grep -q '^# --- Email signature' $RF_T/cfg/snippets
check 10 "  ...which parses to just the new snippet" eq "$(parse $RF_T/cfg/snippets)" $'First\t\t11'
pbset 'https://example.com/search?q={query}'
rf_snap 'create quicklink|enter' >/dev/null; rf_snap '@same|q=Example|enter' >/dev/null
check 10 "Create Quicklink: commented example, then the link from the clipboard" eq "$(grep -v '^#' $RF_T/cfg/quicklinks)" 'Example = https://example.com/search?q={query}'
pbset 'not a url'
rf_snap 'create quicklink|enter' >/dev/null; rf_snap '@same|q=Home = ~|enter' >/dev/null
check 10 "  ...or typed as \"Name = target\"" eq "$(tail -1 $RF_T/cfg/quicklinks)" 'Home = ~'
rf_snap 'edit quicklinks|enter' >/dev/null
check 10 "Edit Quicklinks opens the file (dry run)" grep -qF "${RF_T//\/\///}/cfg/quicklinks" $RF_T/data/snippets-dryrun.log
rf_stop
rf_dirs; rf_start
rf_snap 'edit snippets|enter' >/dev/null
check 10 "Edit Snippets with no file writes the example first" eq "$(parse $RF_T/cfg/snippets)/$(grep -c '^#' $RF_T/cfg/snippets)" "/8"
rf_stop

# ---------- 7. quicklink file format + parser
lparse() { $B --run quicklinks parse "$1"; }
lurl() { $B --run quicklinks url "$@"; }
f=$T/links; : > $f
check 7 "empty file: nothing, no problems" eq "$(lparse $f)" ""
printf -- '# c\r\nGitHub Search | gh = https://github.com/search?q={query}\r\n\r\nHome = ~\r\n' > $f
check 7 "CRLF: two links, keywords" eq "$(lparse $f)" $'GitHub Search\tgh\thttps://github.com/search?q={query}\t\nHome\t\t~\t'
printf -- 'A = https://a.example/{query}' > $f
check 7 "missing trailing newline" eq "$(lparse $f)" $'A\t\thttps://a.example/{query}\t'
printf -- 'Ünïcødé 名前 🙂 | émoji = https://例え.jp/?q={query}\n' > $f
check 7 "unicode name, keywords, URL" eq "$(lparse $f)" $'Ünïcødé 名前 🙂\témoji\thttps://例え.jp/?q={query}\t'
check 7 "  ...the URL still opens (host IDNA or %-encoded, query %-encoded)" grep -qE '^https://(xn--r8jz45g|%E4%BE%8B%E3%81%88)\.jp/\?q=%C3%9F' =(lurl $f 'Ünïcødé 名前 🙂' 'ß')
{ print -rn -- 'Long = https://example.com/?q='; for i in {1..16384}; do print -rn -- 'abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123'; done; print; print -- 'After = /tmp'; } > $f
st=$EPOCHREALTIME; out=$(lparse $f | cut -f1); el=$(( (EPOCHREALTIME - st) * 1000 ))
check 7 "1 MB line parsed (took ${el%.*} ms)" eq "$out" $'Long\nAfter'
check 7 "1 MB line in < 500 ms" test ${el%.*} -lt 500
printf -- 'Dup = /a\ndup = /b\nOther = /c\n' > $f
check 7 "duplicate names: first kept, problem noted" eq "$(lparse $f)" $'Dup\t\t/a\t\nOther\t\t/c\t\nproblem: line 2: "dup" is already used above, skipped'
printf -- 'Eq = https://x.example/?a=b&c = d | e\nMail = mailto:me@x.example\nIn App | a|b = https://y.example/@me @ TextEdit\n' > $f
check 7 "delimiters inside targets: first ' = ' splits, last ' @ ' is the app" eq "$(lparse $f)" $'Eq\t\thttps://x.example/?a=b&c = d | e\t\nMail\t\tmailto:me@x.example\t\nIn App\ta|b\thttps://y.example/@me\tTextEdit'
printf -- 'no equals here\n = https://x\nEmpty = \nRel = foo/bar\nNoApp = https://a @\nFine = /tmp\n' > $f
check 7 "mistakes become problems, rest loads" eq "$(lparse $f)" $'Fine\t\t/tmp\t\nproblem: line 1: needs "Name = URL or path", skipped\nproblem: line 2: a quicklink needs a name before " = ", skipped\nproblem: line 3: "Empty" has no URL or path, skipped\nproblem: line 4: "Rel": "foo/bar" is not a URL (https://…) or a path (~/… or /…), skipped\nproblem: line 5: "NoApp": no app after "@", skipped'
printf -- '\xef\xbb\xbfBom = /tmp\n' > $f
check 7 "UTF-8 BOM ignored" eq "$(lparse $f)" $'Bom\t\t/tmp\t'
printf -- 'Bad = /\xff\xfe\n' > $f
check 7 "not UTF-8: a problem, no crash" eq "$(lparse $f)" 'problem: the file is not UTF-8 text, nothing loaded'
cat > $f <<'EOF'
Search | s = https://example.com/search?q={query}&lang=en
Def = https://example.com/?q={query|swift ui}
Dir = ~/Projects/{query}
Ed = /tmp @ TextEdit
Gone = https://x.example @ No Such App 12345
Raw = file:///tmp/{query}
EOF
check 7 "{query} percent-encoded in a URL" eq "$(lurl $f Search 'a b&c=d/é?')" $'https://example.com/search?q=a%20b%26c%3Dd%2F%C3%A9%3F&lang=en\t'
check 7 "{query|default} used when nothing typed" eq "$(lurl $f Def)" $'https://example.com/?q=swift%20ui\t'
check 7 "  ...and replaced when something is" eq "$(lurl $f Def objc)" $'https://example.com/?q=objc\t'
check 7 "{query} raw in a path, ~ expanded" eq "$(lurl $f Dir 'my app')" "file://${HOME// /%20}/Projects/my%20app"$'\t'
check 7 "@ App found by name" eq "$(lurl $f Ed)" $'file:///tmp/\t/System/Applications/TextEdit.app'
check 7 "@ App not installed: ? (opens with the default)" eq "$(lurl $f Gone)" $'https://x.example\t?'
check 7 "file:// URL encodes like a URL" eq "$(lurl $f Raw 'a b')" $'file:///tmp/a%20b\t'
crash=0
for i in {1..40}; do
    head -c $((RANDOM % 4000)) /dev/urandom > $f; lparse $f >/dev/null 2>&1; (( $? > 1 )) && crash=1
    : > $f; for j in {1..$((RANDOM % 40))}; do
        for k in {1..$((RANDOM % 6))}; do case $((RANDOM % 9)) in 0) print -rn -- ' = ';; 1) print -rn -- ' | ';; 2) print -rn -- ' @ ';; 3) print -rn -- $'\r';; 4) print -rn -- '#';; 5) print -rn -- '{query|';; 6) print -rn -- 'https://';; 7) print -rn -- '~/';; 8) print -rn -- "w$RANDOM";; esac; done >> $f
        print >> $f
    done; lparse $f >/dev/null 2>&1; (( $? > 1 )) && crash=1
    n=$(lparse $f | grep -v '^problem' | head -1 | cut -f1); [[ -n $n ]] && { lurl $f "$n" "fz $RANDOM" >/dev/null 2>&1; (( $? > 1 )) && crash=1; }
done
check 7 "fuzz: 80 random files (+ url of each first link), no crash" test $crash = 0

# ---------- 8, 9: quicklinks in a headless instance
rf_dirs
cat > $RF_T/cfg/quicklinks <<'EOF'
# test links
GitHub Search | gh = https://github.com/search?q={query}
Docs | d = https://developer.apple.com/search/?q={query|swiftui} @ TextEdit
Projects = /tmp
oops
EOF
export RF_DRYRUN=1
rf_start
sleep 0.5
L=$RF_T/data/snippets-dryrun.log
check 8 "nothing read in start()" eq "$(grep -c 'quicklinks: read' $RF_T/err.log)" 0
check 8 "found by name at the root" grep -qF 'Projects | /tmp {quicklinks.Projects}' =(rf_snap 'projects')
check 8 "type label Quicklink" grep -q $'^GitHub Search\tQuicklink' =(RF_CONFIG_DIR=$RF_T/cfg $B --run quicklinks rows gh)
check 8 "\"gh rayfast\": the rest is the query" grep -qF 'GitHub Search | https://github.com/search?q=rayfast {quicklinks.GitHub Search}' =(rf_snap 'gh rayfast')
rf_snap 'gh rayfast fast|enter' >/dev/null
check 8 "  ...↩ opens it (dry run)" eq "$(tail -1 $L 2>/dev/null)" $'link\thttps://github.com/search?q=rayfast%20fast\t'
check 8 "file read once" eq "$(grep -c 'quicklinks: read' $RF_T/err.log)" 1
check 8 "a bad line shows as a problem row" grep -qF 'Quicklinks file: 1 problem' =(rf_snap 'quicklink')
rf_snap 'github search|enter' > $T/qv
check 8 "needs a query and has none: a view asks" grep -q '^# GitHub Search' $T/qv
rf_snap '@same|q=two words|enter' >/dev/null
check 8 "  ...and ↩ opens with what was typed" eq "$(tail -1 $L 2>/dev/null)" $'link\thttps://github.com/search?q=two%20words\t'
rf_snap 'docs|enter' >/dev/null
check 8 "{query|default} opens at once, in its app" eq "$(tail -1 $L 2>/dev/null)" $'link\thttps://developer.apple.com/search/?q=swiftui\t/System/Applications/TextEdit.app'
rf_snap 'projects|enter' >/dev/null
check 8 "a path opens as a file URL" eq "$(tail -1 $L 2>/dev/null)" $'link\tfile:///tmp/\t'
print 'Later = https://later.example' >> $RF_T/cfg/quicklinks
check 8 "re-read when the file changes" grep -qF 'Later | https://later.example' =(rf_snap 'later')
rf_snap 'esc|cmd=quicklinks.PROJECTS' >/dev/null
check 9 "cmd=quicklinks.<name> (a hotkey) opens it, name case-insensitive" eq "$(tail -1 $L 2>/dev/null)" $'link\tfile:///tmp/\t'
rf_snap '@same|cmd=quicklinks.github search' >/dev/null
check 9 "  ...one that needs a query opens the launcher to ask" grep -q '^# GitHub Search' =(rf_snap '@same')
rf_snap '@same|q=hk|enter' >/dev/null
check 9 "  ...then opens" eq "$(tail -1 $L 2>/dev/null)" $'link\thttps://github.com/search?q=hk\t'
rf_snap 'create quicklink|enter|q=Projects = /tmp' > $T/qv
check 8 "Create Quicklink refuses a name in use" grep -qF 'already exists' $T/qv
rf_snap '@same|esc' >/dev/null
check 8 "Create Quicklink shows a parser problem" grep -qF 'is not a URL' =(rf_snap 'create quicklink|enter|q=X = nope')
rf_snap '@same|esc' >/dev/null
rf_stop

# ---------- 11: import (Raycast's export format as documented from memory: unverified, see docs)
C=$T/icfg; mkdir -p $C
imp() { RF_CONFIG_DIR=$C $B --run $1 import $2; }
cat > $T/s.json <<'EOF'
[{"name": "Email signature", "text": "Best,\n--- me\n{clipboard}", "keyword": ";sig"},
 {"name": "Date", "text": "{date}"}, {"name": "", "text": "x"}, {"name": "a | b", "text": "x"}, {"name": "date", "text": "dup"}]
EOF
check 11 "snippets: imports, skips the bad and the duplicate" eq "$(imp snippets $T/s.json | tail -1)" "imported 2 snippets into ${C//\/\///}/snippets, skipped 3"
check 11 "  ...the file parses with no problems, keyword kept" eq "$(parse $C/snippets)" $'Email signature\t;sig\t24\nDate\t\t6'
check 11 "  ...body intact (header-like line escaped)" eq "$(body $C/snippets 'Email signature')" $'Best,\n--- me\n{clipboard}'
check 11 "  ...importing again adds nothing" eq "$(imp snippets $T/s.json | tail -1 | cut -d' ' -f2)" 0
cat > $T/l.json <<'EOF'
{"quicklinks": [
 {"name": "GitHub", "link": "https://github.com/search?q={argument name=\"q\"}", "openWith": "com.apple.TextEdit"},
 {"name": "Docs", "link": "https://d.example/?q={argument name=\"q\" default=\"swift\"}"},
 {"name": "Old", "link": "https://o.example/{Query}", "openWith": "Safari"},
 {"name": "Bad", "link": "nope"}, {"name": "x = y", "link": "https://x"}]}
EOF
check 11 "quicklinks: imports, skips the bad" eq "$(imp quicklinks $T/l.json)" $'skipped "Bad": "nope" is not a URL (https://…) or a path (~/… or /…), skipped\nskipped "x = y": " = " or " | " in the name\nimported 3 quicklinks into '"${C//\/\///}"$'/quicklinks, skipped 2'
check 11 "  ...{argument} -> {query}, default kept, bundle id -> app path" eq "$(lparse $C/quicklinks)" $'GitHub\t\thttps://github.com/search?q={query}\t/System/Applications/TextEdit.app\nDocs\t\thttps://d.example/?q={query|swift}\t\nOld\t\thttps://o.example/{query}\tSafari'
check 11 "not a Raycast export: an error, nothing written" eq "$(print '{"x":1}' > $T/b.json; imp quicklinks $T/b.json 2>/dev/null; print $?; grep -vc '^#' $C/quicklinks)" $'1\n3'
unset RF_DRYRUN
rm -rf $T

# ---------- measurement
# Idle is noisy on a shared, loaded machine (one binary reads 10.8-13.8 MB run to run), so base and module are
# measured interleaved in the same run: base = these same sources without snip.m. Each start gets a copy of a warm
# icon cache (as a real install has), so IconServices doesn't load.
pass=0; for i in {1..11}; do (( ITEM[$i] == 1 )) && (( pass++ )); done
idle="(skipped)"; base="(skipped)"
if [[ $1 != noidle ]]; then
    W=$(mktemp -d ${TMPDIR:-/tmp}/rf-snip-w.XXXXXX)
    cp -R $RF_ROOT/build/rayfast.app $W/base.app
    clang -fobjc-arc -Os -Wall -Wno-deprecated-declarations -mmacosx-version-min=13.0 $RF_ROOT/(^snip).m \
        -o $W/base.app/Contents/MacOS/rayfast -framework Cocoa -framework Carbon -framework QuartzCore -framework IOSurface -Wl,-dead_strip 2>/dev/null &&
        strip -x $W/base.app/Contents/MacOS/rayfast && codesign -s - -f $W/base.app 2>/dev/null
    $W/base.app/Contents/MacOS/rayfast --run snippets x 2>&1 | grep -q "no module" || print "WARNING: base binary still has the snippets module"
    rf_start; sleep 1.5; cp $RF_T/data/icons.bin $W/ 2>/dev/null; rf_stop
    fp() { print $(( $(footprint -f bytes $RF_PID | sed -n "s/.*Footprint: \([0-9]*\) B.*/\1/p" | head -1) / 1024 )); }
    mine=(); bas=(); keep=$RF_BIN
    for i in {1..5}; do
        for which in mine bas; do
            RF_BIN=$keep; [[ $which == bas ]] && RF_BIN=$W/base.app/Contents/MacOS/rayfast
            rf_dirs; cp $W/icons.bin $RF_T/data/ 2>/dev/null; rf_start; sleep 1.5
            eval "$which+=\$(fp)"; rf_stop
        done
    done
    RF_BIN=$keep; rm -rf $W
    mine=(${(on)mine}); bas=(${(on)bas})
    idle="$mine[3] KB (n=5: $mine)"; base="$bas[3] KB (n=5: $bas)"
fi
print "checklist: $pass/11"
print "idle: $idle (base $base)"
