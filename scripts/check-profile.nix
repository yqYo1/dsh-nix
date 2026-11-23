{ pkgs }:
pkgs.runCommand "dsh-nix-check-profile"
  {
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.typescript
    ];
  }
  ''
    mkdir -p "$out/bin"
    cp ${./check-profile.ts} "$TMPDIR/check-profile.ts"
    (cd "$TMPDIR" && tsc --ignoreConfig --target ES2022 --module ESNext \
      --moduleResolution bundler --skipLibCheck --outDir "$out/bin" check-profile.ts)
    mv "$out/bin/check-profile.js" "$out/bin/check-profile.mjs"
    patchShebangs "$out/bin/check-profile.mjs"
  ''
