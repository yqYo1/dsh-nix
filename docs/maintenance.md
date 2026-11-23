# Maintenance scripts

## update-dsh.sh

Retargets the root `dsh` flake input to a released `dsh-v*` tag, re-locks the
root and tests subflakes, verifies the locked commit and evaluated package
version, then runs the package build, root/tests flake checks and host Home
Manager E2E.

The script never edits package-owner files (`pkgs/dsh.nix`, `modules/`, `lib/`
or profiles) or `tests/flake.nix`. If the version or pnpm store hash is stale,
it fails closed with a pointer for the package owner. Only `flake.nix`,
`flake.lock` and `tests/flake.lock` may be modified; any other change aborts
the run. Build evidence stays outside the repository.

Usage:

```sh
scripts/update-dsh.sh [--tag TAG] [--pattern 'dsh-v*']
```

It emits `tag`, `sha`, `version` and `changed` KEY=VALUE lines to
`GITHUB_OUTPUT` when that file exists. Exit 0 means updated/already current;
non-zero means a gate failed.

Commits created by automation from this result are unsigned. Automation must
stop before push/PR if signed commits are required; never invent keys or
bypass protection.

## check-profile

`scripts/check-profile.ts` boots a composed profile with dsh's own `boot()`
and disposes it. A non-zero exit means the tree failed to settle or an entry
stayed pending/failed; a requested app exit is recorded and fails the check.
It mirrors the pinned `apps/cli/src/profile-boot.ts` sequence without a heal
step. It checks boot and disposal only; it does not prove that a plugin did not
schedule fire-and-forget work.

Usage: `check-profile <dsh-install> <profile-name> <dsh-home> [args...]`. The compiled entry point is `check-profile.mjs`.
See [TESTING.md](../TESTING.md) for how the checks invoke it.
