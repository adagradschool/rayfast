#!/bin/zsh
# usage: ./snap.sh "query|down|cmdk"  -> renders launcher (own pixels only) to scratchpad/snap.png
mkdir -p ${TMPDIR:-/tmp}/rayfast-test; cd "$(dirname "$0")/.."
echo "$1" > ${TMPDIR:-/tmp}/rayfast-test/snap.q; kill -USR2 $(pgrep -x rayfast-test); sleep 0.6
