#!/bin/sh
# Current CPU share per process over a 1s window (delta of utime+stime from
# /proc/*/stat). ps' pcpu is a lifetime average and would mislead. Prints
# "name\tpct" for the top processes plus a "TOTAL\tpct" line for the sum, so
# the panel can attribute the measured battery draw to each process.
#
# comm(15) truncates long names (powerprofilesctl -> powerprofilesct), and
# only comm values are shown, so probes run by this panel are filtered out.

snap() {
  awk '{ p = index($0, "(")
         q = index($0, ")")
         if (p < 1 || q <= p) next
         split(substr($0, q + 1), f, " ")
         printf "%s\t%s\t%d\n", $1, substr($0, p + 1, q - p - 1), f[12] + f[13]
       }' /proc/[0-9]*/stat 2>/dev/null
}

snap > /tmp/.omarchy-pw.1
sleep 1
snap > /tmp/.omarchy-pw.2

awk -F'\t' '
  NR == FNR { t1[$1] = $3; next }
  ($1 in t1) {
    d = $3 - t1[$1]
    if (d < 0) d = 0
    if (d < 1) next          # below ~1% CPU
    n = $2
    if (n == "ps" || n == "sh" || n == "top" || n == "powerprofilesct") next
    sum[n] += d
    tot += d
  }
  END {
    for (n in sum) printf "%s\t%.1f\n", n, sum[n]
    printf "TOTAL\t%.1f\n", tot
  }
' /tmp/.omarchy-pw.1 /tmp/.omarchy-pw.2 | sort -k2,2rn | head -7