# LINSTOR マルチリージョン運用マニュアル

## 1. アーキテクチャ概要

### リージョン構成図

```
Region A                              Region B
┌───────────────────────┐             ┌───────────────────────┐
│ PVE Cluster           │             │ PVE Cluster           │
│ ┌─────────┐ ┌───────┐ │ Protocol A  │ ┌───────┐ ┌─────────┐ │
│ │ Node A1 │─│Node A2│─│─────────────│─│Node B1│─│ Node B2 │ │
│ └─────────┘ └───────┘ │  (async)    │ └───────┘ └─────────┘ │
│   Protocol C (sync)   │  no 2pri    │   Protocol C (sync)   │
│   allow-2pri: yes     │             │   allow-2pri: yes     │
│   Aux/site=region-a   │             │   Aux/site=region-b   │
└───────────────────────┘             └───────────────────────┘
         ↕                                      ↕
  ライブマイグレーション可              ライブマイグレーション可
         ↔ ─ ─ ─ ─ ─ フェイルオーバーのみ ─ ─ ─ ─ ─ ↔
```

### リージョン内 vs リージョン間の設定差分

| 項目 | リージョン内 | リージョン間 |
|------|------------|------------|
| Protocol | C (同期) | A (非同期) |
| allow-two-primaries | yes | **no** |
| ライブマイグレーション | 可 | **不可** |
| フェイルオーバー | 可 | 可 (手動) |
| 設定レベル | resource-group (デフォルト) | resource-connection (オーバーライド) |
| Corosync | 同一クラスタ (< 5ms RTT) | 独立クラスタ or 不要 |

### 前提条件・制約

- **allow-two-primaries と Protocol の排他制約**: DRBD カーネルモジュールは `allow-two-primaries yes` と Protocol A/B の共存を許可しない (error 139)。Protocol A/B を使う接続では必ず `allow-two-primaries no` を設定する
- **`--protocol` と `--allow-two-primaries` は同時に設定する**: 片方だけ変更すると DRBD カーネルが拒否する
- **LINSTOR 設定の優先順位**: `resource-connection > node-connection > resource-definition > resource-group > controller`
- **DRBD 9.x / LINSTOR 1.33+ が必要**: per-connection protocol 設定には DRBD 9 の機能が必要

## 2. 初期セットアップ

### 2.1 config/linstor.yml にリージョン情報を定義

```yaml
regions:
  region-a:
    - node-a1
    - node-a2
  region-b:
    - node-b1
    - node-b2
```

### 2.2 セットアップスクリプトの実行

```sh
./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
```

このスクリプトは以下を実行する:

1. 各ノードに `Aux/site` プロパティを設定
2. 異なるリージョン間のノードペアに対して、各リソースの resource-connection に `--protocol A --allow-two-primaries no` を設定

### 2.3 手動で設定する場合

```sh
# Aux/site プロパティの設定
linstor node set-property <node> Aux/site <region-name>

# リージョン間 Protocol A の設定 (各リソース×リージョン間ノードペアに対して)
linstor resource-connection drbd-peer-options <nodeA> <nodeB> <resource> \
  --protocol A --allow-two-primaries no
```

### 2.4 設定確認

```sh
./scripts/linstor-multiregion-status.sh config/linstor.yml
```

## 3. 状態確認

### 3.1 ステータス一覧表示

```sh
./scripts/linstor-multiregion-status.sh [config/linstor.yml]
```

表示内容:
- 全ノードの Aux/site プロパティ (config との整合性チェック付き)
- 各リソースの per-connection protocol 設定 (intra-region / INTER-REGION 表示)
- DRBD 同期状態 (linstor resource list)
- DRBD 接続詳細 (drbdsetup status)

### 3.2 個別確認コマンド

リージョン/サイト割り当ての確認:

```sh
linstor node list-properties <node> | grep Aux/site
```

per-connection Protocol の確認:

```sh
linstor resource-connection list-properties <nodeA> <nodeB> <resource>
```

DRBD 同期状態の確認:

```sh
drbdsetup status --verbose --statistics
```

out-of-sync 量の確認:

```sh
drbdsetup status --statistics | grep out-of-sync
```

## 4. リージョン内ライブマイグレーション

### 4.1 前提条件の確認

ライブマイグレーション前に以下を確認する:

1. **Protocol C であること**: リージョン内接続のデフォルト
2. **allow-two-primaries yes であること**: resource-group レベルで設定済み
3. **両ノードが UpToDate であること**:
   ```sh
   linstor resource list
   ```

### 4.2 PVE CLI での手順

```sh
# VM のライブマイグレーション
qm migrate <vmid> <target-node> --online
```

### 4.3 確認項目

- マイグレーション中、一時的にデュアルプライマリ状態になる (正常)
- マイグレーション完了後、移行元が Secondary に降格する (auto-promote)
- DRBD 状態が両ノードで UpToDate であること

## 5. リージョン間フェイルオーバー

### 5.1 計画的フェイルオーバー (メンテナンス時)

メンテナンスウィンドウで元リージョンの VM を DR サイトに移行する手順:

1. **DRBD 同期完了を確認**:
   ```sh
   drbdsetup status --statistics | grep out-of-sync
   ```
   out-of-sync が 0 であることを確認。

2. **元リージョンで VM を停止**:
   ```sh
   qm stop <vmid>
   ```

3. **DR サイトで VM を起動**:
   ```sh
   qm start <vmid>
   ```
   `auto-promote yes` により、DRBD デバイスを open した時点で自動的に Primary に昇格する。

4. **状態確認**:
   ```sh
   linstor resource list
   drbdsetup status
   ```

### 5.2 障害時フェイルオーバー

元リージョンが応答不能になった場合:

1. **障害を確認**:
   ```sh
   # 元リージョンのノードに接続不可
   linstor resource list
   ```
   障害ノードのリソースが `Unknown` や `Connecting` になる。

2. **DR サイトで VM を起動**:
   ```sh
   qm start <vmid>
   ```
   `quorum=off` の場合、単独ノードでも Primary 昇格が可能。

3. **注意**: Protocol A (非同期) のため、障害発生時点で未同期のデータが失われる可能性がある (RPO > 0)。

### 5.3 フェイルバック

元リージョンが復旧した後、VM を戻す手順:

1. **元リージョンのノード復旧を確認**:
   ```sh
   linstor node list
   linstor resource list
   ```
   復旧ノードのリソースが `SyncTarget` → `UpToDate` に遷移するのを待つ。

2. **DRBD 再同期完了を待機**:
   ```sh
   drbdsetup status --statistics | grep out-of-sync
   ```
   out-of-sync が 0 になるまで待機。

3. **DR サイトで VM を停止**:
   ```sh
   qm stop <vmid>
   ```

4. **元リージョンで VM を起動**:
   ```sh
   qm start <vmid>
   ```

5. **状態確認**:
   ```sh
   linstor resource list
   ```

## 6. ノード追加・削除

### 6.1 リージョンへのノード追加

前提: ノードが LINSTOR に登録済み (IB インターフェース、ストレージプール設定済み)。
未登録の場合は先に LINSTOR ノード作成を行う。

```sh
./scripts/linstor-multiregion-node.sh add <node> <region> config/linstor.yml
```

スクリプトの処理:
1. `Aux/site` プロパティを設定
2. 異なるリージョンのノードとの間で、各リソースに Protocol A + allow-two-primaries no を設定

追加後の確認:

```sh
./scripts/linstor-multiregion-status.sh config/linstor.yml
```

### 6.2 リージョンからのノード削除

```sh
./scripts/linstor-multiregion-node.sh remove <node> config/linstor.yml
```

スクリプトの処理:
1. リージョン間の resource-connection オーバーライドを Protocol C に復元後クリア
2. ノードのリソースを全て削除
3. ストレージプールを削除
4. `Aux/site` プロパティを削除
5. LINSTOR ノードを削除

**注意**: place-count の変更 (必要に応じて `linstor resource-group modify <rg> --place-count N`) はスクリプトの責務外。事前に手動で調整すること。

## 7. トラブルシューティング

### 7.1 "Protocol C required" エラー (error 139)

```
Failure: (139) Protocol C required
```

**原因**: `allow-two-primaries yes` が設定された状態で Protocol A/B を設定しようとした。

**対処**:
```sh
# --protocol と --allow-two-primaries を同時に設定する
linstor resource-connection drbd-peer-options <nodeA> <nodeB> <resource> \
  --protocol A --allow-two-primaries no
```

`--protocol` のみの設定は常に失敗する。必ず両方を同時に変更すること。

### 7.2 スプリットブレイン

リージョン間で両方のノードが Primary になった場合 (障害時フェイルオーバー後に元リージョンも復帰した場合等)、スプリットブレインが発生する可能性がある。

**検知**:
```sh
drbdsetup status
# StandAlone 状態や SplitBrain 警告を確認
```

**対処**:
1. データが新しい方のノードを特定
2. 古い方のノードで:
   ```sh
   drbdadm disconnect <resource>
   drbdadm secondary <resource>
   drbdadm connect --discard-my-data <resource>
   ```
3. 新しい方のノードで:
   ```sh
   drbdadm disconnect <resource>
   drbdadm connect <resource>
   ```

**注意**: スプリットブレイン解消は破壊的操作。必ずバックアップを確認してから実行すること。

### 7.3 リージョン間同期遅延

Protocol A では非同期レプリケーションのため、同期遅延が発生する。

**確認**:
```sh
drbdsetup status --statistics | grep -E '(out-of-sync|send)'
```

**大量の out-of-sync が継続する場合の原因と対処**:

| 原因 | 対処 |
|------|------|
| ネットワーク帯域不足 | WAN 帯域の拡張、DRBD の c-max-rate 調整 |
| 書き込み量過多 | ワークロード調整、DR 側ディスク性能確認 |
| ネットワーク断 | `drbdsetup status` で接続状態を確認、ルーティング確認 |

## 参考資料

- [LINSTOR マルチリージョン per-connection protocol 実験レポート](../report/2026-03-01_051957_linstor_multi_region_protocol_experiment.md)
- [DRBD Protocol 比較レポート](../report/2026-02-27_074430_drbd_protocol_comparison.md)
- [LINBIT DRBD Users Guide — Protocol](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-replication-protocols)
- [LINBIT LINSTOR Users Guide — Resource Connections](https://linbit.com/linstor-user-guide/linstor-guide-1_0-en/)
