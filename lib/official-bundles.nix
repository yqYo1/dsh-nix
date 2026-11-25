# The official bundle catalog used by this repository.
#
# This file is generated from the built `@deepseek-ai/dsh-official-bundles`
# export by scripts/generate-official-bundles.ts.  Upstream remains the source
# of truth; do not hand-edit lib/official-bundles.json.
{ lib }:
let
  catalog = builtins.fromJSON (builtins.readFile ./official-bundles.json);
in
{
  inherit (catalog) profileTemplates optional onDemand;

  # Derived values keep the catalog shape and the accepted in-box names in
  # lockstep; consumers no longer recompute the relationship themselves.
  inBoxNames = lib.unique (
    builtins.concatLists (builtins.attrValues catalog.profileTemplates) ++ catalog.optional
  );
  profileTemplateNames = builtins.attrNames catalog.profileTemplates;
}
