#!/bin/sh
# Current CPU share per process over a 1s window (delta of utime+stime from
# /proc/<pid>/stat). ps' pcpu is a lifetime average and would mislead. Prints
# "name\tpct" for the top processes plus a "TOTAL\tpct" line for the sum.
#
# Work is bounded at the producer: at most 2048 /proc pids, comm capped at
# 15 bytes, top 6 names kept in awk (no unbounded sort). Deadline and
# process-group reap come from the timeout wrapper in Panel.qml.
#
# Scratch files live in a mktemp dir removed on exit.

set -u

hz=$(getconf CLK_TCK)
[ "$hz" -gt 0 ] || hz=100

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-cellmate.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
f1="$tmpdir/pw.1"
f2="$tmpdir/pw.2"

# find+head, not a /proc/[0-9]* glob: the glob would unbounded-expand into argv.
snap() {
  find /proc -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -print 2>/dev/null \
  | head -n 2048 \
  | awk '{
      f = $0 "/stat"
      if ((getline line < f) <= 0) { close(f); next }
      close(f)
      p = index(line, "(")
      q = index(line, ")")
      if (p < 1 || q <= p) next
      split(substr(line, q + 1), a, " ")
      name = substr(line, p + 1, q - p - 1)
      if (length(name) > 15) name = substr(name, 1, 15)
      pid = substr(line, 1, p - 1) + 0
      if (pid < 1) next
      printf "%s\t%s\t%d\n", pid, name, a[12] + a[13]
    }'
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
    if (n == "ps" || n == "sh" || n == "top" || n == "powerprofilesct" || n == "timeout" || n == "find" || n == "head" || n == "python3") next
    sum[n] += pct
    tot += pct
  }
  END {
    n = 0
    for (name in sum) {
      n++
      names[n] = name
      vals[n] = sum[name]
    }
    lim = n < 6 ? n : 6
    for (i = 1; i <= lim; i++) {
      max = i
      for (j = i + 1; j <= n; j++) if (vals[j] > vals[max]) max = j
      tmpv = vals[i]; tmpn = names[i]
      vals[i] = vals[max]; names[i] = names[max]
      vals[max] = tmpv; names[max] = tmpn
      printf "%s\t%.1f\n", names[i], vals[i]
    }
    printf "TOTAL\t%.1f\n", tot
  }
' "$f1" "$f2"
