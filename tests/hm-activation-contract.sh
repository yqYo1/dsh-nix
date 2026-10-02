#!/usr/bin/env bash
# Run the pinned, real Home Manager activation regression in a Nix sandbox.
# Unlike a stub-generated activation snippet, this exercises three actual
# homeManagerConfiguration activationPackages. Consumer dotfiles are untouched.
# Nix-CLI profile probes are shimmed inside the check; host profile installation
# and the packaged dsh runtime are deliberately not claimed by this gate.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
system=$(nix eval --impure --raw --expr builtins.currentSystem)
scratch=$(mktemp -d -t dsh-hm-real.XXXXXXXX)

nix build --no-write-lock-file \
  ".#checks.${system}.home-manager-integration" \
  --out-link "$scratch/check" --print-out-paths -L

# Read the result from the realised artifact, not a captured pipeline status.
test -f "$scratch/check/result.txt"
printf 'Home Manager regression artifact: %s\n' "$scratch/check"
