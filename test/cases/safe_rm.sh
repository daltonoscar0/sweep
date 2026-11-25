#!/bin/bash
# safe_rm is the only thing in sweep that deletes, so it gets the most tests.
. "$(dirname "$0")/../helpers.sh"

t_home
t_load

echo "refusals"
mkdir -p "$HOME/Documents/important"
printf 'x\n' > "$HOME/Documents/important/file"
mkdir -p "$HOME/Library/Caches/com.example.app/data"
ln -s "$HOME/Documents" "$HOME/Library/Caches/com.example.link"

assert_false '$HOME itself'              sweep_safe_rm "$HOME" test
assert_false '$HOME with a trailing /'   sweep_safe_rm "$HOME/" test
assert_false '/'                         sweep_safe_rm "/" test
assert_false '/ with trailing slashes'   sweep_safe_rm "///" test
assert_false '/System'                   sweep_safe_rm "/System" test
assert_false 'a symlink'                 sweep_safe_rm "$HOME/Library/Caches/com.example.link" test
assert_false 'outside the allowlist'     sweep_safe_rm "$HOME/Documents/important" test
assert_false 'a .. component'            sweep_safe_rm "$HOME/Library/Caches/../Documents/important" test
assert_false 'a .. at the end'           sweep_safe_rm "$HOME/Library/Caches/.." test
assert_false 'a relative path'           sweep_safe_rm "Library/Caches/x" test
assert_false 'an empty path'             sweep_safe_rm "" test
assert_false 'the Caches root itself'    sweep_safe_rm "$HOME/Library/Caches" test
assert_false 'the Logs root itself'      sweep_safe_rm "$HOME/Library/Logs" test
assert_false 'CODE_DIR itself'           sweep_safe_rm "$CODE_DIR" test
assert_false 'a non-cache dir in CODE_DIR' sweep_safe_rm "$CODE_DIR/myproject" test

assert_exists 'the symlink survived'     "$HOME/Library/Caches/com.example.link"
assert_exists 'its target survived'      "$HOME/Documents/important/file"
assert_exists 'Documents survived'       "$HOME/Documents/important"

echo "acceptances"
assert_true  'inside ~/Library/Caches'   sweep_safe_rm "$HOME/Library/Caches/com.example.app/data" cache
assert_missing 'it is gone'              "$HOME/Library/Caches/com.example.app/data"
assert_exists 'its parent is kept'       "$HOME/Library/Caches/com.example.app"

mkdir -p "$CODE_DIR/proj/tests/__pycache__"
assert_true  'a __pycache__ in CODE_DIR' sweep_safe_rm "$CODE_DIR/proj/tests/__pycache__" cache
assert_missing 'it is gone'              "$CODE_DIR/proj/tests/__pycache__"

mkdir -p "$CODE_DIR/proj/.pytest_cache" "$CODE_DIR/proj/build"
assert_true  '.pytest_cache in CODE_DIR' sweep_safe_rm "$CODE_DIR/proj/.pytest_cache" cache
assert_false 'but not a build dir'       sweep_safe_rm "$CODE_DIR/proj/build" cache

echo "accounting and the run log"
log=$(cat "$SWEEP_RUN_LOG")
assert_contains 'refusals are logged'    "$log" "refused (\$HOME)"
assert_contains 'symlinks are logged'    "$log" "refused (symlink)"
assert_contains 'allowlist is logged'    "$log" "refused (outside allowlist)"
assert_contains 'removals are logged'    "$log" "removed [cache]"
assert_not_contains 'log shows ~, not an escaped tilde' "$log" '\~'
assert_contains 'log shows the tilde path' "$log" '~/Library/Caches'
assert_eq 'three paths were recorded'    "$(wc -l < "$SWEEP_CLEANED" | tr -d ' ')" "3"

echo "dry run deletes nothing"
mkdir -p "$HOME/Library/Caches/com.example.app/more"
SWEEP_DRY_RUN=1
assert_true  'dry run accepts the path'  sweep_safe_rm "$HOME/Library/Caches/com.example.app/more" cache
assert_exists 'but the path is still there' "$HOME/Library/Caches/com.example.app/more"
assert_contains 'and it says "would remove"' "$(cat "$SWEEP_RUN_LOG")" "would remove"

t_end
