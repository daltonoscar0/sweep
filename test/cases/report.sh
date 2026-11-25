#!/bin/bash
# The report, end to end through "sweep run", and the notification.
. "$(dirname "$0")/../helpers.sh"

t_home
export CACHE_MIN_MB=5
export MAX_PUSH_FILE_MB=5
export NOTIFY=1
export PUSH_OWNERS="daltonoscar0"
export SWEEP_TEST_OWNER_OVERRIDE="daltonoscar0"

# something to clean
t_mkfile "$HOME/Library/Caches/com.spotify.client/Data/blob" 8
t_age_tree "$HOME/Library/Caches/com.spotify.client" 1
mkdir -p "$CODE_DIR/proj/tests/__pycache__"
printf 'x\n' > "$CODE_DIR/proj/tests/__pycache__/a.pyc"

# something to push
A=$(t_mkrepo mine)
t_commit "$A" "work.txt" "progress"

# something that needs him
H=$(t_mkrepo hem)
mkdir -p "$H/outputs"; printf 'r\n' > "$H/outputs/run1.json"
git -C "$H" add -A; git -C "$H" commit -qm results; git -C "$H" push -q origin main
rm -rf "$H/outputs"
printf 'tar\n' > "$H/hem-archive-20261125.tar.gz"

LEAK="hf_$(printf 'w%.0s' $(seq 1 34))"
S=$(t_mkrepo leaky)
t_commit "$S" "conf.py" "KEY = \"$LEAK\""

t_sweep run --now >/dev/null 2>&1
r=$(t_report)

echo "the report exists and is dated"
assert_true     'latest.md was written'        test -f "$HOME/Library/Logs/sweep/latest.md"
assert_true     'and the dated copy too'       test -f "$HOME/Library/Logs/sweep/$(date -r "$SWEEP_NOW" +%Y-%m-%d).md"
assert_contains 'it has a heading'             "$r" "# sweep "
assert_contains 'with free space before and after' "$r" "Free space"
assert_contains 'the tiers that ran'           "$r" "Tiers: light"
assert_contains 'and how many repos'           "$r" "repos checked"

echo "paths are shown with a real tilde"
assert_not_contains 'no escaped tilde anywhere' "$r" '\~'
assert_not_contains 'no backslash at all'       "$r" '\'
assert_contains     'and ~ is used'             "$r" '~/code'

echo "Needs you comes first and is specific"
assert_contains 'the secret is at the top'     "$(printf '%s\n' "$r" | sed -n '/## Needs you/,/## /p' | head -4)" "leaky"
assert_contains 'named by pattern'              "$r" "what looks like a Hugging Face token"
assert_not_contains 'but never by value'        "$r" "$LEAK"
assert_contains 'the missing results are listed' "$r" "**hem**"
assert_contains 'with the archive hint'        "$r" "probably archived rather than lost"
assert_contains 'and the exact command'        "$r" 'git -C ~/code/hem restore outputs'

echo "Pushed, Cleaned and FYI"
assert_contains 'the push is listed'           "$r" "**mine** \`main\`, 1 commit(s)"
assert_contains 'the cleaned table is there'   "$r" "| what | freed |"
assert_contains 'with the app caches row'      "$r" "| App caches |"
assert_contains 'the project caches row'       "$r" "| Project caches |"
assert_contains 'and a total'                  "$r" "| **total** |"
assert_contains 'the setup notes are there'    "$r" "Remove items from the Trash after 30 days"
assert_contains 'with the ssh hint'            "$r" "AddKeysToAgent"

echo "the notification says the same thing in one line"
n=$(cat "$HOME/notifications.txt" 2>/dev/null)
assert_eq       'exactly one notification'     "$(printf '%s\n' "$n" | wc -l | tr -d ' ')" "1"
assert_contains 'it mentions the push'         "$n" "pushed 1 repo"
assert_contains 'and what needs him'           "$n" "you"
assert_contains 'and how to read more'         "$n" "Run: sweep report"

echo "sweep report prints it"
assert_contains 'the command works'            "$(t_sweep report)" "# sweep "

echo "a quiet run renders cleanly and says nothing"
t_home
export NOTIFY=1
t_mkrepo quiet >/dev/null
t_sweep run --now >/dev/null 2>&1
r=$(t_report)
assert_contains 'the empty case has a sentence, not a blank' "$r" "_Nothing. Every repo under \`~/code\` is on GitHub and backed up._"
assert_not_contains 'no Pushed section'        "$r" "## Pushed"
assert_not_contains 'no stray table'           "$r" "| what |"
assert_contains     'the headline is still there' "$r" "Free space"
assert_false        'and no notification was posted' test -f "$HOME/notifications.txt"

echo "a dry run says so and changes nothing"
t_home
t_mkfile "$HOME/Library/Caches/com.big.app/Data/blob" 8
t_age_tree "$HOME/Library/Caches/com.big.app" 1
export CACHE_MIN_MB=5
B=$(t_mkrepo dry); t_own "$B" daltonoscar0
t_commit "$B" "x.txt" x
t_sweep run --now --dry-run >/dev/null 2>&1
r=$(t_report)
assert_contains 'the title says dry run'       "$r" "(dry run, nothing was deleted or pushed)"
assert_contains 'the table says would free'    "$r" "| would free |"
assert_contains 'the push is marked as such'   "$r" "_(dry run: not pushed)_"
assert_exists   'the cache is still there'     "$HOME/Library/Caches/com.big.app/Data/blob"
assert_eq       'and the remote never moved'   "$(git -C "$B" rev-parse --verify --quiet origin/main)" "$(git -C "$B" rev-parse HEAD~1)"
assert_false    'no notification from a dry run' test -f "$HOME/notifications.txt"

t_end
