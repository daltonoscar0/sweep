#!/bin/bash
# What the git check reports, and what it refuses to fix by itself.
. "$(dirname "$0")/../helpers.sh"

t_home
t_load

finding() {  # kind -> the messages recorded for it
  awk -F'\t' -v k="$1" '$1 == k {print $2 ": " $3 " || " $4}' "$SWEEP_GIT"
}

# --- a repo in detached HEAD with no remote, like tknzn4Irish-patches was ----
D="$CODE_DIR/detachedrepo"
mkdir -p "$D"
git init -q "$D"
printf 'a\n' > "$D/a.txt"; git -C "$D" add -A; git -C "$D" commit -qm one
printf 'b\n' > "$D/b.txt"; git -C "$D" add -A; git -C "$D" commit -qm two
git -C "$D" checkout -q --detach HEAD

# --- results deleted locally and replaced by an archive, like hem and mend ---
H=$(t_mkrepo hem)
mkdir -p "$H/outputs"
printf 'r1\n' > "$H/outputs/run1.json"
printf 'r2\n' > "$H/outputs/run2.json"
printf 'r3\n' > "$H/cache/spy/probe_results.json" 2>/dev/null || {
  mkdir -p "$H/cache/spy"; printf 'r3\n' > "$H/cache/spy/probe_results.json"; }
git -C "$H" add -A; git -C "$H" commit -qm "results"; git -C "$H" push -q origin main
rm -rf "$H/outputs" "$H/cache"
printf 'tarball\n' > "$H/hem-archive-20261125.tar.gz"

# --- a big untracked file, like the 276 MB archives --------------------------
B=$(t_mkrepo bigdata)
t_mkfile "$B/data/samples.jsonl.gz" 60

# --- a committed __pycache__ and some uncommitted work ----------------------
C=$(t_mkrepo cached)
mkdir -p "$C/pkg/__pycache__"
printf 'x\n' > "$C/pkg/__pycache__/mod.cpython-312.pyc"
printf 'x\n' > "$C/.DS_Store"
git -C "$C" add -f pkg/__pycache__ .DS_Store
git -C "$C" commit -qm "oops"
printf 'wip\n' > "$C/scratch.txt"

# --- a repo the remote is ahead of, like the_mainspring ---------------------
M=$(t_mkrepo mainspring)
t_remote_commit "$M" "theirs.txt" "from elsewhere"

# --- a branch with no upstream, like morphology's irish-next-steps ----------
N=$(t_mkrepo morphology)
git -C "$N" checkout -q -b irish-next-steps
t_commit "$N" "notes.md" "next steps"

export AUTO_PUSH=0   # classification only in this case
sweep_git_check

echo "detached HEAD"
got=$(finding detached)
assert_contains 'it is reported'                 "$got" "detachedrepo"
assert_contains 'with a warning about losing commits' "$got" "git will eventually discard them"
assert_contains 'and a way out'                  "$got" "switch -c rescue-"

echo "no remote"
assert_contains 'reported'                       "$(finding no_remote)" "detachedrepo: no remote at all"
assert_contains 'with a gh command'              "$(finding no_remote)" "gh repo create"

echo "tracked files deleted locally"
got=$(finding deleted_tracked)
assert_contains 'the outputs directory is named' "$got" "outputs"
assert_contains 'with a count'                   "$got" "2 tracked file(s) missing"
assert_contains 'the nested cache dir too'       "$got" "cache/spy"
assert_contains 'the danger is spelled out'      "$got" "git add -A"
assert_contains 'the archive is noticed'         "$got" "hem-archive-20261125.tar.gz"
assert_contains 'and the fix is git restore'     "$got" "restore outputs"
assert_eq       'nothing was restored by sweep'  "$(git -C "$H" ls-files --deleted | wc -l | tr -d ' ')" "3"

echo "large untracked files"
got=$(finding large_untracked)
assert_contains 'the file is named'              "$got" "data/samples.jsonl.gz"
assert_contains 'with its size'                  "$got" "60 MB"
assert_contains 'and a .gitignore line'          "$got" "echo '*.gz' >>"

echo "committed caches and uncommitted work (FYI, not urgent)"
fyi=$(cat "$SWEEP_FYI")
assert_contains 'the __pycache__ is reported'    "$fyi" "cached/pkg/__pycache__"
assert_contains 'the .DS_Store too'              "$fyi" "cached/.DS_Store"
assert_contains 'git rm --cached is suggested'   "$fyi" "git rm -r --cached"
assert_contains 'uncommitted changes are counted' "$fyi" "**cached** has 1 uncommitted change"

echo "behind upstream"
got=$(finding behind)
assert_contains 'reported'                       "$got" "mainspring"
assert_contains 'with the count'                 "$got" "1 commit(s) on"
assert_contains 'and pull --rebase as the fix'   "$got" "pull --rebase"
assert_contains 'and sweep says it will not pull' "$got" "sweep never pulls"

echo "branch with no upstream"
assert_contains 'reported'                       "$fyi" "branch \`irish-next-steps\` has no upstream"

echo "nothing was pushed, committed or staged anywhere"
assert_eq 'hem still has its archive untracked'  "$(git -C "$H" status --porcelain | grep -c 'hem-archive')" "1"
assert_eq 'nothing was staged in cached'         "$(git -C "$C" diff --cached --name-only | wc -l | tr -d ' ')" "0"
assert_eq 'morphology branch is still local'     "$(git -C "$N" rev-parse --abbrev-ref --symbolic-full-name 'irish-next-steps@{upstream}' 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_contains 'AUTO_PUSH=0 is explained'       "$fyi" "AUTO_PUSH=0"

echo "nested repos are found, virtualenvs are not"
mkdir -p "$CODE_DIR/morphology/external"
E=$(t_mkrepo morphology/external/tknzn4Irish)
mkdir -p "$CODE_DIR/deep/a/b/c"; git init -q "$CODE_DIR/deep/a/b/c"
mkdir -p "$CODE_DIR/proj/.venv-extract/src/pkg"; git init -q "$CODE_DIR/proj/.venv-extract/src/pkg"
repos=$(sweep_find_repos)
assert_contains 'a repo three deep is found'     "$repos" "morphology/external/tknzn4Irish"
assert_not_contains 'a repo four deep is not'    "$repos" "deep/a/b/c"
assert_not_contains 'nor one inside .venv-extract' "$repos" ".venv-extract"

t_end
