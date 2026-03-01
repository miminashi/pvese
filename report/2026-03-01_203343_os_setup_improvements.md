# OS セットアップスキル改善レポート

- **実施日時**: 2026年3月1日 20:33

## 前提・目的

6号機の OS セットアップ (Debian 13 + PVE 9) を os-setup スキルで実行した際に発見された2つの問題を改善する。

- **背景**: 6号機セットアップ時、フェーズ状態が5号機のものと共有されており全8フェーズを手動リセットする必要があった。また POST code 0x01 が3分以上 stale のまま変化しなかったが、実際にはサーバは正常にブート済みだった
- **目的**: フェーズ状態のサーバ別分離と、POST code 0x01 stale ケースのドキュメント追記
- **前提条件**: 既存の `os-setup-phase.sh` が動作していること

## 環境情報

- ローカルマシン: Ubuntu (Claude Code 実行環境)
- 対象スクリプト: `scripts/os-setup-phase.sh`
- 対象ドキュメント: `.claude/skills/os-setup/SKILL.md`, `.claude/skills/os-setup/reference.md`

## 問題の詳細

### 問題 1: フェーズ状態がグローバル

`os-setup-phase.sh` の状態ディレクトリが `state/os-setup/` の1つだけで、全サーバで共有されていた。5号機セットアップ完了後に6号機を実行すると、全8フェーズが "done" のまま残っており、`reset` を8回手動実行する必要があった。

### 問題 2: POST code 0x01 の stale 値

Power On 後、POST code が 0x01 (SEC: 電源投入、リセット検出) のまま3分以上変化しなかった。実際にはサーバは正常にブートしており SSH 接続も可能だった。`reference.md` の stale 値判定テーブルには 0x92 と 0x00 のケースしか記載されておらず、0x01 のケースが未対応だった。

## 対策内容

### 対策 1: `--config` オプションによるサーバ別状態分離

**ファイル**: `scripts/os-setup-phase.sh`

`parse_state_dir()` 関数に `--config` オプションを追加。設定ファイル名からサーバ名を自動導出してサーバ別の状態ディレクトリを使用する。

- `--config config/server6.yml` → `state/os-setup/server6/`
- `--config config/server5.yml` → `state/os-setup/server5/`
- `--state-dir` が同時に指定された場合は `--state-dir` が優先
- `--config` も `--state-dir` もなしの場合は従来通り `state/os-setup/` を使用（後方互換）

### 対策 2: SKILL.md の全コマンド例に `--config "$CONFIG"` を付与

**ファイル**: `.claude/skills/os-setup/SKILL.md`

- 初期化・status・next・mark・check・reset・times の全コマンド例に `--config "$CONFIG"` を追加
- Phase 6 の POST code 判定に 0x01 stale ケースを追記

### 対策 3: reference.md の POST code stale 値テーブルに 0x01 を追加

**ファイル**: `.claude/skills/os-setup/reference.md`

判定テーブルに以下の2行を追加:

| PowerState | POST code | SSH/ping | 判定 |
|------------|-----------|----------|------|
| On | 0x01 | 不達 (3分以上) | **stale 疑い** — KVM スクリーンショットで視覚確認 |
| On | 0x01 | 到達可能 | stale 確定 — POST code API は信頼不可 |

## テスト結果

### 後方互換テスト

`--config` なしの従来動作が正常に機能することを確認:

```
$ ./scripts/os-setup-phase.sh init
Initialized: /home/ubuntu/projects/pvese/state/os-setup

$ ./scripts/os-setup-phase.sh status
iso-download              done
preseed-generate          done
...

$ ./scripts/os-setup-phase.sh reset iso-download
Reset: iso-download

$ ./scripts/os-setup-phase.sh mark iso-download
Marked done: iso-download
```

### サーバ別状態分離テスト

```
$ ./scripts/os-setup-phase.sh init --config config/server5.yml
Initialized: /home/ubuntu/projects/pvese/state/os-setup/server5

$ ./scripts/os-setup-phase.sh init --config config/server6.yml
Initialized: /home/ubuntu/projects/pvese/state/os-setup/server6

$ ./scripts/os-setup-phase.sh mark iso-download --config config/server5.yml
Marked done: iso-download

$ ./scripts/os-setup-phase.sh status --config config/server5.yml
iso-download              done       ← server5 のみ done
preseed-generate          pending
...

$ ./scripts/os-setup-phase.sh status --config config/server6.yml
iso-download              pending    ← server6 は独立して pending
preseed-generate          pending
...
```

### 状態ディレクトリパス確認

- `state/os-setup/server5/` — 正常に作成
- `state/os-setup/server6/` — 正常に作成
- `state/os-setup/` — 従来通りフェーズファイルが直接配置

全テスト合格。テスト後のクリーンアップ済み。
