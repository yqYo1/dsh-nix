{ profilesLib, inBoxNames }:
profilesLib.mkProfileBundle {
  name = "tui-spec";
  inherit inBoxNames;
  plugins = [
    ("file:" + toString ./../plugins/tui-core)
  ];
  specsHash = "sha256-KqekPIpuqDlumzonwsRWWgB1mIY4KciSJBG2h86z/2w=";
}
