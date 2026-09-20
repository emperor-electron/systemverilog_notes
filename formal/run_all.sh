#!/bin/bash
# Run every formal proof in this directory. Exits non-zero on any failure.
#
# Task names are read from each file's [tasks] section rather than matched
# against a fixed list, so a proof can add a task (fsm_safe_fv's `recover`, for
# instance) without it being silently skipped here.
cd "$(dirname "$0")"
fail=0
for f in *.sby; do
  m=${f%.sby}
  tasks=$(sed -n '/^\[tasks\]/,/^\[/p' "$f" \
          | sed -e 's/#.*//' -e 's/[[:space:]]*$//' \
          | grep -vE '^\[|^$')
  for t in $tasks; do
    r=$(sby -f "$f" "$t" 2>&1 | grep -oE "DONE \((PASS|FAIL|ERROR|UNKNOWN)" | head -1)
    r=${r#DONE (}
    printf "  %-22s %-8s %s\n" "$m" "$t" "$r"
    [ "$r" = "PASS" ] || fail=1
  done
done
exit $fail
