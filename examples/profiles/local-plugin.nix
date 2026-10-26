{ plugins, profilesLib, inBoxNames }:
profilesLib.mkProfile {
  name = "local-plugin";
  inherit inBoxNames;
  plugins = [
    (plugins.mkBundle {
      path = ./../plugins/lifecycle-probe;
    })
  ];
}
