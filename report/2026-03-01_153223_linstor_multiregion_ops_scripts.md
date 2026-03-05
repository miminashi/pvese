# LINSTOR マルチリージョン運用マニュアル・スクリプト作成レポート

- **実施日時**: 2026年3月1日 15:32
- **Issue**: #29 (関連)

## 前提・目的

Issue #29 の per-connection protocol 実験結果をもとに、DRBD/LINSTOR マルチリージョン構成の運用マニュアルとスクリプトを作成する。

- **背景**: per-connection protocol 設定 (Protocol A/C の使い分け) が検証済みだが、手順が手作業に依存しており再現性が低い
- **目的**: オペレータ向けの運用マニュアルと、繰り返し使うコマンド群のスクリプトを作成する
- **前提条件**: DRBD 9.3.0 / LINSTOR 1.33.1 環境、2 ノード構成で検証

### 参照レポート

- [LINSTOR マルチリージョン per-connection protocol 実験レポート](2026-03-01_051957_linstor_multi_region_protocol_experiment.md)

## 環境情報

| 項目 | 値 |
|------|-----|
| Node 4 | ayase-web-service-4 (10.10.10.204) |
| Node 5 | ayase-web-service-5 (10.10.10.205) |
| DRBD | 9.3.0 |
| LINSTOR | 1.33.1 |
| リソース | pm-c0401219, vm-100-cloudinit |

## 成果物

### 1. 運用マニュアル: `docs/linstor-multiregion-ops.md`

7 セクション構成:

1. アーキテクチャ概要 (構成図、設定差分表、排他制約)
2. 初期セットアップ (スクリプト案内 + 手動手順)
3. 状態確認 (スクリプト案内 + 個別コマンド)
4. リージョン内ライブマイグレーション (前提条件、PVE CLI 手順)
5. リージョン間フェイルオーバー (計画的 / 障害時 / フェイルバック)
6. ノード追加・削除 (スクリプト案内)
7. トラブルシューティング (error 139、スプリットブレイン、同期遅延)

### 2. スクリプト群

| スクリプト | サブコマンド | 機能 |
|-----------|-------------|------|
| `scripts/linstor-multiregion-setup.sh` | `setup <config>` | Aux/site 設定 + リージョン間 Protocol A 一括設定 |
| | `teardown <config>` | Protocol C 復元 + オーバーライドクリア + Aux/site 削除 |
| `scripts/linstor-multiregion-status.sh` | `[<config>]` | 全ノード Aux/site、per-connection protocol、DRBD 同期状態表示 |
| `scripts/linstor-multiregion-node.sh` | `add <node> <region> <config>` | ノード追加: Aux/site + Protocol A 設定 |
| | `remove <node> <config>` | ノード削除: オーバーライドクリア + リソース/SP/ノード削除 |

### 3. 設定ファイル拡張: `config/linstor.yml`

```yaml
regions:
  region-a:
    - ayase-web-service-4
  region-b:
    - ayase-web-service-5
```

## スクリプト設計

- POSIX sh (`#!/bin/sh`, `set -eu`)
- `config/linstor.yml` から `./bin/yq` で設定読み取り
- SSH 経由で LINSTOR コントローラにコマンド実行
- リソース一覧は `linstor -m resource list` で 1 回取得してキャッシュ (SSH 回数最小化)
- 状態変更コマンドは echo で実行内容を表示してから実行

## 検証手順と結果

5 ステップの往復テストを実施:

### Step 1: status (初期状態)

```
ayase-web-service-4: Aux/site=region-a  [OK]      (前回実験の残り)
ayase-web-service-5: Aux/site=region-b  [OK]
pm-c0401219:      protocol=default(C)  allow-two-primaries=default(yes)
vm-100-cloudinit: protocol=default(C)  allow-two-primaries=default(yes)
```

### Step 2: setup 実行

```sh
./oplog.sh ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
```

結果: 全 SUCCESS。Aux/site 設定 + 2 リソース × 1 ノードペア = 2 件の resource-connection 設定。

### Step 3: status (setup 後)

```
pm-c0401219:      protocol=A  allow-two-primaries=no
vm-100-cloudinit: protocol=A  allow-two-primaries=no
```

両リソースとも UpToDate 維持。ライブで Protocol 変更が適用された。

### Step 4: teardown 実行

```sh
./oplog.sh ./scripts/linstor-multiregion-setup.sh teardown config/linstor.yml
```

結果: 全 SUCCESS。Protocol C 復元 → オーバーライドプロパティ削除 → Aux/site 削除。

### Step 5: status (teardown 後)

```
ayase-web-service-4: Aux/site=(not set)  [config: region-a]
ayase-web-service-5: Aux/site=(not set)  [config: region-b]
pm-c0401219:      protocol=default(C)  allow-two-primaries=default(yes)
vm-100-cloudinit: protocol=default(C)  allow-two-primaries=default(yes)
```

初期状態に完全復元。

## 実装中に修正した問題

### 1. LINSTOR の JSON 出力フラグ

`linstor resource list --output-version=v1` はサブコマンドの後に配置すると argparse エラーになった。`linstor -m resource list` (`-m` はトップレベルフラグ) に変更。

### 2. `-m` 出力の JSON 構造

`-m` 出力は `[[{resource}, ...]]` 構造 (配列の配列)。`--output-version=v1` の `[{resources: [{...}]}]` とは異なるため、yq パスを `.[0][].name` に修正。

### 3. teardown の変数参照バグ

teardown 関数内で未定義の `$na`/`$nb` を参照していた箇所を `$node_a`/`$node_b` に修正。

## 結論

- setup/teardown の往復テストで、マルチリージョン Protocol A 設定の適用と復元が正常に動作することを確認
- スクリプトは LINSTOR リソース一覧を 1 回キャッシュする設計で SSH 呼び出し回数を最小化
- 運用マニュアルは実験レポートの知見を手順書として再構成し、トラブルシューティングセクションを追加
