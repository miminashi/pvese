# LINSTOR 同一ノード内ディスク冗長性調査レポート作成プラン

## Context

ユーザーは LINSTOR/DRBD 環境で、LVM RAID や mdraid 等の追加管理レイヤーなしに、
ディスクごとに個別の storage pool を登録して DRBD レプリケーションだけでディスク冗長性を確保できるか調査を依頼。

## 調査結論

**DRBD は同一ノード内レプリケーションを設計上サポートしていない。**
ディスクごとに個別 pool を作ることは LINSTOR 上可能だが、同一ノード上に同一リソースの複数レプリカを配置することは DRBD の設計制約により不可能。

## 作業内容

1. 調査レポートを `report/2026-03-28_000658_linstor_per_disk_pool_investigation.md` に作成
2. プランファイルを添付

### レポート構成

1. 前提・目的
2. 調査結果
   - DRBD の設計制約（同一ノード内レプリカ不可）
   - LINSTOR 複数 storage pool の可能性と制約
   - 関連 GitHub Issue
3. これまでの RAID 構成実験の振り返り
4. 代替アプローチの比較
5. 結論

### 参照する過去レポート

- `report/2026-03-22_220051_linstor_software_raid1_experiment.md`
- `report/2026-03-22_120534_linstor_raid5_resilience_experiment.md`
- `report/2026-02-27_203200_linstor_lvm_raid10_disk_failure_experiment.md`
- `report/2026-02-28_010338_linstor_lvm_raid_operational_concerns.md`
