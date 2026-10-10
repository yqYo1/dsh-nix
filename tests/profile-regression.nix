# Offline profile artifact regression (no network, no IFD).
#
# Covers the advertised HM integration: `plugins` accepts raw Nix packages
# (derivations) alongside in-box strings and local paths, in one ordered list.
# Raw derivations defer package.json name/patch resolution to build time.
#
# Run offline (flake nixpkgs, no substituters needed beyond base):
#   nix build --offline --option build-use-substitutes false \
#     --impure --expr '(import ./tests/profile-regression.nix { pkgs = import <nixpkgs> {}; }).check' \
#     --out-link /tmp/dsh-regression-check
# Or via flake legacyPackages:
#   nix build --offline .#checks.x86_64-linux.profile-regression
#   (once wired; this file itself needs no flake change to evaluate)
#
# What is asserted (see `check` below):
#   - ordered mixture: in-box strings (exact declared order) + local PATH
#     bundle + raw bundle DERIVATION + raw plain DERIVATION
#   - plain dependency is symlinked but NOT activated in bundles
#   - explicit in-box layer order is exact, not sorted
#   - userPatchesFile wins over inline userPatches, payload preserved verbatim
#   - inline userPatches JSON payload preserved when no file is set
#   - explicit patchPath projects a real rc.2-consumable layer: projected
#     node_modules manifest declares exactly the selected patch, patch bytes
#     exist beside it in valid Cordis insert/id syntax, identity preserved
#   - eval-time duplicate packageNames still throw; deferred nulls do not
{ pkgs }:

let
  lib = pkgs.lib;
  pluginsLib = import ../lib/plugins.nix { inherit lib; };
  profilesLib = import ../lib/profiles.nix { inherit lib; };

  inBoxNames = [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
  ];

  # Raw bundle derivation: package.json + node_modules payload, with patch.
  bundleDrv = pkgs.runCommand "test-bundle-plugin" { } ''
    mkdir -p "$out"
    cat > "$out/package.json" <<'EOF'
    {
      "name": "@test/bundle-plugin",
      "version": "0.0.0",
      "private": true,
      "type": "module",
      "exports": { "./plugin": "./plugin.mjs" },
      "dsh": { "bundle": { "patch": "cordis.patch.yml" } }
    }
    EOF
    printf '%s\n' '- insert:' '    - id: test-bundle-plugin-row' "      name: '@test/bundle-plugin/plugin'" > "$out/cordis.patch.yml"
    printf '%s\n' 'export const plugin = { name: "@test/bundle-plugin" };' > "$out/plugin.mjs"
  '';

  # Raw plain derivation: package.json + payload, NO bundle.patch declaration.
  # It still carries the selectable patch FILE so an explicit patchPath can
  # project a real rc.2-consumable layer from it.
  plainDrv = pkgs.runCommand "test-plain-dep" { } ''
    mkdir -p "$out"
    cat > "$out/package.json" <<'EOF'
    {
      "name": "@test/plain-dep",
      "version": "0.0.0",
      "private": true,
      "type": "module",
      "main": "./index.js"
    }
    EOF
    printf '%s\n' '- insert:' '    - id: test-plain-dep-row' "      name: '@test/plain-dep'" > "$out/cordis.patch.yml"
    printf '%s\n' 'module.exports = 42;' > "$out/index.js"
  '';

  ordered = profilesLib.mkProfileBundle {
    name = "regression-ordered";
    inherit inBoxNames;
    plugins = [
      "@deepseek-ai/dsh-web-app"
      "@deepseek-ai/dsh-base"
      (pluginsLib.mkPluginBundle { path = ./fixtures/local-bundle; })
      bundleDrv
      plainDrv
    ];
    userPatchesFile = ./fixtures/user-patch.yml;
    userPatches = [
      { insert = [{ id = "inline-shadowed-row"; name = "@test/shadowed"; }]; }
    ];
    specsHash = "";
  };

  inline = profilesLib.mkProfileBundle {
    name = "regression-inline";
    inherit inBoxNames;
    plugins = [
      (pluginsLib.mkPluginBundle { path = ./fixtures/local-bundle; })
    ];
    userPatchesFile = null;
    userPatches = [
      { insert = [{ id = "test-inline-row"; name = "@test/inline-row"; }]; }
    ];
    specsHash = "";
  };

  # Narrow explicit-patchPath case: plain manifest has no bundle.patch, but
  # an explicit patchPath must force layer membership at runtime.
  forced = profilesLib.mkProfileBundle {
    name = "regression-forced";
    inherit inBoxNames;
    plugins = [
      (pluginsLib.mkPluginBundle { path = plainDrv; patchPath = "cordis.patch.yml"; })
    ];
    userPatchesFile = null;
    userPatches = [ ];
    specsHash = "";
  };

  # External selections sharing the package file's basename (cordis.patch.yml).
  # Two variants because Nix path semantics differ:
  # - path-typed ./fixtures/external-patch/cordis.patch.yml -> builtins.path
  #   copies the FILE to /nix/store/<hash>-cordis.patch.yml, so the store
  #   basename (<hash>-cordis.patch.yml) does NOT collide with the package's
  #   cordis.patch.yml. Proves selection wins, but would pass even without
  #   the basename-skip guard.
  # - colliding absolute string "${builtins.path { path =
  #   ./fixtures/external-patch; }}/cordis.patch.yml" copies the DIRECTORY,
  #   so the store basename stays cordis.patch.yml: a TRUE basename
  #   collision with plainDrv's own cordis.patch.yml. Projection must skip
  #   the stale in-package file before cp, else cp writes through a symlink
  #   into the read-only store (or same-file error). This leg fails without
  #   the guard and is the real regression proof.
  external = profilesLib.mkProfileBundle {
    name = "regression-external";
    inherit inBoxNames;
    plugins = [
      (pluginsLib.mkPluginBundle { path = plainDrv; patchPath = ./fixtures/external-patch/cordis.patch.yml; })
    ];
    userPatchesFile = null;
    userPatches = [ ];
    specsHash = "";
  };

  externalColliding = profilesLib.mkProfileBundle {
    name = "regression-external-colliding";
    inherit inBoxNames;
    plugins = [
      (pluginsLib.mkPluginBundle { path = plainDrv; patchPath = "${builtins.path { path = ./fixtures/external-patch; }}/cordis.patch.yml"; })
    ];
    userPatchesFile = null;
    userPatches = [ ];
    specsHash = "";
  };

  orderedArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = ordered; };
  inlineArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = inline; };
  forcedArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = forced; };
  externalArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = external; };
  externalCollidingArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = externalColliding; };

  # Eval-time duplicate names (path bundles) must still throw.
  duplicateEval = builtins.tryEval (profilesLib.mkProfileBundle {
    name = "dup";
    inherit inBoxNames;
    plugins = [
      (pluginsLib.mkPluginBundle { path = ./fixtures/local-bundle; })
      (pluginsLib.mkPluginBundle { path = ./fixtures/local-bundle; })
    ];
  });

  # Two deferred (null) names must NOT throw at eval; runtime resolves them.
  deferredEval = builtins.tryEval (profilesLib.mkProfileBundle {
    name = "deferred-ok";
    inherit inBoxNames;
    plugins = [ bundleDrv plainDrv ];
  });

  # Actual duplicate raw names: eval defers (both null), but the build must
  # fail loud on the resolved duplicate. Exposed separately so callers can
  # exercise the malformed failure without breaking `check`.
  duplicateProfile = profilesLib.mkProfileBundle {
    name = "regression-duplicate";
    inherit inBoxNames;
    plugins = [ bundleDrv bundleDrv ];
    userPatchesFile = null;
    userPatches = [ ];
    specsHash = "";
  };
  duplicateArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = duplicateProfile; };
in
assert !duplicateEval.success;
assert deferredEval.success;
{
  inherit orderedArtifact inlineArtifact forcedArtifact duplicateArtifact externalArtifact externalCollidingArtifact;

  check = pkgs.runCommand "dsh-profile-regression-check"
    {
      nativeBuildInputs = [ pkgs.jq pkgs.diffutils ];
    }
    ''
      set -euo pipefail
      ordered=${orderedArtifact}
      inline=${inlineArtifact}
      forced=${forcedArtifact}

      # --- ordered mixture: exact layer order (in-box order preserved) ---
      expected_layers='["@deepseek-ai/dsh-web-app","@deepseek-ai/dsh-base","@test/local-bundle","@test/bundle-plugin"]'
      actual_layers=$(jq -c '.dsh.profile.bundles' "$ordered/package.json")
      if [ "$actual_layers" != "$expected_layers" ]; then
        echo "layers mismatch: got $actual_layers want $expected_layers" >&2
        exit 1
      fi

      # --- plain dep: present in dependencies, absent from bundles ---
      jq -e '.dependencies | has("@test/plain-dep")' "$ordered/package.json" > /dev/null
      jq -e '.dependencies | has("@test/bundle-plugin")' "$ordered/package.json" > /dev/null
      jq -e '.dependencies | has("@test/local-bundle")' "$ordered/package.json" > /dev/null
      if jq -e '.dsh.profile.bundles | index("@test/plain-dep")' "$ordered/package.json" > /dev/null; then
        echo "plain dep must not be activated" >&2
        exit 1
      fi

      # --- node_modules symlinks for all nix plugins ---
      test -L "$ordered/node_modules/@test/local-bundle"
      test -L "$ordered/node_modules/@test/bundle-plugin"
      test -L "$ordered/node_modules/@test/plain-dep"
      # manifest preserved verbatim through the symlink
      test "$(jq -r '.name' "$ordered/node_modules/@test/bundle-plugin/package.json")" = "@test/bundle-plugin"
      test "$(jq -r '.name' "$ordered/node_modules/@test/plain-dep/package.json")" = "@test/plain-dep"

      # --- userPatchesFile priority: file wins, payload verbatim ---
      if ! cmp -s "$ordered/cordis.patch.yml" ${./fixtures/user-patch.yml}; then
        echo "userPatchesFile payload not preserved verbatim" >&2
        diff -u ${./fixtures/user-patch.yml} "$ordered/cordis.patch.yml" >&2 || true
        exit 1
      fi
      if grep -q inline-shadowed "$ordered/cordis.patch.yml"; then
        echo "inline userPatches must not win over userPatchesFile" >&2
        exit 1
      fi

      # --- inline JSON payload preserved when no file is set (valid Cordis syntax) ---
      jq -e '.[0].insert[0].id == "test-inline-row"' "$inline/cordis.patch.yml" > /dev/null
      test "$(jq -c '.dsh.profile.bundles' "$inline/package.json")" = '["@test/local-bundle"]'

      # --- explicit patchPath forces layer membership AND real rc.2 content ---
      test "$(jq -c '.dsh.profile.bundles' "$forced/package.json")" = '["@test/plain-dep"]'
      jq -e '.dependencies | has("@test/plain-dep")' "$forced/package.json" > /dev/null
      # projected manifest declares exactly the selected patch (rc.2 reads this)
      test "$(jq -r '.dsh.bundle.patch' "$forced/node_modules/@test/plain-dep/package.json")" = "cordis.patch.yml"
      # manifest identity/payload preserved through the projection
      test "$(jq -r '.name' "$forced/node_modules/@test/plain-dep/package.json")" = "@test/plain-dep"
      test "$(jq -r '.main' "$forced/node_modules/@test/plain-dep/package.json")" = "./index.js"
      # projection is a real directory, not a bare symlink to the patch-less original
      test ! -L "$forced/node_modules/@test/plain-dep"
      test -d "$forced/node_modules/@test/plain-dep"
      # actual patch file exists beside the projected manifest, valid Cordis syntax
      test -f "$forced/node_modules/@test/plain-dep/cordis.patch.yml"
      grep -q "test-plain-dep-row" "$forced/node_modules/@test/plain-dep/cordis.patch.yml"
      if grep -q "op: add" "$forced/node_modules/@test/plain-dep/cordis.patch.yml"; then
        echo "forced patch must use Cordis insert/id syntax, not RFC6902 op/path" >&2
        exit 1
      fi
      # projected bytes match the source package's selected file
      orig=$(jq -r '.dependencies["@test/plain-dep"]' "$forced/package.json")
      cmp -s "$orig/cordis.patch.yml" "$forced/node_modules/@test/plain-dep/cordis.patch.yml" || {
        echo "projected patch bytes differ from source package selection" >&2
        exit 1
      }

      # --- external path-typed patch with colliding basename ---
      external=${externalArtifact}
      test "$(jq -c '.dsh.profile.bundles' "$external/package.json")" = '["@test/plain-dep"]'
      jq -e '.dependencies | has("@test/plain-dep")' "$external/package.json" > /dev/null
      # projected manifest refers to the SELECTED patch file beside it
      extPatchRel=$(jq -r '.dsh.bundle.patch' "$external/node_modules/@test/plain-dep/package.json")
      if [ -z "$extPatchRel" ] || [ "$extPatchRel" = "null" ]; then
        echo "external projection must declare dsh.bundle.patch" >&2
        exit 1
      fi
      test -f "$external/node_modules/@test/plain-dep/$extPatchRel"
      # identity/exports preserved through the projection
      test "$(jq -r '.name' "$external/node_modules/@test/plain-dep/package.json")" = "@test/plain-dep"
      test "$(jq -r '.main' "$external/node_modules/@test/plain-dep/package.json")" = "./index.js"
      test ! -L "$external/node_modules/@test/plain-dep"
      test -d "$external/node_modules/@test/plain-dep"
      # selected bytes win: projected file matches the external selection,
      # not the stale in-package bytes
      cmp -s ${./fixtures/external-patch/cordis.patch.yml} "$external/node_modules/@test/plain-dep/$extPatchRel" || {
        echo "external projected patch bytes differ from selected patch" >&2
        exit 1
      }
      grep -q "test-external-selected-row" "$external/node_modules/@test/plain-dep/$extPatchRel"
      if grep -q "test-plain-dep-row" "$external/node_modules/@test/plain-dep/$extPatchRel"; then
        echo "external projection carries stale in-package bytes" >&2
        exit 1
      fi
      # source package unchanged: still carries its own old bytes only
      extOrig=$(jq -r '.dependencies["@test/plain-dep"]' "$external/package.json")
      grep -q "test-plain-dep-row" "$extOrig/cordis.patch.yml"
      if grep -q "test-external-selected-row" "$extOrig/cordis.patch.yml"; then
        echo "external selection leaked into source package" >&2
        exit 1
      fi

      # --- TRUE basename collision: absolute store-dir string keeps basename
      # cordis.patch.yml, identical to the package's own file. Manifest must
      # declare exactly cordis.patch.yml; projection must hold SELECTED bytes
      # as a real file (not a symlink), source package untouched.
      colliding=${externalCollidingArtifact}
      test "$(jq -c '.dsh.profile.bundles' "$colliding/package.json")" = '["@test/plain-dep"]'
      jq -e '.dependencies | has("@test/plain-dep")' "$colliding/package.json" > /dev/null
      test "$(jq -r '.dsh.bundle.patch' "$colliding/node_modules/@test/plain-dep/package.json")" = "cordis.patch.yml"
      test "$(jq -r '.name' "$colliding/node_modules/@test/plain-dep/package.json")" = "@test/plain-dep"
      test "$(jq -r '.main' "$colliding/node_modules/@test/plain-dep/package.json")" = "./index.js"
      test ! -L "$colliding/node_modules/@test/plain-dep"
      test -d "$colliding/node_modules/@test/plain-dep"
      test -f "$colliding/node_modules/@test/plain-dep/cordis.patch.yml"
      test ! -L "$colliding/node_modules/@test/plain-dep/cordis.patch.yml"
      cmp -s ${builtins.path { path = ./fixtures/external-patch; }}/cordis.patch.yml "$colliding/node_modules/@test/plain-dep/cordis.patch.yml" || {
        echo "colliding projected patch bytes differ from selected patch" >&2
        exit 1
      }
      grep -q "test-external-selected-row" "$colliding/node_modules/@test/plain-dep/cordis.patch.yml"
      if grep -q "test-plain-dep-row" "$colliding/node_modules/@test/plain-dep/cordis.patch.yml"; then
        echo "colliding projection carries stale in-package bytes" >&2
        exit 1
      fi
      colOrig=$(jq -r '.dependencies["@test/plain-dep"]' "$colliding/package.json")
      grep -q "test-plain-dep-row" "$colOrig/cordis.patch.yml"
      if grep -q "test-external-selected-row" "$colOrig/cordis.patch.yml"; then
        echo "colliding selection leaked into source package" >&2
        exit 1
      fi

      # --- artifact shape ---
      test "$(jq -r '.name' "$ordered/package.json")" = "regression-ordered"
      jq -e '.private == true' "$ordered/package.json" > /dev/null

      mkdir -p "$out"
      printf 'REGRESSION-OK %s\n' "$ordered" > "$out/marker"
    '';
}
