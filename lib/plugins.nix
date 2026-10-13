{ lib }:

let
  mkPluginBundle =
    {
      packageName ? null,
      path,
      patchPath ? null,
      ...
    }:
    let
      packagePath = if builtins.isPath path then builtins.path { inherit path; } else path;
      # Only local directories are inspectable at evaluation time.  A raw
      # derivation (or any non-path package) defers package.json name/patch
      # resolution to build time, where buildProfileBundle reads package.json
      # with jq (no IFD).  An explicit patchPath forces layer membership at
      # build time; otherwise the manifest's dsh.bundle.patch declaration
      # decides (plain deps stay inactive).
      inspectable = builtins.isPath path;
      manifest =
        if inspectable then
          let
            manifestPath = "${toString path}/package.json";
          in
          if builtins.pathExists manifestPath then
            builtins.fromJSON (builtins.readFile manifestPath)
          else
            throw "dsh plugin bundle: missing package.json at ${manifestPath}"
        else
          null;
      resolvedPackageName = if packageName != null then packageName else manifest.name or null;
      # Raw Nix packages (derivations) are not inspectable at evaluation time:
      # reading their package.json would be IFD.  Defer the missing-name
      # error to buildProfileBundle, which reads package.json at build time.
      checkedPackageName =
        if resolvedPackageName == null || resolvedPackageName == "" then
          if manifest == null then null
          else
            throw "dsh plugin bundle: packageName is required (set it explicitly or provide package.json name)"
        else
          resolvedPackageName;
      declaredPatch =
        if manifest == null then null else (((manifest.dsh or { }).bundle or { }).patch or null);
      # Carry Nix path context for explicit patch files: a path-typed
      # patchPath (e.g. ./cordis.patch.yml) must materialise into the store
      # so the build sandbox can see it; relative strings stay verbatim as
      # package-relative manifest values.
      explicitPatch =
        if patchPath == null then null
        else if builtins.isPath patchPath then builtins.path { path = patchPath; }
        else patchPath;
      resolvedPatchPath = if explicitPatch != null then explicitPatch else declaredPatch;
    in
    {
      packageName = checkedPackageName;
      inherit packagePath;
      patchPath = resolvedPatchPath;
      # Raw explicit selection (null when the caller did not pass patchPath):
      # projection triggers only on this, never on a manifest-declared patch.
      inherit explicitPatch;
      isLayer = resolvedPatchPath != null;
    };

  classifyPlugin =
    {
      inBoxNames ? [ ],
      plugin,
    }:
    if builtins.isString plugin then
      if builtins.elem plugin inBoxNames then
        {
          kind = "in-box";
          name = plugin;
        }
      else
        {
          kind = "spec";
          spec = plugin;
        }
    else if builtins.isAttrs plugin && plugin ? packageName && plugin ? packagePath then
      {
        kind = "nix";
        inherit plugin;
      }
    else
      {
        kind = "nix";
        plugin = mkPluginBundle { path = plugin; };
      };

  fetchSpecs =
    {
      pkgs,
      specs,
      hash ? "",
      specsLock ? null,
    }:
    let
      # Preserve store-path context for file: specs.  Without this explicit
      # builtins.storePath reference, the fixed-output derivation has no input
      # source and sandboxed pnpm cannot see the local package.
      contextualSpecs = lib.imap0 (
        index: spec:
        if lib.hasPrefix "file:/nix/store/" spec then "file:/build/spec-inputs/${toString index}" else spec
      ) specs;
      specCopies = lib.concatStringsSep "\n" (
        lib.imap0 (
          index: spec:
          if lib.hasPrefix "file:/nix/store/" spec then
            let
              source = builtins.path { path = lib.removePrefix "file:" spec; };
            in
            ''
              mkdir -p /build/spec-inputs
                          cp -rL ${lib.escapeShellArg (toString source)} ${lib.escapeShellArg "/build/spec-inputs/${toString index}"}''
          else
            ""
        ) specs
      );
      specsOrigJson = builtins.toJSON specs;
      specsCtxJson = builtins.toJSON contextualSpecs;
      lockSource = if specsLock == null then null else builtins.path { path = specsLock; };
      lockArg = if lockSource == null then "" else lib.escapeShellArg (toString lockSource);
    in
    pkgs.stdenv.mkDerivation {
      name = "dsh-spec-plugins";
      outputHashMode = "recursive";
      # An empty hash is the discovery mode: fakeHash lets evaluation proceed
      # and Nix reports the actual recursive hash at build time.
      outputHash = if hash == "" then lib.fakeHash else hash;
      nativeBuildInputs = [
        pkgs.cacert
        pkgs.nodejs
        pkgs.pnpm_11
        pkgs.yq-go
        pkgs.jq
      ];
      impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars ++ [ "NIX_NPM_REGISTRY" ];
      buildCommand = ''
        # The fixed-output sandbox does not inherit the caller's CA file.
        # Use the Nix CA bundle; retain certificate verification for pnpm.
        export NODE_EXTRA_CA_CERTS="$NIX_SSL_CERT_FILE"
        export HOME=/build/home
        mkdir -p "$HOME"
        pnpm config set store-dir /build/pnpm-store >/dev/null
        # pnpm 11 ambient-version behaviour (mirrors nixpkgs fetchPnpmDeps):
        # never auto-download another pnpm, never cache platform artefacts in
        # the fixed-output hash, never hit the update notifier.
        export pnpm_config_pm_on_fail=ignore
        export pnpm_config_side_effects_cache=false
        export pnpm_config_update_notifier=false
        mkdir -p /build/project
        cd /build/project
        printf '%s\n' \
          'packages:' \
          '  - .' \
          'strictDepBuilds: false' \
          > pnpm-workspace.yaml
        ${specCopies}
        printf '%s' ${lib.escapeShellArg specsOrigJson} > /build/specs-orig.json
        printf '%s' ${lib.escapeShellArg specsCtxJson} > /build/specs-ctx.json
        cat > /build/spec-validate.mjs <<'NODE_EOF'
        // Maps each declared spec to exactly one importer entry, preserving
        // declaration order.  npm alias keys (alias@npm:real@ver) resolve to
        // the alias key; file:/git:/tarball forms match by full specifier
        // since their package key derives from the remote manifest.
        import fs from "node:fs";
        const args = Object.fromEntries(
          process.argv.slice(2).map((a, i, arr) => (a.startsWith("--") ? [a, arr[i + 1]] : null)).filter(Boolean),
        );
        const fail = (msg) => { console.error(`dsh fetchSpecs: ''${msg}`); process.exit(1); };
        const parseNpmSpec = (spec) => {
          if (/^(file:|link:|git\+.*:|git:|github:|gitlab:|bitbucket:|https?:|ftp:|\/|\.\/|~\/)/.test(spec)) return null;
          if (spec.includes("://")) return null;
          if (spec.startsWith("@")) {
            const m = spec.match(/^(@[^/]+\/[^@]+)(@(.*))?$/s);
            if (!m) return null;
            return { key: m[1], want: m[3] === undefined ? null : m[3] };
          }
          const at = spec.indexOf("@");
          if (at === -1) return { key: spec, want: null };
          return { key: spec.slice(0, at), want: spec.slice(at + 1) };
        };
        const orig = JSON.parse(fs.readFileSync(args["--orig"], "utf8"));
        const ctx = JSON.parse(fs.readFileSync(args["--ctx"], "utf8"));
        if (orig.length !== ctx.length) fail("spec list length mismatch");
        let importer = {};
        let sections = {};
        if (args["--lock"]) {
          const lock = JSON.parse(fs.readFileSync(args["--lock"], "utf8"));
          const importerKeys = Object.keys(lock.importers || {});
          if (importerKeys.length !== 1 || importerKeys[0] !== ".") {
            fail("lock must contain exactly the root importer");
          }
          const imp = lock.importers["."] || {};
          for (const s of ["dependencies", "optionalDependencies", "devDependencies"]) {
            const sec = imp[s] || {};
            sections[s] = sec;
            for (const [k, v] of Object.entries(sec)) {
              if (importer[k]) fail(`duplicate importer key ''${JSON.stringify(k)}`);
              importer[k] = v && typeof v === "object" ? (v.specifier ?? "") : "";
            }
          }
          if (Object.keys(imp.devDependencies || {}).length > 0) fail("lock root importer must not contain devDependencies");
        } else if (args["--pkg"]) {
          const pkg = JSON.parse(fs.readFileSync(args["--pkg"], "utf8"));
          for (const s of ["dependencies", "optionalDependencies", "devDependencies"]) {
            const sec = pkg[s] || {};
            sections[s] = sec;
            for (const [k, v] of Object.entries(sec)) {
              if (importer[k]) fail(`duplicate importer key ''${JSON.stringify(k)}`);
              importer[k] = v;
            }
          }
        } else fail("need --lock or --pkg");
        if (Object.keys(importer).length !== orig.length) {
          fail(`importer has ''${Object.keys(importer).length} entries for ''${orig.length} declared specs (stale/missing/extra lock entries fail closed)`);
        }
        const used = new Set();
        const direct = [];
        for (let i = 0; i < orig.length; i++) {
          const o = orig[i], c = ctx[i];
          const parsed = parseNpmSpec(c);
          let key = null;
          if (parsed) {
            if (!(parsed.key in importer)) fail(`spec ''${JSON.stringify(o)} (key ''${JSON.stringify(parsed.key)}) missing from installer importer`);
            if (parsed.want !== null && importer[parsed.key] !== parsed.want) {
              fail(`spec ''${JSON.stringify(o)} wants specifier ''${JSON.stringify(parsed.want)} but installer has ''${JSON.stringify(importer[parsed.key])}`);
            }
            key = parsed.key;
          } else {
            const hits = Object.keys(importer).filter((k) => importer[k] === c);
            if (hits.length === 0) fail(`spec ''${JSON.stringify(o)} (contextual ''${JSON.stringify(c)}) missing from installer importer`);
            if (hits.length > 1) fail(`spec ''${JSON.stringify(o)} is ambiguous (''${hits.map((k) => JSON.stringify(k)).join(", ")})`);
            key = hits[0];
          }
          if (used.has(key)) fail(`duplicate resolved package ''${JSON.stringify(key)} for spec ''${JSON.stringify(o)}`);
          used.add(key);
          // A local Nix path belongs to the input closure, not the output
          // bytes: serialising its enclosing flake source path would make
          // specsHash depend on its own source edit. Keep the stable copy spec.
          direct.push({ spec: c, packageName: key });
        }
        for (const k of Object.keys(importer)) {
          if (!used.has(k)) fail(`installer importer entry ''${JSON.stringify(k)} matches no declared spec (stale lock?)`);
        }
        fs.writeFileSync(args["--out-direct"], JSON.stringify(direct, null, 2) + "\n");
        if (args["--lock"] && args["--out-pkg"]) {
          const lock = JSON.parse(fs.readFileSync(args["--lock"], "utf8"));
          const imp = (lock.importers || {})["."] || {};
          const pkg = { name: "dsh-profile-plugins", private: true, version: "0.0.0", type: "module" };
          for (const s of ["dependencies", "optionalDependencies", "devDependencies"]) {
            const sec = imp[s] || {};
            if (Object.keys(sec).length > 0) {
              pkg[s] = Object.fromEntries(Object.entries(sec).map(([k, v]) => [k, v.specifier]));
            }
          }
          fs.writeFileSync(args["--out-pkg"], JSON.stringify(pkg, null, 2) + "\n");
          // Integrity guard: registry sources must pin integrity; exempt only
          // exact immutable non-registry resolutions (directory/link, git
          // commit+repo).  Never guess a resolution.
          const pkgsMap = lock.packages || {};
          const bad = [];
          for (const [k, v] of Object.entries(pkgsMap)) {
            const res = (v && v.resolution) || {};
            if (res.directory != null || res.type === "directory") continue;
            if (/^(file:|link:)/.test(k) || /@file:|-file-/.test(k)) continue;
            if (res.commit && res.repo) continue;
            if (typeof res.integrity !== "string" || res.integrity === "") bad.push(k);
          }
          if (bad.length > 0) fail(`lock packages missing integrity: ''${bad.slice(0, 8).map((k) => JSON.stringify(k)).join(", ")}`);
          const lv = String(lock.lockfileVersion || "");
          const major = parseInt(lv.split(".")[0], 10);
          if (!Number.isFinite(major)) fail(`unparseable lockfileVersion ''${JSON.stringify(lv)}`);
          if (major > 11) fail(`lockfileVersion ''${JSON.stringify(lv)} is newer than pnpm_11 (major 11)`);
        }
        NODE_EOF
        if [ -n ${if specsLock == null then ''""'' else lockArg} ]; then
          lockSrc=${if specsLock == null then ''""'' else lockArg}
          cp "$lockSrc" ./pnpm-lock.yaml
          lv=$(yq -o=json '.' pnpm-lock.yaml | jq -r '.lockfileVersion')
          major=''${lv%%.*}
          pmMajor=$(pnpm --version | cut -d. -f1)
          if [ "$major" -gt "$pmMajor" ]; then
            echo "dsh fetchSpecs: lockfileVersion $lv is newer than pnpm major $pmMajor" >&2
            exit 1
          fi
          yq -o=json '.' pnpm-lock.yaml > /build/lock.json
          node /build/spec-validate.mjs --lock /build/lock.json --orig /build/specs-orig.json --ctx /build/specs-ctx.json --out-direct /build/direct-specs.json --out-pkg ./package.json
          pnpm install --frozen-lockfile --ignore-scripts --package-import-method=copy
        else
          printf '%s' '{"name":"dsh-profile-plugins","private":true,"version":"0.0.0","type":"module"}' > package.json
          pnpm add --ignore-scripts --package-import-method=copy ${lib.escapeShellArgs contextualSpecs}
          node /build/spec-validate.mjs --pkg ./package.json --orig /build/specs-orig.json --ctx /build/specs-ctx.json --out-direct /build/direct-specs.json
        fi
        # Drop only machine-local caches/metadata.  NEVER .pnpm, dependency
        # links, or pnpm-lock.yaml: the full runtime/transitive/auto-peer
        # graph must survive in the fixed-output closure.
        rm -rf node_modules/.cache node_modules/.modules.yaml node_modules/.pnpm-workspace-state-v1.json
        mkdir -p "$out"
        cp package.json "$out/package.json"
        cp /build/direct-specs.json "$out/direct-specs.json"
        if [ -n ${if specsLock == null then ''""'' else lockArg} ]; then
          cp ${if specsLock == null then ''/dev/null'' else lockArg} "$out/pnpm-lock.yaml"
        else
          if [ -f pnpm-lock.yaml ]; then cp pnpm-lock.yaml "$out/pnpm-lock.yaml"; fi
        fi
        cp -r node_modules "$out/node_modules"
      '';
    };
in
{
  inherit mkPluginBundle;
  mkPlugin = mkPluginBundle;
  inherit classifyPlugin fetchSpecs;
}
