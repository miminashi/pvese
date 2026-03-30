# LINSTOR ZFS raidz1 マルチリージョンマイグレーション実験

## Context

両リージョンを ZFS raidz1 に統一し、マルチリージョンマイグレーションを検証する。
- Region A (4+5+6号機): 現在 LVM thick-stripe → **ZFS raidz1 に変更** (既存データ消去 OK)
- Region B (7+8+9号機): ZFS raidz1 構築済み (ベンチマーク 2026-03-30)
- LVM のみの 5x マイグレーションテスト (2026-03-20) は成功済み

## Phase 0: 現状確認

1. `ssh pve4 "linstor storage-pool list"` — 全ノードのプール状態
2. `ssh pve4 "linstor resource list"` — 残存リソース確認
3. Region B ZFS 健全性: 7/8/9号機で `zpool status linstor_zpool`
4. Region A のディスク構成確認: 4/5/6号機で `lsblk`

## Phase 1: Region A を ZFS raidz1 に変更

### 1.1 LINSTOR リソース・プール削除

各ノード (4, 5, 6号機) で:
```sh
# 全リソース削除
linstor resource delete <node> <resource>  # 残存リソースがあれば
# ストレージプール削除
linstor storage-pool delete <node> striped-pool
```

### 1.2 LVM VG 削除

各ノードで SSH 経由:
```sh
vgremove -f linstor_vg
pvremove /dev/sda /dev/sdb /dev/sdc /dev/sdd
```

### 1.3 ZFS raidz1 プール作成

各ノードで SSH 経由:
```sh
# ZFS インストール (既にインストール済みか確認)
apt-get install -y zfsutils-linux

# raidz1 プール作成 (4ディスク: 3 data + 1 parity = 75% 容量効率)
zpool create linstor_zpool raidz1 sda sdb sdc sdd
zfs set compression=off linstor_zpool
zfs set atime=off linstor_zpool

# ARC 設定 (4 GiB)
echo 'options zfs zfs_arc_max=4294967296' > /etc/modprobe.d/zfs-arc.conf
echo 4294967296 > /sys/module/zfs/parameters/zfs_arc_max
```

### 1.4 LINSTOR ZFS ストレージプール作成

```sh
linstor storage-pool create zfs ayase-web-service-4 zfs-pool linstor_zpool
linstor storage-pool create zfs ayase-web-service-5 zfs-pool linstor_zpool
linstor storage-pool create zfs ayase-web-service-6 zfs-pool linstor_zpool
```

### 1.5 LINSTOR リソースグループ更新

`pve-rg` の `--storage-pool` を `zfs-pool` に変更:
```sh
linstor resource-group modify pve-rg --storage-pool zfs-pool
```

### 1.6 PVE ストレージ更新

Region A の `linstor-storage` が `pve-rg` を参照しているなら、リソースグループ更新で自動反映。
Region B の `linstor-storage-b` が `pve-rg-b` を参照しているか確認し、必要なら統一。

## Phase 2: config/linstor.yml 更新

```yaml
# グローバル設定を ZFS に変更
storage_pool_name: zfs-pool
storage_pool_type: zfs

# lvcreate_options は不要になるが互換性のため残す
# 各リージョンに storage_pool_name を追加
regions:
  region-a:
    storage_pool_name: zfs-pool
  region-b:
    storage_pool_name: zfs-pool
```

## Phase 3: スクリプト修正

### 3.1 scripts/linstor-migrate-cold.sh

**修正箇所 2 か所** — `resource create` に `--storage-pool` 追加:

スクリプト冒頭に変数追加:
```sh
TARGET_POOL=$("$YQ" ".regions.\"$TARGET_REGION\".storage_pool_name // .storage_pool_name" "$CONFIG")
SOURCE_POOL=$("$YQ" ".regions.\"$SOURCE_REGION\".storage_pool_name // .storage_pool_name" "$CONFIG")
```

- **L208**: `run_linstor "resource create $node $base_resource --storage-pool $TARGET_POOL"`
- **L322**: `run_linstor "resource create $dr_node $base_resource --storage-pool $SOURCE_POOL"`

### 3.2 scripts/linstor-multiregion-node.sh

`do_remove()` L187: リージョン別プール名解決:
```sh
region_pool=$("$YQ" ".regions.\"$node_region\".storage_pool_name // .storage_pool_name" "$CONFIG")
run_linstor "storage-pool delete $NODE $region_pool"
```

## Phase 4: テスト VM 準備

1. Region A (4号機) で VMID 200 作成
   - `linstor-storage`, `zfs-pool`, 32GiB ディスク
   - kvm64 CPU, 4096MiB RAM, vmbr1 + vmbr0 (10.10.10.210)
2. 512MiB テストデータ + MD5 チェックサム作成

## Phase 5: マイグレーション実験 (3 サイクル)

各サイクル:

| ステップ | 内容 | コマンド |
|---------|------|---------|
| S1 | コールド A→B (ZFS→ZFS) | `./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh 200 region-a region-b` |
| S2 | ライブ B 内 7→8→7 | `./scripts/linstor-migrate-live.sh 200 ayase-web-service-8` → `...7` |
| S3 | コールド B→A (ZFS→ZFS) | `./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh 200 region-b region-a` |
| S4 | ライブ A 内 4→5→4 | `./scripts/linstor-migrate-live.sh 200 ayase-web-service-5` → `...4` |

各ステップ後: `md5sum -c checksums.txt` + `linstor resource list`

## 検証方法

1. 各マイグレーション後に VM 内で `md5sum -c checksums.txt`
2. `linstor resource list -r <resource>` で配置・状態確認
3. マイグレーション所要時間の記録 (LVM 5x テストとの比較)
4. 全サイクル完了後にレポート作成

## Phase 6: レポート作成

`report/` にレポートを作成 (REPORT.md フォーマットに従う):

- **ファイル名**: `report/YYYY-MM-DD_HHMMSS_linstor_zfs_raidz1_multiregion_migration.md`
- **内容**:
  - 前提・目的: LVM→ZFS 移行 + ZFS raidz1 マルチリージョンマイグレーション検証
  - 環境情報: 6 ノード構成、ZFS raidz1 設定、DRBD/LINSTOR バージョン
  - Region A ZFS 変更手順と結果
  - マイグレーション実験結果: 各ステップの所要時間、チェックサム結果
  - LVM 5x テスト (2026-03-20) との性能比較
  - 発生した問題と対処
  - 結論・推奨
- **添付ファイル**: 実行ログ、DRBD 状態スナップショット等を `report/attachment/` に格納

## Phase 7: スキル・ドキュメント更新

実験成功後、得られた知見を反映:

1. **`.claude/skills/linstor-migration/SKILL.md`** — ZFS raidz1 対応手順、ZFS 固有の注意点追加
2. **`docs/linstor-multiregion-ops.md`** — ZFS ストレージプール前提の運用手順に更新
3. **`docs/linstor-multiregion-tutorial.md`** — ZFS セットアップ手順の追加
4. **config/linstor.yml** — ZFS ベースの設定に更新
5. **メモリファイル** (`linstor.md`) — ZFS raidz1 統一構成の記録

## 修正対象ファイル

- `config/linstor.yml` — ストレージプール設定を ZFS に変更
- `scripts/linstor-migrate-cold.sh` — `--storage-pool` 対応 (2 箇所)
- `scripts/linstor-multiregion-node.sh` — リージョン別プール対応 (1 箇所)
- `.claude/skills/linstor-migration/SKILL.md` — ZFS 対応知見追加
- `docs/linstor-multiregion-ops.md` — ZFS 運用手順
- `docs/linstor-multiregion-tutorial.md` — ZFS セットアップ追加
