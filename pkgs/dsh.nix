# The DeepSeek Harness CLI as a Nix package: pnpm monorepo build of the
# deepseek-harness repo, producing `bin/dsh`.
#
# - `fetchPnpmDeps` materialises the pnpm store from pnpm-lock.yaml.
# - `pnpmConfigHook` points the offline install at that store.
# - The HMR service requires Node internals access, so the wrapper launches
#   node with `--expose-internals` (dsh itself never sets this flag).
# - `dsh plugin` forwards to pnpm on PATH (default command `pnpm`), so the
#   wrapper prefixes a private pnpm_11 (matching upstream packageManager
#   pnpm@11) plus nodejs for child execution. HM `cfg.package` is untouched.
{ lib
, stdenv
, nodejs
, pnpm_11
, pnpmConfigHook
, fetchPnpmDeps
, makeBinaryWrapper
, python3
, node-gyp
, src
}:

let
  version = "0.2.0-rc.2";
  # rc.8+ embeds the source commit into client artifacts by shelling out to
  # `git rev-parse HEAD`.  The nix build is a gitless tarball with no `git`
  # in the environment, so we feed the pinned rev instead — the dsh build
  # script honours DSH_CLIENT_COMMIT_HASH and skips the git call entirely.
  dshCommitHash = if src ? rev
    then src.rev
    else throw "dsh.nix: source has no .rev to embed as DSH_CLIENT_COMMIT_HASH";
  pnpmDeps = fetchPnpmDeps {
    pname = "deepseek-harness";
    inherit version src;
    fetcherVersion = 4;
    hash = "sha256-26wDKJYpsyz55zCe9qqn0vVbs+JI/Wi3c4EXYbffDNk=";
  };
in
stdenv.mkDerivation {
  pname = "dsh";
  inherit version src;

  nativeBuildInputs = [ nodejs pnpm_11 pnpmConfigHook makeBinaryWrapper python3 node-gyp ];
  inherit pnpmDeps;
  env.DSH_CLIENT_COMMIT_HASH = dshCommitHash;

  buildPhase = ''
    runHook preBuild
    pnpm install --offline --frozen-lockfile
    # node-pty ships no linux prebuilds in its npm tarball, so its install
    # script must fall back to node-gyp — which needs python3 and the node
    # headers. Build it explicitly: pty.node and the unix spawn-helper both
    # come out of this rebuild, and the dsh patch loads both from
    # build/Release.
    (
      cd node_modules/.pnpm/node-pty@*/node_modules/node-pty
      export HOME="$TMPDIR"
      export npm_config_nodedir=${nodejs}
      export npm_config_python=python3
      node-gyp rebuild
    )
    pnpm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    # The CLI resolves workspace packages through the pnpm node_modules
    # layout at runtime, so ship the built repo together with node_modules.
    cp -r . "$out/"
    rm -rf "$out/.git" "$out/.github" "$out/website" \
      "$out/.agents" "$out/.claude" \
      "$out/node_modules/.pnpm/node_modules/@deepseek-ai/website" \
      "$out/node_modules/.cache"
    mkdir -p "$out/bin"
    # rc.2 Node builtin compat: ship the narrowly-triggered
    # `--expose-internals` fallback preload next to the CLI and load it
    # before the entrypoint. Paths derive from $out at build time.
    install -Dm444 "${./dsh-builtin-compat.cjs}" "$out/lib/dsh-builtin-compat.cjs"
    makeBinaryWrapper "${nodejs}/bin/node" "$out/bin/dsh" \
      --add-flags "--expose-internals" \
      --add-flags "--require $out/lib/dsh-builtin-compat.cjs" \
      --add-flags "$out/apps/cli/lib/bin.js" \
      --prefix PATH : "${lib.makeBinPath [ pnpm_11 nodejs ]}" \
      --append-flags ""
    runHook postInstall
  '';

  meta = {
    description = "DeepSeek Harness CLI (dsh)";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = lib.platforms.all;
  };
}
