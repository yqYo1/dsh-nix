#!/usr/bin/env bash
# Tag-based DSH flake-input updater (maintenance helper).
#
# CONTRACT
#   - Retargets ONLY the `dsh` flake input in the ROOT flake.nix to a released
#     deepseek-harness tag (default: latest `dsh-v*`), re-locks the root
#     (`nix flake lock --update-input dsh`, immutable rev + narHash), then
#     re-syncs the tests subflake graph (`nix flake lock ./tests`) WITHOUT
#     bumping Home Manager or any unrelated input (never a wholesale
#     `nix flake update`). Verifies the evaluated Nix package `version`
#     equals the upstream tag's CLI version (fail closed with an owner
#     pointer when stale), then gates on a real `nix build` of the dsh
#     package, root `nix flake check`, tests `nix flake check`, and the
#     real host Home Manager E2E (scripts/hm-e2e.sh via the tests devShell,
#     same command as CI).
#   - NEVER edits package-owner files (pkgs/dsh.nix version/hash,
#     modules/, lib/, profiles) nor tests/flake.nix (owned by the
#     test-flake author). On a stale version or a pnpm store
#     hash mismatch it fails CLOSED with a pointer for the package
#     owner instead of rewriting owner lines. At exit the only
#     modified paths may be flake.nix, flake.lock, and tests/flake.lock;
#     anything else aborts the run. (The pnpm lockfile hash and the Nix
#     fixed-output store hash are DIFFERENT objects — never compare them;
#     the real `nix build` fixed-output mismatch gate below is the correct
#     one.)
#   - Build evidence (build.log, result outlink) lives OUTSIDE the repo
#     under scratch/runner temp, never as repo files; Nix exit codes
#     are propagated exactly, with no hidden success markers.
#   - NEVER touches packaging upstream (no merge, no `-X ours`), never
#     pushes anywhere, never opens PRs. Callers (CI workflow, humans)
#   decide what to do with the working tree.
#   - Accepts the current flake.nix pin in EITHER form: commit-rev
#     (`github:.../<40hex>`) or tag (`github:.../dsh-v...`). The old
#     40-hex-only regex is gone.
#
# USAGE
#   scripts/update-dsh.sh [--tag TAG] [--pattern 'dsh-v*']
#   Emits KEY=VALUE lines for GITHUB_OUTPUT when that file exists:
#     tag, sha, version, changed(true/false).
#   Exit 0 = update applied (or already current); non-zero = failed gate.
#
# SIGNED-COMMIT CONSTRAINT
#   Commits created from this script's result by automation
#   (GITHUB_TOKEN) are UNSIGNED. If branch protection on main ever
#   requires signed commits, automation must stop before push/PR
#   (the workflow gates on this) — never invent keys or bypass.
set -euo pipefail

UPSTREAM_REPO="deepseek-ai/deepseek-harness"
TAG=""
PATTERN="dsh-v*"
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --pattern) PATTERN="${2:?--pattern needs a value}"; shift 2 ;;
    *) echo "update-dsh.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# Check the relative-input prerequisite before retargeting or locking sources.
nix_version=$(nix --version | awk '{ print $3 }')
if [ "$(printf '%s\n%s\n' '2.26' "$nix_version" | sort -V | head -1)" != '2.26' ]; then
  echo "update-dsh.sh: Nix >= 2.26 required for relative test-flake inputs (got $nix_version)" >&2
  exit 2
fi

emit() {
  # $1 KEY, $2 VALUE — stdout always, GITHUB_OUTPUT when present.
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

if [ -z "$TAG" ]; then
  # Latest tag matching the pattern, version-sorted. `^{}` lines are the
  # peeled commits of annotated tags — drop them, keep tag objects.
  TAG=$(git ls-remote --tags "https://github.com/${UPSTREAM_REPO}.git" "$PATTERN" \
    | awk '$2 !~ /\^\{\}$/ { sub("refs/tags/", "", $2); print $2 }' \
    | sort -V | tail -1)
  if [ -z "$TAG" ]; then
    echo "update-dsh.sh: no tags matching '$PATTERN' in ${UPSTREAM_REPO}" >&2
    exit 1
  fi
fi
echo "target tag: ${TAG}"

# True source version: package.json AT the tag, not floating main HEAD.
VERSION=$(curl -sfL "https://raw.githubusercontent.com/${UPSTREAM_REPO}/${TAG}/apps/cli/package.json" \
  | jq -r .version)
if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
  echo "update-dsh.sh: could not read version for tag ${TAG}" >&2
  exit 1
fi

# Tag -> commit SHA (peeled), for the lock-verification step below.
SHA=$(git ls-remote --tags "https://github.com/${UPSTREAM_REPO}.git" "$TAG" \
  | awk -v tag="refs/tags/${TAG}^{}" '$2 == tag { print $1 }' | head -1)
if [ -z "$SHA" ]; then
  # Lightweight tag: the ref line itself is the commit.
  SHA=$(git ls-remote --tags "https://github.com/${UPSTREAM_REPO}.git" "$TAG" \
    | awk -v tag="refs/tags/${TAG}" '$2 == tag { print $1 }' | head -1)
fi
if [ ! "$SHA" ] || [ "${#SHA}" -ne 40 ]; then
  echo "update-dsh.sh: could not resolve tag ${TAG} to a commit SHA" >&2
  exit 1
fi
echo "target sha: ${SHA:0:12} version: ${VERSION}"

# Current pin, rev-form or tag-form.
CURRENT_REF=$(grep -o "github:${UPSTREAM_REPO}/[^\"]*" flake.nix | head -1)
CURRENT_REF=${CURRENT_REF#"github:${UPSTREAM_REPO}/"}
echo "current pin: ${CURRENT_REF}"

if [ "$CURRENT_REF" != "$TAG" ]; then
  sed -i "s|github:${UPSTREAM_REPO}/[^\"]*|github:${UPSTREAM_REPO}/${TAG}|" flake.nix
  echo "flake.nix retargeted to ${TAG}"
fi

nix flake lock --update-input dsh

# Re-sync the tests subflake graph against the retargeted root WITHOUT
# bumping Home Manager or any unrelated input: a plain lock only
# re-resolves what moved (never `nix flake update` here).
nix flake lock ./tests

# The lock must resolve the tag to the exact immutable commit.
LOCKED_REV=$(nix flake metadata --no-update-lock-file --no-write-lock-file --json | jq -r '.locks.nodes.dsh.locked.rev')
if [ "$LOCKED_REV" != "$SHA" ]; then
  echo "update-dsh.sh: lock rev ${LOCKED_REV} != expected ${SHA}" >&2
  exit 1
fi
echo "lock verified: ${LOCKED_REV:0:12}"

# Owner-file guard: only flake.nix + flake.lock + tests/flake.lock may change.
# tests/flake.nix is owned by the test-flake author and is never touched here.
STRAY=$(git status --porcelain | awk '{ print $2 }' | grep -v -e '^flake\.nix$' -e '^flake\.lock$' -e '^tests/flake\.lock$' || true)
if [ -n "$STRAY" ]; then
  echo "update-dsh.sh: refusing to proceed with stray modifications:" >&2
  echo "$STRAY" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64) SYSTEM="x86_64-linux" ;;
  aarch64) SYSTEM="aarch64-linux" ;;
  *) echo "update-dsh.sh: unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

# Evaluated package version guard: the Nix package's own version must
# equal the upstream tag's CLI version BEFORE any build. A stale
# pkgs/dsh.nix `version` (owner file; this script never edits it) fails
# CLOSED here instead of burning a full build or publishing a
# mismatched lock.
EVAL_VERSION=$(nix eval --no-update-lock-file --no-write-lock-file --raw ".#packages.${SYSTEM}.dsh.version")
if [ "$EVAL_VERSION" != "$VERSION" ]; then
  echo "update-dsh.sh: BLOCKED — evaluated package version ${EVAL_VERSION} != upstream tag CLI version ${VERSION} for ${TAG}." >&2
  echo "The package owner must update \`version\` (+ pnpm \`hash\` if the lockfile moved) in" >&2
  echo "pkgs/dsh.nix (owner file; this script never edits it), then re-run." >&2
  echo "No PR is opened from a red gate." >&2
  exit 4
fi
echo "package version verified: ${EVAL_VERSION}"

# Real gates: build the package, then the root flake checks (profile
# artifacts, dsh boot checks, HM-independent module eval), then the tests
# flake check (pinned-HM regression), then the real host HM E2E.
# Evidence lives OUTSIDE the repo under scratch/runner temp — never
# ./build.log or ./result in the working tree (which would also trip
# the owner-file guard on re-runs). Nix exit codes propagate exactly.
UPDATE_TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dsh-update-$$"
mkdir -p "$UPDATE_TMP"
BUILD_LOG="$UPDATE_TMP/build.log"
RESULT_LINK="$UPDATE_TMP/result-dsh"
if nix build --no-update-lock-file --no-write-lock-file ".#packages.${SYSTEM}.dsh" --out-link "$RESULT_LINK" 2>"$BUILD_LOG"; then
  :
else
  rc=$?
  if grep -q "hash mismatch" "$BUILD_LOG"; then
    cat "$BUILD_LOG" >&2
    echo "update-dsh.sh: BLOCKED — pnpm store hash changed for ${TAG}." >&2
    echo "The package owner must update \`version\` + pnpm \`hash\` in" >&2
    echo "pkgs/dsh.nix (owner file; this script never edits it), then re-run." >&2
    echo "No PR is opened from a red build." >&2
    exit 3
  fi
  cat "$BUILD_LOG" >&2
  exit "$rc"
fi
echo "build evidence: ${BUILD_LOG} ${RESULT_LINK}"

nix flake check --no-update-lock-file --no-write-lock-file --system "$SYSTEM"
nix flake check ./tests --no-update-lock-file --no-write-lock-file --system "$SYSTEM"

# Real host Home Manager gate (same command as CI): must pass AFTER both
# flake checks and BEFORE changed=true is emitted. No shims, no
# skips — a red gate fails closed and no PR is opened.
HM_E2E_TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
TMPDIR="$HM_E2E_TMP" DSH_HM_E2E_ARTIFACT_DIR="$HM_E2E_TMP/dsh-hm-host-e2e" \
  nix develop ./tests --no-update-lock-file --no-write-lock-file -c bash scripts/hm-e2e.sh
echo "hm host e2e evidence: $HM_E2E_TMP/dsh-hm-host-e2e"

if git status --porcelain -- flake.nix flake.lock tests/flake.lock | grep -q .; then
  emit changed true
else
  emit changed false
  echo "already tracking ${TAG}; nothing to do"
fi
emit tag "$TAG"
emit sha "$SHA"
emit version "$VERSION"
