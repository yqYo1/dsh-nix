{ plugins, profilesLib, inBoxNames }:
profilesLib.mkProfile {
  name = "tui";
  inherit inBoxNames;
  plugins = [
    (plugins.mkBundle {
      path = ./../plugins/tui-core;
    })
  ];
}
