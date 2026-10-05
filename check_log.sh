#!/bin/sh
# check_log.sh <vsim log>
# Questa can exit 0 even when a UVM run logged UVM_ERROR/UVM_FATAL, so the verdict
# is taken from the log: a run PASSES only if
#   1. the UVM Report Summary is present (the sim did not die early),
#   2. UVM_ERROR and UVM_FATAL counts are both zero,
#   3. no tool-level "** Error" / "** Fatal" lines were printed, and
#   4. the scoreboard printed its PASS banner.

log="$1"

if [ -z "$log" ] || [ ! -f "$log" ]; then
  echo "CHECK: log file not found: $log"
  exit 2
fi

fail=0

if ! grep -q "UVM Report Summary" "$log"; then
  echo "CHECK: no UVM Report Summary (simulation ended early or crashed)"
  fail=1
fi

# Summary lines look like "UVM_ERROR :    0" (possibly prefixed with "# ")
bad=$(awk '/UVM_(ERROR|FATAL) *:/ { n = $NF + 0; if (n > 0) print }' "$log")
if [ -n "$bad" ]; then
  echo "CHECK: non-zero UVM error/fatal count:"
  echo "$bad"
  fail=1
fi

if grep -Eq '^(# )?\*\* (Error|Fatal)' "$log"; then
  echo "CHECK: tool-level errors found:"
  grep -E '^(# )?\*\* (Error|Fatal)' "$log" | head -n 10
  fail=1
fi

if ! grep -q "APB SCOREBOARD: PASS" "$log"; then
  echo "CHECK: scoreboard PASS banner missing"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "CHECK: PASS  ($log)"
  exit 0
fi
echo "CHECK: FAIL  ($log)"
exit 1
