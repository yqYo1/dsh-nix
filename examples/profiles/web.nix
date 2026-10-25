{ profilesLib, inBoxNames }:
profilesLib.mkProfile {
  name = "web";
  inherit inBoxNames;
  plugins = [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
  ];
}
