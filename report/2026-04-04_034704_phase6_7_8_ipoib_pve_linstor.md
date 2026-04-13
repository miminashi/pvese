# Phase 6-8: IPoIB + PVE/VM + LINSTOR 操作 トレーニングレポート

- **実施日時**: 2026年4月4日 03:28 〜 03:47 JST
- **対象**: Phase 6 (Iter 58-63), Phase 7 (Iter 64-72), Phase 8 (Iter 73-81)

## 添付ファイル

- [実装プラン](attachment/2026-04-04_023058_phase1_monitoring_baseline/plan.md)

## 前提・目的

- 背景: Phase 5 でクラスタ参加完了。pve6/pve9 の LINSTOR 登録と全体セットアップが必要
- 目的: IPoIB 全ノード設定、LINSTOR プラグインインストール、ノード登録、マルチリージョン構成復元

## イテレーション結果

### Phase 6 (Iter 58-63): IPoIB セットアップ

| ノード | 初期状態 | 修正 | 最終状態 |
|--------|---------|------|---------|
| pve4 | UP, 192.168.100.1/24 | 不要 | OK |
| pve5 | UP, 192.168.100.2/24 | 不要 | OK |
| pve6 | UP, 192.168.100.3/24 | 不要 | OK |
| pve7 | **DOWN** | `ib-setup-remote.sh --persist` | OK |
| pve8 | **DOWN** | `ib-setup-remote.sh --persist` | OK |
| pve9 | **DOWN** | `ib-setup-remote.sh --persist` | OK |

**知見**: Region B の永続設定に `sleep 2` pre-up が欠けていたため IPoIB がリブート後 DOWN に。修正済み。

### Phase 7 (Iter 64-72): PVE/VM + LINSTOR 登録

**LINSTOR プラグインインストール**:
- pve6: `drbd-dkms`, `linstor-satellite`, `linstor-client`, `linstor-proxmox` 全インストール
- pve9: `linstor-proxmox` のみ追加 (他は既存)
- 両ノードで `pvesm status` が drbd ストレージを認識

**pve6 LINSTOR 登録**:
1. DRBD 8.4→9.3 モジュール切替 (`modprobe -r drbd && modprobe drbd`)
2. ZFS プール作成 (`zpool create -f linstor_zpool raidz1 /dev/sda /dev/sdb /dev/sdc /dev/sdd`)
3. ノード登録、Aux/site=region-a、PrefNic=ibp134s0、zfs-pool 作成

**pve9 修正**:
1. Aux/site=region-b 設定
2. IB インターフェース登録 (ibp10s0, 192.168.101.9)
3. PrefNic=ibp10s0 設定
4. ZFS プール作成 (`zpool create -f linstor_zpool /dev/sdb /dev/sdc /dev/sdd /dev/sde`)
5. Auto-eviction 無効化

**cross-region パス**: 9本作成 (Region A 3ノード x Region B 3ノード)

**multiregion setup**: `linstor-multiregion-setup.sh setup` 正常完了

### Phase 8 (Iter 73-81): LINSTOR ストレージ操作

最終状態:

| ノード | LINSTOR | Aux/site | PrefNic | zfs-pool | Auto-evict |
|--------|---------|----------|---------|----------|-----------|
| pve4 | Online | region-a | ib0 | Ok (1.27 TiB) | - |
| pve5 | Online | region-a | ib0 | Ok (1.27 TiB) | - |
| pve6 | Online | region-a | ibp134s0 | Ok (1.28 TiB) | - |
| pve7 | Online | region-b | ibp10s0 | Ok (3.15 TiB) | Disabled |
| pve8 | Online | region-b | ibp10s0 | Ok (3.15 TiB) | Disabled |
| pve9 | Online | region-b | ibp10s0 | Ok (3.15 TiB) | Disabled |

VM 200 (test-vm): pve4 上で Running

## 発見した問題と改善

| # | 問題 | 対策 | 反映先 |
|---|------|------|--------|
| 1 | Region B IPoIB sleep 2 欠損 | ib-setup-remote.sh --persist で修正 | 既にスクリプトに含まれる |
| 2 | pve6 DRBD 8.4 がロード済み | modprobe -r drbd + modprobe drbd | `linstor-node-ops` に追記検討 |
| 3 | pve6/pve9 ZFS プール未作成 | zpool create で作成 | `linstor-node-ops` rejoin に ZFS 手順追加必要 |
| 4 | pve9 zfsutils-linux 未インストール | apt install で対応 | os-setup スキルの LINSTOR パッケージリストに追加 |
| 5 | pve4/pve5 PrefNic が `ib0` (pve6 は `ibp134s0`) | 動作に影響なし (同一 IB) | 統一推奨だが非破壊 |

## 参考

- [Phase 5 レポート](2026-04-04_032859_phase5_pve_setup.md)
