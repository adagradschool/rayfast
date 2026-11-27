#!/bin/zsh
# launcher.pin: commands named in the config sit above the apps on an empty query; without it nothing changes.
cd ${0:A:h:h}
source tests/mod.sh
bad=0; check() { if eval "$2"; then print "ok   $1"; else print "FAIL $1"; bad=1; fi }
rf_dirs; print "launcher.pin = Clipboard History, search emoji, No Such Thing" > $RF_T/cfg/config
rf_start
s=$(rf_snap "")
check "pinned rows come first, in config order" '[[ "$(print -r -- $s | sed -n 2,5p | tr "\n" "~")" == "# Pinned~> Clipboard History {clipboard.history}~  Search Emoji"*"~# Suggestions~" ]]'
check "an unknown title is skipped" '[[ $s != *"No Such Thing"* ]]'
check "↩ on the first row opens the pinned command" '[[ "$(rf_snap "|enter")" == *"# Clipboard History"* ]]'
check "pins are only for the empty query" '[[ "$(rf_snap "|esc|q=zzzq")" != *"# Pinned"* ]]'
rf_stop
rf_start
check "no setting: no Pinned section" '[[ "$(rf_snap "")" != *"# Pinned"* ]]'
rf_stop
exit $bad
