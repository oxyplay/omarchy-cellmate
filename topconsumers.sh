#!/bin/sh
# Current CPU share per process over a 1s window (delta of utime+stime from
# /proc/*/stat). ps' pcpu is a lifetime average and would mislead. Prints
# "name\tpct" for the top processes plus a "TOTAL\tpct" line for the sum, so
# the panel can attribute the measured battery draw by share. The pct is
# computed from real ticks and CLK_TCK, so it stays correct on non-100Hz
# systems.
#
# comm(15) truncates long names (powerprofilesctl -> powerprofilesct), and
# only comm values are shown, so probes run by this panel are filtered out.
#
# Scratch files live in a mktemp dir removed on exit: no fixed /tmp paths,
# so no symlink-substitution or races with other users of the same host.

set -u

hz=$(getconf CLK_TCK)
[ "$hz" -gt 0 ] || hz=100

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-cellmate.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
f1="$tmpdir/pw.1"
f2="$tmpdir/pw.2"

snap() {
  awk '{ p = index($0, "(")
         q = index($0, ")")
         if (p < 1 || q <= p) next
         split(substr($0, q + 1), f, " ")
         printf "%s\t%s\t%d\n", $1, substr($0, p + 1, q - p - 1), f[12] + f[13]
       }' /proc/[0-9]*/stat 2>/dev/null
}

snap > "$f1"
sleep 1
snap > "$f2"

awk -v hz="$hz" -F'\t' '
  NR == FNR { t1[$1] = $3; next }
  ($1 in t1) {
    d = $3 - t1[$1]
    if (d < 0) d = 0
    pct = d / hz * 100
    if (pct < 0.5) next
    n = $2
    if (n == "ps" || n == "sh" || n == "top" || n == "powerprofilesct") next
    sum[n] += pct
    tot += pct
  }
  END {
    for (n in sum) printf "%s\t%.1f\n", n, sum[n]
    printf "TOTAL\t%.1f\n", tot
  }
' "$f1" "$f2" | sort -k2,2rn | head -7