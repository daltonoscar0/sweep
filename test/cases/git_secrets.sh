#!/bin/bash
# A push that would publish a secret, or a blob GitHub would refuse, is blocked.
. "$(dirname "$0")/../helpers.sh"

t_home
t_load
export AUTO_PUSH=1
export PUSH_OWNERS="daltonoscar0"
export MAX_PUSH_FILE_MB=5

# The fake credentials below are made up and never leave the temp directory.
HF_FAKE="hf_$(printf 'q%.0s' $(seq 1 34))"
ANTHROPIC_FAKE="sk-ant-api03-$(printf 'z%.0s' $(seq 1 30))"
AWS_FAKE="AKIAZZZZQQQQ7777TTTT"

S=$(t_mkrepo leaky); t_own "$S" daltonoscar0
mkdir -p "$S/src"
printf 'TOKEN = "%s"\n' "$HF_FAKE" > "$S/src/config.py"
t_commit "$S" "src/config.py" "TOKEN = \"$HF_FAKE\""

A=$(t_mkrepo keyfile); t_own "$A" daltonoscar0
printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_FAKE" > "$A/.env"
git -C "$A" add -f .env
git -C "$A" commit -qm "add env"

W=$(t_mkrepo awskey); t_own "$W" daltonoscar0
t_commit "$W" "deploy/vars.tf" "access_key = \"$AWS_FAKE\""

P=$(t_mkrepo pemfile); t_own "$P" daltonoscar0
printf -- '-----BEGIN RSA PRIVATE KEY-----\nnot-a-real-key\n-----END RSA PRIVATE KEY-----\n' > "$P/id.pem"
git -C "$P" add -f id.pem
git -C "$P" commit -qm "add pem"

# A repo whose first commit is not on any remote at all: the diff has no base
# commit to compare against, so sweep has to fall back to the empty tree.
F="$CODE_DIR/fresh"
mkdir -p "$F"
git init -q --bare "$T_TMP/remotes/fresh.git"
git init -q "$F"
printf 'TOKEN = "%s"\n' "$HF_FAKE" > "$F/secrets.py"
git -C "$F" add -A
git -C "$F" commit -qm "first and only"
git -C "$F" remote add origin "$T_TMP/remotes/fresh.git"
t_own "$F" daltonoscar0

# A blob over the limit, like the 276 MB archives
G=$(t_mkrepo heavy); t_own "$G" daltonoscar0
t_mkfile "$G/model.bin" 7
git -C "$G" add -f model.bin
git -C "$G" commit -qm "add a 7 MB model"

# Clean repo, to prove the scan does not block everything
K=$(t_mkrepo clean); t_own "$K" daltonoscar0
t_commit "$K" "safe.py" "TOKEN = os.environ['HF_TOKEN']"

sweep_git_check

secrets=$(awk -F'\t' '$1 == "secret" {print $2 ": " $3}' "$SWEEP_GIT")
toobig=$(awk -F'\t' '$1 == "too_big" {print $2 ": " $3}' "$SWEEP_GIT")
pushed=$(awk -F'\t' '{print $2}' "$SWEEP_PUSH")
whole=$(cat "$SWEEP_GIT" "$SWEEP_PUSH" "$SWEEP_FYI" "$SWEEP_RUN_LOG")

echo "secrets block the push"
assert_contains 'the Hugging Face token is caught'  "$secrets" "leaky: NOT PUSHED: what looks like a Hugging Face token"
assert_contains 'with the file and line'            "$secrets" "src/config.py:1"
assert_contains 'the Anthropic key is caught'       "$secrets" "keyfile:"
assert_contains 'a .env file is caught by name'     "$secrets" "a credential file by name"
assert_contains 'the AWS key is caught'             "$secrets" "awskey: NOT PUSHED: what looks like a AWS access key id"
assert_contains 'the private key block is caught'   "$secrets" "pemfile:"
assert_contains 'a brand new repo is scanned too'   "$secrets" "fresh: NOT PUSHED: what looks like a Hugging Face token"

echo "nothing was pushed from those repos"
assert_not_contains 'leaky'    "$pushed" "leaky"
assert_not_contains 'keyfile'  "$pushed" "keyfile"
assert_not_contains 'awskey'   "$pushed" "awskey"
assert_not_contains 'pemfile'  "$pushed" "pemfile"
assert_not_contains 'fresh'    "$pushed" "fresh"
assert_eq 'the leaky remote never moved' "$(git -C "$S" rev-parse --verify --quiet origin/main)" "$(git -C "$S" rev-parse HEAD~1)"

echo "the secret values themselves are never written down"
assert_not_contains 'no HF token anywhere'        "$whole" "$HF_FAKE"
assert_not_contains 'no Anthropic key anywhere'   "$whole" "$ANTHROPIC_FAKE"
assert_not_contains 'no AWS key anywhere'         "$whole" "$AWS_FAKE"
assert_not_contains 'not even a fragment'         "$whole" "not-a-real-key"

echo "a blob over the limit blocks the push"
assert_contains 'reported'                    "$toobig" "heavy: not pushed"
assert_contains 'the file is named'           "$toobig" "model.bin"
assert_contains 'with its size'               "$toobig" "(7 MB)"
assert_not_contains 'and nothing was pushed'  "$pushed" "heavy"

echo "an innocent repo is still pushed"
assert_contains 'pushed'                      "$pushed" "clean"

t_end
