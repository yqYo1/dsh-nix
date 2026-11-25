{
  lib,
  cfg,
  checkedArtifacts,
}:
let
  # Separate shell words: double-quoted $HOME prefix, single-quoted name.
  profileDir = name: "\"$HOME/.dsh/profiles\"/" + lib.escapeShellArg name;
  stampFile = name: "\"$HOME/.dsh/profiles\"/" + lib.escapeShellArg name + "/\".dsh-nix-stamp\"";
  managedFile = "$HOME/.dsh/.dsh-nix-managed-profiles";

  # Refuse symlinked roots BEFORE any profile write: the per-profile
  # rm -rf/mkdir/cp below must never run through a user-supplied symlink.
  # Checked again in activateCleanup below (defence in depth); this early
  # guard is what makes the refusal effective.
  activateRootGuard = ''
    if [ -L "$HOME/.dsh" ]; then
      echo "programs.dsh: refusing to manage $HOME/.dsh: symlinked root" >&2
      exit 1
    fi
    if [ -L "$HOME/.dsh/profiles" ]; then
      echo "programs.dsh: refusing to manage $HOME/.dsh/profiles: symlinked root" >&2
      exit 1
    fi
  '';

  activateProfile =
    name: artifact:
    let
      dir = profileDir name;
      stamp = stampFile name;
      artifactString = toString artifact;
      stagingTemplate = "\"$HOME/.dsh/profiles\"/" + lib.escapeShellArg ("." + name + ".staging.XXXXXX");
      previous = "\"$HOME/.dsh/profiles\"/" + lib.escapeShellArg ("." + name + ".previous");
    in
    ''
      if [ -f ${stamp} ] && [ "$(cat ${stamp})" = ${lib.escapeShellArg artifactString} ]; then
        :
      elif [[ -v DRY_RUN ]]; then
        echo "dshProfiles: would materialise profile ${lib.escapeShellArg name} from ${lib.escapeShellArg artifactString}"
      else
        if [ -L ${stamp} ]; then
          echo "dshProfiles: refusing to write through symlinked stamp ${stamp}" >&2
          exit 1
        fi
        # A previous interrupted replacement may have moved the old profile
        # aside; restore it before starting a new replacement.
        if [ ! -e ${dir} ] && [ -e ${previous} ]; then
          mv ${previous} ${dir}
        fi
        rm -rf ${previous}
        mkdir -p "$HOME/.dsh/profiles"
        stage=$(mktemp -d ${stagingTemplate})
        if ! cp -a ${lib.escapeShellArg artifactString}/. "$stage"/; then
          rm -rf "$stage"
          exit 1
        fi
        # cp -a syncs the destination directory attributes (read-only store
        # modes) too; dsh rewrites the profile root cordis.yml on every boot.
        if ! chmod -R u+w "$stage"; then
          rm -rf "$stage"
          exit 1
        fi
        if [ -e ${dir} ] || [ -L ${dir} ]; then
          mv ${dir} ${previous}
        fi
        if ! mv "$stage" ${dir}; then
          if [ -e ${previous} ]; then
            mv ${previous} ${dir}
          fi
          rm -rf "$stage"
          exit 1
        fi
        rm -rf ${previous}
        printf '%s' ${lib.escapeShellArg artifactString} > ${stamp}
      fi
    '';

  activateSettings = lib.optionalString (cfg.settings != { }) ''
    if [ ! -f "$HOME/.dsh/settings.yaml" ]; then
      if [[ -v DRY_RUN ]]; then
        echo "dshProfiles: would seed $HOME/.dsh/settings.yaml"
      else
      if [ -L "$HOME/.dsh/settings.yaml" ]; then
        echo "dshProfiles: refusing to write through symlinked settings.yaml" >&2
        exit 1
      fi
      mkdir -p "$HOME/.dsh"
      umask 077
      cat > "$HOME/.dsh/settings.yaml" <<'DSH_NIX_SETTINGS'
    ${builtins.toJSON cfg.settings}
    DSH_NIX_SETTINGS
      fi
    fi
  '';

  currentNames = lib.attrNames checkedArtifacts;

  # Remove profile directories this module previously managed but which are
  # no longer declared.  Only names recorded in our own manifest are ever
  # removed, and only as a single path component under
  # ~/.dsh/profiles (belt and braces alongside the eval-time name check),
  # so user-owned profiles are never touched.

  removeOrphanProfiles = if cfg.removeOrphanProfiles then "1" else "0";

  activateCleanup = ''
    removeOrphanProfiles=${lib.escapeShellArg removeOrphanProfiles}
    # Never follow a user-supplied symlink: rm -rf through a symlinked
    # root would delete the link target's contents.
    if [ -L "$HOME/.dsh/profiles" ]; then
      echo "programs.dsh: refusing to manage $HOME/.dsh/profiles: symlinked root" >&2
      exit 1
    fi
    if [[ -v DRY_RUN ]]; then
      echo "dshProfiles: dry run, skipping profile cleanup and manifest update"
    else
    mkdir -p "$HOME/.dsh/profiles"
    retained=""
    if [ -f "${managedFile}" ]; then
      while IFS= read -r old; do
        case "$old" in
          ${
            lib.concatStringsSep "|" (map lib.escapeShellArg (currentNames ++ [ "" ]))
          }) : ;; # still declared (or empty line)
          "." | ".." | "node_modules" | "" | *[/\\]*) : ;; # never delete unsafe, reserved, or empty entries
          *)
            if [[ "$old" == *[[:cntrl:]]* ]]; then
              :
            elif [ "$removeOrphanProfiles" = 1 ]; then
              stamp="$HOME/.dsh/profiles/$old/.dsh-nix-stamp"
              if [ -L "$stamp" ] || [ ! -f "$stamp" ] || ! grep -Eq '^/nix/store/[a-z0-9]+-dsh-profile-' "$stamp"; then
                echo "dshProfiles: keeping unmanaged orphan profile $old (invalid dsh-nix stamp)" >&2
                retained="$retained$old"$'\n'
              else
                rm -rf "$HOME/.dsh/profiles/$old"
              fi
            else
              echo "dshProfiles: keeping orphan profile $old (set programs.dsh.removeOrphanProfiles = true to remove)" >&2
              retained="$retained$old"$'\n'
            fi
            ;;
        esac
      done < "${managedFile}"
    fi
    # Rewrite the manifest only when it changed, so repeat activations are
    # byte-identical no-ops (command substitution strips trailing newlines
    # on both sides, keeping the comparison exact).
    new_managed=""
    if [ ${toString (builtins.length currentNames)} -gt 0 ]; then
      new_managed=$(printf '%s\n' ${lib.escapeShellArgs currentNames})
    fi
    new_managed="$new_managed$retained"
    if [ -L "${managedFile}" ]; then
      echo "dshProfiles: refusing to write through symlinked manifest ${managedFile}" >&2
      exit 1
    fi
    if [ ! -f "${managedFile}" ] || [ "$(cat "${managedFile}")" != "$new_managed" ]; then
      if [ -n "$new_managed" ]; then
        printf '%s\n' "$new_managed" > "${managedFile}"
      else
        : > "${managedFile}"
      fi
    fi
    fi
  '';

  activationScript =
    activateRootGuard
    + "\n"
    + lib.concatStringsSep "\n" (lib.mapAttrsToList activateProfile checkedArtifacts)
    + "\n"
    + activateCleanup
    + "\n"
    + activateSettings;

in
{
  inherit activationScript;
}
