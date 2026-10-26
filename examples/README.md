# Examples

These examples include flake outputs (`web`, `headless`, `local-plugin`) and are built and booted by the repository checks, so they double as examples of the supported composition forms and cannot silently rot.

| Path | Demonstrates | Consumed by |
|---|---|---|
| `profiles/web.nix` | a profile composed from official bundle names (`dsh-base` + `dsh-web-app`) | `packages.web`, `profile-boot-web` |
| `profiles/headless.nix` | an official headless composition | `packages.headless`, `profile-boot-headless` |
| `profiles/local-plugin.nix` | a profile built from a local plugin bundle passed by path | `packages.local-plugin`, `profile-local-plugin`, `profile-boot-local-plugin`, `scripts/profile-smoke.sh` |
| `plugins/lifecycle-probe/` | a minimal plugin bundle (`package.json` `dsh.bundle.patch`, `cordis.patch.yml`, `apply`/dispose markers) | `local-plugin`; the Home Manager tests use it as their activation/lifecycle fixture |

`local-plugin` is a lifecycle smoke example, not a TUI: the plugin writes `dsh-nix-lifecycle.log` in the DSH home and stays alive until its fiber is disposed.
The Home Manager tests reuse `plugins/lifecycle-probe` deliberately: the same example exercises the user-facing Nix plugin path end to end.
