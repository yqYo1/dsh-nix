# Spec-lock / direct-order / transitive-closure regression gate.
#
# Covers the specsLock production contract at three levels:
#   A. eval: declaration order, lock threading, specsLock-without-specs
#      fail-closed, and extraction fidelity against the EVALUATED
#      fetcher buildCommand (sentinels asserted on probeFetcher, not on
#      raw lib source).
#   B. validator-unit battery (offline, no FOD build): the validator
#      extracted from the EVALUATED fetcher buildCommand
#      (renderedBuildCommand = writeText of fetchSpecs.buildCommand for
#      the ordered spec set; Nix escapes already resolved, so no
#      unescaping step exists) run against mutated locks. The runner
#      models sequencing with a record_validator_pass marker file: that
#      marker proves ONLY this unit runner's own branching on the
#      validator's exit code. It NEVER proves the production
#      owner/installer callback boundary, and no such claim is made
#      here. Real sequencing is proven only by the builder legs (C) on
#      real FOD/profile outputs.
#   C. builder (needs pinned FOD hashes; the parent realizes after
#      pinning specsHash): real FOD + profile outputs for the synthetic
#      ordered fixtures and tui-spec — ordered direct names, exact
#      layers, no transitive/auto-peer leakage at the profile top, lock
#      bytes retained, stable contextual specs, no enclosing-source path
#      leakage, and REAL transitive imports (not symlink shape).
#
# The declaration order below is DELIBERATELY reversed relative to the
# lock's alphabetical importer order (lock: aaa-leaf, zzz-branch;
# declared: zzz-branch index 0, aaa-leaf index 1). Any implementation
# that reads declaration order out of package.json key order or the
# lock importer order fails the ordered-direct legs.
{ pkgs }:

let
  lib = pkgs.lib;
  pluginsLib = import ../lib/plugins.nix { inherit lib; };
  profilesLib = import ../lib/profiles.nix { inherit lib; };
  inBoxNames = [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
    "@deepseek-ai/dsh-headless"
  ];

  synthLock = ./fixtures/synth-order-pnpm-lock.yaml;
  # Discovered from the real frozen-lock FOD build; no source path is
  # embedded in the output metadata, so pin edits do not change its bytes.
  synthHash = "sha256-vd51u2gd7NewVUuhR6U7oCNN+YeldDsJJIJXKXrSUn8=";

  zzzSpec = "file:" + toString ./fixtures/synth-zzz-branch;
  aaaSpec = "file:" + toString ./fixtures/synth-aaa-leaf;
  nixSibling = pluginsLib.mkPluginBundle { path = ./fixtures/synth-nix-sibling; };

  orderedProfile = profilesLib.mkProfileBundle {
    name = "spec-lock-ordered";
    inherit inBoxNames;
    plugins = [
      zzzSpec
      nixSibling
      aaaSpec
    ];
    specsLock = synthLock;
    specsHash = synthHash;
  };
  orderedArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = orderedProfile; };

  tuiSpecProfile = import ../examples/profiles/tui-spec.nix { inherit profilesLib inBoxNames; };
  tuiSpecArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = tuiSpecProfile; };

  # Negative collision case (expected FAILURE, NOT wired into `check`):
  # the SAME two spec declarations [zzzSpec, aaaSpec] and the SAME
  # lock/hash as orderedProfile, plus a Nix entry whose packageName
  # (@dsh-synth/aaa-leaf) collides with the aaa-leaf spec. The
  # direct-count backstop passes here (2 == 2), so a real build reaches
  # the same-scope projection and must fail loud with:
  #   duplicate plugin packageName @dsh-synth/aaa-leaf (spec vs nix)
  # (A one-spec/two-entry pairing would only trip the count backstop and
  # proves nothing about name collision; do not regress to it.)
  # The expected-failure artifact is exposed separately from `check`:
  # asserting a failing derivation from a successful builder needs IFD.
  collidingDrv = pkgs.runCommand "synth-aaa-collider" { } ''
    mkdir -p "$out"
    cat > "$out/package.json" <<'EOF'
    {
      "name": "@dsh-synth/aaa-leaf",
      "version": "0.0.0",
      "private": true,
      "type": "module"
    }
    EOF
  '';
  collisionProfile = profilesLib.mkProfileBundle {
    name = "spec-lock-collision";
    inherit inBoxNames;
    plugins = [
      zzzSpec
      nixSibling
      aaaSpec
      (pluginsLib.mkPluginBundle { path = collidingDrv; })
    ];
    specsLock = synthLock;
    specsHash = synthHash;
  };
  collisionArtifact = profilesLib.buildProfileBundle { inherit pkgs; profile = collisionProfile; };

  # Rendered-caller probe: the SAME fetchSpecs instantiation the ordered
  # profile builds (same spec set, lock, and hash), evaluated here. Its
  # buildCommand is the actual rendered caller text, so `check` extracts
  # spec-validate.mjs from this value via writeText — never from raw lib
  # source with hand-unescaping.
  probeFetcher = pluginsLib.fetchSpecs {
    inherit pkgs;
    specs = [ zzzSpec aaaSpec ];
    hash = synthHash;
    specsLock = synthLock;
  };
  renderedBuildCommand = pkgs.writeText "dsh-spec-fetch-build-command.sh" probeFetcher.buildCommand;

  # Eval-level contract: the REAL production fetcher must render the
  # validator and its fail-closed sentinels, else extraction below
  # would silently test nothing.
  pluginsSrc = builtins.readFile ../lib/plugins.nix;
in
assert orderedProfile.specs == [ zzzSpec aaaSpec ];
assert collisionProfile.specs == [ zzzSpec aaaSpec ];
assert collisionProfile.specsLock == orderedProfile.specsLock;
assert collisionProfile.specsHash == orderedProfile.specsHash;
assert orderedProfile.specsLock != null;
# NOTE: project `.specsLock`: the fail-closed throw lives in a lazy let
# binding, and tryEval alone only forces weak head normal form.
assert !(builtins.tryEval (profilesLib.mkProfileBundle {
  name = "spec-lock-nolock";
  inherit inBoxNames;
  plugins = [ "@deepseek-ai/dsh-base" ];
  specsLock = synthLock;
}).specsLock).success;
assert lib.hasInfix "spec-validate.mjs" pluginsSrc;
assert lib.hasInfix "spec-validate.mjs" probeFetcher.buildCommand;
assert lib.hasInfix "stale/missing/extra lock entries fail closed" probeFetcher.buildCommand;
assert lib.hasInfix "exactly the root importer" probeFetcher.buildCommand;
assert lib.hasInfix "missing integrity" probeFetcher.buildCommand;
assert lib.hasInfix "newer than pnpm_11" probeFetcher.buildCommand;
assert lib.hasInfix "must not contain devDependencies" probeFetcher.buildCommand;
{
  inherit orderedArtifact tuiSpecArtifact collisionArtifact orderedProfile;

  check = pkgs.runCommand "dsh-profile-spec-lock-check"
    {
      nativeBuildInputs = [ pkgs.nodejs pkgs.jq pkgs.yq-go pkgs.diffutils ];
      renderedCaller = renderedBuildCommand;
      lockFile = synthLock;
      tuiLock = ../examples/profiles/tui-spec-pnpm-lock.yaml;
      guard = ./fixtures/no-net-guard.cjs;
      zzzStore = ./fixtures/synth-zzz-branch;
      aaaStore = ./fixtures/synth-aaa-leaf;
      tuiStore = ../examples/plugins/tui-core;
      ordered = orderedArtifact;
      tuiOrdered = tuiSpecArtifact;
    }
    ''
      set -euo pipefail
      work="$TMPDIR/spec-lock"
      mkdir -p "$work"
      cd "$work"
      fail() { echo "profile-spec-lock FAIL: $*" >&2; exit 1; }
      pass() { echo "profile-spec-lock ok: $*"; }

      # --- guard positive controls (fail-closed egress, loopback listen) ---
      guard_log="$work/guard-probe.log"
      if ! ${pkgs.nodejs}/bin/node --require "$guard" --input-type=module -e "
        const out = [];
        try { await fetch('http://example.com/'); out.push('FETCH-LEAK'); }
        catch (e) { out.push('FETCH:' + e.code); }
        try { (await import('node:net')).default.connect(80, '93.184.216.34'); out.push('NET-LEAK'); }
        catch (e) { out.push('NET:' + e.code); }
        try { await (await import('node:dns')).promises.resolve('example.com'); out.push('DNS-LEAK'); }
        catch (e) { out.push('DNS:' + e.code); }
        const net = (await import('node:net')).default;
        const srv = net.createServer(() => {});
        await new Promise((res, rej) => { srv.on('error', rej); srv.listen(0, '127.0.0.1', res); });
        out.push('LISTEN:' + srv.address().port);
        srv.close();
        console.log(out.join(' '));
      " > "$guard_log" 2>&1; then
        cat "$guard_log" >&2
        fail "no-network guard probe crashed"
      fi
      grep -q 'FETCH:NETWORK_FORBIDDEN' "$guard_log" || fail "guard does not block fetch"
      grep -q 'NET:NETWORK_FORBIDDEN' "$guard_log" || fail "guard does not block TCP connect"
      grep -q 'DNS:NETWORK_FORBIDDEN' "$guard_log" || fail "guard does not block DNS"
      grep -q 'LISTEN:' "$guard_log" || fail "guard blocks loopback listen"
      grep -q 'LEAK' "$guard_log" && fail "guard leaked: $(cat "$guard_log")"
      pass "no-network guard blocks egress, allows loopback bind"

      # --- extract the validator from the EVALUATED fetcher caller ---
      # renderedCaller is writeText of fetchSpecs.buildCommand for the
      # ordered spec set, so Nix escapes are already resolved: extract
      # verbatim. No unescaping step exists here, and none may be added.
      sed -n "/spec-validate.mjs <<'NODE_EOF'/,/^ *NODE_EOF$/p" "$renderedCaller" \
        | sed '1d;$d' > spec-validate.mjs
      test -s spec-validate.mjs || fail "validator extraction empty (fetcher layout changed?)"
      grep -q 'stale/missing/extra lock entries fail closed' spec-validate.mjs \
        || fail "extracted validator lacks fail-closed sentinel"
      grep -q 'exactly the root importer' spec-validate.mjs \
        || fail "extracted validator lacks root-importer sentinel"
      ${pkgs.nodejs}/bin/node --check spec-validate.mjs \
        || fail "extracted validator is not valid JS"
      pass "validator extracted from evaluated fetcher buildCommand"

      # --- validator-unit battery (sequencing model ONLY, see file header) ---
      # record_validator_pass touches a marker AFTER the validator exits 0.
      # The marker proves this runner's own if/then branching, never the
      # production caller: rejection legs prove the validator exits
      # non-zero with the expected signature before any downstream step.
      printf '%s' '["file:/nix/store/PLACEHOLDER-synth-zzz-branch","file:/nix/store/PLACEHOLDER-synth-aaa-leaf"]' > specs-orig.json
      printf '%s' '["file:/build/spec-inputs/0","file:/build/spec-inputs/1"]' > specs-ctx.json
      ${pkgs.yq-go}/bin/yq -o=json '.' "$lockFile" > lock-base.json
      record_validator_pass() { touch "$work/validator-$1.pass.log"; }
      run_case() {
        name=$1; lock=$2; expect=$3; pat=$4; tag=$5
        rm -f "$work/validator-$tag.pass.log" out-direct.json
        if ${pkgs.nodejs}/bin/node spec-validate.mjs --lock "$lock" \
          --orig specs-orig.json --ctx specs-ctx.json \
          --out-direct out-direct.json --out-pkg pkg.json \
          >stdout.log 2>stderr.log; then rc=0; else rc=1; fi
        if [ "$expect" = pass ]; then
          [ "$rc" -eq 0 ] || { cat stderr.log >&2; fail "$name: validator should pass"; }
          record_validator_pass "$tag"
          [ -f "$work/validator-$tag.pass.log" ] || fail "$name: pass marker missing after validator pass"
        else
          [ "$rc" -ne 0 ] || fail "$name: validator should reject, but passed"
          grep -qF "$pat" stderr.log || { cat stderr.log >&2; fail "$name: missing pattern [$pat]"; }
          [ ! -f "$work/validator-$tag.pass.log" ] || fail "$name: pass marker present despite validator rejection"
        fi
        pass "validator-unit $name"
      }
      run_case positive-lock lock-base.json pass "" pos
      ${pkgs.jq}/bin/jq -e '. == [{"spec":"file:/build/spec-inputs/0","packageName":"@dsh-synth/zzz-branch"},{"spec":"file:/build/spec-inputs/1","packageName":"@dsh-synth/aaa-leaf"}]' \
        out-direct.json > /dev/null \
        || fail "positive direct order/content (lock alphabetical must not win)"
      ${pkgs.jq}/bin/jq 'del(.importers["."].dependencies["@dsh-synth/aaa-leaf"])' lock-base.json > lock-missing.json
      run_case missing-entry lock-missing.json fail "stale/missing/extra" miss
      ${pkgs.jq}/bin/jq '.importers["."].dependencies["bogus-pkg"] = {"specifier":"1.0.0","version":"1.0.0"}' lock-base.json > lock-extra.json
      run_case extra-entry lock-extra.json fail "stale/missing/extra" extra
      ${pkgs.jq}/bin/jq '.importers["."].dependencies["@dsh-synth/zzz-branch"].specifier = "9.9.9"' lock-base.json > lock-stale.json
      run_case stale-specifier lock-stale.json fail "missing from installer importer" stale
      ${pkgs.jq}/bin/jq '.importers["workspace-packages/extra"] = {"dependencies":{}}' lock-base.json > lock-ws.json
      run_case extra-workspace-importer lock-ws.json fail "exactly the root importer" ws
      ${pkgs.jq}/bin/jq 'del(.importers["."])' lock-base.json > lock-noroot.json
      run_case missing-lock-root lock-noroot.json fail "exactly the root importer" noroot
      ${pkgs.jq}/bin/jq '.importers["."].devDependencies = {"x": {"specifier":"1.0.0","version":"1.0.0"}}' lock-base.json > lock-dev.json
      run_case dev-deps lock-dev.json fail "must not contain devDependencies" dev
      ${pkgs.jq}/bin/jq '.lockfileVersion = "99.0"' lock-base.json > lock-newver.json
      run_case new-major lock-newver.json fail "newer than pnpm_11" newver
      ${pkgs.jq}/bin/jq 'del(.packages["is-odd@3.0.1"].resolution.integrity)' lock-base.json > lock-noint.json
      run_case missing-integrity lock-noint.json fail "missing integrity" noint
      ${pkgs.jq}/bin/jq '.importers["."].optionalDependencies = {"@dsh-synth/zzz-branch": {"specifier":"file:/build/spec-inputs/0","version":"file:../spec-inputs/0"}}' lock-base.json > lock-dup.json
      run_case duplicate-key lock-dup.json fail "duplicate importer key" dup
      # no-lock (--pkg) branch: positive order + registry specifier discipline
      printf '%s' '{"dependencies":{"@dsh-synth/zzz-branch":"file:/build/spec-inputs/0","@dsh-synth/aaa-leaf":"file:/build/spec-inputs/1"}}' > pkg-in.json
      rm -f "$work/validator-pkg.pass.log" out-direct.json
      ${pkgs.nodejs}/bin/node spec-validate.mjs --pkg pkg-in.json \
        --orig specs-orig.json --ctx specs-ctx.json --out-direct out-direct.json \
        || fail "pkg-branch positive"
      record_validator_pass pkg
      ${pkgs.jq}/bin/jq -e '.[0].packageName == "@dsh-synth/zzz-branch" and .[1].packageName == "@dsh-synth/aaa-leaf"' \
        out-direct.json > /dev/null || fail "pkg-branch order"
      pass "validator-unit pkg-branch positive"
      printf '%s' '["dsh-codex@0.3.2"]' > reg-orig.json
      printf '%s' '{"dependencies":{"dsh-codex":"0.3.2"}}' > reg-pkg-ok.json
      printf '%s' '{"dependencies":{"dsh-codex":"9.9.9"}}' > reg-pkg-bad.json
      ${pkgs.nodejs}/bin/node spec-validate.mjs --pkg reg-pkg-ok.json \
        --orig reg-orig.json --ctx reg-orig.json --out-direct reg-out.json \
        || fail "registry positive"
      ${pkgs.jq}/bin/jq -e '. == [{"spec":"dsh-codex@0.3.2","packageName":"dsh-codex"}]' reg-out.json > /dev/null \
        || fail "registry direct"
      pass "validator-unit registry positive"
      if ${pkgs.nodejs}/bin/node spec-validate.mjs --pkg reg-pkg-bad.json \
        --orig reg-orig.json --ctx reg-orig.json --out-direct reg-out.json 2>reg-err.log; then
        fail "registry mismatch passed"
      fi
      grep -qF "wants specifier" reg-err.log || fail "registry mismatch pattern"
      pass "validator-unit registry mismatch"

      # --- builder legs: synthetic ordered profile (same-scope mixed) ---
      # REAL FOD/profile outputs from here on (no unit-runner markers).
      actual_bundles=$(${pkgs.jq}/bin/jq -c '.dsh.profile.bundles' "$ordered/package.json")
      [ "$actual_bundles" = '["@dsh-synth/zzz-branch","@dsh-synth/nix-sibling","@dsh-synth/aaa-leaf"]' ] \
        || fail "ordered bundles: got $actual_bundles"
      pass "ordered layers follow declaration order (reversed vs lock)"
      scope_list=$(ls "$ordered/node_modules/@dsh-synth")
      [ "$scope_list" = "aaa-leaf
      nix-sibling
      zzz-branch" ] || fail "scope projection not exact-single: got $scope_list"
      test -L "$ordered/node_modules/@dsh-synth/zzz-branch" || fail "zzz not a single link"
      test -L "$ordered/node_modules/@dsh-synth/aaa-leaf" || fail "aaa not a single link"
      test ! -e "$ordered/node_modules/is-odd" || fail "transitive dep leaked to profile top"
      test ! -e "$ordered/node_modules/is-number" || fail "transitive dep leaked to profile top"
      jq -e '.dsh.profile.bundles | index("is-odd") | not' "$ordered/package.json" > /dev/null \
        || fail "transitive dep became a layer"
      pass "only exact direct entries projected; no transitive/auto-peer layers"
      fod=$(dirname $(dirname $(dirname $(readlink "$ordered/node_modules/@dsh-synth/zzz-branch"))))
      ${pkgs.jq}/bin/jq -e '. == [{"spec":"file:/build/spec-inputs/0","packageName":"@dsh-synth/zzz-branch"},{"spec":"file:/build/spec-inputs/1","packageName":"@dsh-synth/aaa-leaf"}]' \
        "$fod/direct-specs.json" > /dev/null \
        || fail "FOD direct-specs order/stable specs"
      cmp "$fod/pnpm-lock.yaml" "$lockFile" || fail "FOD lock bytes differ from input lock"
      pass "FOD direct order, stable contextual specs, lock bytes retained"
      if grep -rF -q "file:$zzzStore" "$fod"; then fail "enclosing zzz source path leaked into FOD"; fi
      if grep -rF -q "file:$aaaStore" "$fod"; then fail "enclosing aaa source path leaked into FOD"; fi
      pass "no enclosing-source path in FOD output"
      ${pkgs.nodejs}/bin/node --input-type=module -e "
        const z = await import('$ordered/node_modules/@dsh-synth/zzz-branch/index.js');
        const a = await import('$ordered/node_modules/@dsh-synth/aaa-leaf/index.js');
        if (z.check(3) !== true || z.check(4) !== false) { console.error('zzz transitive check failed'); process.exit(1); }
        if (a.answer() !== 42) { console.error('aaa leaf check failed'); process.exit(1); }
        console.log('TRANSITIVE-OK');
      " > transitive.log 2>&1 || { cat transitive.log >&2; fail "real transitive import"; }
      grep -q 'TRANSITIVE-OK' transitive.log || fail "transitive marker missing"
      pass "real preserved transitive import (is-odd/is-number closure)"

      # --- builder legs: tui-spec (local file: spec, stable output) ---
      test "$(${pkgs.jq}/bin/jq -c '.dsh.profile.bundles' "$tuiOrdered/package.json")" = '["@dsh-nix/tui-core"]' \
        || fail "tui-spec bundles"
      test -L "$tuiOrdered/node_modules/@dsh-nix/tui-core" || fail "tui-core not a single link"
      test -d "$tuiOrdered/node_modules/@dsh-nix" || fail "scope parent not a directory"
      test ! -L "$tuiOrdered/node_modules/@dsh-nix" || fail "whole-scope symlink leaked"
      pass "tui-spec profile shape (single-link leaf, no whole-scope symlink)"
      tuiFod=$(dirname $(dirname $(dirname $(readlink "$tuiOrdered/node_modules/@dsh-nix/tui-core"))))
      ${pkgs.jq}/bin/jq -e '. == [{"spec":"file:/build/spec-inputs/0","packageName":"@dsh-nix/tui-core"}]' \
        "$tuiFod/direct-specs.json" > /dev/null \
        || fail "tui-spec direct-specs (must be the stable contextual spec)"
      cmp "$tuiFod/pnpm-lock.yaml" "$tuiLock" || fail "tui-spec lock bytes differ"
      pass "tui-spec stable local-spec output + lock bytes retained"
      if grep -rF -q "file:$tuiStore" "$tuiFod"; then fail "enclosing tui-core source path leaked into FOD"; fi
      pass "tui-spec no enclosing-source path in FOD output"
      ${pkgs.nodejs}/bin/node --input-type=module -e "
        const m = await import('$tuiOrdered/node_modules/@dsh-nix/tui-core/plugin.mjs');
        if (typeof m.apply !== 'function') { console.error('tui-core apply not a function'); process.exit(1); }
        console.log('TUI-IMPORT-OK');
      " > tui-import.log 2>&1 || { cat tui-import.log >&2; fail "tui-core real import"; }
      grep -q 'TUI-IMPORT-OK' tui-import.log || fail "tui import marker missing"
      pass "tui-core real module import through the projection"

      mkdir -p "$out"
      printf 'SPEC-LOCK-OK ordered=%s tui=%s\n' "$ordered" "$tuiOrdered" > "$out/marker"
    '';
}
