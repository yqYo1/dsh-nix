# Optional example: inject dsh's own shipped bundles (a non-flake repo input)
# into a profile with zero transcription of their rows.  Activate by making
# the dsh checkout visible to the flake, then wire `profiles.dsh-web` into
# flake outputs.  Import this file with the enclosing flake's plugin/profile
# libraries; in-box names resolve from the `inBoxNames` your module passes.
{ plugins, profilesLib, inBoxNames ? [ ], ... }:
if ! builtins.pathExists ../../dsh/packages/bundle/base then
  null
else
  profilesLib.mkProfile {
    inherit inBoxNames;
    name = "dsh-web";
    plugins = [
      (plugins.mkBundle {
        path = ../../dsh/packages/bundle/base;
      })
      (plugins.mkBundle {
        path = ../../dsh/packages/bundle/web-app;
      })
    ];
  }
