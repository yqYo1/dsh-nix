#!/usr/bin/env bash
# Run the pinned, real Home Manager activation regression in a Nix sandbox.
# Unlike a stub-generated activation snippet, this exercises three actual
# homeManagerConfiguration activationPackages (gen1 covers agent, extra,
# tricky names, the lock-bearing codex spec, and the directly declared
# user-npm buildNpmPackage profile). Consumer dotfiles are untouched.
# Nix-CLI profile probes are shimmed inside the check; host profile installation
# and the packaged dsh runtime are deliberately not claimed by this gate.
#
# The Home Manager pin lives in the tests subflake (tests/flake.lock), so the
# root flake stays Home Manager-independent: this gate builds the check from
# ./tests, never from the root flake.
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
