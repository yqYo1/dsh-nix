{ pkgs, checkProfile }:
pkgs.runCommand "dsh-boot-checker-wiring"
  {
    nativeBuildInputs = [ pkgs.nodejs ];
    src = ../.;
  }
  ''
    export SCRATCH="$TMPDIR/boot-wiring"
    export CHECKER="${checkProfile}/bin/check-profile.mjs"
    node "$src/tests/boot-checker-wiring.mjs" > "$TMPDIR/wiring.log" 2>&1 || {
      cat "$TMPDIR/wiring.log" >&2
      exit 1
    }
    mkdir -p "$out"
    cp "$TMPDIR/wiring.log" "$out/result.log"
    printf 'passed\n' > "$out/passed"
  ''
