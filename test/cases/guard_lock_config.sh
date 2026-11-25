#!/bin/bash
# The once-per-day guard, the lock, and config loading.
. "$(dirname "$0")/../helpers.sh"

t_home
t_load

echo "config"
assert_eq 'default LOW_SPACE_GB'      "$LOW_SPACE_GB" "20"
assert_eq 'default MAX_PUSH_FILE_MB'  "$MAX_PUSH_FILE_MB" "95"
assert_eq 'CODE_DIR from the env wins' "$CODE_DIR" "$HOME/code"

cat > "$HOME/.config/sweep/config" <<'EOF'
LOW_SPACE_GB=5
KEEP_HF="gpt2 pythia"
EOF
sweep_load_config
assert_eq 'the config file is read'   "$LOW_SPACE_GB" "5"
assert_eq 'and multi-word values too' "$KEEP_HF" "gpt2 pythia"
assert_eq 'untouched keys keep defaults' "$DEVICE_SUPPORT_KEEP" "2"

assert_false 'an existing config is never overwritten' sweep_write_default_config
assert_eq 'it really is untouched'    "$(sed -n 1p "$HOME/.config/sweep/config")" "LOW_SPACE_GB=5"

rm -f "$HOME/.config/sweep/config"
assert_true 'a missing config is created' sweep_write_default_config
assert_contains 'with the documented defaults' "$(cat "$HOME/.config/sweep/config")" "DEVICE_SUPPORT_KEEP=2"
assert_true 'and it is valid bash' bash -n "$HOME/.config/sweep/config"

echo "day key boundary (a sweep day starts at 03:00)"
# 2026-11-25 02:59 local, and 03:01 local
before=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-25 02:59:00' +%s)
after=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-25 03:01:00' +%s)
assert_eq '02:59 belongs to the previous day' "$(sweep_day_key "$before")" "2026-11-24"
assert_eq '03:01 starts the new day'          "$(sweep_day_key "$after")"  "2026-11-25"

echo "lock"
assert_true  'the lock is taken'     sweep_lock_acquire
assert_exists 'the lock dir exists'  "$HOME/.local/state/sweep/lock"
( sweep_lock_acquire ) && t_fail 'a second run must not get the lock' || t_ok 'a second run is kept out'
sweep_lock_release
assert_missing 'releasing removes it' "$HOME/.local/state/sweep/lock"

mkdir -p "$HOME/.local/state/sweep/lock"
t_age_hours "$HOME/.local/state/sweep/lock" 3
assert_true 'a lock older than 2 hours is broken' sweep_lock_acquire
sweep_lock_release

echo "state"
sweep_state_set alpha 1
sweep_state_set beta "two words"
sweep_state_set alpha 9
assert_eq 'the newest value wins'  "$(sweep_state_get alpha)" "9"
assert_eq 'other keys survive'     "$(sweep_state_get beta)" "two words"
assert_eq 'only one line per key'  "$(grep -c '^alpha=' "$HOME/.local/state/sweep/state")" "1"
assert_false 'an unknown key fails' sweep_state_get gamma

t_end
