#!/bin/bash
# The once-per-day guard, exercised through the real "sweep run".
. "$(dirname "$0")/../helpers.sh"

t_home

starts() {
  grep -h -c 'sweep run start' "$HOME/Library/Logs/sweep"/*.log 2>/dev/null |
    awk '{s+=$1} END {print s+0}'
}

# 2026-11-25 at 04:30 local
SWEEP_NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-25 04:30:00' +%s); export SWEEP_NOW

t_sweep run --now >/dev/null 2>&1
assert_eq 'the first run of the day works'      "$(starts)" "1"
assert_eq 'and it records the sweep day'        "$(sed -n 's/^last_run_day=//p' "$HOME/.local/state/sweep/state")" "2026-11-25"

t_sweep run --now >/dev/null 2>&1
assert_eq 'a second run the same day does nothing' "$(starts)" "1"

# later the same day, 23:00
SWEEP_NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-25 23:00:00' +%s); export SWEEP_NOW
t_sweep run --now >/dev/null 2>&1
assert_eq 'still the same sweep day, still nothing' "$(starts)" "1"

# 02:00 the next morning is still the same sweep day
SWEEP_NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-26 02:00:00' +%s); export SWEEP_NOW
t_sweep run --now >/dev/null 2>&1
assert_eq '02:00 still counts as yesterday'     "$(starts)" "1"

echo "--force overrides the guard"
t_sweep run --now --force >/dev/null 2>&1
assert_eq 'it ran again'                        "$(starts)" "2"

echo "after 03:00 the next sweep day starts"
SWEEP_NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-26 04:30:00' +%s); export SWEEP_NOW
t_sweep run --now >/dev/null 2>&1
assert_eq 'a new day runs on its own'           "$(starts)" "3"

echo "a dry run never consumes the day"
t_home
SWEEP_NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-25 04:30:00' +%s); export SWEEP_NOW
t_sweep run --now --dry-run >/dev/null 2>&1
assert_eq 'the dry run happened'                "$(starts)" "1"
assert_false 'and left no day marker' grep -q 'last_run_day' "$HOME/.local/state/sweep/state"
t_sweep run --now >/dev/null 2>&1
assert_eq 'so the real run still happens'       "$(starts)" "2"

echo "a held lock makes a run a no-op"
t_home
mkdir -p "$HOME/.local/state/sweep/lock"
t_sweep run --now >/dev/null 2>&1
assert_eq 'nothing ran while the lock was held' "$(starts)" "0"

t_end
