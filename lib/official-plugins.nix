# Pins for the OFFICIAL on-demand dsh bundles.
#
# dsh ships these two bundles through its on-demand catalog instead of the
# installation (their provider runtimes are costly), so an installation cannot
# resolve them by name.  This repository builds each one from its published
# npm tarball at the exact host version, with a committed pnpm lockfile and a
# fixed pnpm-store hash, and hands the result to profile composition like any
# Nix-package plugin.  Users write the bare package name; maintaining the pin
# is this repository's job (update-dsh flow).
#
# Regenerating a pin for a new dsh tag:
#   1. version = the tag's version; tarballHash = `npm view <name>@<version> dist.integrity`
#   2. lockfile: take the published tarball's package.json, drop
#      devDependencies/scripts/packageManager, add pnpm-workspace.yaml with
#      `autoInstallPeers: false`, run `pnpm install --lockfile-only
#      --ignore-scripts`, and commit the lockfile here.
#   3. depsHash: build with "" and copy the reported `got:` hash.
{ lib }:

let
  pin =
    { version
    , tarballHash
    , depsHash
    , lock
    }:
    {
      inherit version tarballHash depsHash;
      lockFile = lock;
    };
in
{
  names = [
    "@deepseek-ai/dsh-subagent-codex"
    "@deepseek-ai/dsh-subagent-claude-code"
  ];

  pins = {
    "@deepseek-ai/dsh-subagent-codex" = pin {
      version = "0.2.1-rc.2";
      tarballHash = "sha512-ajbb0gFeDwNHE4cqKlFxmP77xsm6XsG2L55YDHWTSZVTjK3t6iSlmpwLY2tI08F7hkez6jgv4MqkVswC6IAQXA==";
      depsHash = "sha256-LvcBcdf2yB2lK5mwTMhJn/9itF+N52gsFljvrNZH5h8=";
      lock = ../official/dsh-subagent-codex/pnpm-lock.yaml;
    };
    "@deepseek-ai/dsh-subagent-claude-code" = pin {
      version = "0.2.1-rc.2";
      tarballHash = "sha512-iyfQyKN+gM/gxS12uh904ddo7jbW7ezyerYWVStZf/bsLQ26hUwxf89sMv6sF1kuVTt+Zi9nOkjbA/tbM89nWA==";
      depsHash = "sha256-jNVxN9wLeAJylAsdYw4dFN3z7Zyfs9WdIwK/HNIGsTA=";
      lock = ../official/dsh-subagent-claude-code/pnpm-lock.yaml;
    };
  };
}
