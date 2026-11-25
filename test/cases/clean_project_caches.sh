#!/bin/bash
# Tier 3: caches inside ~/code. The two traps are descending into virtual
# environments and deleting a __pycache__ that someone committed.
. "$(dirname "$0")/../helpers.sh"

t_home
t_load

P="$CODE_DIR/myproj"
mkdir -p "$P"

# ordinary caches: these go
mkdir -p "$P/tests/__pycache__" "$P/.pytest_cache" "$P/.mypy_cache" \
         "$P/.ruff_cache" "$P/notebooks/.ipynb_checkpoints" "$P/.hypothesis" \
         "$P/src/pkg/__pycache__"
printf 'x\n' > "$P/tests/__pycache__/test_x.cpython-312.pyc"
printf 'x\n' > "$P/src/pkg/__pycache__/mod.cpython-312.pyc"

# inside virtual environments: must not even be listed
mkdir -p "$P/.venv-extract/lib/python3.12/site-packages/numpy/__pycache__"
mkdir -p "$P/.venv/lib/python3.12/site-packages/x/__pycache__"
mkdir -p "$P/venv311/lib/python3.11/site-packages/y/__pycache__"
mkdir -p "$P/node_modules/pkg/__pycache__"
printf 'x\n' > "$P/.venv-extract/lib/python3.12/site-packages/numpy/__pycache__/a.pyc"
printf 'x\n' > "$P/.venv/lib/python3.12/site-packages/x/__pycache__/a.pyc"
printf 'x\n' > "$P/venv311/lib/python3.11/site-packages/y/__pycache__/a.pyc"
printf 'x\n' > "$P/node_modules/pkg/__pycache__/a.pyc"

listed=$(sweep_project_cache_dirs)
assert_contains     'tests/__pycache__ is found'      "$listed" "$P/tests/__pycache__"
assert_contains     'src/pkg/__pycache__ is found'    "$listed" "$P/src/pkg/__pycache__"
assert_not_contains 'nothing from .venv-extract'      "$listed" ".venv-extract"
assert_not_contains 'nothing from .venv'              "$listed" "/.venv/"
assert_not_contains 'nothing from venv311'            "$listed" "venv311"
assert_not_contains 'nothing from site-packages'      "$listed" "site-packages"
assert_not_contains 'nothing from node_modules'       "$listed" "node_modules"

# a repo that committed its __pycache__, as hem and friends had
R=$(t_mkrepo tracked)
mkdir -p "$R/pkg/__pycache__"
printf 'x\n' > "$R/pkg/__pycache__/mod.cpython-312.pyc"
git -C "$R" add -f pkg/__pycache__
git -C "$R" commit -qm "oops, committed a cache"

sweep_clean_project_caches

assert_missing 'tests/__pycache__ is gone'            "$P/tests/__pycache__"
assert_missing 'src/pkg/__pycache__ is gone'          "$P/src/pkg/__pycache__"
assert_missing '.pytest_cache is gone'                "$P/.pytest_cache"
assert_missing '.mypy_cache is gone'                  "$P/.mypy_cache"
assert_missing '.ruff_cache is gone'                  "$P/.ruff_cache"
assert_missing '.ipynb_checkpoints is gone'           "$P/notebooks/.ipynb_checkpoints"
assert_missing '.hypothesis is gone'                  "$P/.hypothesis"
assert_exists  'the project itself is untouched'      "$P/src"
assert_exists  '.venv-extract is untouched'           "$P/.venv-extract/lib/python3.12/site-packages/numpy/__pycache__/a.pyc"
assert_exists  '.venv is untouched'                   "$P/.venv/lib/python3.12/site-packages/x/__pycache__/a.pyc"
assert_exists  'venv311 is untouched'                 "$P/venv311/lib/python3.11/site-packages/y/__pycache__/a.pyc"
assert_exists  'node_modules is untouched'            "$P/node_modules/pkg/__pycache__/a.pyc"

assert_exists  'a committed __pycache__ is not deleted' "$R/pkg/__pycache__/mod.cpython-312.pyc"
assert_contains 'it is reported instead'              "$(cat "$SWEEP_FYI")" "committed_cache"
assert_contains 'with the fix'                        "$(cat "$SWEEP_FYI")" "git rm -r --cached"
assert_contains 'and the log says why it was kept'    "$(cat "$SWEEP_RUN_LOG")" "kept (tracked by git)"
assert_eq      'the repo has nothing staged'          "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')" "0"

t_end
