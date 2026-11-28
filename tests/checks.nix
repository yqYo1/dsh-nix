{
  pkgs,
  lib,
  system,
  dshNix,
  rootSrc,
}:

let
  inherit (dshNix) profilesLib;
  inherit (dshNix) officialBundles;
  dshSrc = dshNix.inputs.dsh;
  dshPackage = dshNix.packages.${system}.dsh;
  checkProfile = pkgs.callPackage (rootSrc + "/scripts/check-profile.nix") { };

  # The official on-demand bundles are not installation dependencies, but
  # the pinned dsh source still contains and builds them.  Profile builds
  # link the installed package directly, so no npm fetch, version pin,
  # lockfile, or pnpm-store hash is maintained separately.
  onDemandBundles = officialBundles.onDemand;

  # The official bundles shipped by the dsh installation: every bundle in
  # the shipped profile templates plus the shipped optional bundles.
  # Mirrors upstream PROFILE_TEMPLATES + OPTIONAL_BUNDLES; the
  # `official-bundles` check fails on drift with the pinned source.
  inBoxNames = lib.unique (
    lib.concatLists (lib.attrValues officialBundles.profileTemplates) ++ officialBundles.optional
  );

  # Shipped profile templates (dsh `PROFILE_TEMPLATES`).  The module
  # installs one profile per name by default; the bundles come from the
  # dsh installation at build time, never from user configuration.
  profileTemplates = lib.attrNames officialBundles.profileTemplates;

  webArtifact = profilesLib.buildProfile {
    inherit pkgs;
    profile = profilesLib.mkProfile {
      name = "web";
      plugins = [
        "@deepseek-ai/dsh-base"
        "@deepseek-ai/dsh-web-app"
      ];
      inherit inBoxNames;
    };
  };
  headlessArtifact = profilesLib.buildProfile {
    inherit pkgs;
    profile = profilesLib.mkProfile {
      name = "headless";
      plugins = [
        "@deepseek-ai/dsh-base"
        "@deepseek-ai/dsh-headless"
      ];
      inherit inBoxNames;
    };
  };
in
{
  # Official-bundle drift guard: the accepted by-name set must equal
  # every bundle the installation ships.  The rule mirrors the
  # plugin-manager's own `shipped` computation: a package is an
  # installation-provided bundle iff its name is a key of the
  # installation package.json `dependencies` and its manifest
  # declares `dsh.bundle.patch`.  The on-demand subagent bundles are
  # not installation dependencies (catalog-only), so the rule
  # excludes them without a path allowlist and cannot miss a bundle
  # placed anywhere else in the tree; they are covered by the
  # official-on-demand check and linked at build time.
  # The README's official-bundle section is part of the public catalog
  # surface.  Keep its names in lockstep with the catalog rather than
  # silently drifting when a bundle is added or removed.
  readme-catalog =
    pkgs.runCommand "dsh-readme-catalog-check"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
        src = rootSrc;
        names = builtins.toJSON (inBoxNames ++ onDemandBundles);
      }
      ''
        sed -n '/^### Official bundles$/,/^### Out-of-tree plugins/p' "$src/README.md" \
          | grep -oE '@deepseek-ai/[A-Za-z0-9._/-]+' | sort -u > "$TMPDIR/readme.txt"
        printf '%s\n' "$names" | jq -r '.[]' | sort -u > "$TMPDIR/catalog.txt"
        if ! diff -u "$TMPDIR/catalog.txt" "$TMPDIR/readme.txt"; then
          echo "readme-catalog: README and lib/official-bundles.nix disagree" >&2
          exit 1
        fi
        touch "$out"
      '';

  official-bundles =
    pkgs.runCommand "dsh-official-bundles-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
        src = dshSrc;
        expected = builtins.toJSON inBoxNames;
      }
      ''
        # Do not pipe a large dependency list into `grep -q`: it exits
        # on the first match, the writer can receive SIGPIPE, and with
        # pipefail the condition flips nondeterministically.  Search a
        # file instead.
        cliDepsFile="$TMPDIR/cli-deps.txt"
        jq -r '.dependencies // {} | keys[]' "$src/apps/cli/package.json" > "$cliDepsFile"
        actualFile="$TMPDIR/actual.txt"
        (
          cd "$src"
          find . -name node_modules -prune -o -name package.json -print | while IFS= read -r p; do
            name=$(jq -r '.name // empty' "$p" 2>/dev/null) || continue
            [ -n "$name" ] || continue
            if grep -qxF -- "$name" "$cliDepsFile" \
              && jq -e '((.dsh // {}).bundle // {}).patch != null' "$p" >/dev/null 2>&1; then
              printf '%s\n' "$name"
            fi
          done | sort > "$actualFile"
        )
        wantFile="$TMPDIR/want.txt"
        printf '%s\n' "$expected" | jq -r '.[]' | sort > "$wantFile"
        if ! cmp -s "$actualFile" "$wantFile"; then
          echo "official-bundles: by-name set drifted from the installation's shipped bundles" >&2
          diff -u "$wantFile" "$actualFile" >&2 || true
          echo "(left: accepted list, right: shipped bundles)" >&2
          exit 1
        fi
        touch "$out"
      '';

  # The on-demand bundle names are the only per-bundle list this
  # repository keeps; it must equal upstream ON_DEMAND_BUNDLES, and
  # each name must be a built bundle in the pinned dsh source.  No npm
  # fetch, version pin, lockfile, or store hash is maintained here.
  official-on-demand =
    pkgs.runCommand "dsh-official-on-demand-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
        install = dshPackage.dev;
        names = builtins.toJSON onDemandBundles;
      }
      ''
        upstream=$(sed -n 's/^const ON_DEMAND_BUNDLES = \(.*\);/\1/p' \
          "$install/packages/util/official-bundles/lib/index.js" \
          | jq -r '.[]' | sort)
        want=$(printf '%s\n' "$names" | jq -r '.[]' | sort)
        if [ "$upstream" != "$want" ]; then
          echo "official-on-demand: names differ from upstream ON_DEMAND_BUNDLES" >&2
          diff <(printf '%s\n' "$want") <(printf '%s\n' "$upstream") >&2 || true
          exit 1
        fi
        index="$install/share/dsh-nix/bundles.tsv"
        [ -f "$index" ] || { echo "official-on-demand: installation has no bundle index" >&2; exit 1; }
        for name in $want; do
          indexed=$(awk -F '\t' -v n="$name" '$1 == n { print $2 }' "$index")
          [ -n "$indexed" ] && [ -f "$indexed/package.json" ] \
            || { echo "official-on-demand: bundle index has no usable entry for $name" >&2; exit 1; }
          matches=$(find "$install" -path '*/node_modules' -prune -o -name package.json -print \
            | while IFS= read -r manifest; do
                if [ "$(jq -r '.name // empty' "$manifest")" = "$name" ]; then
                  printf '%s\n' "$manifest"
                fi
              done)
          count=$(printf '%s\n' "$matches" | grep -c . || true)
          if [ "$count" -ne 1 ]; then
            echo "official-on-demand: expected one built source package for $name, found $count" >&2
            exit 1
          fi
          [ "$indexed" = "$(dirname "$matches")" ] \
            || { echo "official-on-demand: bundle index path disagrees for $name" >&2; exit 1; }
          jq -e '((.dsh // {}).bundle // {}).patch != null' "$matches" >/dev/null \
            || { echo "official-on-demand: $name declares no dsh.bundle.patch" >&2; exit 1; }
          main=$(jq -r '.main // empty' "$matches")
          [ -n "$main" ] && [ -f "$(dirname "$matches")/$main" ] \
            || { echo "official-on-demand: $name is not built (missing $main)" >&2; exit 1; }
        done
        echo "on-demand bundles: $(printf '%s\n' "$want" | wc -l)"
        touch "$out"
      '';

  # Every plugin package named by a shipped bundle's rows must exist in
  # the built installation: that is what lets a profile row (or the
  # bundle itself) resolve the name without Nix packaging.  Guards the
  # "names resolve from the installation" promise across tag bumps.
  official-plugin-resolution =
    pkgs.runCommand "dsh-official-plugin-resolution-check"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.yq-go
        ];
        src = dshSrc;
        install = dshPackage.dev;
        shipped = builtins.toJSON inBoxNames;
      }
      ''
        printf '%s\n' "$shipped" | jq -r '.[]' | sort > "$TMPDIR/shipped.txt"
        cd "$src"
        find . -name node_modules -prune -o -name package.json -print > "$TMPDIR/pkgs.txt"
        : > "$TMPDIR/names.txt"
        : > "$TMPDIR/problems.txt"
        while IFS= read -r p; do
          name=$(jq -r '.name // empty' "$p" 2>/dev/null) || continue
          [ -n "$name" ] || continue
          grep -qxF "$name" "$TMPDIR/shipped.txt" || continue
          jq -r '[((.dsh // {}).bundle // {}).patch // empty] | flatten | .[]' "$p" > "$TMPDIR/patches.txt" 2>/dev/null || true
          while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            f="$(dirname "$p")/$rel"
            if [ ! -f "$f" ]; then
              echo "$name: declared patch $rel does not exist" >> "$TMPDIR/problems.txt"
              continue
            fi
            yq -r '.. | .name? // "" | select(. != "")' "$f" \
              | grep -E '^@deepseek-ai/' >> "$TMPDIR/names.txt" || true
          done < "$TMPDIR/patches.txt"
        done < "$TMPDIR/pkgs.txt"
        if [ -s "$TMPDIR/problems.txt" ]; then
          echo "official-plugin-resolution: shipped bundle patch declarations are broken" >&2
          cat "$TMPDIR/problems.txt" >&2
          exit 1
        fi
        sed -E 's#^(@deepseek-ai/[^/]+)/.*#\1#' "$TMPDIR/names.txt" | sort -u > "$TMPDIR/want.txt"
        # The installation emits its package index at build time; use it
        # instead of walking the pnpm symlink farm.
        index="$install/share/dsh-nix/bundles.tsv"
        [ -f "$index" ] || { echo "official-plugin-resolution: installation has no bundle index" >&2; exit 1; }
        awk -F '\t' '{ print $1 }' "$index" | sort -u > "$TMPDIR/have.txt"
        missing=$(comm -23 "$TMPDIR/want.txt" "$TMPDIR/have.txt")
        if [ -n "$missing" ]; then
          echo "official-plugin-resolution: packages named by shipped bundle rows are absent from the installation:" >&2
          printf '%s\n' "$missing" >&2
          exit 1
        fi
        echo "resolved $(wc -l < "$TMPDIR/want.txt") official plugin packages from the installation"
        touch "$out"
      '';

  # The module installs the shipped profile templates by default; this
  # guard keeps its name list and every template's bundle list aligned
  # with the pinned dsh installation.
  profile-templates =
    pkgs.runCommand "dsh-profile-templates-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.jq
        ];
        install = dshPackage.profileMeta;
        names = builtins.toJSON profileTemplates;
        shipped = builtins.toJSON inBoxNames;
      }
      ''
        templates=$(node ${dshPackage}/lib/read-profile-template.mjs "$install") || exit 1
        printf '%s\n' "$names" | jq -r '.[]' | sort > "$TMPDIR/want.txt"
        printf '%s' "$templates" | jq -r 'keys[]' | sort > "$TMPDIR/have.txt"
        if ! diff -u "$TMPDIR/want.txt" "$TMPDIR/have.txt"; then
          echo "profile-templates: module template list differs from PROFILE_TEMPLATES" >&2
          exit 1
        fi
        printf '%s' "$templates" | jq -r 'to_entries[] | .value.bundles[]' | sort -u > "$TMPDIR/bundles.txt"
        printf '%s\n' "$shipped" | jq -r '.[]' | sort > "$TMPDIR/shipped.txt"
        missing=$(comm -23 "$TMPDIR/bundles.txt" "$TMPDIR/shipped.txt")
        if [ -n "$missing" ]; then
          echo "profile-templates: template bundles outside the in-box set:" >&2
          printf '%s\n' "$missing" >&2
          exit 1
        fi
        echo "templates: $(wc -l < "$TMPDIR/have.txt"); bundles: $(wc -l < "$TMPDIR/bundles.txt")"
        touch "$out"
      '';

  # A template profile takes its bundles from PROFILE_TEMPLATES and
  # boots without the user listing any bundle.
  profile-template =
    let
      profile = profilesLib.mkProfile {
        name = "web";
        extends = "web";
        inherit inBoxNames;
      };
      artifact = profilesLib.buildProfile {
        inherit pkgs profile;
        install = dshPackage.dev;
        inherit (dshPackage) profileMeta;
      };
    in
    pkgs.runCommand "dsh-profile-template-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.jq
        ];
      }
      ''
        expected=$(node --expose-internals --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${dshPackage}/lib/read-profile-template.mjs ${dshPackage} web) || exit 1
        jq -e --argjson want "$expected" '.dsh.profile.bundles == $want' ${artifact}/package.json >/dev/null \
          || { echo "profile-template: bundles differ from PROFILE_TEMPLATES.web" >&2; exit 1; }
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${artifact} "$home/profiles/web"
        chmod -R u+w "$home/profiles/web"
        if ! ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} web "$home" --port 0 --no-open \
          > "$TMPDIR/check.log" 2>&1; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
        if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        touch "$out"
      '';

  # Extending a template keeps its bundles and settings, appends the
  # declared extra bundle, and applies the user patch layer on top.
  profile-template-extension =
    let
      profile = profilesLib.mkProfile {
        name = "web-extended";
        extends = "web";
        extraPlugins = [ "@deepseek-ai/dsh-experimental-session-search" ];
        userPatches = [
          {
            insert = [
              {
                id = "str-replace-editor";
                name = "@deepseek-ai/dsh-tool-str-replace-editor";
              }
            ];
          }
        ];
        inherit inBoxNames;
      };
      artifact = profilesLib.buildProfile {
        inherit pkgs profile;
        install = dshPackage.dev;
        inherit (dshPackage) profileMeta;
      };
    in
    pkgs.runCommand "dsh-profile-template-extension-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.jq
        ];
      }
      ''
        expected=$(node --expose-internals --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${dshPackage}/lib/read-profile-template.mjs ${dshPackage} web) || exit 1
        jq -e --argjson want "$(printf '%s' "$expected" | jq -c '. + ["@deepseek-ai/dsh-experimental-session-search"]')" \
          '.dsh.profile.bundles == $want' ${artifact}/package.json >/dev/null \
          || { echo "profile-template-extension: template bundles were not kept in order" >&2; exit 1; }
        jq -e '.[0].insert[0].name == "@deepseek-ai/dsh-tool-str-replace-editor"' \
          ${artifact}/cordis.patch.yml >/dev/null \
          || { echo "profile-template-extension: user patch layer missing" >&2; exit 1; }
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${artifact} "$home/profiles/web-extended"
        chmod -R u+w "$home/profiles/web-extended"
        if ! ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} web-extended "$home" --port 0 --no-open \
          > "$TMPDIR/check.log" 2>&1; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
        if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        touch "$out"
      '';

  # Genuine user-declared buildNpmPackage regression: the raw
  # derivation goes straight into `plugins` (no installedRoot selectors).
  profile-user-npm =
    (import (rootSrc + "/tests/user-npm.nix") {
      inherit pkgs;
      inherit dshPackage;
      checker = "${checkProfile}/bin/check-profile.mjs";
    }).check;

  boot-checker-wiring = import (rootSrc + "/tests/boot-checker.nix") { inherit pkgs checkProfile; };

  profile-regression = (import (rootSrc + "/tests/profile-regression.nix") { inherit pkgs; }).check;

  home-module =
    pkgs.runCommand "dsh-home-module-check"
      {
        src = rootSrc;
        nativeBuildInputs = [ pkgs.nix ];
      }
      ''
        cd "$src"
        NIX_STATE_DIR="$TMPDIR/nix-state" \
          ${pkgs.nix}/bin/nix-instantiate --eval --strict --json \
          --arg pkgs 'import ${pkgs.path} {}' \
          tests/home-module.nix > "$TMPDIR/result.json"
        ${pkgs.jq}/bin/jq -e '.all == true' "$TMPDIR/result.json" > /dev/null
        touch "$out"
      '';

  # Build-time fail-loud: boot each in-box profile with dsh's own
  # boot() (which runs auditStartupEntries) and dispose.  A
  # profile that would fail at runtime — missing services, failed
  # activation — fails `nix build` here instead.
  profile-boot-web =
    pkgs.runCommand "dsh-profile-boot-web-check"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${webArtifact} "$home/profiles/web"
        chmod -R u+w "$home/profiles/web"
        if ! ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} web "$home" --port 0 --no-open \
          > "$TMPDIR/check.log" 2>&1; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
        if grep -Eq 'did not activate|ERR_MODULE_NOT_FOUND|Cannot find package' "$TMPDIR/check.log"; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        touch "$out"
      '';

  # Boot the real dsh wrapper's web profile and stop it after the server
  # reports its URL.  This exercises the production launcher + profile
  # resolution, not the checker's internal boot API.
  profile-cli-web =
    pkgs.runCommand "dsh-profile-cli-web-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.coreutils
        ];
      }
      ''
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${webArtifact} "$home/profiles/web"
        chmod -R u+w "$home/profiles/web"
        set +e
        NODE_OPTIONS="--require ${./fixtures/no-net-guard.cjs}" \
          DSH_HOME="$home" timeout 15 ${dshPackage}/bin/dsh \
          --profile web --port 0 --no-open > "$TMPDIR/web.log" 2>&1
        rc=$?
        set -e
        # timeout returns 124 after a successful long-running server.
        if [ "$rc" -ne 124 ]; then
          cat "$TMPDIR/web.log" >&2
          echo "profile-cli-web: dsh web exited unexpectedly (rc=$rc)" >&2
          exit 1
        fi
        grep -q '^dsh web: http://' "$TMPDIR/web.log" \
          || { cat "$TMPDIR/web.log" >&2; exit 1; }
        if grep -Eq 'did not activate|ERR_MODULE_NOT_FOUND|Cannot find package|NETWORK_FORBIDDEN' "$TMPDIR/web.log"; then
          cat "$TMPDIR/web.log" >&2
          exit 1
        fi
        touch "$out"
      '';

  # Exercise the real dsh wrapper (not the checker's internal boot API) for
  # the profile entrypoint.  --help resolves the shipped profile and imports
  # the launcher without starting an application task.
  profile-cli-help =
    pkgs.runCommand "dsh-profile-cli-help-check"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        home="$TMPDIR/home"
        mkdir -p "$home"
        if ! NODE_OPTIONS="--require ${./fixtures/no-net-guard.cjs}" \
          DSH_HOME="$home" ${dshPackage}/bin/dsh --profile headless --help \
          > "$TMPDIR/help.log" 2>&1; then
          cat "$TMPDIR/help.log" >&2
          exit 1
        fi
        grep -q '^Usage: dsh --profile headless' "$TMPDIR/help.log" \
          || { cat "$TMPDIR/help.log" >&2; exit 1; }
        ! grep -q 'NETWORK_FORBIDDEN' "$TMPDIR/help.log" \
          || { cat "$TMPDIR/help.log" >&2; exit 1; }
        touch "$out"
      '';

  profile-boot-headless =
    pkgs.runCommand "dsh-profile-boot-headless-check"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${headlessArtifact} "$home/profiles/headless"
        chmod -R u+w "$home/profiles/headless"
        # The headless runner starts during apply without
        # appReady. This boot-only fixture disables that row and
        # parses help instead of starting a model/application task.
        # It covers base + headless startup, NOT runner execution.
        printf '%s\n' '[{"id":"headless-runner","disabled":true}]' \
          > "$home/profiles/headless/cordis.patch.yml"
        # Fail closed on any outbound network attempt during boot; the
        # headless launcher must reach CHECK-OK without egress.
        if ! NODE_OPTIONS="--require ${./fixtures/no-net-guard.cjs}" \
          ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} headless "$home" --help \
          > "$TMPDIR/check.log" 2>&1; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
        touch "$out"
      '';

  # Optional official bundles need no packaging: base + web-app plus two
  # experimental bundles (session-search, the worktree tool) must boot
  # exactly like the plain web profile.
  profile-boot-experimental =
    let
      profile = profilesLib.mkProfile {
        name = "experimental";
        plugins = [
          "@deepseek-ai/dsh-base"
          "@deepseek-ai/dsh-web-app"
          "@deepseek-ai/dsh-experimental-session-search"
          "@deepseek-ai/dsh-experimental-tool-worktree"
        ];
        inherit inBoxNames;
      };
      artifact = profilesLib.buildProfile { inherit pkgs profile; };
    in
    pkgs.runCommand "dsh-profile-boot-experimental-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.jq
        ];
      }
      ''
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${artifact} "$home/profiles/experimental"
        chmod -R u+w "$home/profiles/experimental"
        # Composition is exact: all four declared bundles, order kept.
        jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-experimental-session-search", "@deepseek-ai/dsh-experimental-tool-worktree"]' \
          "$home/profiles/experimental/package.json" >/dev/null
        if ! ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} experimental "$home" --port 0 --no-open \
          > "$TMPDIR/check.log" 2>&1; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
        # A dropped optional bundle would still let the boot pass; assert
        # the launcher reported no skipped bundle.
        if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        touch "$out"
      '';

  # An official cordis plugin package that ships without a bundle of
  # its own mounts without packaging: a patch row in the profile's own
  # layer names the package and the name resolves from the built
  # installation (no bundle, no extra Nix packaging).  base + web-app +
  # one official tool plugin (str-replace-editor, no dsh.bundle) must
  # compose the row and boot CHECK-OK.
  profile-official-plugin =
    let
      profile = profilesLib.mkProfile {
        name = "official-plugin";
        plugins = [
          "@deepseek-ai/dsh-base"
          "@deepseek-ai/dsh-web-app"
        ];
        userPatches = [
          {
            insert = [
              {
                id = "str-replace-editor";
                name = "@deepseek-ai/dsh-tool-str-replace-editor";
              }
            ];
          }
        ];
        inherit inBoxNames;
      };
      artifact = profilesLib.buildProfile { inherit pkgs profile; };
    in
    pkgs.runCommand "dsh-profile-official-plugin-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.jq
        ];
      }
      ''
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${artifact} "$home/profiles/official-plugin"
        chmod -R u+w "$home/profiles/official-plugin"
        jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]' \
          "$home/profiles/official-plugin/package.json" >/dev/null
        grep -q 'str-replace-editor' "$home/profiles/official-plugin/cordis.patch.yml"
        if ! ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} official-plugin "$home" --port 0 --no-open \
          > "$TMPDIR/check.log" 2>&1; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
        if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        touch "$out"
      '';

  # A real third-party plugin packaged as a Nix derivation (the user
  # route): the user-npm fixture is a real buildNpmPackage derivation
  # with a manifest bundle; the profile links it like any Nix plugin.
  profile-nix-plugin =
    let
      plugin = import (rootSrc + "/tests/fixtures/user-npm-plugin.nix") { inherit pkgs; };
      profile = profilesLib.mkProfile {
        name = "nix-plugin";
        plugins = [
          "@deepseek-ai/dsh-base"
          "@deepseek-ai/dsh-web-app"
          plugin
        ];
        userPatches = [ ];
        inherit inBoxNames;
      };
      artifact = profilesLib.buildProfile { inherit pkgs profile; };
    in
    pkgs.runCommand "dsh-profile-nix-plugin-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.jq
        ];
      }
      ''
        jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@dsh-poc/user-npm-plugin"]' \
          ${artifact}/package.json >/dev/null
        test -L ${artifact}/node_modules/@dsh-poc/user-npm-plugin
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${artifact} "$home/profiles/nix-plugin"
        chmod -R u+w "$home/profiles/nix-plugin"
        if ! ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} nix-plugin "$home" --port 0 --no-open \
          > "$TMPDIR/check.log" 2>&1; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
        if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        touch "$out"
      '';

  # Official ON-DEMAND bundles by name: dsh-subagent-codex and
  # dsh-subagent-claude-code are not installation dependencies, but the
  # pinned dsh source builds them; dsh-nix links the installed package
  # and boots with no skipped bundle.
  profile-official-on-demand =
    let
      profile = profilesLib.mkProfile {
        name = "official-on-demand";
        plugins = [
          "@deepseek-ai/dsh-base"
          "@deepseek-ai/dsh-web-app"
        ]
        ++ onDemandBundles;
        inherit inBoxNames;
        installBundles = onDemandBundles;
      };
      artifact = profilesLib.buildProfile {
        inherit pkgs profile;
        install = dshPackage.dev;
        inherit (dshPackage) profileMeta;
      };
    in
    pkgs.runCommand "dsh-profile-official-on-demand-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.jq
        ];
        bootBundles = builtins.toJSON onDemandBundles;
      }
      ''
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${artifact} "$home/profiles/official-on-demand"
        chmod -R u+w "$home/profiles/official-on-demand"
        want=$(jq -cn --argjson extra "$bootBundles" '["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"] + $extra')
        jq -e --argjson want "$want" '.dsh.profile.bundles == $want' \
          "$home/profiles/official-on-demand/package.json" >/dev/null
        printf '%s\n' "$bootBundles" | jq -r '.[]' | while IFS= read -r name; do
          test -f "$home/profiles/official-on-demand/node_modules/$name/package.json"
        done
        test -e "$home/profiles/official-on-demand/node_modules/@deepseek-ai/dsh-subagent-codex/node_modules/@openai/codex"
        test -e "$home/profiles/official-on-demand/node_modules/@deepseek-ai/dsh-subagent-claude-code/node_modules/@anthropic-ai/claude-agent-sdk"
        if ! ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} official-on-demand "$home" --port 0 --no-open \
          > "$TMPDIR/check.log" 2>&1; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
        if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
          cat "$TMPDIR/check.log" >&2
          exit 1
        fi
        touch "$out"
      '';

  # Counterexample: web-app without base must fail the boot check
  # with dsh's own fail-loud (pending services), proving the check
  # catches the composition error at build time.
  # The user runtime must not carry test-only workspace packages or test
  # runners.  This is a regression guard for the build/runtime split.
  plugin-roots = import ./plugin-roots.nix { inherit pkgs; };

  runtime-clean =
    pkgs.runCommand "dsh-runtime-clean-check"
      {
        nativeBuildInputs = [ pkgs.findutils ];
        dsh = dshPackage;
      }
      ''
        if [ -e "$dsh/packages/test-support" ]; then
          echo "runtime-clean: test-support is present in the runtime artifact" >&2
          exit 1
        fi
        if find "$dsh" -type d \( -name vitest -o -name playwright -o -name jsdom -o -name '@testing-library' \) -print -quit | grep -q .; then
          echo "runtime-clean: test runner package is present in the runtime artifact" >&2
          exit 1
        fi
        touch "$out"
      '';

  profile-boot-web-nobase =
    pkgs.runCommand "dsh-profile-boot-web-nobase-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.jq
        ];
      }
      ''
        home="$TMPDIR/home"
        mkdir -p "$home/profiles"
        cp -a ${webArtifact} "$home/profiles/web-nobase"
        chmod -R u+w "$home/profiles/web-nobase"
        jq '.dsh.profile.bundles = ["@deepseek-ai/dsh-web-app"]' \
          "$home/profiles/web-nobase/package.json" > "$TMPDIR/package.json"
        mv "$TMPDIR/package.json" "$home/profiles/web-nobase/package.json"
        if ${pkgs.nodejs}/bin/node --expose-internals \
          --require ${dshPackage}/lib/dsh-builtin-compat.cjs \
          ${checkProfile}/bin/check-profile.mjs \
          ${dshPackage} web-nobase "$home" --port 0 --no-open \
          > "$TMPDIR/check.log" 2>&1; then
          echo "profile-boot-web-nobase: expected fail-loud, got success" >&2
          exit 1
        fi
        grep -q 'did not activate' "$TMPDIR/check.log" \
          || { cat "$TMPDIR/check.log" >&2; exit 1; }
        touch "$out"
      '';
}
