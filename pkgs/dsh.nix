# The DeepSeek Harness CLI as a Nix package: a build derivation with the
# full development closure, and a separate runtime derivation that consumes
# only the built workspace and a production dependency closure.
#
# - `fetchPnpmDeps` materialises the pnpm store from pnpm-lock.yaml.  Call
#   sites override it with the pinned fetch support (flake input
#   `nixpkgs-fetch`): the output hash below is bound to the fetch script
#   text, so this fetch must not be instantiated from a consumer-overridden
#   nixpkgs.
# - `pnpmConfigHook` points the offline install at that store.
# - The HMR service requires Node internals access, so the wrapper launches
#   node with `--expose-internals` (dsh itself never sets this flag).
# - `dsh plugin` forwards to pnpm on PATH (default command `pnpm`), so the
#   wrapper prefixes a private pnpm_11 (matching upstream packageManager
#   pnpm@11) plus nodejs for child execution. HM `cfg.package` is untouched.
{
  lib,
  stdenv,
  nodejs,
  pnpm_11,
  pnpmConfigHook,
  fetchPnpmDeps,
  makeBinaryWrapper,
  python3,
  node-gyp,
  jq,
  src,
}:

let
  version = "0.2.2-rc.3";
  # The dsh client build embeds the source commit into client artifacts by
  # shelling out to `git rev-parse HEAD` (since dsh 0.1.0-rc.8).  The nix
  # build is a gitless tarball with no `git` in the environment, so we feed
  # the pinned rev instead — the dsh build script honours
  # DSH_CLIENT_COMMIT_HASH and skips the git call entirely.
  dshCommitHash = src.rev or (throw "dsh.nix: source has no .rev to embed as DSH_CLIENT_COMMIT_HASH");
  pnpmDeps = fetchPnpmDeps {
    pname = "deepseek-harness";
    inherit version src;
    fetcherVersion = 4;
    hash = "sha256-dJNfmdcjq6UOvxeAvUSRtgLGxqcF6TVSFrEEh5gBi+k=";
  };

  # Build-time closure: devDependencies, TypeScript, node-gyp and tests are
  # all legitimate here.  Its output is the complete built workspace used by
  # the test harness and profile composition; it is never the user runtime.
  dshBuild = stdenv.mkDerivation {
    pname = "dsh-build";
    inherit version src;

    nativeBuildInputs = [
      nodejs
      pnpm_11
      pnpmConfigHook
      python3
      node-gyp
      jq
    ];
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
      cp -r . "$out/"
      rm -rf "$out/.git" "$out/.github" "$out/website" \
        "$out/.agents" "$out/.claude" \
        "$out/node_modules/.pnpm/node_modules/@deepseek-ai/website" \
        "$out/node_modules/.cache"
      mkdir -p "$out/share/dsh-nix"
      find "$out" -path '*/node_modules' -prune -o -name package.json -print \
        | while IFS= read -r manifest; do
            name=$(jq -r '.name // empty' "$manifest" 2>/dev/null) || continue
            [ -n "$name" ] || continue
            printf '%s\t%s\n' "$name" "$(dirname "$manifest")"
          done \
        | sort -u > "$out/share/dsh-nix/bundles.tsv"
      install -Dm444 "${./dsh-builtin-compat.cjs}" "$out/lib/dsh-builtin-compat.cjs"
      runHook postInstall
    '';

    passthru = {
      inherit pnpmDeps;
    };
  };
in
stdenv.mkDerivation {
  pname = "dsh";
  inherit version;
  src = dshBuild;
  outputs = [
    "out"
    "profileMeta"
  ];
  # The production workspace still carries pnpm peer/type links that are not
  # runtime dependencies; remove the dangling ones instead of shipping an
  # unnecessary full development tree.
  dontCheckForBrokenSymlinks = true;

  # Runtime build inputs only: no TypeScript, node-gyp, python3 or test tools.
  nativeBuildInputs = [
    nodejs
    pnpm_11
    pnpmConfigHook
    makeBinaryWrapper
    jq
  ];
  inherit pnpmDeps;
  env.CI = "true";
  pnpmInstallFlags = [ "--prod" ];
  postUnpack = ''
    find "$sourceRoot" -type d -name node_modules -prune -exec rm -rf {} +
  '';

  installPhase = ''
    runHook preInstall

    # Consume only the built workspace, and copy only the apps and packages
    # that the CLI runtime needs.  The full dshBuild output remains the
    # test/dev-only derivation.
    mkdir -p "$out/apps"
    cp -r "$src/apps/cli" "$src/apps/web" "$out/apps/"
    cp -r "$src/packages" "$src/vendor" "$src/native" "$src/scripts" \
      "$src/package.json" "$src/pnpm-lock.yaml" "$src/pnpm-workspace.yaml" \
      "$src/patches" "$out/"
    chmod -R u+w "$out"
    pnpm --dir "$out" --recursive --prod install --offline --frozen-lockfile \
      --ignore-scripts --config.confirm-modules-purge=false

    mkdir -p "$out/bin" "$out/lib"
    install -Dm444 "${./dsh-builtin-compat.cjs}" "$out/lib/dsh-builtin-compat.cjs"
    makeBinaryWrapper "${nodejs}/bin/node" "$out/bin/dsh" \
      --add-flags "--expose-internals" \
      --add-flags "--require $out/lib/dsh-builtin-compat.cjs" \
      --add-flags "$out/apps/cli/lib/bin.js" \
      --prefix PATH : "${
        lib.makeBinPath [
          pnpm_11
          nodejs
        ]
      }"

    # Small metadata for profile generation, derived from the full build
    # output rather than from the runtime installation.
    mkdir -p "$profileMeta/share/dsh-nix"
    node --expose-internals --require "$src/lib/dsh-builtin-compat.cjs" \
      "${../lib/read-profile-template.mjs}" "$src" \
      > "$profileMeta/share/dsh-nix/profile-templates.json"
    runHook postInstall
  '';

  # Exposed so consumers and tests can target the pinned FOD and the full
  # build/test tree directly.
  passthru = {
    inherit pnpmDeps;
    dev = dshBuild;
  };

  meta = {
    description = "DeepSeek Harness CLI (dsh)";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = lib.platforms.linux;
  };
}
