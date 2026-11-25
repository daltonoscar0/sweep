#!/bin/bash
# Tier 1: ~/Library/Caches, and tier 2: ~/Library/Logs.
. "$(dirname "$0")/../helpers.sh"

t_home
export CACHE_MIN_MB=5
export CACHE_ACTIVE_HOURS=6
export CACHE_SKIP="com.apple.Safari com.apple.akd"
export LOG_MAX_AGE_DAYS=14
t_load

C="$HOME/Library/Caches"

# big and idle: should be emptied
t_mkfile "$C/com.spotify.client/Data/blob1" 4
t_mkfile "$C/com.spotify.client/Data/blob2" 4
mkdir -p "$C/com.spotify.client/empty-subdir"
# big but touched ten minutes ago: an app is probably using it
t_mkfile "$C/com.google.Chrome/Data/blob" 8
# big but on the skip list
t_mkfile "$C/com.apple.Safari/Data/blob" 8
# too small to bother with
t_mkfile "$C/com.tiny.app/Data/blob" 1
# a file rather than a folder at the top level
t_mkfile "$C/loose-file.bin" 8

for d in com.spotify.client com.apple.Safari com.tiny.app; do
  t_age_tree "$C/$d" 1
done
t_age_hours "$C/loose-file.bin" 24

sweep_clean_app_caches

assert_exists    'the big idle cache folder is kept'  "$C/com.spotify.client"
assert_empty_dir 'but it was emptied'                 "$C/com.spotify.client"
assert_exists    'the recently used cache is skipped' "$C/com.google.Chrome/Data/blob"
assert_exists    'a CACHE_SKIP cache is skipped'      "$C/com.apple.Safari/Data/blob"
assert_exists    'a cache under CACHE_MIN_MB is left' "$C/com.tiny.app/Data/blob"
assert_exists    'a loose top-level file is left'     "$C/loose-file.bin"
assert_contains  'the skip is explained in the log'   "$(cat "$SWEEP_RUN_LOG")" "skipped (active within 6h)"
assert_contains  'and the freeing is recorded'        "$(cat "$SWEEP_CLEANED")" "App caches"
assert_true      'about 8 MB was accounted for'       test "$(sweep_cleaned_kb)" -gt 7000

echo "tier 2: old logs"
L="$HOME/Library/Logs"
t_mkfile "$L/old.log" 1 30
t_mkfile "$L/DiagnosticReports/crash.ips" 1 60
t_mkfile "$L/fresh.log" 1 1
mkdir -p "$L/sweep"
t_mkfile "$L/sweep/2026-01-01.md" 1 100

sweep_clean_logs

assert_missing 'a log older than 14 days goes'       "$L/old.log"
assert_missing 'and so does an old crash report'     "$L/DiagnosticReports/crash.ips"
assert_exists  'a recent log stays'                  "$L/fresh.log"
assert_exists  "sweep's own old reports are spared"  "$L/sweep/2026-01-01.md"

t_end
