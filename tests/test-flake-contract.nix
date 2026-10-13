# Tests-only separation contract for the dsh-nix / tests subflake split.
#
# Fails evaluation (explicit `throw`) when any of these is violated:
#   1. root flake.nix reintroduces a test-only `home-manager` input or the
#      `home-manager-integration` check wiring;
#   2. root flake.lock contains a `home-manager` node;
#   3. tests flake.lock does not pin home-manager to the expected rev, or
#      its nixpkgs edge is not a follows-edge onto dsh-nix/nixpkgs;
#   4. public identity regresses: homeManagerModules.dsh, overlays.default,
#      or packages.<system>.default is missing, or the root check set is
#      not exactly the original HM-independent checks;
#   5. nested pins for dsh/nixpkgs/systems recorded in tests/flake.lock go
#      stale relative to the parent on-disk flake.lock, or unexpected extra
#      inputs appear in the tests lock.
{ pkgs, lib, system, nixpkgs, dshNix, rootSrc, testsLock }:

let
  expectedHmRev = "d9d750e4fc11c10cab2da677bdd31e427f3a3a71";

  # The HM-independent checks that must stay in the root flake,
  # exactly (sorted: builtins.attrNames returns sorted names).
  hmIndependentChecks = [
    "boot-checker-wiring"
    "home-module"
    "profile-boot-headless"
    "profile-boot-tui"
    "profile-boot-web"
    "profile-boot-web-nobase"
    "profile-codex"
    "profile-regression"
    "profile-spec-lock"
    "profile-tui"
    "profile-tui-spec"
    "profile-user-npm"
  ];

  fail = msg: throw "test-flake-contract: ${msg}";

  rootFlake = builtins.readFile (rootSrc + "/flake.nix");
  rootLock = builtins.fromJSON (builtins.readFile (rootSrc + "/flake.lock"));
  rootNodes = rootLock.nodes or (fail "root flake.lock has no 'nodes' object");
  testsNodes = testsLock.nodes or (fail "tests flake.lock has no 'nodes' object");

  revOf = nodes: name:
    if builtins.hasAttr name nodes
      && builtins.isAttrs nodes.${name}
      && builtins.hasAttr "locked" nodes.${name}
      && builtins.isAttrs nodes.${name}.locked
      && builtins.hasAttr "rev" nodes.${name}.locked
    then nodes.${name}.locked.rev
    else null;

  # --- 1. no test-only wiring in the public root flake ---------------------
  # NOTE: the public module path ./modules/home-manager/dsh.nix legitimately
  # contains "home-manager", so match the input/check wiring precisely.
  c1 = if lib.hasInfix "inputs.home-manager" rootFlake
    then fail "root flake.nix declares 'inputs.home-manager'; test-only inputs belong in tests/flake.nix"
    else true;
  c2 = if lib.hasInfix "home-manager-integration" rootFlake
    then fail "root flake.nix wires 'home-manager-integration'; HM checks belong in tests/flake.nix"
    else true;
  c3 = if lib.hasInfix "hmPath = home-manager" rootFlake
    then fail "root flake.nix passes 'hmPath = home-manager'; HM harness belongs in tests/flake.nix"
    else true;

  # --- 2. HM fully gone from the root lock ---------------------------------
  c4 = if builtins.hasAttr "home-manager" rootNodes
    then fail "root flake.lock still contains a 'home-manager' node"
    else true;

  # --- 3. HM pinned only in tests, nixpkgs follows the parent --------------
  testsHmRev = revOf testsNodes "home-manager";
  c5 = if testsHmRev == null
    then fail "tests flake.lock has no locked 'home-manager' node"
    else if testsHmRev != expectedHmRev
    then fail "tests home-manager rev '${testsHmRev}' != expected '${expectedHmRev}'"
    else true;

  testsRootInputs = testsLock.nodes.root.inputs
    or (fail "tests flake.lock root node has no 'inputs' object");
  c6 = if builtins.attrNames testsRootInputs != [ "dsh-nix" "home-manager" "nixpkgs" ]
    then fail "tests flake.lock root inputs must be exactly {dsh-nix, home-manager, nixpkgs}; got: ${builtins.toJSON (builtins.attrNames testsRootInputs)}"
    else true;
  # follows-edges are recorded as input-address arrays in the lock.
  c7 = if testsRootInputs.nixpkgs != [ "dsh-nix" "nixpkgs" ]
    then fail "tests nixpkgs must follow dsh-nix/nixpkgs; lock edge is: ${builtins.toJSON testsRootInputs.nixpkgs}"
    else true;
  hmInputs = testsNodes.home-manager.inputs
    or (fail "tests flake.lock home-manager node has no 'inputs' object");
  c8 = if hmInputs.nixpkgs != [ "nixpkgs" ]
    then fail "tests home-manager nixpkgs must follow tests nixpkgs; lock edge is: ${builtins.toJSON hmInputs.nixpkgs}"
    else true;
  # The parent source itself must be a portable relative path reference.
  parentOriginal = testsNodes.dsh-nix.original
    or (fail "tests flake.lock has no dsh-nix original reference");
  c9 = if !(builtins.isAttrs parentOriginal)
      || parentOriginal.type or "" != "path"
      || lib.hasPrefix "/" (parentOriginal.path or "/")
    then fail "dsh-nix must stay a portable relative path:../. reference; got: ${builtins.toJSON parentOriginal}"
    else true;

  # --- 4. public identity preserved ----------------------------------------
  c10 = if !(builtins.hasAttr "homeManagerModules" dshNix)
      || !(builtins.isAttrs dshNix.homeManagerModules)
      || !(builtins.hasAttr "dsh" dshNix.homeManagerModules)
    then fail "public homeManagerModules.dsh missing from parent flake"
    else true;
  c11 = if !(builtins.hasAttr "overlays" dshNix)
      || !(builtins.isAttrs dshNix.overlays)
      || !(builtins.hasAttr "default" dshNix.overlays)
    then fail "public overlays.default missing from parent flake"
    else true;
  parentPkgs = if builtins.hasAttr "packages" dshNix && builtins.hasAttr system dshNix.packages
    then dshNix.packages.${system}
    else fail "parent flake has no packages.${system}";
  c12 = if !(builtins.hasAttr "default" parentPkgs)
    then fail "parent packages.${system}.default missing"
    else true;
  c13 = if !(builtins.hasAttr "dsh" parentPkgs)
      || parentPkgs.default.outPath != parentPkgs.dsh.outPath
    then fail "parent packages.${system}.default must stay identical to packages.${system}.dsh"
    else true;
  parentCheckNames = builtins.attrNames (
    if builtins.hasAttr "checks" dshNix && builtins.hasAttr system dshNix.checks
    then dshNix.checks.${system}
    else fail "parent flake has no checks.${system}"
  );
  c14 = if parentCheckNames != hmIndependentChecks
    then fail "parent checks.${system} must be exactly the HM-independent checks ${builtins.toJSON hmIndependentChecks}; got: ${builtins.toJSON parentCheckNames}"
    else true;

  # --- 5. no stale nested pins vs the parent on-disk lock ------------------
  stalePin = name:
    let
      a = revOf rootNodes name;
      b = revOf testsNodes name;
    in
    if a == null then fail "root flake.lock has no locked '${name}' node"
    else if b == null then fail "tests flake.lock has no locked '${name}' node; re-run `nix flake lock` in tests/"
    else if a != b then fail "stale nested pin: tests '${name}' rev '${b}' != parent on-disk rev '${a}'"
    else true;
  c15 = stalePin "nixpkgs";
  c16 = stalePin "systems";
  c17 = stalePin "dsh";

  allOk = lib.all (x: x) [ c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 ];

in
assert allOk;
pkgs.runCommand "dsh-test-flake-contract"
  {
    rootFlake = rootSrc + "/flake.nix";
    rootLock = rootSrc + "/flake.lock";
    testsLock = ./flake.lock;
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    set -euo pipefail
    fail() { echo "test-flake-contract BUILD-CHECK FAIL: $*" >&2; exit 1; }

    # Re-verify at build time so the realized artifact carries the evidence.
    grep -q 'inputs\.home-manager' "$rootFlake" && fail "root flake.nix declares inputs.home-manager"
    grep -q 'home-manager-integration' "$rootFlake" && fail "root flake.nix wires home-manager-integration"
    jq -e 'has("nodes")' "$rootLock" > /dev/null || fail "root lock has no nodes"
    jq -e '.nodes | has("home-manager") | not' "$rootLock" > /dev/null \
      || fail "root flake.lock contains home-manager"
    [ "$(jq -r '.nodes."home-manager".locked.rev' "$testsLock")" = "${expectedHmRev}" ] \
      || fail "tests home-manager rev mismatch"
    [ "$(jq -r '.nodes.root.inputs.nixpkgs | join(",")' "$testsLock")" = "dsh-nix,nixpkgs" ] \
      || fail "tests nixpkgs does not follow dsh-nix/nixpkgs"
    for pin in nixpkgs systems dsh; do
      a=$(jq -r --arg n "$pin" '.nodes[$n].locked.rev' "$rootLock")
      b=$(jq -r --arg n "$pin" '.nodes[$n].locked.rev' "$testsLock")
      [ -n "$a" ] && [ "$a" != "null" ] || fail "root lock missing $pin rev"
      [ "$a" = "$b" ] || fail "stale nested pin for $pin: tests=$b parent=$a"
    done

    mkdir -p "$out"
    {
      echo "test-flake-contract: passed"
      printf 'parent checks: %s\n' ${lib.escapeShellArg (builtins.toJSON hmIndependentChecks)}
      echo "home-manager rev: ${expectedHmRev}"
    } > "$out/result.txt"
  ''
