# Target-composition fixture: in-box base + web-app with the dsh-codex spec
# and an llm-openai-codex user layer ({searchMode=live;
# useNativeCompaction=true}).
#
# Declaration-only: `nix-instantiate --eval` checks the classification
# (in-box vs spec, layer order) with no build and no network.  The full
# artifact build pins specsHash once the FOD discovery reports it:
#   nix build --impure --expr \
#     '(import ./tests/fixtures/codex-spec.nix { pkgs = ...; })'
# then replace SPECS_HASH below with the reported `got: sha256-…` value and
# buildProfileBundle the result.
{ profilesLib, inBoxNames }:
profilesLib.mkProfileBundle {
  name = "codex";
  inherit inBoxNames;
  plugins = [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
    "dsh-codex@0.3.2"
  ];
  userPatches = [
    {
      id = "llm-openai-codex";
      config = {
        searchMode = "live";
        useNativeCompaction = true;
      };
    }
  ];
  specsHash = "sha256-uBKkJroE8dj6/pytUiIgYp8CyjrNtUVfmksMeL1bgWg=";
}
