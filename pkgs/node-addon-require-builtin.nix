{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchzip,
  nodejs,
  node-gyp,
  python3,
}:

let
  nodeAddonApi = fetchzip {
    url = "https://registry.npmjs.org/node-addon-api/-/node-addon-api-8.9.0.tgz";
    hash = "sha256-H4SW+H3PwHs/duMnKxAmjrs552fdlUVNA8pTgck9hr0=";
  };
in
stdenv.mkDerivation {
  pname = "node-addon-require-builtin-patched";
  version = "0.1.9";

  src = fetchFromGitHub {
    owner = "deepseek-ai";
    repo = "dsh-node-addon-require-builtin";
    rev = "a58d3599a2e551d7d706d1ff796c9fd4bbaff63c";
    hash = "sha256-48SWhkHOM0BOpeWWYqLs49GUNgMKz3mekGnkpzEzNmY=";
  };

  patches = [ ./node-addon-require-builtin-gcc16.patch ];

  nativeBuildInputs = [
    nodejs
    node-gyp
    python3
  ];

  buildPhase = ''
    runHook preBuild
    mkdir -p node_modules
    cp -a ${nodeAddonApi} node_modules/node-addon-api
    chmod -R u+w node_modules
    cd packages/native
    node-gyp configure --napi_version=9 --nodedir=${nodejs} --narb_product=require-builtin
    node-gyp build -j"$NIX_BUILD_CORES"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib"
    install -Dm444 build/Release/require_builtin.node "$out/lib/require_builtin.node"
    runHook postInstall
  '';

  meta = {
    description = "Patched node-addon-require-builtin for GCC 16 x64 getters";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
