# Continuous regression for genuine user-declared buildNpmPackage plugins.
#
# The user plugin is the RAW buildNpmPackage derivation — no installedRoot
# subpath selectors or hand-rolled npm layouts in the genuine positive
# path. The standard manifest lives at
# $out/lib/node_modules/<name>/package.json, not at $out/package.json.
# The production builder must resolve that root while preserving closure.
#
# Args: { pkgs, dshPackage, checker }
#   checker is ./scripts/check-profile.mjs from the repo root.
# Exposes: .check (positive gate), .artifact / .profile / .userPkg, plus
# separately-buildable expected-failure derivations (NOT checks):
#   .negativeMissingArtifact   derivation with no package.json anywhere —
#                              must keep failing loud after the core patch.
#   .negativeCollisionArtifact  the same raw derivation twice — must keep
#                              failing loud on the duplicate packageName.
#
# Reproduce the positive gate (from the repo root, no lock writes):
#   nix build --accept-flake-config --no-update-lock-file \
#     --no-write-lock-file .#checks.x86_64-linux.profile-user-npm
# Probe a negative (each must FAIL to build):
#   nix build --impure --accept-flake-config --no-update-lock-file \
#     --no-write-lock-file --expr \
#     'let f = builtins.getFlake "path:/home/yayoi/ghq/github.com/yqYo1/dsh-nix/.worktree/test-user-npm-package"; pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux; in (import ./tests/user-npm.nix { inherit pkgs; dshPackage = f.packages.x86_64-linux.dsh; checker = ./scripts/check-profile.mjs; }).negativeMissingArtifact'
{ pkgs, dshPackage, checker }:

let
  lib = pkgs.lib;
  profilesLib = import ../lib/profiles.nix { inherit lib; };

  userPkg = import ./fixtures/user-npm-plugin.nix { inherit pkgs; };

  profile = profilesLib.mkProfileBundle {
    name = "user-npm";
    plugins = [ userPkg ];
    userPatchesFile = null;
    userPatches = [ ];
    specsHash = "";
  };

  artifact = profilesLib.buildProfileBundle { inherit pkgs profile; };

  missingDrv = pkgs.runCommand "dsh-user-npm-negative-missing" { } ''
    mkdir -p "$out"
    printf 'no package.json anywhere in this output\n' > "$out/README.txt"
  '';

  negativeMissingArtifact = profilesLib.buildProfileBundle {
    inherit pkgs;
    profile = profilesLib.mkProfileBundle {
      name = "user-npm-negative-missing";
      plugins = [ missingDrv ];
      userPatchesFile = null;
      userPatches = [ ];
      specsHash = "";
    };
  };

  negativeCollisionArtifact = profilesLib.buildProfileBundle {
    inherit pkgs;
    profile = profilesLib.mkProfileBundle {
      name = "user-npm-negative-collision";
      plugins = [ userPkg userPkg ];
      userPatchesFile = null;
      userPatches = [ ];
      specsHash = "";
    };
  };

  check = pkgs.runCommand "dsh-profile-user-npm-check"
    {
      nativeBuildInputs = [ pkgs.jq pkgs.nodejs ];
      guard = ./fixtures/no-net-guard.cjs;
    }
    ''
      set -euo pipefail
      work="$TMPDIR/user-npm"
      export HOME="$work/home"
      export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
      export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
      mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
      fail() { echo "profile-user-npm FAIL: $*" >&2; exit 1; }
      pass() { echo "profile-user-npm ok: $*"; }
      # Execute production root/patch policy, including rejection paths.
      grep -q '^PLUGIN-ROOTS-OK ' ${(import ./plugin-roots.nix { inherit pkgs; })}/passed
      pass "production root/patch policy checks passed"

      # --- raw-derivation runtime shape: name / layer / order / direct-only ---
      jq -e '.dsh.profile.bundles == ["@dsh-poc/user-npm-plugin"]' \
        ${artifact}/package.json > /dev/null \
        || fail "bundles is not exactly the manifest-declared layer"
      pass "layer order is exactly the manifest name"
      jq --arg want "${userPkg}/lib/node_modules/@dsh-poc/user-npm-plugin" \
        -e '.dependencies."@dsh-poc/user-npm-plugin" == $want' \
        ${artifact}/package.json > /dev/null \
        || fail "dependencies does not map the manifest name to the installed package root"
      pass "manifest name maps to the installed package root"
      case ${userPkg} in
        *dsh-poc-npm-user-pkg*) pass "derivation pname differs from manifest name" ;;
        *) fail "derivation store path lost the dsh-poc-npm-user-pkg pname" ;;
      esac
      [ "$(ls ${artifact}/node_modules)" = "@dsh-poc" ] \
        || fail "profile top level leaked beyond the direct scope"
      pass "direct-only projection at profile top"
      test -d ${artifact}/node_modules/@dsh-poc || fail "scope parent is not a real dir"
      test ! -L ${artifact}/node_modules/@dsh-poc || fail "scope parent is a symlink (whole-scope leak)"
      test -L ${artifact}/node_modules/@dsh-poc/user-npm-plugin \
        || fail "scoped package is not a single exact link"
      [ "$(ls ${artifact}/node_modules/@dsh-poc)" = "user-npm-plugin" ] \
        || fail "scope contains an undeclared sibling"
      pass "scoped parent is a real dir with one exact package link"
      target=$(readlink ${artifact}/node_modules/@dsh-poc/user-npm-plugin)
      jq -e '.name == "@dsh-poc/user-npm-plugin"' "$target/package.json" > /dev/null \
        || fail "link target manifest name mismatch"
      test -d "$target/node_modules/is-odd" || fail "runtime is-odd missing under installed root"
      test -d "$target/node_modules/is-number" || fail "transitive is-number missing under installed root"
      pass "installed root carries the complete real dependency closure"

      # --- guard positive control (before trusting it below) ---
      ${pkgs.nodejs}/bin/node --require "$guard" --input-type=module -e \
        "await fetch('http://example.com/')" 2>"$work/guard-proof.err" \
        && fail "guard did not block fetch"
      grep -q 'NETWORK_FORBIDDEN' "$work/guard-proof.err" \
        || fail "guard error signature missing"
      pass "no-network guard rejects egress"

      # --- real transitive import (not symlink shape) ---
      ${pkgs.nodejs}/bin/node --require "$guard" --input-type=module -e "
        const { checkOdd } = await import('${artifact}/node_modules/@dsh-poc/user-npm-plugin/lib/index.js');
        if (checkOdd(3) !== true) { console.error('odd3 != true'); process.exit(1); }
        if (checkOdd(4) !== false) { console.error('odd4 != false'); process.exit(1); }
        console.log('IMPORT-OK odd3=true odd4=false');
      " > "$work/import.log" 2>&1 \
        || { cat "$work/import.log" >&2; fail "real transitive index import"; }
      grep -q '^IMPORT-OK' "$work/import.log" || fail "import marker missing"
      pass "real transitive import ($(cat "$work/import.log"))"

      # --- CLI wrapper EXECUTED (never `node bin.js`) under guard/fresh env ---
      if command -v pnpm > /dev/null 2>&1; then fail "ambient pnpm on PATH (must be pnpm-free)"; fi
      pass "parent PATH proven pnpm-free"
      wrapper=${userPkg}/bin/dsh-poc-npm-plugin
      test -x "$wrapper" || fail "buildNpm bin wrapper missing/not executable"
      head -1 "$wrapper" | grep -q '^#!' || fail "bin wrapper has no shebang line"
      run_wrapper() {
        label=$1; shift
        if env -i PATH=${pkgs.nodejs}/bin:/usr/bin:/bin HOME="$HOME" \
          XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
          XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
          NODE_OPTIONS="--require $guard" \
          "$wrapper" "$@" > "$work/$label.out" 2> "$work/$label.err"; then
          printf '0' > "$work/$label.rc"
        else
          printf '%s' "$?" > "$work/$label.rc"
        fi
      }
      run_wrapper help --help
      [ "$(cat "$work/help.rc")" = "0" ] || fail "wrapper --help rc"
      grep -q 'Usage: dsh-poc-npm-plugin' "$work/help.out" || fail "wrapper --help text"
      pass "wrapper --help rc0 under guard"
      run_wrapper check7 check 7
      [ "$(cat "$work/check7.rc")" = "0" ] || fail "wrapper check 7 rc"
      [ "$(cat "$work/check7.out")" = "odd" ] || fail "wrapper check 7 text"
      run_wrapper check8 check 8
      [ "$(cat "$work/check8.rc")" = "0" ] || fail "wrapper check 8 rc"
      [ "$(cat "$work/check8.out")" = "even" ] || fail "wrapper check 8 text"
      pass "wrapper check 7/8 executed (odd/even) under guard"
      run_wrapper status status
      [ "$(cat "$work/status.rc")" = "1" ] || fail "wrapper status rc is not the exact signed-out rc1"
      [ "$(cat "$work/status.out")" = "dsh-poc-npm-plugin: signed out" ] \
        || fail "wrapper status exact signed-out text"
      grep -Eq 'ERR_MODULE_NOT_FOUND|Cannot find package|NETWORK_FORBIDDEN' "$work/status.out" "$work/status.err" \
        && fail "wrapper status rc1 is an import/net error, not signed-out"
      pass "wrapper status rc1 exact signed-out (not import-error rc1)"
      test ! -e "$HOME/.dsh" || fail "wrapper runs created .dsh in fresh HOME"
      pass "wrapper runs create no .dsh under fresh HOME"

      # --- actual profile boot (checker + packaged rc.2, port 0) ---
      bootHome="$work/boot-home"
      mkdir -p "$bootHome/profiles"
      cp -a ${artifact} "$bootHome/profiles/user-npm"
      chmod -R u+w "$bootHome/profiles/user-npm"
      if ! env -i PATH=${pkgs.nodejs}/bin:/usr/bin:/bin HOME="$bootHome" \
        XDG_DATA_HOME="$bootHome/.local/share" XDG_STATE_HOME="$bootHome/.local/state" \
        XDG_CONFIG_HOME="$bootHome/.config" XDG_CACHE_HOME="$bootHome/.cache" \
        NODE_OPTIONS="--require $guard" \
        ${pkgs.nodejs}/bin/node --expose-internals \
        --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
        ${checker} \
        ${dshPackage} user-npm "$bootHome" --port 0 --no-open \
        > "$work/boot.log" 2>&1; then
        cat "$work/boot.log" >&2
        fail "user-npm profile boot (module import was green; app boot must be too)"
      fi
      grep -q '^CHECK-OK$' "$work/boot.log" || fail "boot lacks CHECK-OK"
      pass "user-npm profile boot CHECK-OK under guard"
      printf 'activated odd7=true\ndisposed\n' > "$work/expected-lifecycle"
      cmp "$work/expected-lifecycle" "$bootHome/poc-npm-fixture-lifecycle.log" \
        || fail "lifecycle is not exactly activated odd7=true then disposed"
      pass "exact lifecycle activated odd7=true/disposed"

      mkdir -p "$out"
      printf 'USER-NPM-ARTIFACT-OK %s\n' ${artifact} > "$out/marker"
      cp "$work/import.log" "$work/status.out" "$work/boot.log" "$out/"
    '';
in
{
  inherit check artifact profile userPkg;
  inherit negativeMissingArtifact negativeCollisionArtifact;
}
