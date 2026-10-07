# Continuous execution coverage for production plugin-root/patch selection.
#
# Shape: `{ pkgs } -> check derivation` (pinned flake pkgs from the caller;
# no other inputs, no network, no IFD). Evaluates to the passing check
# derivation itself; `.check` aliases it so both wirings work:
#   import ./tests/plugin-roots.nix { inherit pkgs; }          # derivation
#   (import ./tests/plugin-roots.nix { inherit pkgs; }).check  # flake checks
# A passing build writes `$out/passed` and per-leg logs under `$out/logs`.
#
# Policy under test (lib/profiles.nix `resolve_effective_root` + name/patch
# selection in `buildProfileBundle`):
#   - an existing root package.json wins, whether zero or two installed
#     candidates sit under lib/node_modules;
#   - otherwise exactly one DIRECT lib/node_modules/<name> or
#     lib/node_modules/@<scope>/<name> package.json is accepted;
#   - zero or multiple direct candidates fail loud; deep transitive
#     manifests (.../node_modules/.../node_modules/...) never count;
#   - identity comes from the manifest `name` (never pname/store name);
#     an explicit `mkPluginBundle packageName` override wins for the mapping;
#   - a relative `patchPath` string and an absolute external patch file stay
#     preserved verbatim against the EFFECTIVE root (projected manifest
#     declares exactly the selection, selected bytes beside it);
#   - scoped parents stay real directories (exact-direct projection).
#
# Execution model (no reimplemented resolver, no snapshot-string proofs):
# every leg executes the ACTUAL rendered production builder
# (`subject.drvAttrs.buildCommand` of a real `buildProfileBundle`
# derivation) inside this check's sandbox as
#   out=<scratch-candidate> bash -e -c <rendered buildCommand>
# with pinned bash/stdenv + jq/coreutils/findutils on PATH. The rendered
# string carries its metadata-derivation reference and each mock package is
# also referenced explicitly, so the sandbox closure is complete without
# ever realising a known-failing subject as a dependency (only its
# eval-time `drvAttrs` text is used). Positive legs must exit 0 and their
# scratch candidates are asserted for shape; rejection legs must exit
# non-zero and their logs must carry the exact production error signature.
# Every profile holds a single plugin with a unique name, so a rejection
# can only come from root resolution, never the later duplicate-name guard.
#
# Substituted boundary (documented): the real builder runs under stdenv's
# generic builder (`bash -e` + stdenv setup, `$out` pointing at the real
# output). Here `bash -e` plus the same tool closure is kept; only `$out`
# is redirected at a scratch candidate under $TMPDIR. Mock layouts stand in
# for buildNpmPackage outputs (a genuine buildNpmPackage build+import+boot
# is covered separately by the continuous profile-user-npm check).
#
# Limitations: basename-colliding external patches and the eval-time
# duplicate-name guard already have coverage in tests/profile-regression.nix
# and are not re-proven here.
{ pkgs }:

let
  lib = pkgs.lib;
  pluginsLib = import ../lib/plugins.nix { inherit lib; };
  profilesLib = import ../lib/profiles.nix { inherit lib; };

  mkProfile = name: plugins: profilesLib.mkProfileBundle {
    inherit name plugins;
    inBoxNames = [ ];
    userPatchesFile = null;
    userPatches = [ ];
    specsHash = "";
  };
  build = profile: profilesLib.buildProfileBundle { inherit pkgs profile; };

  # Root manifest, zero installed candidates underneath.
  rootPkg = pkgs.runCommand "roots-mock-root" { } ''
    mkdir -p "$out"
    cat > "$out/package.json" <<'EOF'
    {"name": "@rt/root", "version": "0.0.0", "dsh": {"bundle": {"patch": "cordis.patch.yml"}}}
    EOF
    printf '%s\n' '- insert:' '    - id: rt-root-row' "      name: '@rt/root'" > "$out/cordis.patch.yml"
  '';

  # Root manifest with TWO installed candidates underneath (must still win).
  rootWinsPkg = pkgs.runCommand "roots-mock-root-wins" { } ''
    mkdir -p "$out/lib/node_modules/rt-inner-a" "$out/lib/node_modules/@rt-inner/b"
    cat > "$out/package.json" <<'EOF'
    {"name": "@rt/root-wins", "version": "0.0.0", "dsh": {"bundle": {"patch": "cordis.patch.yml"}}}
    EOF
    printf '%s\n' '- insert:' '    - id: rt-root-wins-row' "      name: '@rt/root-wins'" > "$out/cordis.patch.yml"
    cat > "$out/lib/node_modules/rt-inner-a/package.json" <<'EOF'
    {"name": "rt-inner-a", "version": "0.0.0"}
    EOF
    cat > "$out/lib/node_modules/@rt-inner/b/package.json" <<'EOF'
    {"name": "@rt-inner/b", "version": "0.0.0"}
    EOF
  '';

  # Unscoped installed root + a deep transitive manifest (must be ignored).
  unscopedPkg = pkgs.runCommand "roots-mock-unscoped" { } ''
    mkdir -p "$out/lib/node_modules/rt-foo" "$out/lib/node_modules/rt-foo/node_modules/rt-deep"
    cat > "$out/lib/node_modules/rt-foo/package.json" <<'EOF'
    {"name": "rt-foo", "version": "1.0.0", "dsh": {"bundle": {"patch": "cordis.patch.yml"}}}
    EOF
    printf '%s\n' '- insert:' '    - id: rt-foo-row' "      name: 'rt-foo'" > "$out/lib/node_modules/rt-foo/cordis.patch.yml"
    cat > "$out/lib/node_modules/rt-foo/node_modules/rt-deep/package.json" <<'EOF'
    {"name": "rt-deep", "version": "9.9.9"}
    EOF
  '';

  # Scoped installed root.
  scopedPkg = pkgs.runCommand "roots-mock-scoped" { } ''
    mkdir -p "$out/lib/node_modules/@rt/scope-pkg"
    cat > "$out/lib/node_modules/@rt/scope-pkg/package.json" <<'EOF'
    {"name": "@rt/scope-pkg", "version": "2.0.0", "dsh": {"bundle": {"patch": "cordis.patch.yml"}}}
    EOF
    printf '%s\n' '- insert:' '    - id: rt-scoped-row' "      name: '@rt/scope-pkg'" > "$out/lib/node_modules/@rt/scope-pkg/cordis.patch.yml"
  '';

  # Deep-only: a transitive manifest with no direct root (must fail loud).
  deepOnlyPkg = pkgs.runCommand "roots-mock-deep-only" { } ''
    mkdir -p "$out/lib/node_modules/rt-hollow/node_modules/rt-deep-only"
    printf '%s\n' 'placeholder' > "$out/lib/node_modules/rt-hollow/index.js"
    cat > "$out/lib/node_modules/rt-hollow/node_modules/rt-deep-only/package.json" <<'EOF'
    {"name": "rt-deep-only", "version": "9.9.9"}
    EOF
  '';

  # Empty: no root manifest, no installed roots (must fail loud).
  emptyPkg = pkgs.runCommand "roots-mock-empty" { } ''
    mkdir -p "$out/lib"
    echo data > "$out/README"
  '';

  # Ambiguous: one unscoped + one scoped direct root (must fail loud).
  ambiguousPkg = pkgs.runCommand "roots-mock-ambiguous" { } ''
    mkdir -p "$out/lib/node_modules/rt-amb-a" "$out/lib/node_modules/@rt-amb/b"
    cat > "$out/lib/node_modules/rt-amb-a/package.json" <<'EOF'
    {"name": "rt-amb-a", "version": "1.0.0"}
    EOF
    cat > "$out/lib/node_modules/@rt-amb/b/package.json" <<'EOF'
    {"name": "@rt-amb/b", "version": "1.0.0"}
    EOF
  '';

  # Installed root without a patch declaration; carries a selectable file
  # for the relative `patchPath` leg and doubles as the external-patch base.
  patchPkg = pkgs.runCommand "roots-mock-patch-base" { } ''
    mkdir -p "$out/lib/node_modules/@rt/ep-pkg"
    cat > "$out/lib/node_modules/@rt/ep-pkg/package.json" <<'EOF'
    {"name": "@rt/ep-pkg", "version": "1.0.0", "main": "./index.js"}
    EOF
    printf '%s\n' 'module.exports = 1;' > "$out/lib/node_modules/@rt/ep-pkg/index.js"
    printf '%s\n' '- insert:' '    - id: rt-ep-row' "      name: '@rt/ep-pkg'" > "$out/lib/node_modules/@rt/ep-pkg/cordis.patch.yml"
  '';

  # Absolute external selection (lives outside any package).
  externalPatch = pkgs.writeText "rt-external-patch.yml" ''
    - insert:
        - id: rt-external-selected-row
          name: '@rt/ep-pkg'
  '';

  rootSubject = build (mkProfile "roots-root" [ rootPkg ]);
  rootWinsSubject = build (mkProfile "roots-root-wins" [ rootWinsPkg ]);
  unscopedSubject = build (mkProfile "roots-unscoped" [ unscopedPkg ]);
  scopedSubject = build (mkProfile "roots-scoped" [ scopedPkg ]);
  deepOnlySubject = build (mkProfile "roots-deep-only" [ deepOnlyPkg ]);
  emptySubject = build (mkProfile "roots-empty" [ emptyPkg ]);
  ambiguousSubject = build (mkProfile "roots-ambiguous" [ ambiguousPkg ]);
  overrideSubject = build (mkProfile "roots-override" [
    (pluginsLib.mkPluginBundle { path = scopedPkg; packageName = "@rt/override-name"; })
  ]);
  relativeSubject = build (mkProfile "roots-relative-patch" [
    (pluginsLib.mkPluginBundle { path = patchPkg; patchPath = "cordis.patch.yml"; })
  ]);
  externalSubject = build (mkProfile "roots-external-patch" [
    (pluginsLib.mkPluginBundle { path = patchPkg; patchPath = externalPatch; })
  ]);

  # The ACTUAL rendered production builder commands (eval-time text only;
  # referencing them never realises the subjects, so rejection legs stay
  # buildable as check inputs).
  rootCmd = rootSubject.drvAttrs.buildCommand;
  rootWinsCmd = rootWinsSubject.drvAttrs.buildCommand;
  unscopedCmd = unscopedSubject.drvAttrs.buildCommand;
  scopedCmd = scopedSubject.drvAttrs.buildCommand;
  deepOnlyCmd = deepOnlySubject.drvAttrs.buildCommand;
  emptyCmd = emptySubject.drvAttrs.buildCommand;
  ambiguousCmd = ambiguousSubject.drvAttrs.buildCommand;
  overrideCmd = overrideSubject.drvAttrs.buildCommand;
  relativeCmd = relativeSubject.drvAttrs.buildCommand;
  externalCmd = externalSubject.drvAttrs.buildCommand;

  check = pkgs.runCommand "dsh-plugin-roots-check"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.coreutils pkgs.findutils pkgs.diffutils ];
    }
    ''
      set -euo pipefail
      work="$TMPDIR/roots"
      mkdir -p "$work/candidates" "$out/logs"
      fail() { echo "plugin-roots FAIL: $1" >&2; exit 1; }
      pass() { echo "plugin-roots ok: $1"; }

      # Mock store refs: keep the sandbox closure explicit. The rendered
      # commands additionally carry their metadata-derivation references.
      mockRoot=${rootPkg}
      mockRootWins=${rootWinsPkg}
      mockUnscoped=${unscopedPkg}
      mockScoped=${scopedPkg}
      mockDeepOnly=${deepOnlyPkg}
      mockEmpty=${emptyPkg}
      mockAmbiguous=${ambiguousPkg}
      mockPatch=${patchPkg}
      mockExternal=${externalPatch}

      # Run a rendered production builder with $out redirected at a scratch
      # candidate. Positive legs must exit 0; rejection legs must exit
      # non-zero (captured, never aborting this check).
      expect_ok() {
        name="$1"; cmd="$2"; cand="$work/candidates/$name"
        mkdir -p "$cand"
        set +e
        out="$cand" bash -e -c "$cmd" >"$out/logs/$name.log" 2>&1
        st=$?
        set -e
        if [ "$st" -ne 0 ]; then
          cat "$out/logs/$name.log" >&2
          fail "$name builder exited $st, want 0"
        fi
      }
      expect_fail() {
        name="$1"; cmd="$2"; cand="$work/candidates/$name"
        mkdir -p "$cand"
        set +e
        out="$cand" bash -e -c "$cmd" >"$out/logs/$name.log" 2>&1
        st=$?
        set -e
        if [ "$st" -eq 0 ]; then fail "$name builder succeeded, want rejection"; fi
      }
      bundles_is() {
        cand="$1"; want="$2"
        actual=$(jq -c '.dsh.profile.bundles' "$cand/package.json")
        if [ "$actual" != "$want" ]; then
          fail "bundles mismatch in $cand: got $actual want $want"
        fi
      }

      # --- label=root-preference: root package.json wins, zero candidates ---
      expect_ok root ${lib.escapeShellArg rootCmd}
      cand="$work/candidates/root"
      test -L "$cand/node_modules/@rt/root" || fail "root leg not symlinked"
      test "$(readlink "$cand/node_modules/@rt/root")" = "$mockRoot" || fail "root leg symlink misses package root"
      bundles_is "$cand" '["@rt/root"]'
      jq -e '.dependencies | has("@rt/root")' "$cand/package.json" > /dev/null || fail "root leg mapping missing"
      pass "label=root-preference: root package.json wins with zero installed candidates"

      # --- label=root-preference-2: root wins over TWO installed candidates ---
      expect_ok root-wins ${lib.escapeShellArg rootWinsCmd}
      cand="$work/candidates/root-wins"
      test -L "$cand/node_modules/@rt/root-wins" || fail "root-wins leg not symlinked"
      test "$(readlink "$cand/node_modules/@rt/root-wins")" = "$mockRootWins" || fail "root-wins symlink misses package root"
      bundles_is "$cand" '["@rt/root-wins"]'
      if jq -e '.dependencies | has("rt-inner-a") or has("@rt-inner/b")' "$cand/package.json" > /dev/null; then
        fail "root-wins leg leaked installed candidates"
      fi
      pass "label=root-preference-2: root package.json wins over two installed candidates"

      # --- label=unscoped (+deep ignored): exactly one direct root ---
      expect_ok unscoped ${lib.escapeShellArg unscopedCmd}
      cand="$work/candidates/unscoped"
      test -L "$cand/node_modules/rt-foo" || fail "unscoped leg not symlinked"
      test "$(readlink "$cand/node_modules/rt-foo")" = "$mockUnscoped/lib/node_modules/rt-foo" || fail "unscoped symlink misses installed root"
      bundles_is "$cand" '["rt-foo"]'
      jq -e '.dependencies | has("rt-foo")' "$cand/package.json" > /dev/null || fail "unscoped mapping missing"
      if jq -e '.dependencies | has("rt-deep")' "$cand/package.json" > /dev/null; then
        fail "unscoped leg leaked deep transitive dep"
      fi
      if jq -e '.dsh.profile.bundles | index("rt-deep")' "$cand/package.json" > /dev/null; then
        fail "deep transitive dep activated as layer"
      fi
      pass "label=unscoped: direct lib/node_modules/<name> accepted, deep transitive ignored"

      # --- label=scoped (+real parent): scoped direct root ---
      expect_ok scoped ${lib.escapeShellArg scopedCmd}
      cand="$work/candidates/scoped"
      test -d "$cand/node_modules/@rt" || fail "scoped parent missing"
      test ! -L "$cand/node_modules/@rt" || fail "scoped parent must be a real directory, not a symlink"
      test -L "$cand/node_modules/@rt/scope-pkg" || fail "scoped leg not symlinked"
      test "$(readlink "$cand/node_modules/@rt/scope-pkg")" = "$mockScoped/lib/node_modules/@rt/scope-pkg" || fail "scoped symlink misses installed root"
      bundles_is "$cand" '["@rt/scope-pkg"]'
      pass "label=scoped: lib/node_modules/@<scope>/<name> accepted with real scope parent"

      # --- label=missing-deep-only: transitive manifest alone does not count ---
      expect_fail deep-only ${lib.escapeShellArg deepOnlyCmd}
      grep -q "no installed package under" "$out/logs/deep-only.log" || fail "deep-only signature missing (no installed package)"
      grep -q "want exactly one direct root" "$out/logs/deep-only.log" || fail "deep-only signature missing (direct root)"
      if grep -q "rt-deep-only" "$out/logs/deep-only.log"; then fail "deep-only error must not name the transitive dep"; fi
      pass "label=missing-deep-only: transitive-only layout rejected, deep manifests do not count"

      # --- label=missing: no root manifest, no installed roots ---
      expect_fail empty ${lib.escapeShellArg emptyCmd}
      grep -q "no package.json at" "$out/logs/empty.log" || fail "empty signature missing (no package.json)"
      grep -q "no installed package under" "$out/logs/empty.log" || fail "empty signature missing (no installed package)"
      pass "label=missing: zero candidates rejected loud"

      # --- label=ambiguous: unscoped + scoped direct roots ---
      expect_fail ambiguous ${lib.escapeShellArg ambiguousCmd}
      grep -q "ambiguous installed packages under" "$out/logs/ambiguous.log" || fail "ambiguous signature missing"
      grep -q "pass an explicit installed root path" "$out/logs/ambiguous.log" || fail "ambiguous remediation hint missing"
      pass "label=ambiguous: multiple direct candidates rejected loud"

      # --- label=override-preserved: explicit packageName wins at effective root ---
      expect_ok override ${lib.escapeShellArg overrideCmd}
      cand="$work/candidates/override"
      bundles_is "$cand" '["@rt/override-name"]'
      jq -e '.dependencies | has("@rt/override-name")' "$cand/package.json" > /dev/null || fail "override mapping missing"
      if jq -e '.dependencies | has("@rt/scope-pkg")' "$cand/package.json" > /dev/null; then
        fail "override leg kept manifest key instead of explicit name"
      fi
      test -L "$cand/node_modules/@rt/override-name" || fail "override leg not symlinked"
      test "$(readlink "$cand/node_modules/@rt/override-name")" = "$mockScoped/lib/node_modules/@rt/scope-pkg" || fail "override symlink misses effective installed root"
      test "$(jq -r '.name' "$cand/node_modules/@rt/override-name/package.json")" = "@rt/scope-pkg" || fail "source manifest identity not preserved"
      pass "label=override-preserved: explicit packageName overrides mapping at effective root"

      # --- label=relative-patch-preserved: relative patchPath at effective root ---
      expect_ok relative ${lib.escapeShellArg relativeCmd}
      cand="$work/candidates/relative"
      dest="$cand/node_modules/@rt/ep-pkg"
      test ! -L "$dest" || fail "relative projection must be a real directory"
      test -d "$dest" || fail "relative projection directory missing"
      bundles_is "$cand" '["@rt/ep-pkg"]'
      test "$(jq -r '.dsh.bundle.patch' "$dest/package.json")" = "cordis.patch.yml" || fail "relative projection manifest mismatch"
      test "$(jq -r '.main' "$dest/package.json")" = "./index.js" || fail "relative projection identity lost"
      test -f "$dest/cordis.patch.yml" || fail "relative patch bytes missing"
      grep -q "rt-ep-row" "$dest/cordis.patch.yml" || fail "relative patch content mismatch"
      cmp -s "$mockPatch/lib/node_modules/@rt/ep-pkg/cordis.patch.yml" "$dest/cordis.patch.yml" || fail "relative patch bytes differ from effective root selection"
      pass "label=relative-patch-preserved: relative explicitPatch projected against effective root"

      # --- label=external-patch-preserved: absolute external patch at effective root ---
      expect_ok external ${lib.escapeShellArg externalCmd}
      cand="$work/candidates/external"
      dest="$cand/node_modules/@rt/ep-pkg"
      extBase=$(basename "$mockExternal")
      test ! -L "$dest" || fail "external projection must be a real directory"
      test -d "$dest" || fail "external projection directory missing"
      bundles_is "$cand" '["@rt/ep-pkg"]'
      test "$(jq -r '.dsh.bundle.patch' "$dest/package.json")" = "$extBase" || fail "external projection manifest mismatch"
      test -f "$dest/$extBase" || fail "external patch bytes missing"
      cmp -s "$mockExternal" "$dest/$extBase" || fail "external patch bytes differ from selection"
      grep -q "rt-external-selected-row" "$dest/$extBase" || fail "external selection content missing"
      if grep -q "rt-ep-row" "$dest/$extBase"; then fail "external projection carries stale in-package bytes"; fi
      pass "label=external-patch-preserved: absolute external patch projected against effective root"

      # --- manifest name, never pname/store name, across positive legs ---
      for n in root root-wins unscoped scoped override relative external; do
        if jq -e '[.dependencies | keys[] | select(startswith("roots-mock-"))] | length > 0' "$work/candidates/$n/package.json" > /dev/null; then
          fail "$n leaks a pname-derived dependency key"
        fi
      done
      pass "label=manifest-name: no pname/store-derived keys in any positive leg"

      printf 'PLUGIN-ROOTS-OK %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$out/passed"
      pass "plugin-roots check complete (logs in $out/logs)"
    '';

in
check // { inherit check; }
