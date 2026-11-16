{ pkgs, ... }:
{
  projectRootFile = "flake.nix";
  programs = {
    nixfmt.enable = true;
    deadnix.enable = true;
    statix.enable = true;
    shellcheck.enable = true;
    shellcheck.severity = "warning";
    shfmt.enable = true;
    actionlint.enable = !pkgs.stdenv.hostPlatform.isDarwin;
    prettier.enable = true;
  };
  settings.formatter.prettier.includes = [
    "*.cjs"
    "*.js"
    "*.json"
    "*.md"
    "*.mjs"
    "*.yaml"
    "*.yml"
  ];
  # Lockfiles are generated; reformatting them creates noise and can change
  # the exact text consumers expect.
  settings.formatter.prettier.excludes = [
    "**/*-lock.yaml"
    "**/package-lock.json"
    "**/pnpm-lock.yaml"
  ];
}
