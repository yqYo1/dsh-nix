{ profilesLib, inBoxNames }:
profilesLib.mkProfileBundle {
  name = "tui-spec";
  inherit inBoxNames;
  plugins = [
    ("file:" + toString ./../plugins/tui-core)
  ];
  specsHash = "sha256-+kqyHRBzpioMmGNcdoEf44vlsjW7UZRTwdfAPiKCzAc=";
}
