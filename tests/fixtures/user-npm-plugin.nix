# Reusable genuine user-declared buildNpmPackage fixture.
#
# A user declares their DSH plugin with plain pkgs.buildNpmPackage and
# passes the RAW derivation straight into `plugins` (see
# tests/user-npm.nix). The manifest name (@dsh-poc/user-npm-plugin)
# deliberately differs from the derivation pname
# (dsh-poc-npm-user-pkg), so the resolver is proven to read the installed
# root instead of the derivation name. Real registry dependency chain:
# is-odd -> is-number. The "./plugin" export exists so the lifecycle
# truly activates under rc.2.
#
# Args: { pkgs }. `src` is the ./user-npm-plugin directory next to this
# file (byte copy of the verified fixture); `npmDepsHash` is the real FOD
# hash reported by the actual dependency fetch, never invented.
{ pkgs }:

pkgs.buildNpmPackage {
  pname = "dsh-poc-npm-user-pkg";
  version = "1.0.0";
  src = ./user-npm-plugin;
  npmDepsHash = "sha256-3poAcUcdS+zIeBSwyuYdrZW3pB4H4bli+bMU6RCaPT0=";
  dontNpmBuild = true;
}
