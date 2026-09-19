#!/bin/bash
# Run every formal proof in this directory. Exits non-zero on any failure.
cd "$(dirname "$0")"
fail=0
for f in *.sby; do
  m=${f%.sby}
  tasks=$(sed -n '/^\[tasks\]/,/^\[/p' "$f" | grep -E '^(bmc|prove|cover)$')
  for t in $tasks; do
    r=$(sby -f "$f" "$t" 2>&1 | grep -oE "DONE \((PASS|FAIL|ERROR)" | head -1)
    r=${r#DONE (}
    printf "  %-22s %-6s %s\n" "$m" "$t" "$r"
    [ "$r" = "PASS" ] || fail=1
  done
done
exit $fail
