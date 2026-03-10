# LINSTOR マルチリージョンマイグレーション スクリプト・ドキュメント検証テスト

- **実施日時**: 2026年3月10日 06:50 - 11:30 (JST)

## 前提・目的

LINSTOR/DRBD マルチリージョン環境でのマイグレーション操作を自動化するスクリプト群と、手動操作チュートリアルの品質を実クラスタで検証する。

### 背景

- 2回のテスト (2026-03-09) で全フェーズ成功し、手順の再現性は確認済み
  - [report/2026-03-09_010540_linstor_migration_test.md](2026-03-09_010540_linstor_migration_test.md)
  - [report/2026-03-09_035515_linstor_migration_retest.md](2026-03-09_035515_linstor_migration_retest.md)
- 知見をドキュメント化し、スクリプト化した成果物の検証が目的

### 検証対象

| # | ファイル | 種別 |
|---|---------|------|
| 1 | `scripts/linstor-drbd-sync-wait.sh` | 新規スクリプト |
| 2 | `scripts/linstor-migrate-live.sh` | 新規スクリプト |
| 3 | `scripts/linstor-migrate-cold.sh` | 新規スクリプト |
| 4 | `scripts/linstor-multiregion-setup.sh` | 既存スクリプト修正 |
| 5 | `docs/linstor-multiregion-ops.md` | 既存ドキュメント更新 |
| 6 | `docs/linstor-multiregion-tutorial.md` | 新規チュートリアル |

## 環境情報

| ノード | ホスト名 | IP | リージョン | LINSTOR 状態 |
|--------|----------|-----|----------|-------------|
| 4号機 | ayase-web-service-4 | 10.10.10.204 | region-a | 稼働中 |
| 5号機 | ayase-web-service-5 | 10.10.10.205 | region-a | 稼働中 |
| 6号機 | ayase-web-service-6 | 10.10.10.206 | region-b | 稼働中 |
| 7号機 | ayase-web-service-7 | 10.10.10.207 | region-b | LINSTOR 未登録 |

- OS: Debian 13.3 (Trixie) + Proxmox VE 9.1.6
- カーネル: 6.17.13-1-pve
- LINSTOR Controller: ayase-web-service-4
- テスト VM: VM 200 (bench-vm, 4 cores, 4GB RAM, 32GB disk)
- リソース: pm-39c4600d (striped-pool, 4ストライプ)

## テスト結果サマリ

| Phase | 操作 | 結果 | 備考 |
|-------|------|------|------|
| P1 | 環境確認 | OK | 3ノード LINSTOR、2+1 トポロジー確認 |
| P2 | ライブマイグレーション (双方向) | OK | `linstor-migrate-live.sh` 使用 |
| P3 | コールドマイグレーション B→A | OK | `linstor-migrate-cold.sh` 使用 |
| P4 | リージョン廃止 (B 削除) | OK | node 6 削除、VM 継続稼働 |
| P5 | リージョン追加 (B 再追加) | OK (修正後) | C8: LV サイズ不一致を発見・解決 |
| P6 | コールドマイグレーション A→B | OK (修正後) | setup スクリプト修正後成功 |

**イテレーション数: 1** (修正はテスト中にインラインで適用)

## テスト詳細

### P1: 環境確認

初期状態: VM 200 が node 4 (region-a) で稼働中。リソース pm-39c4600d が node 4, 5 (UpToDate) + node 6 (UpToDate, Protocol A DR レプリカ) に配置。

### P2: ライブマイグレーション

`linstor-migrate-live.sh` を使用:

```
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-live.sh 200 ayase-web-service-5
```

- node 4 → node 5: 成功
- node 5 → node 4: 成功
- 同一リージョン検証、UpToDate 検証が正常動作

#### スクリプト修正 (テスト中に発見)

1. **`.volumes[0].state` → `.volumes[0].state.disk_state`**: yq が JSON オブジェクトを返し文字列比較に失敗。`sync-wait.sh` と `migrate-live.sh` の両方を修正。
2. **リソース名検出ロジック**: `test("_${VMID}$")` で全リソースを検索する方式から、InUse ノードの `qm config` から `scsi0:` 行を解析する方式に変更。LINSTOR リソース名にはVMIDが含まれないため。

### P3: コールドマイグレーション B→A

```
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh 200 region-b region-a
```

全3フェーズ (レプリカ準備 → VM 移行 → DR 再構成) が正常完了。

### P4: リージョン廃止

`linstor-multiregion-node.sh` を使用して node 6 を削除:

```
./pve-lock.sh run ./oplog.sh ./scripts/linstor-multiregion-node.sh remove ayase-web-service-6
```

- リソース削除、ノード削除が正常完了
- VM 200 は node 4 で継続稼働

### P5: リージョン追加 (重要な発見あり)

node 6 を LINSTOR に再追加し、DR レプリカを構成。

#### 手順

1. `linstor-multiregion-node.sh add` でノード追加 → 成功
2. cross-region パス作成 (create-delete-recreate パターン) → C7 発生も想定通り
3. リソース作成 `linstor resource create ayase-web-service-6 pm-39c4600d`

#### C8: LV サイズ不一致 (新規発見)

**症状**: リソース作成後、DRBD 接続が StandAlone のまま。dmesg に以下:

```
drbd pm-39c4600d/0 drbd1000 ayase-web-service-6: The peer's disk size is too small! (67110832 < 67127216 sectors)
```

**原因**: node 4 の LV はストライプ構成 (4デバイス) で PE アライメントにより 8196 PE (32.02 GiB)。node 6 の LV は非ストライプで 8194 PE (32.01 GiB)。差分は 16384 セクタ (8MB)。

| ノード | 構成 | PE 数 | セクタ数 |
|--------|------|-------|---------|
| 4号機 (ストライプ) | sda,sdb,sdc,sdd × 2049 PE | 8196 | 67141632 |
| 6号機 (非ストライプ) | sda × 8194 PE | 8194 | 67125248 |

**解決**: リソースを削除 → `lvcreate -n pm-39c4600d_00000 -l 8196 linstor_vg` で正しいサイズの LV を手動作成 → `linstor resource create` で再登録 → 同期開始。

**教訓**: ストライプ構成が異なるノード間で DRBD レプリケーションする場合、LV サイズが PE アライメントの違いにより数 MB 異なることがある。小さい側のノードでは手動で LV を拡張する必要がある。

#### StandAlone からの復旧手順

StandAlone 状態に入ると `drbdadm disconnect/connect` や `drbdadm adjust` では復旧できない。リソース削除 → LV サイズ修正 → リソース再作成が必要。

#### 同期結果

手動で Protocol A を設定後、約 320 秒で 32GB 同期完了。

### P6: コールドマイグレーション A→B

#### 1回目: 失敗

```
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh 200 region-a region-b
```

**エラー**: `linstor resource create ayase-web-service-7 pm-39c4600d` → "Node 'ayase-web-service-7' not found"

**原因**: config/linstor.yml の region-b に node 7 が含まれるが、LINSTOR に未登録。

#### スクリプト修正

1. **`linstor-migrate-cold.sh`**: `filter_linstor_nodes()` 関数を追加。config のノード一覧を LINSTOR に実在するノードでフィルタ。
2. **`linstor-multiregion-setup.sh`**: `node_exists_in_linstor()` 関数を追加。`node set-property` の前にノード存在チェックを挿入。

#### 2回目: 成功

修正後の再実行で全3フェーズ正常完了:
- Phase 1: target region (region-b) にレプリカ 1 (node 6 のみ)、同期済み
- Phase 2: VM 停止 → source レプリカ削除 → VM 再作成 → 起動
- Phase 3: DR レプリカ (node 4) 作成 → Protocol A → 同期 (約 320 秒)

最終状態:
- VM 200: node 6 (region-b) で running
- pm-39c4600d: node 6 (InUse, UpToDate) + node 4 (Unused, UpToDate)

## 発見した問題と修正

| # | 分類 | 問題 | 修正ファイル |
|---|------|------|------------|
| 1 | バグ | yq パス `.volumes[0].state` が JSON オブジェクトを返す | `sync-wait.sh`, `migrate-live.sh` |
| 2 | バグ | リソース名検出が VMID サフィックスを仮定 | `migrate-live.sh`, `migrate-cold.sh` |
| 3 | 新規 (C8) | ストライプ/非ストライプ間の LV サイズ不一致 | 手動 LV 作成で対処 |
| 4 | バグ | config に存在するが LINSTOR 未登録ノードで失敗 | `migrate-cold.sh`, `multiregion-setup.sh` |

## 性能データ

| 操作 | 所要時間 | データ量 |
|------|---------|---------|
| DRBD 同期 (cross-region) | 約 320 秒 | 32 GB |
| コールドマイグレーション全体 (同期済み) | 約 10 秒 | - |
| コールドマイグレーション全体 (DR 同期含む) | 約 340 秒 | 32 GB |

## 結論

全6フェーズのテストが1イテレーションで完了 (修正はインライン適用)。スクリプトは実クラスタで正常動作することを確認。

### 主要な教訓

1. **C8 (LV サイズ不一致)**: ストライプ構成が異なるノード間では DRBD レプリケーションに LV サイズの手動調整が必要になることがある。ドキュメント・スキルファイルに追記が必要。
2. **config と LINSTOR の不整合**: config/linstor.yml に記載されたノードが LINSTOR に存在しない場合のハンドリングが重要。`filter_linstor_nodes()` による動的フィルタで対応。
3. **StandAlone 復旧**: LV サイズ不一致による StandAlone は `drbdadm adjust` では復旧不可。リソース削除 → LV 修正 → 再作成が唯一の手段。
