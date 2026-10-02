# Fixture: resolve the fixed-output hash for the dsh-codex spec.
# Pass hash = "" for discovery; Nix reports the resulting fixed-output hash.
{ pkgs, hash ? "sha256-cPgMA5DkYZcaRQNB7ql/v4UNWY0ct7s8cRaFXXu5Hjc=" }:

let
  lib = pkgs.lib;
  pluginsLib = import ../../lib/plugins.nix { inherit lib; };
in
pluginsLib.fetchSpecs {
  inherit pkgs;
  specs = [ "dsh-codex@0.3.2" ];
  inherit hash;
}
