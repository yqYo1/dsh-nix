# Testing dsh-nix

The test harness is split into two flakes:

- **Root flake**: non-test checks only — `treefmt` and `version-consistency`.
- **`tests/` flake**: test-only checks, plus the pinned Home Manager harness.

## Commands

```sh
# Formatting and version consistency.
nix flake check

# Profile, bundle, module and pinned Home Manager checks.
nix flake check ./tests

# Real Home Manager activation regression (three generations).
scripts/hm-activation-contract.sh

# Host-level Home Manager E2E (real activation, profile install and dsh boot).
nix develop ./tests -c bash scripts/hm-e2e.sh
```

Local flake checks read Git-tracked files only. `scripts/test.sh` rejects
untracked, non-ignored files before running the two flake checks.

## Test files

- `tests/checks.nix` — profile composition, bundle resolution, official
  catalog, boot checks and the runtime-artifact cleanliness guard.
- `tests/hm-real.nix` — real `lib.homeManagerConfiguration` evaluation and
  three actual activation generations; run by
  `scripts/hm-activation-contract.sh`.
- `tests/hm-host.nix` — host fixture for `scripts/hm-e2e.sh`; real packaged
  dsh, real Home Manager and the host Nix CLI.
- `tests/profile-regression.nix` — offline profile artifact composition,
  patch projection, ordering and duplicate-name failures.
- `tests/plugin-roots.nix` — production plugin-root and patch selection.
- `tests/user-npm.nix` — raw `buildNpmPackage` plugin roots and closure.
- `tests/home-module.nix` — module evaluation, template/profile separation
  and activation-script structure.
- `tests/boot-checker.nix` and `tests/boot-checker-wiring.mjs` — checker
  contract wiring; separate from real-package boot checks.

`boot-checker-wiring.mjs` uses a mock dsh installation whose modules record
the checker's calls. It verifies the checker's prepare → resolve → compose →
boot+dispose wiring and fail-loud propagation, but does not prove a real
pinned-dsh boot. A real-headless no-network guard remains a separate fixture
decision.

- `tests/test-flake-contract.nix` — the root/tests flake separation contract.
