{ lib }:

let
  pluginsLib = import ./plugins.nix { inherit lib; };
  inherit (pluginsLib) classifyPlugin fetchSpecs;

  mkProfileBundle =
    {
      name,
      plugins,
      inBoxNames ? [ ],
      userPatchesFile ? null,
      userPatches ? [ ],
      specsHash ? "",
    }:
    let
      classified = map (plugin: classifyPlugin { inherit inBoxNames plugin; }) plugins;
      nixPlugins = map (entry: entry.plugin)
        (builtins.filter (entry: entry.kind == "nix") classified);
      packageNames = map (plugin: plugin.packageName) nixPlugins;
      # Deferred (null) names from raw derivations resolve at build time from
      # package.json; they must not collide with each other here.  Check only
      # the eval-known names now; buildProfileBundle enforces runtime
      # uniqueness after resolution.
      knownPackageNames = builtins.filter (n: n != null && n != "") packageNames;
      checkedName =
        if name == null || name == "" then
          throw "dsh profile bundle: name must not be empty"
        else
          name;
      uniquePackageNames =
        if builtins.length knownPackageNames == builtins.length (lib.unique knownPackageNames) then
          true
        else
          throw "dsh profile bundle: plugin packageNames must be unique";
    in
    assert uniquePackageNames;
    {
      inherit name userPatchesFile userPatches specsHash;
      plugins = classified;
      inBox = map (entry: entry.name)
        (builtins.filter (entry: entry.kind == "in-box") classified);
      inherit nixPlugins;
      specs = map (entry: entry.spec)
        (builtins.filter (entry: entry.kind == "spec") classified);
    };

  buildProfileBundle =
    { pkgs, profile }:
    let
      classified = profile.plugins;
      nixEntries = builtins.filter (entry: entry.kind == "nix") classified;
      specEntries = builtins.filter (entry: entry.kind == "spec") classified;
      specsRoot = if profile.specs == [ ] then null else fetchSpecs {
        inherit pkgs;
        specs = profile.specs;
        hash = profile.specsHash;
      };
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
        specCount = builtins.length specEntries;
        classes = map (entry:
          if entry.kind == "in-box" then { kind = entry.kind; name = entry.name; }
          else if entry.kind == "spec" then { kind = entry.kind; }
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
      specRootArg = if specsRoot == null then "" else toString specsRoot;
    in
    pkgs.runCommand "dsh-profile-${profile.name}" {
      buildInputs = [ pkgs.jq ];
    } ''
      mkdir -p "$out/node_modules"
      metadata=${lib.escapeShellArg (toString metadata)}
      specRoot=${lib.escapeShellArg specRootArg}

      layers='[]'
      specIndex=0
      # Resolve the runtime package name without IFD: an explicit eval-time
      # packageName wins, otherwise read package.json at build time.
      resolve_nix_name() {
        rawName=$(printf '%s' "$1" | jq -r '.packageName // ""')
        if [ -n "$rawName" ] && [ "$rawName" != "null" ]; then
          printf '%s' "$rawName"
        else
          resolved=$(jq -r '.name // empty' "$2/package.json")
          if [ -z "$resolved" ]; then
            echo "dsh profile bundle: packageName is required (set it explicitly or provide package.json name) for $2" >&2
            return 1
          fi
          printf '%s' "$resolved"
        fi
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
            layer=$(printf '%s' "$entry" | jq -r '.name')
            ;;
          spec)
            layer=$(jq -r --argjson i "$specIndex" '.dependencies | keys_unsorted[$i]' "$specRoot/package.json")
            specIndex=$((specIndex + 1))
            ;;
          nix)
            packagePath=$(printf '%s' "$entry" | jq -r '.packagePath')
            packageName=$(resolve_nix_name "$entry" "$packagePath") || exit 1
            if is_nix_layer "$entry" "$packagePath"; then
              layer=$packageName
            else
              layer=""
            fi
            ;;
        esac
        if [ -n "$layer" ]; then
          layers=$(printf '%s' "$layers" | jq -c --arg layer "$layer" '. + [$layer]')
        fi
      done < <(jq -c '.classes[]' "$metadata")

      dependencies=$(jq -n '{ }')
      seen_nix_names=" "
      while IFS= read -r entry; do
        packagePath=$(printf '%s' "$entry" | jq -r '.packagePath')
        packageName=$(resolve_nix_name "$entry" "$packagePath") || exit 1
        case "$seen_nix_names" in
          *" $packageName "*) echo "dsh profile bundle: plugin packageNames must be unique (duplicate $packageName)" >&2; exit 1 ;;
        esac
        seen_nix_names="$seen_nix_names$packageName "
        dependencies=$(printf '%s' "$dependencies" | jq -c --arg name "$packageName" --arg path "$packagePath" '. + {($name): $path}')
        parent=$(dirname "$packageName")
        if [ "$parent" != . ]; then mkdir -p "$out/node_modules/$parent"; fi
        dest="$out/node_modules/$packageName"
        # Project only explicit patchPath selections; manifest-declared
        # patches (local paths, raw bundle derivations) stay as symlinks.
        explicitPatch=$(printf '%s' "$entry" | jq -r '.explicitPatch // ""')
        if [ -z "$explicitPatch" ] || [ "$explicitPatch" = "null" ]; then
          ln -s "$packagePath" "$dest"
        else
          # Explicit patchPath must yield an rc.2-consumable bundle layer:
          # project the package under node_modules with a manifest that
          # declares exactly the selected patch and the real patch bytes
          # beside it. A missing/escaping selection fails loud instead of a
          # phantom layer rc.2 would skip.
          case "$explicitPatch" in
            /*)
              if [ ! -f "$explicitPatch" ]; then
                echo "dsh profile bundle: explicit patchPath $explicitPatch for $packageName does not exist" >&2
                exit 1
              fi
              patchBase=$(basename "$explicitPatch")
              if [ "$patchBase" = "package.json" ]; then
                echo "dsh profile bundle: explicit patchPath $explicitPatch for $packageName must not be package.json" >&2
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
              done < <(find "$packagePath" -mindepth 1 -maxdepth 1 -print)
              cp "$explicitPatch" "$dest/$patchBase"
              jq --arg patch "$patchBase" '.dsh.bundle.patch = $patch' "$packagePath/package.json" > "$dest/package.json"
              ;;
            *)
              case "$explicitPatch" in
                *".."* )
                  echo "dsh profile bundle: explicit patchPath $explicitPatch for $packageName must stay inside the package" >&2
                  exit 1
                  ;;
              esac
              if [ ! -f "$packagePath/$explicitPatch" ]; then
                echo "dsh profile bundle: explicit patchPath $explicitPatch for $packageName not found in $packagePath" >&2
                exit 1
              fi
              mkdir -p "$dest"
              while IFS= read -r src; do
                base=$(basename "$src")
                if [ "$base" = "package.json" ]; then continue; fi
                ln -s "$src" "$dest/$base"
              done < <(find "$packagePath" -mindepth 1 -maxdepth 1 -print)
              jq --arg patch "$explicitPatch" '.dsh.bundle.patch = $patch' "$packagePath/package.json" > "$dest/package.json"
              ;;
          esac
        fi
      done < <(jq -c '.nixMetadata[]' "$metadata")

      if [ -n "$specRoot" ]; then
        for entry in "$specRoot"/node_modules/*; do
          [ -e "$entry" ] || continue
          ln -s "$entry" "$out/node_modules/$(basename "$entry")"
        done
      fi

      jq -n --arg name ${lib.escapeShellArg profile.name} --argjson layers "$layers" --argjson dependencies "$dependencies" \
        '{name: $name, version: "0.0.0", private: true, dsh: {profile: {bundles: $layers}}, dependencies: $dependencies}' > "$out/package.json"
      printf '[]\n' > "$out/cordis.yml"
      ${if patchSource != null then ''cp ${lib.escapeShellArg (toString patchSource)} "$out/cordis.patch.yml"'' else ''printf '%s' ${lib.escapeShellArg patchText} > "$out/cordis.patch.yml"''}
    '';
in
{
  inherit mkProfileBundle buildProfileBundle;
  mkProfile = mkProfileBundle;
  buildProfile = buildProfileBundle;
}
