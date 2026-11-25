#!/bin/bash
# Auto-push: who gets pushed, who does not, and what a dry run does.
. "$(dirname "$0")/../helpers.sh"

t_home
t_load
export AUTO_PUSH=1
export PUSH_OWNERS="daltonoscar0"

pushes() { awk -F'\t' '{print $1 " " $2 " " $3 " " $4}' "$SWEEP_PUSH"; }
remote_head() { git -C "$1" rev-parse --verify --quiet "origin/$2" 2>/dev/null || echo none; }

# mine, with two commits to send
A=$(t_mkrepo mine); t_own "$A" daltonoscar0
t_commit "$A" "one.txt" 1
t_commit "$A" "two.txt" 2

# someone else's repo, like nyusemantics/LambdaCalculator
O=$(t_mkrepo LambdaCalculator); t_own "$O" nyusemantics
t_commit "$O" "mine.txt" "local work"

# a remote that is not GitHub at all gets no owner and so is never pushed
X=$(t_mkrepo nogithub)
t_commit "$X" "x.txt" x

# behind as well as ahead: never pushed, reported instead
B=$(t_mkrepo bothways); t_own "$B" daltonoscar0
t_remote_commit "$B" "theirs.txt" theirs
t_commit "$B" "ours.txt" ours

# a branch with no upstream
U=$(t_mkrepo sidebranch); t_own "$U" daltonoscar0
git -C "$U" checkout -q -b arr-revision
t_commit "$U" "revision.md" "notes"

# up to date: nothing to do
Q=$(t_mkrepo quiet); t_own "$Q" daltonoscar0

echo "a dry run pushes nothing at all"
before_mine=$(remote_head "$A" main)
SWEEP_DRY_RUN=1 sweep_git_check
assert_contains 'it says what it would do'   "$(pushes)" "would_push mine main 2"
assert_eq       'but the remote did not move' "$(remote_head "$A" main)" "$before_mine"
assert_eq       'and the side branch is still local only' "$(remote_head "$U" arr-revision)" "none"

echo "for real now"
unset SWEEP_ENV_SNAPSHOT
t_load
export AUTO_PUSH=1 PUSH_OWNERS="daltonoscar0"
sweep_git_check
got=$(pushes)

assert_contains 'my repo is pushed with its commit count' "$got" "pushed mine main 2"
assert_eq       'and the remote really moved'  "$(remote_head "$A" main)" "$(git -C "$A" rev-parse HEAD)"

assert_not_contains 'someone else repo is not pushed' "$got" "LambdaCalculator"
assert_eq       'their remote is untouched'    "$(remote_head "$O" main)" "$(git -C "$O" rev-parse HEAD~1)"
assert_contains 'and it is explained'          "$(cat "$SWEEP_FYI")" "belongs to nyusemantics rather than you"

assert_not_contains 'a non-GitHub remote is not pushed' "$got" "nogithub"
assert_contains 'with its own line'            "$(cat "$SWEEP_FYI")" "**nogithub** has 1 commit(s) not on its remote"

assert_not_contains 'a repo that is behind is not pushed' "$got" "bothways"
assert_contains 'it is reported as behind'     "$(awk -F'\t' '$1=="behind" {print $2}' "$SWEEP_GIT")" "bothways"
assert_contains 'and the log says why'         "$(cat "$SWEEP_RUN_LOG")" "not pushing bothways: behind by 1"

assert_contains 'a branch with no upstream is pushed with -u' "$got" "pushed sidebranch arr-revision 1"
assert_eq       'the branch is now on the remote' "$(remote_head "$U" arr-revision)" "$(git -C "$U" rev-parse HEAD)"
assert_eq       'and it has an upstream'       "$(git -C "$U" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" "origin/arr-revision"

assert_not_contains 'an up-to-date repo is left alone' "$got" "quiet"

echo "AUTO_PUSH=0 pauses everything"
unset SWEEP_ENV_SNAPSHOT
t_load
export AUTO_PUSH=0
t_commit "$A" "three.txt" 3
sweep_git_check
assert_eq       'nothing was pushed'           "$(wc -l < "$SWEEP_PUSH" | tr -d ' ')" "0"
assert_contains 'but it is still reported'     "$(cat "$SWEEP_FYI")" "**mine** has 1 commit(s) to push, but AUTO_PUSH=0"

echo "offline: nothing is pushed and the report says so"
unset SWEEP_ENV_SNAPSHOT
t_load
export AUTO_PUSH=1 SWEEP_FAKE_NETWORK=0
sweep_git_check
assert_eq       'no pushes'                    "$(wc -l < "$SWEEP_PUSH" | tr -d ' ')" "0"
assert_contains 'the run is marked offline'    "$(awk -F'\t' '$1=="offline" {print $3}' "$SWEEP_GIT")" "github.com was unreachable"
assert_contains 'and the repo is listed'       "$(cat "$SWEEP_FYI")" "**mine** has 1 commit(s) to push; sweep was offline"

t_end
