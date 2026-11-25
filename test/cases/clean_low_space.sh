#!/bin/bash
# Tier 7: Hugging Face caches, which only run when space is still short.
. "$(dirname "$0")/../helpers.sh"

t_home
export LOW_SPACE_GB=1          # threshold is 1048576 KB of free space
export HF_MAX_IDLE_DAYS=21
export KEEP_HF="distilroberta-base pythia-70m"

# A fake hub: four repos, two of them long idle.
HUB="$HOME/.cache/huggingface/hub"
mkhf() {  # name mb idle_days
  local d="$HUB/$1"
  mkdir -p "$d/refs/main" "$d/snapshots/abc123" "$d/blobs"
  printf 'abc123\n' > "$d/refs/main/x"
  dd if=/dev/zero of="$d/blobs/model.bin" bs=1048576 count="$2" 2>/dev/null
  ln -s "../blobs/model.bin" "$d/snapshots/abc123/model.bin" 2>/dev/null
  t_age_tree "$d" "$3"
}
mkhf "models--EleutherAI--pythia-1b"      3 60   # idle longest, goes first
mkhf "models--openai-community--gpt2"     3 40   # idle, but space runs out first
mkhf "models--sentence-transformers--all" 3 2    # used recently, stays
mkhf "models--distilbert--distilroberta-base" 3 999  # KEEP_HF, stays forever
mkhf "datasets--wikitext"                 3 50   # datasets count too

echo "above the threshold the tier does not run at all"
export SWEEP_FAKE_FREE_KB=$(( 3 * 1048576 ))
t_load
if sweep_free_gb_lt "$LOW_SPACE_GB"; then sweep_clean_huggingface; fi
assert_exists 'nothing was deleted with 3 GB free' "$HUB/models--EleutherAI--pythia-1b/blobs/model.bin"
assert_eq     'and nothing was accounted for'      "$(sweep_cleaned_kb)" "0"

echo "below the threshold it deletes oldest-idle first and stops when there is room"
# 2.2 MB short of the threshold, so one 3 MB repo is enough.
export SWEEP_FAKE_FREE_KB=$(( 1048576 - 2200 ))
unset SWEEP_ENV_SNAPSHOT
t_load
assert_true 'the tier is triggered' sweep_free_gb_lt "$LOW_SPACE_GB"
sweep_clean_huggingface

assert_missing 'the longest-idle repo goes'        "$HUB/models--EleutherAI--pythia-1b"
assert_exists  'the next one is spared: back above the threshold' "$HUB/datasets--wikitext/blobs/model.bin"
assert_exists  'so is gpt2'                        "$HUB/models--openai-community--gpt2/blobs/model.bin"
assert_exists  'the recently used repo stays'      "$HUB/models--sentence-transformers--all/blobs/model.bin"
assert_exists  'a KEEP_HF repo stays'              "$HUB/models--distilbert--distilroberta-base/blobs/model.bin"
assert_exists  'the hub itself stays'              "$HUB"
log=$(cat "$SWEEP_RUN_LOG")
assert_contains 'KEEP_HF is explained'             "$log" "kept (KEEP_HF)"
assert_contains 'recent use is explained'          "$log" "kept (used 2d ago) ~/.cache/huggingface/hub/models--sentence-transformers--all"
assert_contains 'and so is stopping early'         "$log" "back above 1 GB free"

echo "everything idle goes when the disk stays full"
export SWEEP_FAKE_FREE_KB=1000
unset SWEEP_ENV_SNAPSHOT
t_load
sweep_clean_huggingface
assert_missing 'gpt2 goes'                         "$HUB/models--openai-community--gpt2"
assert_missing 'the idle dataset goes'             "$HUB/datasets--wikitext"
assert_exists  'the recently used repo still stays' "$HUB/models--sentence-transformers--all/blobs/model.bin"
assert_exists  'KEEP_HF still holds'               "$HUB/models--distilbert--distilroberta-base/blobs/model.bin"

t_end
