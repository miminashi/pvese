# LINSTOR RAID5 耐障害性実験レポート

- **実施日時**: 2026年3月22日 19:00〜21:05 (JST)
- **所要時間**: 約2時間
- **対象サーバ**: 8号機 (pve8), 9号機 (pve9)
- **7号機**: RAID 再構成時に OS 消失（OS が RAID-0 データ VD にインストールされていたため）。再インストール要。

## 添付ファイル

- [実装プラン](attachment/2026-03-22_120534_linstor_raid5_resilience_experiment/plan.md)

## 前提・目的

### 背景

電力節約のため Region B を最小1ノードで運用し、VM 数の増加に応じてノードを追加するスケーラブル運用を目指している。どのノード数でもディスク障害に耐える構成が必要。

### 目的

1. PERC H710 RAID-5 によるノード内ディスク冗長性を構築
2. LINSTOR の動的 place-count でスケールアップ/ダウン運用を検証
3. 1ノード運用時のディスク障害耐性を実証
4. 2ノード運用時のノード障害＋ディスク障害同時耐性を実証

### 前提条件

- Region B: DELL PowerEdge R320 × 3台 (PERC H710 Mini BBU 搭載)
- 各サーバ: SAS 10K RPM × 4本 (データ用)
- 既存データはすべて破壊可

### 参照レポート

- [LINSTOR LVM RAID10 ディスク障害実験](2026-02-27_203200_linstor_lvm_raid10_disk_failure_experiment.md) — LVM RAID10 の kernel bug (raid10.c:3454) 発見
- [Region B フルセットアップ](2026-03-19_174122_region_b_full_setup.md) — PERC H710 VD 構成の初期セットアップ

## 環境情報

### ハードウェア

| 項目 | 8号機 | 9号機 |
|------|-------|-------|
| サーバ | DELL PowerEdge R320 | DELL PowerEdge R320 |
| RAID | PERC H710 Mini (FW 21.3.0-0009) | PERC H710 Mini (FW 21.3.0-0009) |
| BBU | 搭載 (Write-Back Cache) | 搭載 (Write-Back Cache) |
| OS VD | VD0: RAID-1, 558.38 GB (Bay 0+1) | VD0: RAID-1, 558.38 GB (Bay 0+1) |
| Data VD | VD1: RAID-5, 1675.50 GB (Bay 2,4,5) | VD1: RAID-5, 1675.50 GB (Bay 3,4,5) |
| 注記 | Bay 3: Ready (未使用) | Bay 2: Blocked (障害ディスク) |

### ソフトウェア

- OS: Debian 13.3 (Trixie) + Proxmox VE 9.1.6
- カーネル: 6.17.13-2-pve
- LINSTOR Controller: pve4 (10.10.10.204)
- DRBD: Protocol C, quorum=off, auto-promote=yes

## RAID 構成変更

### 変更前

各サーバ: VD0 (RAID-1, OS) + VD1-3 (各 RAID-0, データ) = LVM ストライプ (RAID0)

### 変更後

各サーバ: VD0 (RAID-1, OS) + VD1 (RAID-5, データ) = 単一 PV の LVM VG

### racadm 実行上の注意

- VD 削除と RAID-5 作成を同一バッチで投入するとジョブが失敗する場合がある（8号機・9号機で発生）
- **2段階で実行**: まず VD 削除を適用（ジョブ＋再起動）→ その後 RAID-5 作成を適用（ジョブ＋再起動）
- 各 RAID ジョブの実行に 5〜10 分かかる (Running 34% で停滞する期間あり)
- `forceoffline` / `forceonline` も再起動が必要 (storcli があればホットで可能だが未インストール)

### 7号機の OS 消失問題

7号機は OS が VD2 (RAID-0, sdc) にインストールされていた（VD0 の RAID-1 "system" は空き）。VD1-4 を削除した際に OS も消失。8号機・9号機は OS が VD0 (RAID-1) にあったため影響なし。

## 実験結果

### テスト1: 1ノード運用 + ディスク障害

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | pve8 のみで LINSTOR リソース作成 (place-count=1, 10 GiB) | 成功、UpToDate |
| 2 | テストデータ 100MB 書き込み + md5sum | `d6ee6a3e51c40ed22ff91172defae1a2` |
| 3 | racadm forceoffline Bay 5 → 再起動 | RAID-5 Degraded で起動 |
| 4 | DRBD ステータス確認 | UpToDate |
| 5 | md5sum 検証 | **完全一致** |

### テスト2: スケールアップ (1→2ノード)

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | pve9 電源投入 → IPoIB 設定 | Online |
| 2 | `linstor resource create ayase-web-service-9` | 成功 |
| 3 | DRBD sync 完了 | 70秒 (10 GiB, IPoIB) |
| 4 | 両ノード UpToDate | 確認済み |

### テスト3: スケールダウン (2→1ノード)

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | `linstor resource delete ayase-web-service-9` | 成功 |
| 2 | pve8 のみでリソースアクセス | UpToDate |
| 3 | md5sum 検証 | **完全一致** |

### テスト4: ノード障害 + ディスク障害同時

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | 2ノード運用 → pve9 電源断 (ノード障害) | pve8 の DRBD: Connecting (pve9) |
| 2 | md5sum 検証 (pve8) | **完全一致** |
| 3 | pve8 RAID-5 Bay 2 forceoffline → 再起動 | RAID-5 Degraded |
| 4 | DRBD ステータス | UpToDate |
| 5 | md5sum 検証 | **完全一致** |

## 障害耐性マトリクス (実証済み)

| ノード数 | place-count | ノード障害 | ディスク障害 | ノード+ディスク |
|---------|------------|----------|------------|--------------|
| 1 | 1 | 不可 | **RAID5 保護 (実証)** | 不可 |
| 2 | 2 | **1台まで可 (実証)** | **RAID5 保護 (実証)** | **可 (実証)** |

## 運用フロー (実証済み)

```
[1ノード] place-count=1, RAID5 でディスク保護
    ↓ ノード起動 → IPoIB 設定 → linstor resource create (レプリカ追加)
[2ノード] place-count=2, DRBD + RAID5
    ↓ linstor resource delete (レプリカ削除) → ノード電源断
[1ノード] place-count=1
```

## 容量比較

| 構成 | ノード容量 | 実効容量 (2ノード place-count=2) |
|------|-----------|-------------------------------|
| 旧: LVM ストライプ (3×RAID-0) | 2.45 TiB | 2.45 TiB |
| 新: RAID-5 (3本, 4本中1本パリティ) | 1.63 TiB | 1.63 TiB |
| 差分 | -33% | -33% |

## 未完了事項

1. **7号機 OS 再インストール**: RAID 再構成時に OS が消失。preseed 経由で再インストール必要
2. **storcli インストール**: ホットでのディスク障害シミュレーションには storcli が必要（現在は racadm + 再起動）
3. **IPoIB 自動設定**: ノード起動時に IPoIB インターフェースが自動設定されない（手動 `ip addr add` 必要）
4. **pve-rg-b の replicas-on-same 問題**: `replicas-on-same site` では Region B のみへの配置を強制できない（手動 `linstor resource create` で対処）

## 再現方法

### RAID-5 VD 作成 (racadm)

```sh
# 1. データ VD 削除
ssh -F ssh/config idrac8 racadm raid deletevd:Disk.Virtual.1:RAID.Integrated.1-1
# ... (VD2, VD3 も同様)
ssh -F ssh/config idrac8 racadm jobqueue create RAID.Integrated.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA
# 再起動完了を待機

# 2. RAID-5 作成
ssh -F ssh/config idrac8 racadm raid createvd:RAID.Integrated.1-1 -rl r5 \
  -pdkey:Disk.Bay.2:Enclosure.Internal.0-1:RAID.Integrated.1-1,Disk.Bay.4:Enclosure.Internal.0-1:RAID.Integrated.1-1,Disk.Bay.5:Enclosure.Internal.0-1:RAID.Integrated.1-1 \
  -name data-r5
ssh -F ssh/config idrac8 racadm jobqueue create RAID.Integrated.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA
```

### LVM + LINSTOR セットアップ

```sh
# LVM
ssh -F ssh/config pve8 "pvcreate /dev/sdb && vgcreate linstor_vg /dev/sdb"

# LINSTOR ストレージプール
ssh -F ssh/config pve4 "linstor storage-pool create lvm ayase-web-service-8 striped-pool linstor_vg"

# リソースグループ (place-count=1)
ssh -F ssh/config pve4 "linstor resource-group create pve-rg-b --place-count 1 --storage-pool striped-pool"
ssh -F ssh/config pve4 "linstor resource-group drbd-options --protocol C pve-rg-b"
ssh -F ssh/config pve4 "linstor resource-group drbd-options --quorum off pve-rg-b"
ssh -F ssh/config pve4 "linstor resource-group drbd-options --auto-promote yes pve-rg-b"
```

### ディスク障害テスト

```sh
# Disk offline (再起動必要)
ssh -F ssh/config idrac8 racadm raid forceoffline:Disk.Bay.5:Enclosure.Internal.0-1:RAID.Integrated.1-1
ssh -F ssh/config idrac8 racadm jobqueue create RAID.Integrated.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA

# データ検証
ssh -F ssh/config pve8 "dd if=/dev/drbd/by-res/test-resilience/0 bs=1M count=100 iflag=direct | md5sum"

# Disk online (再起動必要)
ssh -F ssh/config idrac8 racadm raid forceonline:Disk.Bay.5:Enclosure.Internal.0-1:RAID.Integrated.1-1
ssh -F ssh/config idrac8 racadm jobqueue create RAID.Integrated.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA
```
