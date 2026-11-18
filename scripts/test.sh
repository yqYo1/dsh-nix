#!/usr/bin/env bash
# Run the flake checks on a source tree that Nix can actually see.
#
# Flake inputs taken from a Git working tree include tracked files only.  A
# local run that silently ignores a new fixture or source file can therefore
# report success for code that was never evaluated.  Reject untracked,
# non-ignored files before invoking Nix; CI checks out a clean tree and is
# unaffected.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

untracked=$(git ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
  echo "test.sh: refusing to test with untracked files (git add them first):" >&2
  printf '%s\n' "$untracked" >&2
  exit 1
fi

nix flake check --accept-flake-config --no-update-lock-file --no-write-lock-file "$@"
nix flake check ./tests --accept-flake-config --no-update-lock-file --no-write-lock-file "$@"
