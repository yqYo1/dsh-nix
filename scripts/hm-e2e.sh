#!/usr/bin/env bash
# Real Home Manager host E2E: pinned-HM activation + real profile install + dsh boot.
#
# What this proves (once the dsh package hash is real):
#   1. The flake.lock-pinned Home Manager evaluates programs.dsh into a real
#      homeManagerConfiguration (DAG activation, real file linking) via
#      tests/hm-host.nix -- no <nixpkgs>, no stub options, no shims.
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
# Run via the Nix devShell, never host runtimes directly:
#   nix develop --no-write-lock-file -c bash scripts/hm-e2e.sh
# Optional: DSH_HM_E2E_TIMEOUT_SECONDS (boot wait, default 30),
#   DSH_HM_E2E_ARTIFACT_DIR (success evidence copy, default
#   $scratch/dsh-hm-host-e2e-latest).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
timeout_seconds=${DSH_HM_E2E_TIMEOUT_SECONDS:-30}
scratch=${TMPDIR:-/home/yayoi/.hermes/cache/scratch}
outer_home=${HOME:-/home/yayoi}
outer_user=${USER:-yayoi}
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
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
base="let fl = builtins.getFlake \"$repo_root\"; in import ./tests/hm-host.nix { pkgsPath = fl.inputs.nixpkgs.outPath; hmPath = fl.inputs.home-manager.outPath; dshSrc = fl.inputs.dsh; system = \"$system\"; username = \"$outer_user\"; homeDirectory = \"$HOME\"; }"
hm_rev=$(jq -r '.nodes."home-manager".locked.rev' flake.lock 2>/dev/null ||
  node -e 'console.log(require("./flake.lock").nodes["home-manager"].locked.rev)' 2>/dev/null || echo unknown)
nixpkgs_rev=$(jq -r '.nodes."nixpkgs".locked.rev' flake.lock 2>/dev/null ||
  node -e 'console.log(require("./flake.lock").nodes.nixpkgs.locked.rev)' 2>/dev/null || echo unknown)
echo "hm host e2e: pinned home-manager $hm_rev / nixpkgs $nixpkgs_rev (system $system)"
echo "hm host e2e: eval gate (drvPath only, no build)..."
drv=$(nix eval --impure --raw --expr \
  "let h = $base; in assert h.checks.packageExact; assert h.checks.dagOrdered; assert h.checks.layoutOk; h.activationDrvPath") ||
  fail "eval gate failed (packageExact/dagOrdered/layoutOk); fixture or module regressed"
expected_artifact=$(nix eval --impure --raw --expr "let h = $base; in h.expectedAgentArtifact") ||
  fail "could not evaluate expected agent artifact path"
pkg_out=$(nix eval --impure --raw --expr "let h = $base; in h.packageOutPath") ||
  fail "could not evaluate packaged dsh outPath"
pkg_drv=$(nix eval --impure --raw --expr "let h = $base; in h.packageDrvPath") ||
  fail "could not evaluate packaged dsh drvPath"
echo "hm host e2e: eval gate passed; activation drv $drv; package $pkg_out; package drv $pkg_drv"

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
nix build --impure --out-link "$artifact_dir/generation" --expr "let h = $base; in h.generation" \
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
  echo "home-manager rev: $hm_rev / nixpkgs rev: $nixpkgs_rev / system: $system"
} >"$artifact_dir/result.txt"
cp "$tmp/activation.log" "$artifact_dir/activation.log"
cp "$tmp/nix-build.log" "$artifact_dir/nix-build.log" 2>/dev/null || true

printf 'hm host e2e: passed (generation=%s dsh=%s evidence=%s)\n' \
  "$generation" "$dsh_real" "$artifact_dir"
