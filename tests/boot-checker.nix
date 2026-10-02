# Contract tests are separate from the real-package boot checks: no mock
# result may stand in for booting the packaged rc.2 installation.
{ pkgs }:
pkgs.runCommand "dsh-boot-checker-wiring" {
  nativeBuildInputs = [ pkgs.nodejs ];
  src = ../.;
} ''
  export SCRATCH="$TMPDIR/boot-wiring"
  node "$src/tests/boot-checker-wiring.mjs" > "$TMPDIR/wiring.log" 2>&1 || {
    cat "$TMPDIR/wiring.log" >&2
    exit 1
  }
  mkdir -p "$out"
  cp "$TMPDIR/wiring.log" "$out/result.log"
  printf 'passed\n' > "$out/passed"
''
