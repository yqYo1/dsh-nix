# Target-composition fixture: in-box base + web-app with the dsh-codex spec
# and an llm-openai-codex user layer ({searchMode=live;
# useNativeCompaction=true}).
#
# Declaration-only: `nix-instantiate --eval` checks the classification
# (in-box vs spec, layer order) with no build and no network.  The lock
# (tests/fixtures/codex-pnpm-lock.yaml, generated with pnpm 11.27.0) pins
# the full graph; the runtime FOD hash is discovered by building with
# specsHash = "" and replacing it with the reported `got: sha256-…` value.
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
  specsLock = ./codex-pnpm-lock.yaml;
  specsHash = "sha256-ndnvYvDgL6iNOR8u1JM38NiYg/dmpUCw9HmxUzqKeJg=";
}
