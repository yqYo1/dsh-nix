{
  lib,
  stdenv,
  nodejs,
  pnpm_11,
  patchedAddon ? null,
  pnpmConfigHook,
  fetchPnpmDeps,
  makeBinaryWrapper,
  python3,
  node-gyp,
  jq,
  typescript,
  src,
}:

let
  version = "0.2.2-rc.3";
  # The dsh client build embeds the source commit into client artifacts by
  # shelling out to `git rev-parse HEAD`.  The nix
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
      typescript
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
        nodepty=$(cd packages/subprocess/subprocess-local && node -p "require.resolve('node-pty/package.json')")
        cd "$(dirname "$nodepty")"
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
      compat=$(mktemp -d)
      cp "${./dsh-builtin-compat.ts}" "$compat/dsh-builtin-compat.ts"
      (cd "$compat" && tsc --target ES2022 --module commonjs --skipLibCheck \
        --outDir "$compat" dsh-builtin-compat.ts)
      install -Dm444 "$compat/dsh-builtin-compat.js" "$out/lib/dsh-builtin-compat.cjs"
      cp "${../lib/read-profile-template.ts}" "$out/lib/read-profile-template.ts"
      (cd "$out/lib" && tsc --ignoreConfig --target ES2022 --module ESNext --moduleResolution bundler --skipLibCheck \
        --outDir "$out/lib" read-profile-template.ts)
      rm "$out/lib/read-profile-template.ts"
      mv "$out/lib/read-profile-template.js" "$out/lib/read-profile-template.mjs"
      runHook postInstall
    '';

    passthru = {
      inherit pnpmDeps;
    };
  };

  # Runtime source view: only the built apps, packages and metadata needed by
  # the user package.  Its direct input is small; the full dshBuild closure
  # remains a build/test input.
  dshRuntimeSrc = stdenv.mkDerivation {
    pname = "dsh-runtime-src";
    inherit version;
    src = dshBuild;
    dontCheckForBrokenSymlinks = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/apps"
      cp -r "$src/apps/cli" "$src/apps/web" "$out/apps/"
      cp -r "$src/packages" "$src/vendor" "$src/native" "$src/scripts" \
        "$src/lib" "$src/package.json" "$src/pnpm-lock.yaml" \
        "$src/pnpm-workspace.yaml" "$src/patches" "$out/"
      chmod -R u+w "$out"
      # Package-local pnpm views are required for workspace peer resolution;
      # only the root view is rebuilt by the runtime production install.
      rm -rf "$out/node_modules"
      # The build tree contains test-only workspace packages and test source;
      # they are not part of the runtime package.
      rm -rf "$out/packages/test-support"
      find "$out" -type d -name tests -prune -exec rm -rf {} +
      runHook postInstall
    '';
  };
in
stdenv.mkDerivation {
  pname = "dsh";
  inherit version;
  src = dshRuntimeSrc;
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
    # Remove test-runner views that the production install may have carried
    # through the package-local pnpm layout.
    find "$out" -path '*/node_modules/.pnpm/*' \
      \( -name 'vitest*' -o -name '@vitest*' -o -name 'playwright*' \
         -o -name 'jsdom*' -o -name '@testing-library*' -o -name 'fast-check*' \) \
      -prune -exec rm -rf {} + || true
    find "$out" -path '*/node_modules/.bin/vitest' -delete || true
    find "$out" -type d \
      \( -name 'vitest' -o -name '@vitest' -o -name 'playwright' \
         -o -name 'jsdom' -o -name '@testing-library' -o -name 'fast-check' \) \
      -prune -exec rm -rf {} + || true

    # `dsh-web` imports `zod` from its typert host/client entries without
    # declaring it as a direct dependency.  pnpm's isolated layout keeps it
    # under .pnpm only, so expose the single installed copy at the runtime
    # root; package-local imports then resolve through Node's lookup.
    zod_dir=$(find "$out/node_modules/.pnpm" -maxdepth 1 -type d -name 'zod@*' -print | sort -V | tail -1)
    if [ -n "$zod_dir" ]; then
      ln -s ".pnpm/$(basename "$zod_dir")/node_modules/zod" "$out/node_modules/zod"
    fi

    ${
      if patchedAddon == null then
        ""
      else
        ''
          addon_abi=${if stdenv.hostPlatform.isAarch64 then "linux-arm64-gnu" else "linux-x64-gnu"}
          addon_pkg=$(find "$out/node_modules/.pnpm" -type d \
            -path "*/node_modules/node-addon-require-builtin-''${addon_abi}" -print -quit)
          if [ -z "$addon_pkg" ]; then
            echo "patched addon: node-addon-require-builtin-''${addon_abi}@0.1.9 not found" >&2
            exit 1
          fi
          install -Dm444 "${patchedAddon}/lib/require_builtin.node" \
            "$addon_pkg/prebuilt/''${addon_abi}-napi-v9.node"
        ''
    }

    mkdir -p "$out/bin" "$out/lib"
    install -Dm444 "${dshBuild}/lib/dsh-builtin-compat.cjs" "$out/lib/dsh-builtin-compat.cjs"
    install -Dm444 "${dshBuild}/lib/read-profile-template.mjs" "$out/lib/read-profile-template.mjs"
    makeBinaryWrapper "${nodejs}/bin/node" "$out/bin/dsh" \
      ${
        if patchedAddon == null then
          ''--add-flags "--expose-internals" --add-flags "--require $out/lib/dsh-builtin-compat.cjs"''
        else
          ""
      } \
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
    node --expose-internals --require "${dshBuild}/lib/dsh-builtin-compat.cjs" \
      "${dshBuild}/lib/read-profile-template.mjs" "${dshBuild}" \
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
