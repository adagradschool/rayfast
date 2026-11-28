#!/bin/zsh
# Mutation test of the lane suites: break one line a test should guard, rebuild, run the owner's suite, put it back.
# A mutation is CAUGHT when the suite's checklist drops below its unmutated score (or a FAIL line appears that the
# unmutated run didn't have). Never mutates a dry-run guard (a mutated build must not act on the machine).
#   tests/review/mutate.sh [id ...]      default: all.  ~1-1.5 min per suite run.
cd ${0:A:h:h:h}
OUT=${TMPDIR:-/tmp}/rayfast-mutate.$$; mkdir -p $OUT
FILES=(clip.m sys.m scripts.m snip.m win.m)
trap 'git checkout -q -- $FILES; make -s >/dev/null 2>&1' EXIT
typeset -A MF MS MO MN MD
m() { MF[$1]=$2; MS[$1]=$3; MO[$1]=$4; MN[$1]=$5; MD[$1]=$6; }
#  id   file       suite      original line fragment                                   mutated                          what it breaks
m c-perm clip.m    clipboard  'O_WRONLY | O_APPEND | O_CREAT, 0600'                     'O_WRONLY | O_APPEND | O_CREAT, 0644' "history log created world-readable"
m c-conc clip.m    clipboard  '@"org.nspasteboard.ConcealedType", '                     '@"x.ConcealedType", '           "concealed (password) copies are stored"
m c-ign  clip.m    clipboard  'caseInsensitiveCompare:bid] == NSOrderedSame) return YES' 'caseInsensitiveCompare:bid] == NSOrderedSame) return NO' "clipboard.ignore has no effect"
m s-uid  sys.m     system     'if (p.uid != getuid()) { setHint'                         'if (0) { setHint'               "kill another user's process is attempted"
m s-conf sys.m     system     '        if (c->confirm) confirmView(c);'                 '        if (0) confirmView(c);'  "destructive rows act without the confirm view (dry run)"
m p-conf scripts.m scripts    'return [c isEqual:@"true"] || [c isEqual:@"yes"]; }'     'return NO && c; }'              "needsConfirmation ignored"
m p-sec  scripts.m scripts    'v->secure = [type isEqual:@"password"];'                 'v->secure = NO;'                "password argument shown in clear"
m n-enc  snip.m    snippets   '[v stringByAddingPercentEncodingWithAllowedCharacters:unreserved]' 'v'                "quicklink {query} not percent-encoded"
m w-prune win.m    windows    '[w->live containsObject:k]'                              'YES'                            "restore file never pruned"
IDS=($@); (( $#IDS )) || IDS=(c-perm c-conc c-ign s-uid s-conf p-conf p-sec n-enc w-prune)

score() { grep '^checklist:' $1 | tail -1 | awk '{print $2}'; }
fails() { grep -E '^ *FAIL|^FAIL' $1 | sed 's/ *(.*//' | sort -u; }
typeset -A BASE
SUITES=(); for id in $IDS; do SUITES+=($MS[$id]); done
for s in ${(u)SUITES}; do
    git checkout -q -- $FILES; make -s >/dev/null 2>&1
    zsh tests/$s/run.sh > $OUT/base-$s.txt 2>&1; BASE[$s]=$(score $OUT/base-$s.txt)
    print -r -- "unmutated $s: $BASE[$s]"
done
for id in $IDS; do
    local f=$MF[$id] s=$MS[$id]
    git checkout -q -- $FILES
    python3 -c 'import sys; p,o,n=sys.argv[1:]; t=open(p).read(); assert t.count(o)==1, "fragment not unique/absent"; open(p,"w").write(t.replace(o,n))' $f "$MO[$id]" "$MN[$id]" \
        || { print -r -- "$id: SKIP fragment not found in $f"; continue; }
    if ! make -s >/dev/null 2>$OUT/build-$id.txt; then print -r -- "$id: SKIP mutant does not build"; continue; fi
    zsh tests/$s/run.sh > $OUT/$id.txt 2>&1
    local got=$(score $OUT/$id.txt) new=$(comm -13 <(fails $OUT/base-$s.txt) <(fails $OUT/$id.txt) | tr '\n' ' ')
    if [[ $got != $BASE[$s] || -n $new ]]; then print -r -- "$id: CAUGHT  $s $BASE[$s] -> $got  ($MD[$id]) ${new:+new: $new}"
    else print -r -- "$id: MISSED  $s $BASE[$s] -> $got  ($MD[$id])"; fi
done
print -r -- "logs: $OUT"
