#!/bin/zsh
grep -o 'trial [0-9]*: [0-9.]*' | awk '{print $3}' | sort -n | awk '{a[NR]=$1} END{ if(NR) printf "median %.1f ms (n=%d, min %.1f, max %.1f)\n", (NR%2?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2), NR, a[1], a[NR]; else print "no data"}'
