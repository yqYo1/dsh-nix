{ lib }:

let
  pluginsLib = import ./plugins.nix { inherit lib; };
  inherit (pluginsLib) classifyPlugin;

  mkProfile =
    {
      name,
      plugins ? [ ],
      extraPlugins ? [ ],
      extends ? null,
      inBoxNames ? [ ],
      installBundles ? [ ],
      userPatchesFile ? null,
      userPatches ? [ ],
    }:
    let
      # A template profile starts from a shipped profile template
      # (PROFILE_TEMPLATES, read from the dsh installation at build time) and
      # adds `extraPlugins`; a custom profile declares every entry in
      # `plugins` and uses no template.
      selected = if extends == null then plugins else extraPlugins;
      classified = map (plugin: classifyPlugin { inherit inBoxNames installBundles plugin; }) selected;
      nixEntries = map (entry: entry.plugin)
        (builtins.filter (entry: entry.kind == "nix") classified);
      packageNames = map (plugin: plugin.packageName) nixEntries;
      # Deferred (null) names from raw derivations resolve at build time from
      # package.json; they must not collide with each other here.  Check only
      # the eval-known names now; buildProfile enforces runtime
      # uniqueness after resolution.
      knownPackageNames = builtins.filter (n: n != null && n != "") packageNames;
      checkedName =
        if name == null || name == "" then
          throw "dsh profile: name must not be empty"
        else
          name;
      uniquePackageNames =
        if builtins.length knownPackageNames == builtins.length (lib.unique knownPackageNames) then
          true
        else
          throw "dsh profile: plugin packageNames must be unique";
    in
    assert uniquePackageNames;
    assert extends == null || plugins == [ ];
    assert extends != null || extraPlugins == [ ];
    {
      inherit name extends userPatchesFile userPatches;
      plugins = classified;
      inBox = map (entry: entry.name)
        (builtins.filter (entry: entry.kind == "in-box") classified);
      installBundles = map (entry: entry.name)
        (builtins.filter (entry: entry.kind == "install-bundle") classified);
      inherit nixEntries;
    };

  buildProfile =
    { pkgs, profile, install ? null }:
    let
      template = profile.extends or null;
      installBundleNames = profile.installBundles or [ ];
      needsInstall = template != null || installBundleNames != [ ];
      installArg = if !needsInstall || install == null then "" else toString install;
      classified = profile.plugins;
      nixEntries = builtins.filter (entry: entry.kind == "nix") classified;
      nixMetadata = map (entry: {
        packageName = entry.plugin.packageName;
        packagePath = toString entry.plugin.packagePath;
        patchPath =
          if (entry.plugin.patchPath or null) == null then
            null
          else
            toString entry.plugin.patchPath;
        explicitPatch =
          if (entry.plugin.explicitPatch or null) == null then
            null
          else
            toString entry.plugin.explicitPatch;
      }) nixEntries;
      metadata = pkgs.writeText "dsh-profile-plugins.json" (builtins.toJSON {
        inherit nixMetadata;
        classes = map (entry:
          if entry.kind == "in-box" || entry.kind == "install-bundle" then
            { kind = entry.kind; name = entry.name; }
          else {
            kind = entry.kind;
            packageName = entry.plugin.packageName;
            packagePath = toString entry.plugin.packagePath;
            patchPath =
              if (entry.plugin.patchPath or null) == null then
                null
              else
                toString entry.plugin.patchPath;
          }
        ) classified;
      });
      patchText = builtins.toJSON profile.userPatches;
      # Materialise a source userPatchesFile into the store so the sandbox
      # can see it: plain toString would keep the original /home path.
      patchSource =
        if profile.userPatchesFile != null then builtins.path { path = profile.userPatchesFile; } else null;
    in
    pkgs.runCommand "dsh-profile-${profile.name}" {
      buildInputs = [ pkgs.jq ] ++ (if template == null then [ ] else [ pkgs.nodejs ]);
    } ''
      mkdir -p "$out/node_modules"
      metadata=${lib.escapeShellArg (toString metadata)}

      bundles='[]'
      install=${lib.escapeShellArg installArg}
      template=${lib.escapeShellArg (if template == null then "" else template)}
      if [ -n "$template" ]; then
        if [ -z "$install" ] || [ ! -f "$install/lib/dsh-builtin-compat.cjs" ]; then
          echo "dsh profile: template $template needs the dsh installation" >&2
          exit 1
        fi
        templateBundles=$(node --expose-internals --require "$install/lib/dsh-builtin-compat.cjs" \
          ${../scripts/read-profile-template.mjs} "$install" "$template") || exit 1
        printf '%s' "$templateBundles" | jq -e 'type == "array" and length > 0' >/dev/null \
          || { echo "dsh profile: template $template returned no bundles" >&2; exit 1; }
        bundles=$(printf '%s' "$templateBundles" | jq -c '.')
      fi
      # Resolve the effective package root without IFD: a root package.json
      # wins; otherwise accept exactly one direct buildNpmPackage installed
      # root ($pkg/lib/node_modules/<name> or @<scope>/<name>). Zero or
      # multiple candidates fail loud; deep transitive manifests are never
      # searched and pname/store names never infer identity.
      resolve_effective_root() {
        pkg="$1"
        if [ -f "$pkg/package.json" ]; then
          printf '%s' "$pkg"
          return 0
        fi
        nm="$pkg/lib/node_modules"
        count=0
        chosen=""
        listed=""
        if [ -d "$nm" ]; then
          for manifest in "$nm"/*/package.json; do
            [ -f "$manifest" ] || continue
            dir=$(dirname "$manifest")
            case "$(basename "$dir")" in @*) continue ;; esac
            count=$((count + 1))
            chosen="$dir"
            listed="$listed $dir"
          done
          for manifest in "$nm"/@*/*/package.json; do
            [ -f "$manifest" ] || continue
            dir=$(dirname "$manifest")
            count=$((count + 1))
            chosen="$dir"
            listed="$listed $dir"
          done
        fi
        if [ "$count" -eq 1 ]; then
          printf '%s' "$chosen"
          return 0
        fi
        if [ "$count" -eq 0 ]; then
          echo "dsh profile: no package.json at $pkg/package.json and no installed package under $pkg/lib/node_modules (want exactly one direct root)" >&2
        else
          echo "dsh profile: ambiguous installed packages under $pkg/lib/node_modules (found $count:$listed); pass an explicit installed root path" >&2
        fi
        return 1
      }
      # Resolve the runtime package name without IFD: an explicit eval-time
      # packageName wins, otherwise read package.json at build time.
      resolve_nix_name() {
        rawName=$(printf '%s' "$1" | jq -r '.packageName // ""')
        if [ -n "$rawName" ] && [ "$rawName" != "null" ]; then
          printf '%s' "$rawName"
        else
          resolved=$(jq -r '.name // empty' "$2/package.json")
          if [ -z "$resolved" ]; then
            echo "dsh profile: packageName is required (set it explicitly or provide package.json name) for $2" >&2
            return 1
          fi
          printf '%s' "$resolved"
        fi
      }
      # Find the one installed package named $1 (source tree, no node_modules).
      resolve_install_bundle() {
        want=$1
        count=0
        chosen=""
        while IFS= read -r manifest; do
          [ -f "$manifest" ] || continue
          [ "$(jq -r '.name // empty' "$manifest")" = "$want" ] || continue
          count=$((count + 1))
          chosen=$(dirname "$manifest")
        done < <(find "$install" -path '*/node_modules' -prune -o -name package.json -print)
        if [ "$count" -ne 1 ]; then
          echo "dsh profile: expected exactly one installed package named $want, found $count" >&2
          return 1
        fi
        printf '%s' "$chosen"
      }
      # Explicit patchPath forces layer membership; otherwise the package's
      # own dsh.bundle.patch declaration decides (plain deps stay inactive).
      is_nix_layer() {
        explicitPatch=$(printf '%s' "$1" | jq -r '.patchPath // ""')
        if [ -n "$explicitPatch" ] && [ "$explicitPatch" != "null" ]; then
          return 0
        fi
        jq -e '((.dsh // {}).bundle // {}).patch != null' "$2/package.json" >/dev/null
      }
      while IFS= read -r entry; do
        kind=$(printf '%s' "$entry" | jq -r '.kind')
        case "$kind" in
          in-box)
            bundle=$(printf '%s' "$entry" | jq -r '.name')
            ;;
          install-bundle)
            bundle=$(printf '%s' "$entry" | jq -r '.name')
            ;;
          nix)
            packagePath=$(printf '%s' "$entry" | jq -r '.packagePath')
            effectiveRoot=$(resolve_effective_root "$packagePath") || exit 1
            packageName=$(resolve_nix_name "$entry" "$effectiveRoot") || exit 1
            if is_nix_layer "$entry" "$effectiveRoot"; then
              bundle=$packageName
            else
              bundle=""
            fi
            ;;
        esac
        if [ -n "$bundle" ]; then
          if printf '%s' "$bundles" | jq -e --arg b "$bundle" 'index($b)' >/dev/null 2>&1; then
            if [ -n "$template" ]; then
              echo "dsh profile: bundle $bundle is already in template $template" >&2
            else
              echo "dsh profile: duplicate bundle $bundle" >&2
            fi
            exit 1
          fi
          bundles=$(printf '%s' "$bundles" | jq -c --arg bundle "$bundle" '. + [$bundle]')
        fi
      done < <(jq -c '.classes[]' "$metadata")

      dependencies=$(jq -n '{ }')
      seen_nix_names=" "
      while IFS= read -r entry; do
        packagePath=$(printf '%s' "$entry" | jq -r '.packagePath')
        effectiveRoot=$(resolve_effective_root "$packagePath") || exit 1
        packageName=$(resolve_nix_name "$entry" "$effectiveRoot") || exit 1
        case "$seen_nix_names" in
          *" $packageName "*) echo "dsh profile: plugin packageNames must be unique (duplicate $packageName)" >&2; exit 1 ;;
        esac
        seen_nix_names="$seen_nix_names$packageName "
        dependencies=$(printf '%s' "$dependencies" | jq -c --arg name "$packageName" --arg path "$effectiveRoot" '. + {($name): $path}')
        parent=$(dirname "$packageName")
        if [ "$parent" != . ]; then mkdir -p "$out/node_modules/$parent"; fi
        dest="$out/node_modules/$packageName"
        # Project only explicit patchPath selections; manifest-declared
        # patches (local paths, raw bundle derivations) stay as symlinks.
        explicitPatch=$(printf '%s' "$entry" | jq -r '.explicitPatch // ""')
        if [ -z "$explicitPatch" ] || [ "$explicitPatch" = "null" ]; then
          ln -s "$effectiveRoot" "$dest"
        else
          # Explicit patchPath must yield an rc.2-consumable bundle layer:
          # project the package under node_modules with a manifest that
          # declares exactly the selected patch and the real patch bytes
          # beside it. A missing/escaping selection fails loud instead of a
          # phantom bundle rc.2 would skip.
          case "$explicitPatch" in
            /*)
              if [ ! -f "$explicitPatch" ]; then
                echo "dsh profile: explicit patchPath $explicitPatch for $packageName does not exist" >&2
                exit 1
              fi
              patchBase=$(basename "$explicitPatch")
              if [ "$patchBase" = "package.json" ]; then
                echo "dsh profile: explicit patchPath $explicitPatch for $packageName must not be package.json" >&2
                exit 1
              fi
              mkdir -p "$dest"
              while IFS= read -r src; do
                base=$(basename "$src")
                if [ "$base" = "package.json" ]; then continue; fi
                # Skip the selected basename: the entry below materialises
                # the selected bytes as a real file. Linking first would
                # leave cp writing through a symlink at a read-only store
                # target (or shadowing the selection with stale bytes when
                # an external patch shares the package file's basename).
                if [ "$base" = "$patchBase" ]; then continue; fi
                ln -s "$src" "$dest/$base"
              done < <(find "$effectiveRoot" -mindepth 1 -maxdepth 1 -print)
              cp "$explicitPatch" "$dest/$patchBase"
              jq --arg patch "$patchBase" '.dsh.bundle.patch = $patch' "$effectiveRoot/package.json" > "$dest/package.json"
              ;;
            *)
              case "$explicitPatch" in
                *".."* )
                  echo "dsh profile: explicit patchPath $explicitPatch for $packageName must stay inside the package" >&2
                  exit 1
                  ;;
              esac
              if [ ! -f "$effectiveRoot/$explicitPatch" ]; then
                echo "dsh profile: explicit patchPath $explicitPatch for $packageName not found in $effectiveRoot" >&2
                exit 1
              fi
              mkdir -p "$dest"
              while IFS= read -r src; do
                base=$(basename "$src")
                if [ "$base" = "package.json" ]; then continue; fi
                ln -s "$src" "$dest/$base"
              done < <(find "$effectiveRoot" -mindepth 1 -maxdepth 1 -print)
              jq --arg patch "$explicitPatch" '.dsh.bundle.patch = $patch' "$effectiveRoot/package.json" > "$dest/package.json"
              ;;
          esac
        fi
      done < <(jq -c '.nixMetadata[]' "$metadata")
      # Installed-source bundles (the on-demand official bundles): link the
      # package directory from the dsh installation.  Its node_modules stays
      # in place, so pnpm's relative workspace links remain valid.
      while IFS= read -r entry; do
        name=$(printf '%s' "$entry" | jq -r '.name')
        if [ -z "$install" ]; then
          echo "dsh profile: bundle $name requires the dsh installation" >&2
          exit 1
        fi
        dir=$(resolve_install_bundle "$name") || exit 1
        jq -e '((.dsh // {}).bundle // {}).patch != null' "$dir/package.json" >/dev/null \
          || { echo "dsh profile: $name in the installation is not a bundle" >&2; exit 1; }
        main=$(jq -r '.main // empty' "$dir/package.json")
        [ -n "$main" ] && [ -f "$dir/$main" ] \
          || { echo "dsh profile: $name is not built in the installation (missing $main)" >&2; exit 1; }
        parent=$(dirname "$name")
        if [ "$parent" != . ]; then mkdir -p "$out/node_modules/$parent"; fi
        ln -s "$dir" "$out/node_modules/$name"
      done < <(jq -c '.classes[] | select(.kind == "install-bundle")' "$metadata")

      jq -n --arg name ${lib.escapeShellArg profile.name} --argjson bundles "$bundles" --argjson dependencies "$dependencies" \
        '{name: $name, version: "0.0.0", private: true, dsh: {profile: {bundles: $bundles}}, dependencies: $dependencies}' > "$out/package.json"
      printf '[]\n' > "$out/cordis.yml"
      ${if patchSource != null then ''cp ${lib.escapeShellArg (toString patchSource)} "$out/cordis.patch.yml"'' else ''printf '%s' ${lib.escapeShellArg patchText} > "$out/cordis.patch.yml"''}
    '';
in
{
  inherit mkProfile buildProfile;
}
