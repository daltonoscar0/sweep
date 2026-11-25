#!/bin/bash
# test/run.sh -- plain bash test harness. No bats, no brew.
#
#   bash test/run.sh            run everything
#   bash test/run.sh safe_rm    run cases whose name matches
#   VERBOSE=1 bash test/run.sh  show every check, not just failures

set -u

cd "$(dirname "$0")/.." || exit 1
SWEEP_SRC="$PWD"
export SWEEP_SRC

filter="${1:-}"
pass=0
fail=0
failed=""

printf 'syntax check\n'
for f in bin/sweep lib/*.sh test/*.sh test/cases/*.sh; do
  if ! bash -n "$f" 2>/tmp/sweep-syntax.$$; then
    printf '  FAIL %s\n' "$f"
    sed 's/^/       /' /tmp/sweep-syntax.$$
    fail=$((fail + 1))
    failed="$failed syntax:$f"
  fi
done
rm -f /tmp/sweep-syntax.$$
[ "$fail" -eq 0 ] && printf '  ok, %s files parse\n' "$(ls bin/sweep lib/*.sh test/*.sh test/cases/*.sh | wc -l | tr -d ' ')"

if command -v shellcheck >/dev/null 2>&1; then
  printf 'shellcheck\n'
  # Errors only: style findings are printed by CI but never fail the suite.
  if shellcheck -s bash --severity=error -e SC1090,SC1091,SC2034 bin/sweep lib/*.sh; then
    printf '  ok\n'
  else
    printf '  FAIL\n'
    fail=$((fail + 1))
    failed="$failed shellcheck"
  fi
fi

printf '\n'
for case_file in test/cases/*.sh; do
  name=$(basename "$case_file" .sh)
  if [ -n "$filter" ]; then
    case "$name" in
      *"$filter"*) ;;
      *) continue ;;
    esac
  fi
  out=$(bash "$case_file" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok   %s\n' "$name"
    [ -n "${VERBOSE:-}" ] && printf '%s\n' "$out" | sed 's/^/     /'
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$name"
    printf '%s\n' "$out" | sed 's/^/     /'
    fail=$((fail + 1))
    failed="$failed $name"
  fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf 'failed:%s\n' "$failed"
  exit 1
fi
exit 0
