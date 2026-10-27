{ profilesLib, inBoxNames }:
profilesLib.mkProfile {
  name = "headless";
  inherit inBoxNames;
  plugins = [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-headless"
  ];
}
