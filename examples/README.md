# Examples

These examples include flake outputs (`web`, `headless`, `local-plugin`) and are built and booted by the repository checks, so they double as examples of the supported composition forms and cannot silently rot.

| Path | Demonstrates | Consumed by |
|---|---|---|
| `profiles/web.nix` | a profile composed from official bundle names (`dsh-base` + `dsh-web-app`) | `packages.web`, `profile-boot-web` |
| `profiles/headless.nix` | an official headless composition | `packages.headless`, `profile-boot-headless` |
| `profiles/local-plugin.nix` | a profile built from a local plugin bundle passed by path | `packages.local-plugin`, `profile-local-plugin`, `profile-boot-local-plugin`, `scripts/profile-smoke.sh` |
| `plugins/example-plugin/` | a minimal plugin bundle: `package.json` `dsh.bundle.patch`, `cordis.patch.yml`, and an `apply`/dispose example | `local-plugin` |

`local-plugin` is a lifecycle smoke example, not a TUI: the plugin writes `example-plugin.log` in the DSH home and stays alive until its fiber is disposed.

Test-only fixtures live under `tests/fixtures/` (for example the lifecycle probe the Home Manager tests reuse); this directory contains examples only.
