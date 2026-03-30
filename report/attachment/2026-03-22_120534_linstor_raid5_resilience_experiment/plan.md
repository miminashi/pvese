# LINSTOR 1ノード最小運用 + ディスク障害耐性 調査・実験計画

## Context

電力節約のため、Region B (7,8,9号機) を最小1ノード (7号機) で運用し、VM数増加に応じて8号機・9号機を順に追加する運用を目指す。どのノード数でもディスク障害に耐えられる構成が必要。

### 要件

1. **1ノード (7号機のみ) で VM 作成・運用可能**
2. **どのノード数でもディスク1本の障害に耐える**
3. **スケールアップ**: 8号機→9号機を順に起動・クラスタ復帰
4. **スケールダウン**: レプリカを移動 (evacuate) してからノード停止

## 現状の問題

| 項目 | 現在の設定 | 問題 |
|------|-----------|------|
| place-count | 2 | 1ノードでリソース作成不可 |
| ストレージ | LVM stripe (RAID0) | ディスク1本故障で全損 |
| PERC H710 | VD1-3: 各1本 RAID-0 | ディスク冗長性なし |

## 解決策: PERC H710 RAID5 + 動的 place-count

### アーキテクチャ

```
PERC H710 RAID5 (3本 → 2本分容量, ~1.6 TiB)  ← ディスク冗長
  └─ LVM VG (linstor_vg, single PV)
      └─ LINSTOR storage-pool (striped-pool)
          └─ DRBD リソース (place-count を動的に変更)
```

- **RAID5**: PERC H710 の BBU write-back cache により書き込みペナルティを軽減
- **place-count 動的管理**: ノード数に合わせて 1→2→3 に増減
- LVM ストライプ不要 (RAID5 が内部でストライプ処理)

### 運用フロー

```
[1ノード] place-count=1, RAID5 でディスク保護
    ↓ 8号機起動 → rejoin → place-count=2 → adjust (レプリカ追加)
[2ノード] place-count=2, DRBD + RAID5
    ↓ 9号機起動 → rejoin → place-count=3 → adjust
[3ノード] place-count=3, DRBD 3-way + RAID5
    ↓ place-count=2 → adjust (9号機のレプリカ削除) → depart → 電源断
[2ノード] place-count=2
    ↓ place-count=1 → adjust → depart → 電源断
[1ノード] place-count=1
```

### 障害耐性マトリクス

| ノード数 | place-count | ノード障害 | ディスク障害 | ノード+ディスク |
|---------|------------|----------|------------|--------------|
| 1 | 1 | 不可 | RAID5 で保護 | 不可 |
| 2 | 2 | 1台まで可 | RAID5 で保護 | 可 (DRBD+RAID5) |
| 3 | 3 | 1台まで可 | RAID5 で保護 | 可 (DRBD+RAID5) |

## 実験手順

### Phase 0: 現状監査 (読み取りのみ)

対象: pve4 (LINSTOR controller), pve7/8/9, idrac7/8/9

1. LINSTOR 状態確認 (pve4 経由):
   - `linstor node list`, `resource list`, `storage-pool list`, `resource-group list`
2. Region B ディスクレイアウト (pve7/8/9):
   - `lsblk`, `pvs`, `vgs`
3. PERC RAID VD 構成 (idrac7/8/9):
   - `racadm raid get vdisks`, `racadm raid get pdisks`

### Phase 1: Region B クリーンアップ

1. Region B 上の VM 停止・削除
2. LINSTOR リソース削除 (Region B ノード分)
3. ストレージプール削除
4. LVM VG 削除 (pve7/8/9 の `linstor_vg`)

### Phase 2: PERC H710 RAID5 再構成

各ノード (pve7/8/9) で:

1. iDRAC SSH でデータ VD (VD1-3, 各 RAID-0) を削除:
   - `racadm raid deletevd:<VD_FQDD>`
2. 3本のデータディスクで RAID-5 VD を作成:
   - `racadm raid createvd:<controller_FQDD> -rl r5 -pdkey:<pd1>,<pd2>,<pd3> -name data-r5`
3. ジョブキュー作成・実行:
   - `racadm jobqueue create <controller_FQDD> -r pwrcycle -s TIME_NOW -e TIME_NA`
4. RAID 初期化完了を待機 (background init: 数十分〜1時間程度)
5. 新しい VD が `/dev/sdb` として認識されることを確認

**3台並行で実施可能** (各ノードの iDRAC は独立)

### Phase 3: LVM + LINSTOR セットアップ

各ノードで:

1. LVM PV/VG 作成:
   - `pvcreate /dev/sdb && vgcreate linstor_vg /dev/sdb`
2. LINSTOR ストレージプール作成 (pve4 経由):
   - `linstor storage-pool create lvm <node> striped-pool linstor_vg`
   - LvcreateOptions は不要 (単一 PV、RAID5 がストライプ処理)
3. リソースグループ作成 (place-count=1 で開始):
   ```
   linstor resource-group create pve-rg-b --place-count 1 --storage-pool striped-pool
   linstor resource-group drbd-options --protocol C pve-rg-b
   linstor resource-group drbd-options --quorum off pve-rg-b
   linstor resource-group drbd-options --auto-promote yes pve-rg-b
   linstor volume-group create pve-rg-b
   ```

### Phase 4: テスト1 — 1ノード運用 + ディスク障害

1. 8号機・9号機を電源断 (7号機のみ稼働)
2. テストリソース作成 (10 GiB): `linstor resource-group spawn-resources pve-rg-b test-resilience 10G`
3. 7号機でテストデータ書き込み + md5sum 記録
4. **ディスク障害シミュレーション**: PERC H710 の物理ディスク1本を強制オフライン
   - `perccli` / `storcli` で pdisk offline (要ツール確認)
   - または racadm 経由
5. RAID5 VD がデグレード状態で継続動作することを確認
6. テストデータの md5sum 検証 → **データ生存確認**
7. 物理ディスク復旧 → RAID リビルド完了を確認

### Phase 5: テスト2 — スケールアップ (1→2→3)

1. 8号機電源投入 → SSH 待機 → IPoIB 設定
2. LINSTOR satellite 確認: `linstor node list`
3. place-count を 2 に増加 + adjust:
   ```
   linstor resource-group modify pve-rg-b --place-count 2
   linstor resource-group adjust pve-rg-b
   ```
4. test-resilience が pve7 + pve8 に配置されることを確認
5. DRBD sync 待機
6. 同様に 9号機を追加 → place-count=3 → adjust → 3ノード全配置確認

### Phase 6: テスト3 — スケールダウン (3→2→1)

1. place-count を 2 に減少:
   ```
   linstor resource-group modify pve-rg-b --place-count 2
   linstor resource-group adjust pve-rg-b
   ```
   - 9号機のレプリカが削除されることを確認
   - (adjust が特定ノードを選ばない場合は手動で `linstor resource delete <node> <resource>`)
2. 9号機を正常離脱: `linstor node delete ayase-web-service-9` (または電源断)
3. 同様に place-count=1 → adjust → 8号機離脱
4. 1ノード (7号機) でリソースがアクセス可能なことを確認

### Phase 7: テスト4 — 2ノード運用中のノード障害 + ディスク障害

1. 8号機を再追加 → place-count=2 → 2ノード運用
2. 8号機を IPMI 電源断 (障害シミュレーション)
3. 7号機のみでリソースアクセス可能を確認
4. 7号機で RAID5 ディスク障害シミュレーション
5. デグレード RAID5 でデータ生存を確認 → **ノード障害 + ディスク障害の同時耐性を実証**

### Phase 8: 復旧・クリーンアップ

1. 全ディスク復旧、全ノード電源投入
2. place-count=3 に設定、全リソース UpToDate を確認

## 主要リスクと対策

| リスク | 対策 |
|-------|------|
| racadm で pdisk offline ができない | `storcli` / `perccli` をインストール (PERC H710 = LSI MegaRAID ベース) |
| RAID5 初期化に時間がかかる | 3台並行実施 + background init |
| LVM RAID kernel bug (raid10.c:3454) | 今回はハードウェア RAID5 のため dm-raid 不使用、影響なし |
| adjust が意図しないノードからレプリカ削除 | 手動 `linstor resource delete` で制御 |

## 変更対象ファイル

- PERC H710 VD 構成 (racadm 経由、3台)
- LVM VG 再作成 (3台)
- LINSTOR ストレージプール・リソースグループ再作成
- `config/linstor.yml` — storage_pool_type, lvcreate_options 更新
- `report/` — 実験レポート作成

## 検証基準

1. 1ノードでリソース作成 + VM 運用可能
2. 1ノード運用中にディスク1本障害 → RAID5 でデータ生存
3. スケールアップ (1→2→3) でレプリカ自動追加
4. スケールダウン (3→2→1) でレプリカ移動後にノード停止
5. 2ノード運用中にノード障害 + ディスク障害 → データ生存
