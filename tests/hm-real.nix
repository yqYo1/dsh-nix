# Real Home Manager integration test for modules/home-manager/dsh.nix.
#
# Evaluates programs.dsh through home-manager's own
# lib.homeManagerConfiguration (DAG-typed home.activation, real file
# linking, activationPackage topoSort) instead of stub options.  The
# home-manager source is injected, so the flake needs no new input yet:
#   nix build --impure --expr \
#     '(import ./tests/hm-real.nix { pkgs = import <nixpkgs> {}; hmPath = <home-manager source>; }).check' \
#     --out-link scratch/child-hm -L
# `check` is a REAL regression derivation: it builds three HM generations
# (gen1: agent+extra, gen2: agent-only with changed home patch, gen3: empty)
# and runs each generation's actual ./activate (plus a DRY_RUN leg and a
# symlinked-root refusal leg) under isolated scratch HOME/XDG dirs.
# With hmPath omitted, only the eval-level assertions below run against
# stub options as a smoke fallback (lib.hm.dag absent → bare-string
# activation); `check` then throws naming the missing hmPath.
{ pkgs, hmPath ? "", ... }:

let
  lib = pkgs.lib;
  pluginsLib = import ../lib/plugins.nix { inherit lib; };
  profilesLib = import ../lib/profiles.nix { inherit lib; };
  inBoxNames = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
  dshModule = import ../modules/home-manager/dsh.nix {
    inherit pluginsLib profilesLib inBoxNames;
    dshSrc = null;
  };

  # An external package the module must install EXACTLY (no wrapping).
  # A real package directory (not a bare file) so home.path buildEnv works.
  externalPackage = pkgs.runCommand "dsh-external-dummy" { } ''
    mkdir -p $out/bin
    printf '#!/bin/sh\nprintf "dsh-external-dummy\\n"\n' > $out/bin/dsh
    chmod +x $out/bin/dsh
    printf 'external\n' > $out/dummy.txt
  '';

  nixPluginPath = ../examples/plugins/tui-core;
  patchV1 = ./fixtures/home-patch-v1.yml;
  patchV2 = ./fixtures/home-patch-v2.yml;

  # Stand-ins for the Nix CLI inside the sandboxed check builder (no
  # daemon there).  Every generation is a pre-realised derivation input,
  # and --driver-version 1 skips profile installation, so the activate
  # flow needs no genuine daemon interaction: the sanity `nix-build '{}'`
  # and the `nix-env -q` profile probes succeed trivially, while
  # `nix-store --realise <path> --add-root <root>` (generation GC roots,
  # which linkGeneration needs to clean up removed home.file entries)
  # is honoured by symlinking the already-realised path.  All
  # file/profile behaviour under test executes for real.
  nixShims = pkgs.runCommand "nix-cli-shims" { } ''
    mkdir -p $out/bin
    for tool in nix-build nix-env nix; do
      printf '#!/bin/sh\nexit 0\n' > $out/bin/$tool
      chmod +x $out/bin/$tool
    done
    cat > $out/bin/nix-store <<'SHIM'
    #!/bin/sh
    # Support: nix-store --realise <path> --add-root <root>
    realise=""
    addroot=""
    prev=""
    for arg in "$@"; do
      case "$prev" in
        --realise) realise="$arg" ;;
        --add-root) addroot="$arg" ;;
      esac
      prev="$arg"
    done
    if [ -n "$addroot" ] && [ -n "$realise" ]; then
      mkdir -p "$(dirname "$addroot")"
      ln -sfn "$realise" "$addroot"
    fi
    exit 0
    SHIM
    chmod +x $out/bin/nix-store
  '';

  # --- legacy single-config legs (stub fallback + DAG smoke) ------------
  userModule = {
    home.username = "dsh-test";
    home.homeDirectory = "/tmp/dsh-hm-test-home";
    home.stateVersion = "25.11";
    programs.dsh = {
      enable = true;
      package = externalPackage;
      homePatchesFile = null;
      settings = { };
      profiles.agent = {
        plugins = [ "@deepseek-ai/dsh-base" ../examples/plugins/tui-core ];
        userPatches = [ ];
      };
    };
  };

  useReal = hmPath != "";
  hmLib = if useReal then import (hmPath + "/lib") { inherit lib; } else null;

  stub = { lib, ... }: {
    options.home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
    options.home.file = lib.mkOption { type = lib.types.attrs; default = { }; };
    options.home.activation = lib.mkOption { type = lib.types.attrs; default = { }; };
    options.home.username = lib.mkOption { type = lib.types.str; default = ""; };
    options.home.homeDirectory = lib.mkOption { type = lib.types.str; default = ""; };
    options.home.stateVersion = lib.mkOption { type = lib.types.str; default = ""; };
  };

  evaluated = if useReal then
    hmLib.homeManagerConfiguration {
      inherit pkgs;
      modules = [ dshModule userModule ];
    }
  else
    lib.evalModules {
      modules = [ stub dshModule userModule ];
      specialArgs = { inherit pkgs; };
    };

  config = evaluated.config;
  activationValue = config.home.activation.dshProfiles;
  activation = if builtins.isString activationValue then activationValue else activationValue.data;

  # Under real HM the entry must be a DAG node ordered after writeBoundary
  # (side-effecting blocks run in the write phase, never anywhere).
  dagOrdered = useReal
    && builtins.isAttrs activationValue
    && activationValue.after == [ "writeBoundary" ];

  # Forcing the activation package instantiates the full DAG topoSort:
  # a dependency cycle aborts here, proving DAG compatibility.
  activationDrv = if useReal then config.home.activationPackage.drvPath else null;

  # The CLI installs EXACTLY unmodified: derivation identity.  Under stub
  # evaluation home.packages holds only our entry; real Home Manager adds
  # its own (sessionVariablesPackage, …), so assert membership there.
  packageExact =
    if useReal then
      builtins.elem externalPackage config.home.packages
    else
      builtins.length config.home.packages == 1
      && builtins.head config.home.packages == externalPackage;

  checks = [
    # Safe names interpolate bare; the "$HOME/..." prefix is always a
    # separate double-quoted word (never quotes baked inside quotes).
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/agent" activation)
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/agent/\".dsh-nix-stamp\"" activation)
    (lib.hasInfix ".dsh-nix-managed-profiles" activation)
    packageExact
    (useReal == false || dagOrdered)
    (useReal == false || activationDrv != null)
  ];

  # --- eval-level profile-name battery (stub eval, no build) -------------
  # Mirrors upstream dsh validation: only empty, ".", "..",
  # "node_modules", slash, backslash, and control characters are rejected;
  # spaces, Unicode, quotes, and glob characters are allowed.
  goodNames = [ "agent" "a.b-c_d" "my profile" "o'brien" "a*b" "プロファイル" "a..b" ];
  badNames = [ "" "." ".." "node_modules" "a/b" "a\\b" "line\nbreak" "tab\there" ];

  evalWithName = name: lib.evalModules {
    modules = [
      stub
      dshModule
      {
        programs.dsh = {
          enable = true;
          package = externalPackage;
          profiles."${name}" = { plugins = [ "@deepseek-ai/dsh-base" ]; };
        };
      }
    ];
    specialArgs = { inherit pkgs; };
  };

  # Force the activation script: the name check throws while rendering it.
  probeName = name: (builtins.tryEval (builtins.deepSeq (evalWithName name).config.home.activation.dshProfiles null)).success;

  nameChecks =
    (map (n: probeName n) goodNames)
    ++ (map (n: !(probeName n)) badNames);

  # --- real multi-generation regression ----------------------------------
  mkUserModule = { profiles, settings, homePatchesFile }: {
    # $USER in the check builder (task contract: username=$USER).
    home.username = "yayoi";
    home.homeDirectory = "/build/dsh-home";
    home.stateVersion = "25.11";
    # Keep the ambient PATH visible inside activation (test tooling).
    home.emptyActivationPath = false;
    # No real profile installation; home.file symlinking still executes.
    submoduleSupport.externalPackageInstall = true;
    # Generation GC roots under the scratch XDG state dir (the nix-store
    # shim honours --add-root; linkGeneration needs oldGenPath to clean
    # up removed home.file entries, exactly as in production).
    home.activationGenerateGcRoot = true;
    # Nix-CLI shims for the sandboxed activate runs (see nixShims).
    home.extraActivationPath = [ nixShims ];
    programs.dsh = {
      enable = true;
      package = externalPackage;
      inherit profiles settings homePatchesFile;
    };
  };

  gen1cfg = {
    profiles = {
      agent.plugins = [ "@deepseek-ai/dsh-base" nixPluginPath ];
      extra.plugins = [ "@deepseek-ai/dsh-base" ];
      "my profile" = { plugins = [ "@deepseek-ai/dsh-base" ]; };
      "o'brien" = { plugins = [ "@deepseek-ai/dsh-base" ]; };
      "a*b" = { plugins = [ "@deepseek-ai/dsh-base" ]; };
      "プロファイル" = { plugins = [ "@deepseek-ai/dsh-base" ]; };
      "a..b" = { plugins = [ "@deepseek-ai/dsh-base" ]; };
    };
    settings = { seed = "gen1"; };
    homePatchesFile = patchV1;
  };
  gen2cfg = {
    profiles = {
      agent.plugins = [ "@deepseek-ai/dsh-base" ];
    };
    settings = { seed = "gen1"; };
    homePatchesFile = patchV2;
  };
  gen3cfg = {
    profiles = { };
    settings = { seed = "gen1"; };
    homePatchesFile = null;
  };

  mkGen = cfg: hmLib.homeManagerConfiguration {
    inherit pkgs;
    modules = [ dshModule (mkUserModule cfg) ];
  };

  gen1 = mkGen gen1cfg;
  gen2 = mkGen gen2cfg;
  gen3 = mkGen gen3cfg;

  genActivation = g: g.config.home.activation.dshProfiles;
  genDagOk = g:
    let v = genActivation g;
    in builtins.isAttrs v && v.after == [ "writeBoundary" ];
  genPkgOk = g: builtins.elem externalPackage g.config.home.packages;
  # New quoting layout: "$HOME/.dsh/profiles"/agent for safe names;
  # unsafe-but-valid names get an escapeShellArg word: "/'my profile'".
  genLayoutOk = g: lib.hasInfix "\"$HOME/.dsh/profiles\"/agent" (genActivation g).data;
  quoteLayoutOk =
    let
      v = (evalWithName "my profile").config.home.activation.dshProfiles;
      s = if builtins.isString v then v else v.data;
    in lib.hasInfix "\"$HOME/.dsh/profiles\"/'my profile'" s;

  realEvalOk =
    useReal
    && quoteLayoutOk
    && genDagOk gen1 && genDagOk gen2 && genDagOk gen3
    && genPkgOk gen1 && genPkgOk gen2 && genPkgOk gen3
    && genLayoutOk gen1 && genLayoutOk gen2;

  # Expected profile artifacts, rebuilt from identical declarations so the
  # stamp assertions compare exact store paths (module builds the same).
  mkDecls = defs: lib.mapAttrs (name: p: profilesLib.mkProfileBundle ({
    inherit name inBoxNames;
    userPatchesFile = null;
    userPatches = [ ];
    specsHash = "";
  } // (if builtins.isAttrs p then p else { plugins = p; }))) defs;
  mkArtifacts = decls: lib.mapAttrs (name: d: profilesLib.buildProfileBundle { inherit pkgs; profile = d; }) decls;

  artifacts1 = mkArtifacts (mkDecls gen1cfg.profiles);
  artifacts2 = mkArtifacts (mkDecls gen2cfg.profiles);

  check = if !useReal then
    throw "tests/hm-real.nix: `check` requires hmPath (a real Home Manager source tree)"
  else
    assert realEvalOk;
    assert lib.all (x: x) nameChecks;
    pkgs.runCommand "dsh-hm-regression-check"
      {
        buildInputs = [ pkgs.bash pkgs.coreutils pkgs.diffutils pkgs.findutils pkgs.gnugrep pkgs.jq ];
        # Fully sandboxed: generations arrive as pre-realised inputs, HOME
        # and XDG dirs stay under the build directory, and Nix-CLI shims
        # ride the activation PATH (see nixShims).
        gen1act = gen1.config.home.activationPackage;
        gen2act = gen2.config.home.activationPackage;
        gen3act = gen3.config.home.activationPackage;
        agentArtifact1 = artifacts1.agent;
        extraArtifact1 = artifacts1.extra;
        agentArtifact2 = artifacts2.agent;
        spaceArtifact1 = artifacts1."my profile";
        tickArtifact1 = artifacts1."o'brien";
        globArtifact1 = artifacts1."a*b";
        uniArtifact1 = artifacts1."プロファイル";
        dotdotArtifact1 = artifacts1."a..b";
        fixtureV1 = patchV1;
        fixtureV2 = patchV2;
      } ''
      set -euo pipefail

      work=$PWD/work
      mkdir -p "$work"
      export HOME="$work/builder-home"
      export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
      export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
      export USER=yayoi SKIP_SANITY_CHECKS=1
      mkdir -p "$HOME"

      homeA=$work/homeA; homeB=$work/homeB; homeC=$work/homeC
      for h in "$homeA" "$homeB" "$homeC"; do
        mkdir -p "$h/.local/state/nix/profiles" "$h/.cache" "$h/.config"
      done

      fail() { echo "check FAIL: $*" >&2; exit 1; }
      pass() { echo "check ok: $*"; }

      run_act() { # <generation> <home> [extra activate args...]
        local act=$1 home=$2; shift 2
        env HOME="$home" USER=yayoi SKIP_SANITY_CHECKS=1 \
          XDG_DATA_HOME="$home/.local/share" XDG_STATE_HOME="$home/.local/state" \
          XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" \
          bash "$act/activate" --driver-version 1 "$@"
      }

      snapshot() { # <dir>: content+link-target inventory (no mtimes)
        ( cd "$1" && find . \( -type f -o -type l \) -print0 | sort -z \
          | while IFS= read -r -d "" f; do
              if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")";
              else printf 'F %s %s\n' "$f" "$(sha256sum < "$f" | cut -d' ' -f1)"; fi
            done )
      }

      # --- gen1 on homeA (app-owned data predates Nix management) ---------
      mkdir -p "$homeA/.dsh/profiles/custom" "$homeA/.dsh/sessions" "$homeA/.dsh/storages"
      printf 'user-settings-sentinel\n' >"$homeA/.dsh/settings.yaml"
      printf 'user-credentials-sentinel\n' >"$homeA/.dsh/.credentials.yaml"
      printf 'user-session-sentinel\n' >"$homeA/.dsh/sessions/s1.json"
      printf 'user-storage-sentinel\n' >"$homeA/.dsh/storages/s1.json"
      mkdir -p "$homeA/.dsh/profiles/custom"
      printf 'custom\n' >"$homeA/.dsh/profiles/custom/keep.txt"

      run_act "$gen1act" "$homeA"

      [ -d "$homeA/.dsh/profiles/agent" ] || fail "agent dir missing after gen1"
      [ -d "$homeA/.dsh/profiles/extra" ] || fail "extra dir missing after gen1"
      [ -f "$homeA/.dsh/profiles/agent/package.json" ] || fail "agent package.json missing"
      [ -f "$homeA/.dsh/profiles/agent/cordis.yml" ] || fail "agent cordis.yml missing"
      [ "$(cat "$homeA/.dsh/profiles/agent/.dsh-nix-stamp")" = "$agentArtifact1" ] \
        || fail "agent stamp != gen1 artifact outPath"
      [ "$(cat "$homeA/.dsh/profiles/extra/.dsh-nix-stamp")" = "$extraArtifact1" ] \
        || fail "extra stamp != gen1 artifact outPath"
      # Tricky-but-valid names materialise as exact single components.
      [ -d "$homeA/.dsh/profiles/my profile" ] || fail "spaced profile dir missing after gen1"
      [ -d "$homeA/.dsh/profiles/o'brien" ] || fail "apostrophe profile dir missing after gen1"
      [ -d "$homeA/.dsh/profiles/a*b" ] || fail "glob profile dir missing after gen1"
      [ -d "$homeA/.dsh/profiles/プロファイル" ] || fail "unicode profile dir missing after gen1"
      [ -d "$homeA/.dsh/profiles/a..b" ] || fail "double-dot-within-name profile dir missing after gen1"
      [ "$(cat "$homeA/.dsh/profiles/my profile/.dsh-nix-stamp")" = "$spaceArtifact1" ] \
        || fail "spaced profile stamp mismatch"
      [ "$(cat "$homeA/.dsh/profiles/o'brien/.dsh-nix-stamp")" = "$tickArtifact1" ] \
        || fail "apostrophe profile stamp mismatch"
      [ "$(cat "$homeA/.dsh/profiles/a*b/.dsh-nix-stamp")" = "$globArtifact1" ] \
        || fail "glob profile stamp mismatch"
      [ "$(cat "$homeA/.dsh/profiles/プロファイル/.dsh-nix-stamp")" = "$uniArtifact1" ] \
        || fail "unicode profile stamp mismatch"
      [ "$(cat "$homeA/.dsh/profiles/a..b/.dsh-nix-stamp")" = "$dotdotArtifact1" ] \
        || fail "double-dot-within-name profile stamp mismatch"
      # No literal quote artifacts from mis-quoted interpolation.
      [ ! -e "$homeA/.dsh/profiles/'my profile'" ] || fail "literal-quote spaced dir present"
      [ ! -e "$homeA/.dsh/profiles/'agent'" ] || fail "literal-quote agent dir present"
      [ ! -e "$homeA/.dsh/profiles/'extra'" ] || fail "literal-quote extra dir present"
      for d in "$homeA"/.dsh/profiles/*; do
        base=$(basename "$d")
        case "$base" in "'"*) fail "literal quote artifact: $d" ;; esac
      done
      pass "gen1 materialises tricky profile names exactly, no quote artifacts"
      test -L "$homeA/.dsh/profiles/agent/node_modules/@dsh-nix/tui-core" \
        || fail "agent nix plugin link missing after gen1"
      [ "$(cat "$homeA/.dsh/settings.yaml")" = "user-settings-sentinel" ] \
        || fail "seed overwrote user settings.yaml"
      [ "$(cat "$homeA/.dsh/.credentials.yaml")" = "user-credentials-sentinel" ] \
        || fail "credentials not preserved"
      [ "$(cat "$homeA/.dsh/sessions/s1.json")" = "user-session-sentinel" ] \
        || fail "sessions not preserved"
      [ "$(cat "$homeA/.dsh/storages/s1.json")" = "user-storage-sentinel" ] \
        || fail "storages not preserved"
      [ "$(cat "$homeA/.dsh/profiles/custom/keep.txt")" = "custom" ] \
        || fail "unmanaged profile touched"
      [ -L "$homeA/.dsh/cordis.patch.yml" ] || fail "home patch not linked after gen1"
      cmp -s "$homeA/.dsh/cordis.patch.yml" "$fixtureV1" || fail "home patch content != v1"
      pass "gen1 materialises profiles, stamps, links home patch, preserves app data"

      # --- seed on empty homeB (+0600 permissions) -------------------------
      run_act "$gen1act" "$homeB"
      grep -q '"seed"' "$homeB/.dsh/settings.yaml" \
        || fail "settings not seeded on empty HOME"
      [ "$(stat -c %a "$homeB/.dsh/settings.yaml")" = "600" ] \
        || fail "seeded settings.yaml mode != 600"
      [ -d "$homeB/.dsh/profiles/agent" ] || fail "agent dir missing on homeB"
      pass "empty HOME gets seed settings.yaml with 0600"

      # --- gen1 idempotence (content-based: HM may relink identically) -----
      before=$(snapshot "$homeA")
      run_act "$gen1act" "$homeA"
      after=$(snapshot "$homeA")
      [ "$before" = "$after" ] || fail "gen1 second activation changed state"
      pass "gen1 activation is idempotent"

      # --- gen2 refresh on homeA ------------------------------------------
      run_act "$gen2act" "$homeA"
      [ "$(cat "$homeA/.dsh/profiles/agent/.dsh-nix-stamp")" = "$agentArtifact2" ] \
        || fail "agent stamp not refreshed to gen2 artifact"
      [ ! -e "$homeA/.dsh/profiles/agent/node_modules/@dsh-nix" ] \
        || fail "removed plugin link still present after refresh"
      [ ! -e "$homeA/.dsh/profiles/extra" ] \
        || fail "removed managed profile 'extra' not cleaned"
      [ ! -e "$homeA/.dsh/profiles/my profile" ] \
        || fail "removed spaced profile not cleaned (cleanup regression)"
      [ ! -e "$homeA/.dsh/profiles/o'brien" ] \
        || fail "removed apostrophe profile not cleaned"
      [ ! -e "$homeA/.dsh/profiles/a*b" ] \
        || fail "removed glob profile not cleaned"
      [ ! -e "$homeA/.dsh/profiles/プロファイル" ] \
        || fail "removed unicode profile not cleaned"
      [ ! -e "$homeA/.dsh/profiles/a..b" ] \
        || fail "removed double-dot-within-name profile not cleaned (cleanup *..* regression)"
      pass "gen2 removes all tricky profiles including a..b"
      [ "$(cat "$homeA/.dsh/profiles/custom/keep.txt")" = "custom" ] \
        || fail "unmanaged profile dir touched on refresh"
      [ "$(cat "$homeA/.dsh/settings.yaml")" = "user-settings-sentinel" ] \
        || fail "settings sentinel lost on refresh"
      [ "$(cat "$homeA/.dsh/.credentials.yaml")" = "user-credentials-sentinel" ] \
        || fail "credentials lost on refresh"
      [ "$(cat "$homeA/.dsh/sessions/s1.json")" = "user-session-sentinel" ] \
        || fail "sessions lost on refresh"
      cmp -s "$homeA/.dsh/cordis.patch.yml" "$fixtureV2" || fail "home patch content != v2"
      pass "config refresh + plugin removal + managed-profile removal, app data kept"

      before=$(snapshot "$homeA")
      run_act "$gen2act" "$homeA"
      after=$(snapshot "$homeA")
      [ "$before" = "$after" ] || fail "gen2 second activation changed state"
      pass "gen2 activation is idempotent"

      # --- dry run of gen3 leaves everything unchanged --------------------
      before=$(snapshot "$homeA")
      DRY_RUN=1 run_act "$gen3act" "$homeA"
      after=$(snapshot "$homeA")
      [ "$before" = "$after" ] || fail "DRY_RUN activation changed files"
      pass "dry run leaves files unchanged"

      # --- gen3: empty profiles, home patch removed -----------------------
      run_act "$gen3act" "$homeA"
      [ ! -e "$homeA/.dsh/profiles/agent" ] || fail "managed profile 'agent' not cleaned in gen3"
      [ ! -e "$homeA/.dsh/cordis.patch.yml" ] || fail "removed home patch file still present"
      [ -z "$(cat "$homeA/.dsh/.dsh-nix-managed-profiles")" ] \
        || fail "managed manifest not empty after gen3"
      [ "$(cat "$homeA/.dsh/profiles/custom/keep.txt")" = "custom" ] \
        || fail "unmanaged profile dir touched in gen3"
      [ "$(cat "$homeA/.dsh/settings.yaml")" = "user-settings-sentinel" ] \
        || fail "settings sentinel lost in gen3"
      pass "gen3 empties managed profiles and removes home patch, app data kept"

      # --- symlinked profiles root is refused before any write ------------
      mkdir -p "$work/outside-target"
      printf 'outside-sentinel\n' >"$work/outside-target/sentinel.txt"
      mkdir -p "$homeC/.dsh"
      ln -sfn "$work/outside-target" "$homeC/.dsh/profiles"
      if refuse_out=$(run_act "$gen1act" "$homeC" 2>&1); then
        fail "symlinked profiles root was accepted"
      fi
      case "$refuse_out" in
        *symlinked*) pass "symlinked profiles root refused" ;;
        *) fail "refusal message missing (got: $refuse_out)" ;;
      esac
      [ "$(cat "$work/outside-target/sentinel.txt")" = "outside-sentinel" ] \
        || fail "outside sentinel mutated through symlinked profiles root"
      [ "$(find "$work/outside-target" -mindepth 1 | wc -l | tr -d ' ')" = "1" ] \
        || fail "outside target gained files through symlinked root"
      [ ! -e "$homeC/.dsh/settings.yaml" ] \
        || fail "settings seeded despite refused profiles root"
      [ ! -e "$homeC/.dsh/.dsh-nix-managed-profiles" ] \
        || fail "manifest written despite refused profiles root"
      pass "refusal precedes all writes: outside target untouched"

      # --- symlinked .dsh root is refused too -------------------------------
      mkdir -p "$work/outside-dsh"
      printf 'dsh-sentinel\n' >"$work/outside-dsh/sentinel.txt"
      homeD=$work/homeD
      mkdir -p "$homeD/.local/state/nix/profiles" "$homeD/.cache" "$homeD/.config"
      ln -sfn "$work/outside-dsh" "$homeD/.dsh"
      if refuse_out=$(run_act "$gen1act" "$homeD" 2>&1); then
        fail "symlinked .dsh root was accepted"
      fi
      case "$refuse_out" in
        *symlinked*) pass "symlinked .dsh root refused" ;;
        *) fail "refusal message missing (got: $refuse_out)" ;;
      esac
      [ "$(cat "$work/outside-dsh/sentinel.txt")" = "dsh-sentinel" ] \
        || fail "outside .dsh sentinel mutated"

      mkdir -p $out/bin
      {
        echo "dsh HM real-activation regression: passed"
        echo "gen1: $gen1act"
        echo "gen2: $gen2act"
        echo "gen3: $gen3act"
        echo "agentArtifact1: $agentArtifact1"
        echo "extraArtifact1: $extraArtifact1"
        echo "agentArtifact2: $agentArtifact2"
      } > $out/result.txt
      pass "ALL REAL ACTIVATION CHECKS PASSED"
    '';
in
{
  inherit checks useReal dagOrdered nameChecks realEvalOk;
  all = lib.all (x: x) checks;
  activationSnippet = builtins.substring 0 200 activation;
  inherit check;
  genActivations = if useReal then {
    gen1 = gen1.config.home.activationPackage.outPath;
    gen2 = gen2.config.home.activationPackage.outPath;
    gen3 = gen3.config.home.activationPackage.outPath;
  } else null;
}
