# LINSTOR マルチリージョンマイグレーション再現性テスト (2回目)

- **実施日時**: 2026年3月9日 11:02 - 12:55 JST
- **1回目レポート**: [2026-03-09 マイグレーションテスト](2026-03-09_010540_linstor_migration_test.md)

## 前提・目的

2026-03-09 に実施した LINSTOR マルチリージョンマイグレーションテスト (Phase 0-5) の再現性を確認する。

- 背景: 1回目のテストで全 Phase 成功。操作手順の再現性と障害パターンの再現有無を検証する
- 目的: 同一環境で Phase 1-5 を再実行し、1回目と同じ結果が得られるか確認する
- 前提条件: Phase 0 (2+1 トポロジー構成) は完了済み。VM 200 が Region B (6号機) で稼働中

## 環境情報

| 項目 | 値 |
|------|-----|
| Region A (pvese-cluster1) | 4号機 (10.10.10.204, controller) + 5号機 (10.10.10.205) |
| Region B (pvese-cluster2) | 6号機 (10.10.10.206) + 7号機 (10.10.10.207) |
| LINSTOR コントローラ | 4号機 (10.10.10.204:3370) |
| DRBD | 9.3.0 |
| LINSTOR | 1.33.1 |
| PVE | 9.1.6 |
| カーネル | 6.17.13-1-pve |
| テスト VM | VM 200 (bench-vm), 4GiB RAM, 4 cores, 32GiB DRBD disk, kvm64 CPU |
| VM 管理 IP | 10.10.10.210/8 |
| テストデータ | 512 MiB urandom (md5sum: 3ba0fc5d86eb0244bda2ed8116a01a58) |

## テスト結果サマリ

| Phase | テスト | 結果 | 備考 |
|-------|--------|------|------|
| Phase 1 | リージョン内ライブマイグレーション | **成功** | 双方向, ゼロダウンタイム |
| Phase 2 | コールドマイグレーション B→A | **成功** | VM config 再作成方式 |
| Phase 3 | リージョン廃止 (B 削除) | **成功** | linstor-multiregion-node.sh remove |
| Phase 4 | リージョン追加 (B 再追加) | **成功** | C3 (stale パス) 再発、対策で解消 |
| Phase 5 | コールドマイグレーション A→B (復帰) | **成功** | ラウンドトリップでデータ整合性維持 |

## 1回目 vs 2回目 比較

| 項目 | 1回目 | 2回目 | 差異 |
|------|-------|-------|------|
| Phase 1: 6→7 ダウンタイム | 73ms | **37ms** | 改善 (約半分) |
| Phase 1: 6→7 転送量 | 911 MiB | **834 MiB** | やや減少 |
| Phase 1: 6→7 所要時間 | 18秒 | **17秒** | ほぼ同等 |
| Phase 1: 7→6 ダウンタイム | 33ms | **74ms** | 増加 (方向による変動) |
| Phase 1: 7→6 転送量 | 349 MiB | **844 MiB** | 増加 |
| Phase 1: 7→6 所要時間 | 11秒 | **15秒** | やや増加 |
| Phase 2: コールドマイグレーション B→A | 成功 | **成功** | 同一手順で再現 |
| Phase 3: リージョン廃止 | 成功 | **成功** | 同一手順で再現 |
| Phase 4: stale パス (C3) 発生 | あり | **あり** | 再現性あり (LINSTOR の既知動作) |
| Phase 4: PeerClosingConnectionException | 不明 | **あり (新規)** | パス作成時の一過性エラー |
| Phase 5: ラウンドトリップ整合性 | OK | **OK** | md5sum 一致 |
| Phase 5: 最終状態 | 6号機Primary, 7号機Secondary, 4号機DR | **同一** | 完全一致 |

## Phase 1: リージョン内ライブマイグレーション

### 結果

| テスト | 結果 | ダウンタイム | 転送量 | 時間 |
|--------|------|------------|--------|------|
| 6号機 → 7号機 | 成功 | 37ms | 834 MiB | 17秒 |
| 7号機 → 6号機 | 成功 | 74ms | 844 MiB | 15秒 |

- uptime が連続 (VM リブートなし)
- データ整合性 OK (md5sum 一致)
- DRBD Primary ロールが移行先に正常遷移
- DR レプリカ (4号機) は UpToDate を維持

### 1回目との比較考察

ダウンタイムは方向によって変動する (1回目: 6→7=73ms/7→6=33ms、2回目: 6→7=37ms/7→6=74ms)。平均値は同等レンジ (1回目平均: 53ms、2回目平均: 55.5ms)。転送量の差異は VM のメモリ使用状態 (dirty pages) に依存。

## Phase 2: コールドマイグレーション (Region B → A)

1回目と同一手順で成功:

1. 5号機にレプリカ追加 + cross-region パス作成
2. DRBD 同期完了待ち (32GiB, 約2.5分)
3. VM 停止 → Region B レプリカ削除
4. VM config を Region A (4号機) に再作成
5. `qm set --scsi0 linstor-storage:pm-39c4600d_200` で既存リソースをアタッチ
6. VM 起動 → データ整合性 OK

## Phase 3: リージョン廃止 (Region B ノード削除)

`linstor-multiregion-node.sh remove` で7号機 → 6号機の順に削除。1回目と同一手順で成功。

## Phase 4: リージョン追加 (Region B 再追加)

### C3 (stale パス) の再現

1回目と同様に、ノード remove/re-add 後に stale パスの問題が再発:

1. `node-connection path create` で PeerClosingConnectionException が一部発生 (1回目では未報告の新パターン)
2. リソース作成時に `Network interface 'default' of node ... does not exist!` エラー
3. パスの delete + recreate で解消

#### 新知見: PeerClosingConnectionException

パス作成時に一過性の `PeerClosingConnectionException` エラーが発生。ノード再登録直後のパス作成で衛星ノードとの通信が不安定な場合に発生する模様。パス自体は作成されるが、DRBD の adjust が失敗する。delete + recreate で完全に解消。

#### 対策手順 (確定)

ノード remove/re-add 後のパス作成は以下の手順が確実:

1. `path create` を実行 (エラーが出る可能性あり)
2. `path delete` で一旦削除
3. `path create` で再作成 (今度は成功)
4. リソース作成

## Phase 5: コールドマイグレーション復帰 (Region A → B)

1回目と同一手順で成功:

1. 7号機にレプリカ追加 (C3 エラーなし — パスが有効)
2. DRBD 同期完了待ち
3. VM 停止 → Region A レプリカ削除
4. VM config を Region B (6号機) に再作成
5. VM 起動 → **データ整合性 OK** (md5sum: `3ba0fc5d86eb0244bda2ed8116a01a58`)
6. 4号機に DR レプリカ追加 → Protocol A 設定 → 同期完了

### 最終状態

```
Region B (Primary):
  ayase-web-service-6: pm-39c4600d InUse UpToDate (Primary)
  ayase-web-service-7: pm-39c4600d Unused UpToDate (Secondary)
  (Protocol C, allow-two-primaries=yes)

Region A (DR):
  ayase-web-service-4: pm-39c4600d Unused UpToDate (Secondary)
  (Protocol A, allow-two-primaries=no)
```

## 障害パターンまとめ

| ID | 障害 | 1回目 | 2回目 | 再現性 |
|----|------|-------|-------|--------|
| C3 | node remove/re-add 後の stale パス | 発生 | **発生** | 100% 再現 |
| C7 (新規) | パス作成時の PeerClosingConnectionException | 未報告 | **発生** | 条件依存 (ノード再登録直後) |

### C7: パス作成時の PeerClosingConnectionException

**発生条件**: ノード remove/re-add 直後の `node-connection path create` 実行時。
**症状**: パスは作成されるが、衛星ノードへの適用が PeerClosingConnectionException で失敗。
**影響**: DRBD の adjust が実行されず、後続のリソース作成で C3 (default does not exist) エラーが発生。
**対策**: パスの delete + recreate。2回目の create は安定して成功する。

## 再現性の結論

| 観点 | 結果 |
|------|------|
| 手順の再現性 | 全 Phase で1回目と同一手順が有効 |
| 結果の再現性 | 全 Phase 成功、最終状態が完全一致 |
| 障害パターンの再現性 | C3 (stale パス) は確実に再発。対策 (delete + recreate) も確実に有効 |
| ライブマイグレーションの性能 | ダウンタイム平均値は同等レンジ (53ms vs 55.5ms)。方向による変動あり |
| データ整合性 | 2回のラウンドトリップ (1回目 B→A→B + 2回目 B→A→B) でデータ完全一致 |

**操作手順は再現性が確認された。スキルに記載の手順で安定的に運用可能。**

### 添付

- [テスト計画書](attachments/2026-03-09_035515_linstor_migration_retest_plan.md)
