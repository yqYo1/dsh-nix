#!/usr/bin/env bash
# Real Home Manager host E2E: tests-flake-pinned HM activation + real profile install + dsh boot.
#
# What this proves (the dsh package hash is a real pinned hash, so every
# generation below is genuinely built and activated):
#   1. The tests-flake-lock-pinned Home Manager (tests/flake.lock) evaluates
#      programs.dsh into a real homeManagerConfiguration (DAG activation,
#      real file linking) via tests/hm-host.nix -- no <nixpkgs>, no stub
#      options, no shims. The root flake stays Home Manager-independent.
#   2. The generation's ./activate runs with driver 0 (default flags: NO
#      --driver-version, NO SKIP_SANITY_CHECKS, NO DRY_RUN). Pinned HM then
#      owns the install itself: `nix-env --profile
#      $XDG_STATE_HOME/nix/profiles/home-manager --set` creates the
#      generation profile, and `nix-env -i home-manager-path` installs the
#      ACTUAL packaged cfg.package (pkgs.dsh, unwrapped) into
#      $HOME/.nix-profile. The script asserts both landings and refuses to
#      continue otherwise -- never faking success.
#   3. The profile-installed dsh boots the fixture `agent` profile
#      (examples/plugins/tui-core, path-only, no network): the marker shows
#      `activated`, then SIGTERM yields clean exit 0 and `disposed`.
#   4. The lock-bearing `codex` profile (shared fixture
#      tests/fixtures/codex-profile.nix: in-box base + web-app,
#      dsh-codex@0.3.2, llm-openai-codex layer, committed pnpm lock) lands
#      with stamp == fixture-built artifact, direct-only manifest/layers,
#      spec link into the live FOD (direct-specs order, lock bytes, .pnpm
#      graph) and a runnable bin; the project-pinned node then proves the
#      real transitive pi-ai import and the packaged check-profile.mjs
#      boots the activated codex CHECK-OK under the rejecting no-network
#      guard (fresh HOME/XDG, --port 0 --no-open so no real browser ever
#      opens), with no network/import failure. Persisted evidence is
#      token-redacted (CHECK-OK and diagnostics survive).
#   5. The directly declared `user-npm` profile (the RAW buildNpmPackage
#      derivation in plugins, no selectors/surgery) lands with stamp ==
#      the expected artifact built from the SAME module declaration,
#      scoped direct-only manifest/layers, the symlink landing on the
#      immutable installed root (manifest .name, never the pname), a real
#      odd/even import + bin execution under the project-pinned node, and
#      a packaged rc.2 boot whose lifecycle log cmps exactly
#      `activated odd7=true` / `disposed` (function only: no
#      authentication claim for this synthetic fixture).
#
# Confinement contract (primary source: home-manager's
# modules/lib-bash/activation-init.sh `setupVars`/`migrateProfile`):
#   - HOME/XDG_* /DSH_HOME live under a mktemp dir in $scratch; the script
#     refuses to run if HOME escapes $scratch or equals the real home.
#   - $XDG_STATE_HOME/nix/profiles is pre-created so setupVars picks the
#     scratch profiles dir (never /nix/var/nix/profiles/per-user/$USER).
#   - NIX_STATE_DIR points into scratch so the "global" profiles/gcroots
#     paths (migrateProfile source, legacyGenGcPath removal) resolve under
#     scratch and can never touch the real per-user state. The REAL $USER is
#     kept (no synthetic username), so this shield is load-bearing.
#   - NIX_REMOTE=unix:///nix/var/nix/daemon-socket/socket reattaches EVERY
#     Nix CLI (nix, nix-env, nix-store, nix-build, including the ones pinned
#     HM invokes inside ./activate) to the live daemon, undoing the local-
#     store fallback that a scratch NIX_STATE_DIR would otherwise select.
#     PM-proved: under scratch HOME+NIX_STATE_DIR with this exact URI,
#     `nix store ping --json` returns url exactly this URI with trusted, and
#     `nix-store --query --deriver` resolves registered packages. The daemon
#     gate below re-proves both before any build/activation.
#   - XDG_RUNTIME_DIR points into scratch (no bus) and DBUS_SESSION_BUS_-
#     ADDRESS is unset, so `systemctl --user` is unreachable; the script
#     aborts if a user systemd is somehow running there, so reloadSystemd
#     can never reload real user services.
#   - Real external state (user profiles, gcroots, ~/.dsh) is snapshotted
#     before/after and must be byte-identical, else FAIL -- including on
#     failure paths after activation is attempted (see cleanup).
#
# Run via the tests devShell, never host runtimes directly:
#   nix develop ./tests --accept-flake-config --no-update-lock-file --no-write-lock-file -c bash scripts/hm-e2e.sh
# (tests/flake.nix references the parent via a relative path input, so this
# requires Nix >= 2.26.)
# Optional: DSH_HM_E2E_TIMEOUT_SECONDS (boot wait, default 30),
#   DSH_HM_E2E_ARTIFACT_DIR (success evidence copy, default
#   $scratch/dsh-hm-host-e2e-latest).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
nix_version=$(nix --version | awk '{ print $3 }')
if [ "$(printf '%s\n%s\n' '2.26' "$nix_version" | sort -V | head -1)" != '2.26' ]; then
  echo "hm host e2e: Nix >= 2.26 required for relative test-flake inputs (got $nix_version)" >&2
  exit 2
fi
timeout_seconds=${DSH_HM_E2E_TIMEOUT_SECONDS:-30}
scratch=${TMPDIR:?hm host e2e: TMPDIR must point at a scratch directory}
outer_home=${HOME:?hm host e2e: HOME must be set}
outer_user=${USER:?hm host e2e: USER must be set}
artifact_dir=${DSH_HM_E2E_ARTIFACT_DIR:-$scratch/dsh-hm-host-e2e-latest}

# Live-daemon socket: exact unix URI every real Nix CLI is routed to.
nix_daemon_uri="unix:///nix/var/nix/daemon-socket/socket"

for tool in nix nix-env nix-store nix-build; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "hm host e2e: missing required real tool: $tool (no shims allowed)" >&2
    exit 2
  }
done
# Refuse shimmed CLIs resolving out of scratch (all CLIs HM may invoke).
for tool in nix nix-env nix-store nix-build; do
  case "$(readlink -f "$(command -v "$tool")")" in
  *scratch* | *hm-host-e2e*)
    echo "hm host e2e: $tool resolves into scratch; refusing shimmed CLI" >&2
    exit 2
    ;;
  esac
done

tmp=$(mktemp -d "$scratch/dsh-hm-host-e2e.XXXXXX")
export HOME="$tmp/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
export DSH_HOME="$HOME/.dsh"
export NIX_STATE_DIR="$tmp/nix-state"
export NIX_REMOTE="$nix_daemon_uri"
export XDG_RUNTIME_DIR="$tmp/xdg-runtime"
unset DBUS_SESSION_BUS_ADDRESS || true

case "$HOME" in "$scratch"/*) ;; *)
  echo "hm host e2e: HOME escaped scratch ($HOME)" >&2
  exit 2
  ;;
esac
[[ "$HOME" != "$outer_home" ]] || {
  echo "hm host e2e: refusing to run against the real HOME" >&2
  exit 2
}

child=''
activation_attempted=0
fail() {
  echo "hm host e2e FAIL: $*" >&2
  echo "hm host e2e: diagnostics retained under: $tmp" >&2
  exit 1
}
reap_child() {
  if [[ -n "${child:-}" ]]; then
    if kill -0 "$child" 2>/dev/null; then
      kill -TERM "$child" 2>/dev/null || true
      for _ in $(seq 1 50); do
        kill -0 "$child" 2>/dev/null || break
        sleep 0.1
      done
      if kill -0 "$child" 2>/dev/null; then
        kill -KILL "$child" 2>/dev/null || true
      fi
    fi
    wait "$child" 2>/dev/null || true
    child=''
  fi
}
verify_post_guards() {
  # $1 = file to snapshot into. Reports drift, returns 0 when identical.
  snapshot_guards "$1"
  if cmp -s "$guard_before" "$1"; then
    echo "hm host e2e: real-user-state guard: untouched" >&2
    return 0
  fi
  echo "hm host e2e: real-user-state guard: MOVED (before=$guard_before after=$1)" >&2
  diff "$guard_before" "$1" 2>/dev/null | head -20 >&2 || true
  return 1
}
cleanup() {
  rc=$?
  reap_child
  if ((activation_attempted)) && [[ -f "${guard_before:-}" ]] && [[ ! -f "${guard_after:-}" ]]; then
    # Activation/boot failed before the success-path guard ran: still verify
    # real user state, preserving diagnostics under $tmp.
    verify_post_guards "$tmp/guard-after-fail.txt" || rc=1
  fi
  if ((rc != 0)); then
    echo "hm host e2e: FAILED (rc=$rc); scratch retained: $tmp" >&2
  else
    rm -rf "$tmp"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$HOME" "$XDG_STATE_HOME/nix/profiles" \
  "$XDG_STATE_HOME/home-manager/gcroots" "$NIX_STATE_DIR" "$XDG_RUNTIME_DIR"

# --- guard: real external profiles + real ~/.dsh must not move ------------
guard_before="$tmp/guard-before.txt"
guard_after="$tmp/guard-after.txt"
inventory() {
  (
    cd "$1" && find . \( -type f -o -type l \) -print0 2>/dev/null | sort -z |
      while IFS= read -r -d '' f; do
        if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")";
        else printf 'F %s %s\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)"; fi
      done
  )
}
snapshot_guards() {
  {
    echo '# real-profile readlinks (must be byte-identical after)'
    for p in \
      "$outer_home/.local/state/nix/profiles/home-manager" \
      "$outer_home/.nix-profile" \
      "/nix/var/nix/profiles/per-user/$outer_user/home-manager" \
      "/nix/var/nix/gcroots/per-user/$outer_user/current-home"; do
      if [ -e "$p" ] || [ -L "$p" ]; then
        printf 'EXISTS %s -> %s canon=%s mtime=%s\n' "$p" \
          "$(readlink "$p" 2>/dev/null || true)" "$(readlink -f "$p" 2>/dev/null || true)" "$(stat -c %Y "$p" 2>/dev/null || true)"
      else
        printf 'ABSENT %s\n' "$p"
      fi
    done
    echo '# real profile/gcroot directories incl generation symlinks (must be byte-identical after)'
    for d in \
      "$outer_home/.local/state/nix/profiles" \
      "/nix/var/nix/profiles/per-user/$outer_user" \
      "/nix/var/nix/gcroots/per-user/$outer_user"; do
      if [ -d "$d" ]; then
        printf '## DIR %s\n' "$d"
        inventory "$d"
      else
        printf '## NO-DIR %s\n' "$d"
      fi
    done
    echo '# real ~/.dsh inventory (must be byte-identical after)'
    if [ -d "$outer_home/.dsh" ]; then inventory "$outer_home/.dsh";
    else echo 'NO-REAL-DSH'; fi
  } >"$1"
}
snapshot_guards "$guard_before"

# No user systemd may be reachable under isolation (reloadSystemd guard).
if command -v systemctl >/dev/null 2>&1; then
  if XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS= \
    systemctl --user is-system-running 2>/dev/null | grep -Eq '^(running|degraded)$'; then
    fail "user systemd reachable under XDG_RUNTIME_DIR isolation; refusing (service-reload risk)"
  fi
fi

# --- pinned sources + eval gate (no build: package hash may be placeholder)
# All pins resolve through the tests subflake, so the root flake stays Home
# Manager-independent. Reject lock updates and never write the lock during
# verification. Address the whole Git repository with dir=tests, so the
# path:../. parent stays inside the source root (not a tests-only source tree).
system=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr 'builtins.currentSystem')
base="let fl = builtins.getFlake \"git+file://$repo_root?dir=tests\"; in import ./tests/hm-host.nix { pkgsPath = fl.inputs.nixpkgs.outPath; hmPath = fl.inputs.home-manager.outPath; dshSrc = fl.inputs.dsh-nix.inputs.dsh; system = \"$system\"; username = \"$outer_user\"; homeDirectory = \"$HOME\"; }"
hm_rev=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let h = (builtins.getFlake \"git+file://$repo_root?dir=tests\").inputs.home-manager; in h.rev or h.sourceInfo.rev or (throw \"home-manager rev unavailable\")") ||
  fail "could not resolve pinned home-manager rev from the tests flake"
nixpkgs_rev=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let n = (builtins.getFlake \"git+file://$repo_root?dir=tests\").inputs.nixpkgs; in n.rev or n.sourceInfo.rev or (throw \"nixpkgs rev unavailable\")") ||
  fail "could not resolve pinned nixpkgs rev from the tests flake"
echo "hm host e2e: pinned home-manager $hm_rev / nixpkgs $nixpkgs_rev (system $system)"
echo "hm host e2e: eval gate (drvPath only, no build)..."
drv=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr \
  "let h = $base; in assert h.checks.packageExact; assert h.checks.dagOrdered; assert h.checks.layoutOk; assert h.checks.codexLayoutOk; assert h.checks.userNpmLayoutOk; assert h.checks.codexLocked; h.activationDrvPath") ||
  fail "eval gate failed (packageExact/dagOrdered/layoutOk/codexLayoutOk/userNpmLayoutOk/codexLocked); fixture or module regressed"
expected_artifact=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let h = $base; in h.expectedAgentArtifact") ||
  fail "could not evaluate expected agent artifact path"
expected_codex=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let h = $base; in h.expectedCodexArtifact") ||
  fail "could not evaluate expected codex artifact path"
expected_usernpm=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let h = $base; in h.expectedUserNpmArtifact") ||
  fail "could not evaluate expected user-npm artifact path"
usernpm_out=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let h = $base; in h.userNpmOutPath") ||
  fail "could not evaluate user-npm package outPath"
node_out=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let h = $base; in h.nodeOutPath") ||
  fail "could not evaluate project-pinned node outPath"
codex_lock="$repo_root/tests/fixtures/codex-pnpm-lock.yaml"
net_guard="$repo_root/tests/fixtures/no-net-guard.cjs"
checker="$repo_root/scripts/check-profile.mjs"
for f in "$codex_lock" "$net_guard" "$checker"; do
  test -f "$f" || fail "required fixture missing: $f"
done
command -v jq >/dev/null 2>&1 || fail "jq required (run via the tests devShell)"
pkg_out=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let h = $base; in h.packageOutPath") ||
  fail "could not evaluate packaged dsh outPath"
pkg_drv=$(nix eval --impure --raw --accept-flake-config --no-update-lock-file --no-write-lock-file --expr "let h = $base; in h.packageDrvPath") ||
  fail "could not evaluate packaged dsh drvPath"
echo "hm host e2e: eval gate passed; activation drv $drv; package $pkg_out; package drv $pkg_drv; codex $expected_codex; user-npm $expected_usernpm (pkg $usernpm_out); node $node_out"

# --- daemon gate: scratch NIX_STATE_DIR must not mean a local empty store --
echo "hm host e2e: daemon gate (NIX_REMOTE=$NIX_REMOTE, NIX_STATE_DIR=$NIX_STATE_DIR)..."
ping_json=$(nix store ping --json 2>"$tmp/store-ping.stderr") ||
  fail "daemon gate: nix store ping failed (see $tmp/store-ping.stderr)"
case "$ping_json" in *"$nix_daemon_uri"*) ;; *)
  fail "daemon gate: store ping url is not the live daemon (want $nix_daemon_uri, got: $ping_json)" ;;
esac
case "$ping_json" in *'"trusted":1'* | *'"trusted":true'*) ;; *)
  fail "daemon gate: store ping not trusted (got: $ping_json)" ;;
esac
echo "hm host e2e: daemon gate: live daemon reachable ($ping_json)"

# --- real build of the generation (needs the real dsh package hash) --------
# Persistent GC root: build directly with a REAL Nix --out-link at
# $artifact_dir/generation (not a cp -P symlink copy, which registers nothing).
mkdir -p "$artifact_dir"
nix build --impure --accept-flake-config --no-update-lock-file --no-write-lock-file --out-link "$artifact_dir/generation" --expr "let h = $base; in h.generation" \
  -L 2>"$tmp/nix-build.log" ||
  fail "nix build of activationPackage failed (see $tmp/nix-build.log)"
generation=$(readlink -f "$artifact_dir/generation") ||
  fail "generation out-link is dangling ($artifact_dir/generation)"
test -e "$generation" ||
  fail "generation target missing ($generation)"
echo "hm host e2e: generation $generation (GC root: $artifact_dir/generation)"

# --- shared-DB proof: registered deriver must EXACTLY equal evaluated drvPath
deriver=$(nix-store --query --deriver "$pkg_out" 2>"$tmp/deriver.stderr") ||
  fail "shared-DB proof: deriver query failed for evaluated $pkg_out (see $tmp/deriver.stderr)"
[[ "$deriver" == "$pkg_drv" ]] ||
  fail "shared-DB proof: registered deriver mismatch (got: $deriver, want exactly: $pkg_drv)"
echo "hm host e2e: shared-DB proof: registered deriver exactly matches evaluated drvPath ($deriver)"

# --- project-pinned node (same pkgs the profiles build with) ---------------
# Realised through the live daemon with a tmp out-link (no ambient runtime
# is ever used for the codex/user-npm probes below).
nix build --impure --accept-flake-config --no-update-lock-file --no-write-lock-file --out-link "$tmp/node-pinned" --expr "let h = $base; in h.nodePackage" \
  -L 2>"$tmp/nix-build-node.log" ||
  fail "nix build of project-pinned nodejs failed (see $tmp/nix-build-node.log)"
node_bin="$tmp/node-pinned/bin/node"
test -x "$node_bin" || fail "pinned node binary missing ($node_bin)"
echo "hm host e2e: project-pinned node $node_bin (out $node_out)"

# --- real activation, driver 0: HM owns the profile install ----------------
# NOTE: no --driver-version (1 would skip it), no SKIP_SANITY_CHECKS (real
# USER/HOME binding verified), no DRY_RUN, no shims on PATH.
# Guarantee the declared live driver0 contract regardless of ambient env.
unset DRY_RUN SKIP_SANITY_CHECKS || true
[[ -z "${DRY_RUN:-}" && -z "${SKIP_SANITY_CHECKS:-}" ]] ||
  fail "could not clear DRY_RUN/SKIP_SANITY_CHECKS for live activation"
activation_attempted=1
VERBOSE=1 env -u DBUS_SESSION_BUS_ADDRESS -u DRY_RUN -u SKIP_SANITY_CHECKS \
  bash "$generation/activate" >"$tmp/activation.log" 2>&1 ||
  fail "activation failed (see $tmp/activation.log)"
echo "hm host e2e: activation exit 0 (see $tmp/activation.log for the pinned-HM nix-env trace)"

gen_profile="$XDG_STATE_HOME/nix/profiles/home-manager"
[[ "$(readlink -f "$gen_profile")" == "$generation" ]] ||
  fail "generation profile $gen_profile does not point at $generation (got: $(readlink "$gen_profile" 2>/dev/null || true))"
dsh_bin="$HOME/.nix-profile/bin/dsh"
test -x "$dsh_bin" ||
  fail "profile-installed dsh missing at $dsh_bin; real package install did not happen"
dsh_real=$(readlink -f "$dsh_bin") ||
  fail "profile-installed dsh link is dangling ($dsh_bin)"
[[ "$dsh_real" == "$pkg_out/bin/dsh" ]] ||
  fail "installed dsh is not the evaluated package (got: $dsh_real, want: $pkg_out/bin/dsh)"
echo "hm host e2e: real profile install owned by pinned HM (gen_profile=$gen_profile dsh=$dsh_real)"

test -f "$HOME/.dsh/profiles/agent/package.json" ||
  fail "agent package.json missing after activation"
stamp_file="$HOME/.dsh/profiles/agent/.dsh-nix-stamp"
test -f "$stamp_file" || fail "agent stamp missing after activation"
[[ "$(cat "$stamp_file")" == "$expected_artifact" ]] ||
  fail "agent stamp != expected artifact (got: $(cat "$stamp_file"), want: $expected_artifact)"

# Idempotence: a second activation changes nothing and exits 0.
before="$tmp/idh-before.txt"
after="$tmp/idh-after.txt"
inventory "$HOME/.dsh" >"$before"
VERBOSE=1 env -u DBUS_SESSION_BUS_ADDRESS -u DRY_RUN -u SKIP_SANITY_CHECKS \
  bash "$generation/activate" >>"$tmp/activation.log" 2>&1 ||
  fail "second activation failed (see $tmp/activation.log)"
inventory "$HOME/.dsh" >"$after"
cmp -s "$before" "$after" || fail "second activation changed ~/.dsh state"
echo "hm host e2e: activation idempotent"

# --- lock-bearing codex: stamp, direct-only manifest/layers, FOD lock -----
# Activated paths only (never derivation string shape). The checker boot at
# the end rewrites the activated cordis.yml, so every byte-identity proof
# lives before it; the scratch tree is disposable afterwards.
codex_dir="$HOME/.dsh/profiles/codex"
test -d "$codex_dir" || fail "codex dir missing after activation"
test -f "$codex_dir/package.json" || fail "codex package.json missing after activation"
codex_stamp="$codex_dir/.dsh-nix-stamp"
test -f "$codex_stamp" || fail "codex stamp missing after activation"
[[ "$(cat "$codex_stamp")" == "$expected_codex" ]] ||
  fail "codex stamp != expected artifact (got: $(cat "$codex_stamp"), want: $expected_codex)"
# All three stamps survive the second activation byte-identical (the
# inventory cmp above already covers the tree; re-assert the strings
# explicitly).
[[ "$(cat "$stamp_file")" == "$expected_artifact" ]] ||
  fail "agent stamp moved after second activation"
[[ "$(cat "$codex_stamp")" == "$expected_codex" ]] ||
  fail "codex stamp moved after second activation"
usernpm_dir="$HOME/.dsh/profiles/user-npm"
usernpm_stamp="$usernpm_dir/.dsh-nix-stamp"
test -f "$usernpm_stamp" || fail "user-npm stamp missing after activation"
[[ "$(cat "$usernpm_stamp")" == "$expected_usernpm" ]] ||
  fail "user-npm stamp moved after second activation"
codex_bundles=$(jq -c '.dsh.profile.bundles' "$codex_dir/package.json") ||
  fail "codex package.json bundles unreadable"
[[ "$codex_bundles" == '["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app","dsh-codex"]' ]] ||
  fail "codex bundles != declared composition (got: $codex_bundles)"
jq -e '.[0].id == "llm-openai-codex" and .[0].config.searchMode == "live" and .[0].config.useNativeCompaction == true' \
  "$codex_dir/cordis.patch.yml" >/dev/null ||
  fail "codex user layer mutated"
[[ "$(ls "$codex_dir/node_modules")" == "dsh-codex" ]] ||
  fail "codex profile top leaked beyond the direct spec (got: $(ls "$codex_dir/node_modules"))"
test -L "$codex_dir/node_modules/dsh-codex" ||
  fail "codex direct spec link missing after activation"
codex_link=$(readlink "$codex_dir/node_modules/dsh-codex")
codex_fod=${codex_link%/node_modules/dsh-codex}
[[ -n "$codex_fod" && "$codex_fod" != "$codex_link" ]] ||
  fail "codex link target has unexpected shape: $codex_link"
jq -e '. == [{"spec":"dsh-codex@0.3.2","packageName":"dsh-codex"}]' \
  "$codex_fod/direct-specs.json" >/dev/null ||
  fail "codex direct-specs != exactly the declared spec"
cmp -s "$codex_fod/pnpm-lock.yaml" "$codex_lock" ||
  fail "codex FOD lock bytes != committed lock ($codex_lock)"
test -d "$codex_fod/node_modules/.pnpm" ||
  fail "codex FOD missing .pnpm graph ($codex_fod)"
test -f "$codex_dir/node_modules/dsh-codex/package.json" ||
  fail "codex spec package.json missing"
test -f "$codex_dir/node_modules/dsh-codex/lib/index.js" ||
  fail "codex spec index missing"
test -f "$codex_dir/node_modules/dsh-codex/lib/bin.js" ||
  fail "codex spec bin missing (executability is proven by the status run below)"
echo "hm host e2e: codex stamp/composition/lock bytes from activated paths (fod=$codex_fod)"

# --- activated codex runs: guard proof, real transitive imports ------------
# Every child below runs on a pnpm-free PATH (pinned node only) in confined
# scratch state -- never ambient runtimes, never the real HOME.
child_path="$tmp/node-pinned/bin:/usr/bin:/bin"
if env -i PATH="$child_path" "$(command -v bash)" -c 'command -v pnpm' >/dev/null 2>&1; then
  fail "ambient pnpm reachable on the child PATH (must be pnpm-free)"
fi
"$node_bin" --require "$net_guard" --input-type=module -e \
  "await fetch('http://example.com/')" 2>"$tmp/guard-proof.err" &&
  fail "no-network guard did not block fetch"
grep -q 'NETWORK_FORBIDDEN' "$tmp/guard-proof.err" ||
  fail "guard error signature missing"
echo "hm host e2e: no-network guard rejects egress"
env -i PATH="$child_path" HOME="$HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
  XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  NODE_OPTIONS="--require $net_guard" \
  CODEX_DIR="$codex_dir" "$node_bin" --experimental-import-meta-resolve --input-type=module -e "
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
// Resolve from the canonical package entry with ESM import conditions:
// synthetic createRequire anchors do not follow profile links, and pi-ai
// intentionally does not expose a CommonJS require entry.
const codexUrl = pathToFileURL(realpathSync(process.env.CODEX_DIR + '/node_modules/dsh-codex/lib/index.js')).href;
const m = await import(codexUrl);
for (const k of ['loginOpenAICodex', 'openAICodexAuthStatus', 'diagnoseOpenAICodex']) {
  if (!(k in m)) { console.error('missing export ' + k); process.exit(1); }
}
console.log('IMPORT-OK ' + Object.keys(m).length + ' keys');
const llmUrl = import.meta.resolve('@deepseek-ai/dsh-llm-pi-ai', codexUrl);
const llm = await import(llmUrl);
console.log('LLM-OK ' + Object.keys(llm).length + ' keys from ' + llmUrl);
const piUrl = import.meta.resolve('@earendil-works/pi-ai', llmUrl);
const pi = await import(piUrl);
console.log('PIAI-OK ' + Object.keys(pi).length + ' keys from ' + piUrl);
" >"$tmp/codex-import.log" 2>&1 ||
  { cat "$tmp/codex-import.log" >&2; fail "activated codex/pi-ai real import (see $tmp/codex-import.log)"; }
grep -q '^IMPORT-OK' "$tmp/codex-import.log" || fail "codex import marker missing"
grep -q '^LLM-OK' "$tmp/codex-import.log" || fail "transitive dsh-llm-pi-ai import marker missing"
grep -q '^PIAI-OK' "$tmp/codex-import.log" || fail "transitive pi-ai import marker missing"
echo "hm host e2e: activated codex real import ($(head -1 "$tmp/codex-import.log"); $(grep '^PIAI-OK' "$tmp/codex-import.log"))"

# Signed-out bin JSON from the ACTIVATED bin (fresh HOME/XDG, rejecting
# guard): proves the bin executes for real, not mere file presence.
bin_home="$tmp/codex-bin-home"
mkdir -p "$bin_home/.local/share" "$bin_home/.local/state" "$bin_home/.config" "$bin_home/.cache"
if env -i PATH="$child_path" HOME="$bin_home" \
  XDG_DATA_HOME="$bin_home/.local/share" XDG_STATE_HOME="$bin_home/.local/state" \
  XDG_CONFIG_HOME="$bin_home/.config" XDG_CACHE_HOME="$bin_home/.cache" \
  NODE_OPTIONS="--require $net_guard" \
  "$node_bin" "$codex_dir/node_modules/dsh-codex/lib/bin.js" status --json \
  >"$tmp/codex-status.out" 2>"$tmp/codex-status.err"; then
  printf '0' >"$tmp/codex-status.rc"
else
  printf '%s' "$?" >"$tmp/codex-status.rc"
fi
[[ "$(cat "$tmp/codex-status.rc")" == "1" ]] || {
  cat "$tmp/codex-status.out" "$tmp/codex-status.err" >&2
  fail "codex status --json rc != signed-out rc1 (got: $(cat "$tmp/codex-status.rc"))"
}
jq -e '. == {schemaVersion: 1, package: "dsh-codex", version: "0.3.2", status: "signed-out"}' \
  "$tmp/codex-status.out" >/dev/null ||
  fail "codex status --json != exact signed-out document"
grep -Eq 'ERR_MODULE_NOT_FOUND|Cannot find package|ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL|NETWORK_FORBIDDEN' \
  "$tmp/codex-status.out" "$tmp/codex-status.err" &&
  fail "codex status hit import/pnpm/network error, not signed-out"
test ! -e "$bin_home/.dsh" || fail "bin run created .dsh in fresh HOME"
echo "hm host e2e: activated codex bin status --json rc1 exact signed-out, no egress"

# Real packaged boot of the ACTIVATED codex (installed package as anchor,
# rejecting guard, scratch fresh HOME/XDG, ephemeral port, no browser open):
# CHECK-OK with no network/import failure. Runs after every byte-identity
# proof: the checker rewrites the activated cordis.yml root, which is fine
# on the disposable scratch tree. --no-open is load-bearing on a real host:
# the web boot must never open the real default browser.
check_home="$tmp/check-home"
mkdir -p "$check_home/.local/share" "$check_home/.local/state" "$check_home/.config" "$check_home/.cache"
if ! env -i PATH="$child_path" HOME="$check_home" \
  XDG_DATA_HOME="$check_home/.local/share" XDG_STATE_HOME="$check_home/.local/state" \
  XDG_CONFIG_HOME="$check_home/.config" XDG_CACHE_HOME="$check_home/.cache" \
  NODE_OPTIONS="--require $net_guard" \
  "$node_bin" --expose-internals \
  --require "$pkg_out/lib/dsh-builtin-compat.cjs" \
  "$checker" "$pkg_out" codex "$HOME/.dsh" --port 0 --no-open \
  >"$tmp/check-codex.log" 2>&1; then
  cat "$tmp/check-codex.log" >&2
  fail "codex profile boot via packaged check-profile (see $tmp/check-codex.log)"
fi
grep -q '^CHECK-OK$' "$tmp/check-codex.log" || fail "codex boot lacks CHECK-OK"
grep -Eq 'NETWORK_FORBIDDEN|ERR_MODULE_NOT_FOUND|Cannot find package' "$tmp/check-codex.log" &&
  fail "codex boot hit network/import failure"
echo "hm host e2e: codex profile boot CHECK-OK under rejecting guard (port 0, no-open)"

# --- directly declared user-npm: stamp, scoped shape, installed root -----
# Activated paths only (never derivation string shape, never the pname).
# The byte-identity proofs live before the user-npm checker boot below,
# which writes the poc-npm-fixture lifecycle log.
usernpm_root="$usernpm_out/lib/node_modules/@dsh-poc/user-npm-plugin"
test -d "$usernpm_dir" || fail "user-npm dir missing after activation"
test -f "$usernpm_dir/package.json" || fail "user-npm package.json missing after activation"
[[ "$(cat "$usernpm_stamp")" == "$expected_usernpm" ]] ||
  fail "user-npm stamp != expected artifact (got: $(cat "$usernpm_stamp"), want: $expected_usernpm)"
usernpm_bundles=$(jq -c '.dsh.profile.bundles' "$usernpm_dir/package.json") ||
  fail "user-npm package.json bundles unreadable"
[[ "$usernpm_bundles" == '["@dsh-poc/user-npm-plugin"]' ]] ||
  fail "user-npm bundles != manifest-declared layer (got: $usernpm_bundles)"
jq --arg want "$usernpm_root" -e '.dependencies."@dsh-poc/user-npm-plugin" == $want' \
  "$usernpm_dir/package.json" >/dev/null ||
  fail "user-npm dependencies does not map the manifest name to the installed package root"
case "$usernpm_out" in
*dsh-poc-npm-user-pkg*) ;;
*) fail "user-npm store path lost the dsh-poc-npm-user-pkg pname" ;;
esac
[[ "$(ls "$usernpm_dir/node_modules")" == "@dsh-poc" ]] ||
  fail "user-npm profile top leaked beyond the direct scope (got: $(ls "$usernpm_dir/node_modules"))"
test -d "$usernpm_dir/node_modules/@dsh-poc" || fail "user-npm scope parent is not a real dir"
test ! -L "$usernpm_dir/node_modules/@dsh-poc" || fail "user-npm scope parent is a symlink (whole-scope leak)"
test -L "$usernpm_dir/node_modules/@dsh-poc/user-npm-plugin" ||
  fail "user-npm scoped package is not a single exact link"
usernpm_link=$(readlink "$usernpm_dir/node_modules/@dsh-poc/user-npm-plugin")
[[ "$usernpm_link" == "$usernpm_root" ]] ||
  fail "user-npm link != immutable installed root (got: $usernpm_link, want: $usernpm_root)"
jq -e '.name == "@dsh-poc/user-npm-plugin"' "$usernpm_link/package.json" >/dev/null ||
  fail "user-npm link target manifest name mismatch (pname must never infer identity)"
test -d "$usernpm_link/node_modules/is-odd" || fail "user-npm runtime is-odd missing under installed root"
test -d "$usernpm_link/node_modules/is-number" || fail "user-npm transitive is-number missing under installed root"
echo "hm host e2e: user-npm stamp/scoped shape/installed root from activated paths (root=$usernpm_root)"

# --- activated user-npm runs: real import + bin odd/even -------------------
# Project-pinned node on a pnpm-free PATH in confined scratch state.
env -i PATH="$child_path" HOME="$HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
  XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  NODE_OPTIONS="--require $net_guard" \
  USERNPM_DIR="$usernpm_dir" "$node_bin" --input-type=module -e "
const { checkOdd } = await import(process.env.USERNPM_DIR + '/node_modules/@dsh-poc/user-npm-plugin/lib/index.js');
if (checkOdd(3) !== true) { console.error('odd3 != true'); process.exit(1); }
if (checkOdd(4) !== false) { console.error('odd4 != false'); process.exit(1); }
console.log('USERNPM-IMPORT-OK odd3=true odd4=false');
" >"$tmp/usernpm-import.log" 2>&1 ||
  { cat "$tmp/usernpm-import.log" >&2; fail "activated user-npm real import (see $tmp/usernpm-import.log)"; }
grep -q '^USERNPM-IMPORT-OK' "$tmp/usernpm-import.log" || fail "user-npm import marker missing"
echo "hm host e2e: activated user-npm real import ($(cat "$tmp/usernpm-import.log"))"
usernpm_bin_home="$tmp/usernpm-bin-home"
mkdir -p "$usernpm_bin_home/.local/share" "$usernpm_bin_home/.local/state" "$usernpm_bin_home/.config" "$usernpm_bin_home/.cache"
if env -i PATH="$child_path" HOME="$usernpm_bin_home" \
  XDG_DATA_HOME="$usernpm_bin_home/.local/share" XDG_STATE_HOME="$usernpm_bin_home/.local/state" \
  XDG_CONFIG_HOME="$usernpm_bin_home/.config" XDG_CACHE_HOME="$usernpm_bin_home/.cache" \
  NODE_OPTIONS="--require $net_guard" \
  "$node_bin" "$usernpm_dir/node_modules/@dsh-poc/user-npm-plugin/lib/bin.js" check 7 \
  >"$tmp/usernpm-check7.out" 2>"$tmp/usernpm-check7.err"; then
  printf '0' >"$tmp/usernpm-check7.rc"
else
  printf '%s' "$?" >"$tmp/usernpm-check7.rc"
fi
[[ "$(cat "$tmp/usernpm-check7.rc")" == "0" ]] ||
  fail "activated user-npm bin check 7 rc != 0 (got: $(cat "$tmp/usernpm-check7.rc"))"
[[ "$(cat "$tmp/usernpm-check7.out")" == "odd" ]] ||
  fail "activated user-npm bin check 7 != odd (got: $(cat "$tmp/usernpm-check7.out"))"
if env -i PATH="$child_path" HOME="$usernpm_bin_home" \
  XDG_DATA_HOME="$usernpm_bin_home/.local/share" XDG_STATE_HOME="$usernpm_bin_home/.local/state" \
  XDG_CONFIG_HOME="$usernpm_bin_home/.config" XDG_CACHE_HOME="$usernpm_bin_home/.cache" \
  NODE_OPTIONS="--require $net_guard" \
  "$node_bin" "$usernpm_dir/node_modules/@dsh-poc/user-npm-plugin/lib/bin.js" check 8 \
  >"$tmp/usernpm-check8.out" 2>"$tmp/usernpm-check8.err"; then
  printf '0' >"$tmp/usernpm-check8.rc"
else
  printf '%s' "$?" >"$tmp/usernpm-check8.rc"
fi
[[ "$(cat "$tmp/usernpm-check8.rc")" == "0" ]] ||
  fail "activated user-npm bin check 8 rc != 0 (got: $(cat "$tmp/usernpm-check8.rc"))"
[[ "$(cat "$tmp/usernpm-check8.out")" == "even" ]] ||
  fail "activated user-npm bin check 8 != even (got: $(cat "$tmp/usernpm-check8.out"))"
grep -Eq 'ERR_MODULE_NOT_FOUND|Cannot find package|NETWORK_FORBIDDEN' \
  "$tmp/usernpm-check7.out" "$tmp/usernpm-check7.err" "$tmp/usernpm-check8.out" "$tmp/usernpm-check8.err" &&
  fail "activated user-npm bin hit import/network error"
test ! -e "$usernpm_bin_home/.dsh" || fail "bin run created .dsh in fresh HOME"
echo "hm host e2e: activated user-npm bin check 7/8 odd/even, no egress"

# Real packaged boot of the ACTIVATED user-npm (installed package as anchor,
# rejecting guard, scratch fresh HOME/XDG, ephemeral port, no browser open):
# CHECK-OK, then the lifecycle log must cmp EXACTLY
# 'activated odd7=true\ndisposed\n' (function only: no authentication
# claim for this synthetic fixture).
usernpm_check_home="$tmp/usernpm-check-home"
mkdir -p "$usernpm_check_home/.local/share" "$usernpm_check_home/.local/state" "$usernpm_check_home/.config" "$usernpm_check_home/.cache"
if ! env -i PATH="$child_path" HOME="$usernpm_check_home" \
  XDG_DATA_HOME="$usernpm_check_home/.local/share" XDG_STATE_HOME="$usernpm_check_home/.local/state" \
  XDG_CONFIG_HOME="$usernpm_check_home/.config" XDG_CACHE_HOME="$usernpm_check_home/.cache" \
  NODE_OPTIONS="--require $net_guard" \
  "$node_bin" --expose-internals \
  --require "$pkg_out/lib/dsh-builtin-compat.cjs" \
  "$checker" "$pkg_out" user-npm "$HOME/.dsh" --port 0 --no-open \
  >"$tmp/check-usernpm.log" 2>&1; then
  cat "$tmp/check-usernpm.log" >&2
  fail "user-npm profile boot via packaged check-profile (see $tmp/check-usernpm.log)"
fi
grep -q '^CHECK-OK$' "$tmp/check-usernpm.log" || fail "user-npm boot lacks CHECK-OK"
grep -Eq 'NETWORK_FORBIDDEN|ERR_MODULE_NOT_FOUND|Cannot find package' "$tmp/check-usernpm.log" &&
  fail "user-npm boot hit network/import failure"
echo "hm host e2e: user-npm profile boot CHECK-OK under rejecting guard (port 0, no-open)"
usernpm_lifecycle="$HOME/.dsh/poc-npm-fixture-lifecycle.log"
printf 'activated odd7=true\ndisposed\n' >"$tmp/usernpm-expected-lifecycle"
cmp -s "$tmp/usernpm-expected-lifecycle" "$usernpm_lifecycle" ||
  fail "user-npm lifecycle mismatch; observed: $(cat "$usernpm_lifecycle" 2>/dev/null || true)"

# --- boot the profile-installed dsh, assert activated -> disposed ----------
marker_file="$DSH_HOME/tui-fixture-lifecycle.log"
stderr_file="$tmp/stderr"
(cd "$HOME" && exec env -u DBUS_SESSION_BUS_ADDRESS \
  HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" DSH_HOME="$DSH_HOME" \
  "$dsh_bin" --profile agent >"$tmp/stdout" 2>"$stderr_file") &
child=$!

expected_file="$tmp/expected"
printf 'activated\n' >"$expected_file"
deadline=$((SECONDS + timeout_seconds))
while ! cmp -s "$expected_file" "$marker_file" 2>/dev/null; do
  if ! kill -0 "$child" 2>/dev/null; then
    set +e
    wait "$child"
    status=$?
    set -e
    child=''
    printf 'hm host e2e: dsh exited before activation (status %s)\n' "$status" >&2
    cat "$stderr_file" >&2
    fail "no activation marker (stdout: $tmp/stdout)"
  fi
  if ((SECONDS >= deadline)); then
    printf 'hm host e2e: timed out waiting for activation\n' >&2
    cat "$stderr_file" >&2
    fail "activation timeout after ${timeout_seconds}s"
  fi
  sleep 0.1
done

kill -TERM "$child" 2>/dev/null || true
for _ in $(seq 1 50); do
  kill -0 "$child" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$child" 2>/dev/null; then
  kill -KILL "$child" 2>/dev/null || true
fi
set +e
wait "$child"
status=$?
set -e
child=''
if ((status != 0)); then
  printf 'hm host e2e: dsh exited with status %s after SIGTERM\n' "$status" >&2
  cat "$stderr_file" >&2
  fail "unclean shutdown (status $status)"
fi

printf 'activated\ndisposed\n' >"$expected_file"
cmp -s "$expected_file" "$marker_file" ||
  fail "lifecycle marker mismatch; observed: $(cat "$marker_file" 2>/dev/null || true)"

# --- post guards: real user state untouched ---------------------------------
verify_post_guards "$guard_after" ||
  fail "real user state moved (diff guard-before guard-after under $tmp)"

# --- success evidence (outside tmp so it survives cleanup) ------------------
pkg_deriver=$(nix-store --query --deriver "$pkg_out" 2>/dev/null || echo unknown)
mkdir -p "$artifact_dir"
cp "$marker_file" "$artifact_dir/lifecycle.log"
cp "$guard_before" "$artifact_dir/guard-before.txt"
cp "$guard_after" "$artifact_dir/guard-after.txt"
cp "$before" "$artifact_dir/idempotence-before.txt"
cp "$after" "$artifact_dir/idempotence-after.txt"
{
  echo "hm host e2e: passed"
  echo "generation: $generation"
  echo "drv: $drv"
  echo "package_out (immutable): $pkg_out"
  echo "package_deriver: $pkg_deriver"
  echo "dsh: $dsh_real"
  echo "codex_artifact (immutable): $expected_codex"
  echo "codex_stamp: $(cat "$codex_stamp")"
  echo "usernpm_artifact (immutable): $expected_usernpm"
  echo "usernpm_stamp: $(cat "$usernpm_stamp")"
  echo "usernpm_root (immutable): $usernpm_root"
  echo "node_out (project-pinned): $node_out"
  echo "home-manager rev: $hm_rev / nixpkgs rev: $nixpkgs_rev / system: $system"
} >"$artifact_dir/result.txt"
cp "$tmp/activation.log" "$artifact_dir/activation.log"
cp "$tmp/nix-build.log" "$artifact_dir/nix-build.log" 2>/dev/null || true
cp "$tmp/nix-build-node.log" "$artifact_dir/nix-build-node.log" 2>/dev/null || true
cp "$tmp/codex-import.log" "$artifact_dir/codex-import.log"
cp "$tmp/codex-status.out" "$artifact_dir/codex-status-json.out"
cp "$tmp/guard-proof.err" "$artifact_dir/guard-proof.err"
cp "$tmp/usernpm-import.log" "$artifact_dir/usernpm-import.log"
cp "$tmp/usernpm-check7.out" "$artifact_dir/usernpm-check7.out"
cp "$tmp/usernpm-check8.out" "$artifact_dir/usernpm-check8.out"
cp "$tmp/check-usernpm.log" "$artifact_dir/check-usernpm.log"
cp "$usernpm_lifecycle" "$artifact_dir/user-npm-lifecycle.log"
# Token-redacted evidence copy: the web boot log may print token-bearing
# localhost URLs; raw tokens must never persist in the artifact. CHECK-OK
# and other diagnostics survive (only token values are masked: double- and
# single-quoted forms first, then bare). The two post-checks are
# fail-closed: any unmasked or half-masked token aborts instead of leaking.
sed -E -e 's/token="[^"]*"/token=REDACTED/g' -e "s/token='[^']*'/token=REDACTED/g" -e "s/token=[^ '\"&]*/token=REDACTED/g" "$tmp/check-codex.log" >"$artifact_dir/check-codex.log"
grep -q '^CHECK-OK$' "$artifact_dir/check-codex.log" || fail "redacted evidence lost CHECK-OK"
if grep -E 'token=' "$artifact_dir/check-codex.log" | grep -qv 'token=REDACTED'; then
  fail "raw token leaked into persisted evidence"
fi
if grep -Eq "token=REDACTED[\"']" "$artifact_dir/check-codex.log"; then
  fail "quoted token remainder in persisted evidence"
fi

printf 'hm host e2e: passed (generation=%s dsh=%s evidence=%s)\n' \
  "$generation" "$dsh_real" "$artifact_dir"
