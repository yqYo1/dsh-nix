#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
system=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr builtins.currentSystem)
scratch=$(mktemp -d -t dsh-hm-real.XXXXXXXX)

nix build --accept-flake-config --no-update-lock-file --no-write-lock-file \
  "./tests#checks.${system}.home-manager-integration" \
  --out-link "$scratch/check" --print-out-paths -L

# Read the result from the realised artifact, not a captured pipeline status.
test -f "$scratch/check/result.txt"
printf 'Home Manager regression artifact: %s\n' "$scratch/check"
