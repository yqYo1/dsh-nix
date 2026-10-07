# dsh-nix

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) を Nix で構築し、profile と Home Manager の設定を宣言的に管理します。
DSH のソースは flake input で固定し、現在の package は `0.2.0-rc.2` です。

- **`pkgs.dsh`**: pnpm monorepo から構築する CLI package。
- **profile packager**: plugin の依存解決と profile の構成を build 時に行います。
- **`programs.dsh`**: `~/.dsh` 内の profile 構成を管理する Home Manager module。session・設定・credential などの利用者データとは管理範囲を分離します。

## plugin の構成

profile の `plugins` には、次の形式を宣言順に混在させられます。

- **in-box bundle**: `"@deepseek-ai/dsh-base"` などの名前。実行する DSH package から解決します。
- **pnpm spec**: `"dsh-codex@0.3.2"` や `"github:someone/plugin"`。build 時に transitive／peer dependency を含む pnpm graph を構築します。
- **Nix package**: 利用者が宣言した `pkgs.buildNpmPackage { ... }` などの derivation。構築済み plugin の依存 closure を保持したまま profile にリンクします。
- **Nix path**: `./my-plugin` など、直下に `package.json` がある構築済み plugin directory。必要な runtime dependency もその成果物に含めます。

各 package の `dsh.bundle.patch` 宣言から layer を登録します。
`plugins` の宣言順が layer 順であり、pnpm manifest や lockfile の key 順には依存しません。
spec の transitive／peer dependency は runtime graph に保持しますが、profile の直接 plugin や layer には昇格させません。
scoped package は scope directory 内の package ごとにリンクするため、同じ scope の Nix plugin と共存できます。
spec と Nix plugin の package 名が衝突した場合は build が失敗します。

## 利用方法

### overlay

```nix
imports = [ inputs.dsh-nix.nixosModules.default ];
# または overlay を直接追加します。
nixpkgs.overlays = [ inputs.dsh-nix.overlays.default ];

environment.systemPackages = [ pkgs.dsh ];
```

Home Manager module の `package` は、overlay 適用時には `pkgs.dsh` を使い、それ以外は同梱の `pkgs/dsh.nix` で構築します。
明示的に指定した `package` は、module が別の package に置き換えたり再包装したりしません。

### Home Manager

```nix
inputs.dsh-nix.url = "github:yqYo1/dsh-nix";
inputs.dsh-nix.inputs.nixpkgs.follows = "nixpkgs";

imports = [ inputs.dsh-nix.homeManagerModules.dsh ];

programs.dsh = {
  enable = true;
  profiles.headless = {
    plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-headless" ];
  };
  profiles.web = {
    plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
  };
  profiles.custom = {
    plugins = [
      "@deepseek-ai/dsh-base"
      "dsh-codex@0.3.2"
    ];
    specsLock = ./custom-pnpm-lock.yaml;
    specsHash = "sha256-..."; # 実 build が報告した hash を指定します。
    userPatchesFile = ./patches.yml;
  };
  homePatchesFile = ./home-patches.yml;
  # settings = { ... }; # ~/.dsh/settings.yaml が無い場合だけ初期値を書き込みます。
};
```

activation は immutable profile を `~/.dsh/profiles/<name>` に展開し、stamp によって同一成果物の再展開を省略します。
module が所有する profile の構成は更新・削除されますが、session・設定・credential や管理対象外の profile は保持します。

```sh
dsh --profile headless "task"
dsh --profile web # http://127.0.0.1:3080
```

### 単独での build

```sh
nix build --accept-flake-config .#dsh
nix build --accept-flake-config .#tui-spec
nix eval .#profiles.tui-spec --json
```

`default` package／app は `dsh` です。
flake configuration を受け入れると、公開 binary cache `yqyo1.cachix.org` を利用できます。
署名検証用の公開鍵は `flake.nix` に固定されており、download に token は不要です。
GitHub Actions からの cache upload には repository secret `CACHIX_AUTH_TOKEN` を使用します。

`dsh-acp-demo` app も公開しています。
これは stdio 上の JSON-RPC を使用する ACP server で、`--config` に leaf `cordis.yml` を指定します。
設定例は upstream の `examples/acp-agent/cordis.yml` を参照してください。

## ユーザー定義 npm package

`pkgs.buildNpmPackage` の derivation は、`plugins` に直接指定します。
ソース、`package-lock.json`、`npmDepsHash` と build の設定は利用者の package 宣言で管理し、dsh-nix は完成した plugin を profile に構成します。
この指定に `specsLock`／`specsHash` は不要です。

以下は、前節の Home Manager module を import した設定に加える例です。
`./my-plugin` は `package.json`、`package-lock.json`、`dsh.bundle.patch` が参照する patch と runtime のソースを含む npm project とします。

```nix
{ pkgs, ... }:
let
  myPlugin = pkgs.buildNpmPackage {
    pname = "my-plugin";
    version = "1.0.0";
    src = ./my-plugin;
    npmDepsHash = pkgs.lib.fakeHash; # 初回 build の got: を取得して置き換えます。
    dontNpmBuild = true; # コンパイル不要な plugin の例です。
  };
in
{
  programs.dsh = {
    enable = true;
    profiles.custom.plugins = [ "@deepseek-ai/dsh-base" myPlugin ];
  };
}
```

`src` には、利用者の flake で固定した source input も指定できます。
初回 build が報告した `got:` の実 hash を `npmDepsHash` に指定し、同じ宣言を再 build して成功を確認します。
コンパイルが必要な plugin は、`dontNpmBuild` を省略して必要な npm build script を実行します。

plugin root は build 時に解決します。
成果物の直下に `package.json` があればその directory を優先し、なければ `lib/node_modules/<name>/package.json`（scoped package を含む）の直接 package を探します。
候補がゼロ件または複数件の場合は build が失敗します。
package 名は derivation の `pname` ではなく、選択した `package.json` の `name` から読み取ります。
plugin 内の `node_modules` は移動や flatten をせず保持するため、transitive dependency は plugin の既存構成から解決されます。

## spec plugin の依存固定

`specsLock` には、対象の spec plugin だけを root importer (`.`) の直接依存として宣言した、pnpm 11 の `pnpm-lock.yaml` を指定します。
余分な workspace importer は許可しません。
version・integrity・peer dependency の組合せを記録した lockfile 自体を、設定とともに Git で管理してください。
plugin の追加・更新時は、同じ Nix 管理の pnpm 11 環境で lockfile を更新します。
ローカル `file:` spec の例と lockfile は `examples/profiles/tui-spec.nix` と `examples/profiles/tui-spec-pnpm-lock.yaml` にあります。

lockfile を指定した build は `--frozen-lockfile` で実行します。
宣言との不一致、余分な直接依存、欠落した registry integrity などは失敗し、未固定の依存解決へ fallback しません。
frozen install でも、cache に存在しない固定済み package の download は発生します。

`specsHash` は依存解決の入力ではなく、構築した成果物を検証する hash です。
lockfile 更新後は `specsHash = "";` で build し、Nix が実際に報告した `got:` を指定して再度 build します。
完全な runtime graph を保持する本変更では成果物が変わるため、旧形式の hash は再取得が必要です。

互換性のため `specsLock` を省略した hash-only 設定も利用できます。
ただし registry の version range を再解決するため、同じ設定の cold build が異なる成果物になり得ます。
再現可能な設定には `specsLock` と `specsHash` の両方を指定してください。

## 回帰検証

```sh
# 公開 flake: profile 成果物・rc.2 boot・HM 非依存の検証
nix flake check --accept-flake-config --no-update-lock-file --no-write-lock-file
# 専用 test flake: 固定した実 Home Manager での評価・sandbox activation
nix flake check ./tests --accept-flake-config --no-update-lock-file --no-write-lock-file
# TUI の実起動・破棄確認
nix develop --accept-flake-config --no-update-lock-file --no-write-lock-file -c bash scripts/profile-smoke.sh
# 実 daemon・driver 0 による profile install → activation → boot
nix develop ./tests --accept-flake-config --no-update-lock-file --no-write-lock-file -c bash scripts/hm-e2e.sh
```

公開 flake は Home Manager に依存しません。
HM を使用する回帰検証だけを `tests/` subflake に分離し、HM pin は `tests/flake.lock` のみで管理します。
[catppuccin/nix の dev-flake](https://github.com/catppuccin/nix/blob/main/dev/flake.nix) と同様の分離です。
相対 input (`path:../.`) を使用するため、Nix >= 2.26 が必要です。
利用者側の Home Manager の選択や `homeManagerModules.dsh` の import 方法は変えません。
公開 flake の input／lock を更新した場合は、`nix flake lock ./tests` も実行してテスト側の graph を同期してください。
DSH updater は両 lock を同期した後、公開 checks・専用 tests checks・実 host E2E を実行します。

- **validator／成果物**: 宣言順、固定した lock bytes、scope 内の共存、直接 plugin のみの投影、実 transitive import を検証します。
- **Codex runtime**: fresh HOME/XDG と通信拒否 guard を使用し、実 CLI、package 付属の private pnpm を使用する `dsh plugin exec`、実 profile の boot/dispose を検証します。
- **ユーザー定義 npm package**：本物の `buildNpmPackage` の derivation を直接宣言し、標準出力 root の選択、曖昧な入力の拒否、依存 import、CLI、rc.2 の boot と lifecycle を検証します。
- **HM sandbox**: 実 activation program を複数世代で実行し、spec profile とユーザー定義 npm package の展開、実 import、削除、再実行、利用者データの保持、symlink の拒否を検証します。sandbox 内の Nix CLI は shim であり、実 host の package install の証明とは区別します。
- **HM host**: scratch に HOME/XDG／Nix state を隔離し、実 daemon と driver 0 で指定 package を install し、展開した npm plugin の実 import、CLI、rc.2 boot を検証します。実利用者の profile、gcroot、app data が変わらないことを外部 guard で確認します。

`scripts/check-profile.mjs` は、固定した rc.2 の `loadProfile` → `createRuntimeResolution` → `readProfilePatches` → `boot` の経路を使用します。
DSH 自身の startup audit が失敗した場合や boot 中に非ゼロの終了要求が発生した場合は、`CHECK-OK` を出さず失敗します。
boot 後は tree を dispose し、launcher readiness は確定しません。
この検証は認証済み generation や native compaction の動作証明ではありません。

`dsh-codex@0.3.2` の `doctor` は、対応 DSH API を `0.2.0-rc.1` と厳密比較するため、rc.2 に対して診断上の incompatibility と終了コード 1 を返します。
回帰検証ではこの診断をそのまま確認し、package metadata を偽装しません。
未ログイン時の `status` の終了コード 1 も、正確な `signed-out` 応答と import／通信の失敗を区別して検証します。
実際の agent 実行には credential の設定が必要です。

## 注意点

- module の既定 package を構築する nixpkgs は、`fetchPnpmDeps`・`pnpmConfigHook`・pnpm 11 を提供する必要があります。
- upstream の標準 surface は `web` と `headless` です。TUI は plugin として構成できます。
- `specsLock`／`specsHash` の更新や consumer の activation は、consumer 側の管理作業です。この repository のテストは consumer dotfiles を変更しません。

## ライセンス

MIT
