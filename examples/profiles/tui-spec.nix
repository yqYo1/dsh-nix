{ profilesLib, inBoxNames }:
profilesLib.mkProfileBundle {
  name = "tui-spec";
  inherit inBoxNames;
  plugins = [
    ("file:" + toString ./../plugins/tui-core)
  ];
  specsHash = "sha256-vzxN0nryp9XzH6jhaMIa1FjboUkEHsGoHi0w8tB4Zj8=";
}
