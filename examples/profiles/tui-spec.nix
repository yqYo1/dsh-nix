# Frozen file: spec example: the local tui-core plugin with a real generated
# lock (tui-spec-pnpm-lock.yaml, pnpm 11.27.0, specifier
# file:/build/spec-inputs/0 matching the builder's contextualSpec index 0).
# The runtime FOD hash is discovered by building with specsHash = "" and
# replacing it with the reported `got: sha256-…` value.
{ profilesLib, inBoxNames }:
profilesLib.mkProfileBundle {
  name = "tui-spec";
  inherit inBoxNames;
  plugins = [
    ("file:" + toString ./../plugins/tui-core)
  ];
  specsLock = ./tui-spec-pnpm-lock.yaml;
  specsHash = "sha256-4scbQ87kyUz4f9epsH3ItSrRvYmrx39pHAIEPpW2LdQ=";
}
