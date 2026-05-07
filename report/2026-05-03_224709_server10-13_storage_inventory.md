# 10-13号機 ストレージ構成インベントリ

- **実施日時**: 2026年5月3日 22:42〜22:47 JST
- **対象**: 10号機 (NX-1065-G5), 11/12/13号機 (NX-3060-G5)
- **Issue**: #60

## 前提・目的

10-13号機は別拠点設置の Nutanix OEM Twin Server (Supermicro X10DRT-P) で、PVE 9 と Debian 13 をインストール済みだが、データ用ディスクの構成・状態が未把握。LINSTOR 参加可否を判断するためにストレージ構成 (OS ディスク・データディスク・ファームウェア・セクタサイズ等) を実機から取得する。

- 背景: 10-13号機は OS セットアップ完了後、シャットダウン状態で保管されており、データディスクの実態 (容量, インターフェース, セクタサイズ) が未確認
- 目的: 4台それぞれの内蔵ストレージを棚卸し、LINSTOR/Ceph 候補としての利用可否を判断する材料を得る
- 前提条件: 10-13号機の OS セットアップが完了し、`pve10`〜`pve13` SSH エイリアスから到達可能であること

## 環境情報

| 項目 | 10号機 | 11号機 | 12号機 | 13号機 |
|------|--------|--------|--------|--------|
| ホスト名 | ayase-web-service-10 | ayase-web-service-11 | ayase-web-service-12 | ayase-web-service-13 |
| 静的 IP | 10.10.10.210 | 10.10.10.211 | 10.10.10.212 | 10.10.10.213 |
| BMC IP | 10.10.10.30 | 10.10.10.31 | 10.10.10.32 | 10.10.10.33 |
| OEM モデル | NX-1065-G5 | NX-3060-G5 | NX-3060-G5 | NX-3060-G5 |
| OS | Debian 13 (Trixie) | 同左 | 同左 | 同左 |
| PVE | pve-manager 9.1.9 | 同左 | 同左 | 同左 |
| カーネル | 7.0.0-3-pve | 同左 | 同左 | 同左 |
| ブートモード | Legacy BIOS | Legacy BIOS | **UEFI** | Legacy BIOS |

共通 PCIe ストレージコントローラ (全 4 台同一):

- `00:11.4` Intel C610/X99 sSATA Controller (AHCI)
- `00:1f.2` Intel C610/X99 6-Port SATA Controller (AHCI)
- `01:00.0` **Broadcom / LSI SAS3008 PCI-Express Fusion-MPT SAS-3** (Nutanix HBA)

## ストレージ構成 (まとめ)

### OS ディスク (Toshiba SATA SSD, sSATA 経由・LSI HBA とは別系統)

| 機 | モデル | 物理容量 | sda 上の構成 | LV 構成 |
|----|--------|----------|-------------|---------|
| 10 | THNSNJ240PCSZ | 240 GB | sda1 /boot 976M ext4 / sda5 LVM2 222.6G | root 211.3G + swap 11.3G |
| 11 | THNSNJ240PCSZ | 240 GB | sda1 /boot 976M ext4 / sda5 LVM2 222.6G | root 211.3G + swap 11.3G |
| 12 | THNSNJ480PCSZ | 480 GB | **sda1 /boot/efi 976M vfat** / sda2 /boot 977M ext4 / sda3 LVM2 445.2G | root 422.7G + swap 22.6G |
| 13 | THNSNJ480PCSZ | 480 GB | sda1 /boot 976M ext4 / sda5 LVM2 446.2G | root 423.6G + swap 22.6G |

すべて MBR (10/11/13) または GPT+EFI (12) で `ext4 + LVM2` 構成。VG 名は `ayase-web-service-N-vg` で 100% 使用 (PFree 0)。

### データディスク (SAS HDD, LSI SAS3008 HBA 経由)

| 機 | スロット | モデル | 容量 | 回転数 | 論理セクタ | Linux 認識 |
|----|---------|--------|------|--------|-----------|-----------|
| 10 | sdb | Seagate **DKS5H-J1R2SS** | 1.20 TB | 10500 rpm | **512 B** | OK (1.1T) |
| 10 | sdc | Seagate **DKS5H-J1R2SS** | 1.20 TB | 10500 rpm | **512 B** | OK (1.1T) |
| 11 | sdb | Seagate **DKS5L-J1R2SS** | 1.20 TB | 10500 rpm | **512 B** | OK (1.1T) |
| 11 | sdc | Seagate DKS5H-J1R2SS | 1.20 TB | 10500 rpm | **512 B** | OK (1.1T) |
| 12 | sdb | Seagate DKS5H-J1R2SS | 1.19 TB | 10500 rpm | **520 B** | **NG (0B 表示)** |
| 12 | sdc | Seagate DKS5H-J1R2SS | 1.19 TB | 10500 rpm | **520 B** | **NG (0B 表示)** |
| 13 | sdb | Seagate DKS5H-J1R2SS | 1.19 TB | 10500 rpm | **520 B** | **NG (0B 表示)** |
| 13 | sdc | Seagate DKS5H-J1R2SS | 1.19 TB | 10500 rpm | **520 B** | **NG (0B 表示)** |

データディスクには **既存 LVM/ZFS/MD/パーティション/ファイルシステムは無い** (lsblk で `disk` 種別のみ、子 partition なし、`pvs/vgs/zpool/mdstat` ですべて空)。

## 重要な発見

### 1. 12/13号機のデータ HDD は 520B セクタ (Nutanix T10-PI フォーマット)

12/13号機の `sdb`/`sdc` は `Logical block size: 520 bytes` で報告され、`lsblk` 上は `0B` (Linux カーネルが扱えないため未公開) となっている。これは Nutanix が出荷時に T10 Protection Information / Advanced Format でフォーマットした名残。

**LINSTOR/Ceph の物理ストレージとして使うためには 512B にリフォーマットが必要**。

リフォーマット手段 (将来作業の選択肢):

```sh
sg_format --format --size=512 /dev/sdb
```

または LSI MegaRAID 系であれば controller 側で再フォーマット。スループットの低い (数時間〜) 操作なので、実施時はロック取得＋メンテ枠で行う。

### 2. 10/11号機のデータ HDD は 512B セクタで即利用可

10/11号機の HDD は既に 512B セクタで Linux に認識されている (各 1.1 TiB)。LINSTOR/Ceph の `pvcreate`/`zpool create` 等が即座に実行可能。

### 3. ブートモード差異 (12号機のみ UEFI)

12号機のみ UEFI ブート (sda1 /boot/efi vfat + sda2 /boot ext4 + GPT パーティショニング)、他 3 台は Legacy BIOS + MBR。`bios-setup` skill 適用時にこの差を意識する必要あり。

### 4. OS ディスクは LSI HBA とは別系統 (sSATA AHCI)

OS の sda は Intel C610 sSATA controller (`00:11.4`) 経由で接続されており、LSI SAS3008 HBA (`01:00.0`) は **データディスク (sdb/sdc) 専用**。`server10_lsi_hba_oprom.md` メモにある「OS disk が LSI HBA 経由」記述は誤り、または当該知見は別文脈 (起動時 OPROM 列挙) で必要なのかもしれず、別途検証が必要 (本件の範囲外)。

### 5. ストレージ容量サマリ

LINSTOR/Ceph 候補ディスクの合計 raw 容量:

- 10号機: 1.2 TB × 2 = **2.4 TB raw** (使用可能)
- 11号機: 1.2 TB × 2 = **2.4 TB raw** (使用可能)
- 12号機: 0 (520B 再フォーマット必要)
- 13号機: 0 (520B 再フォーマット必要)

リフォーマット後は 4 台合計で **9.6 TB raw** が利用可能になる見込み。

## 再現方法

### 1. 電源 ON

```sh
for ip in 10.10.10.30 10.10.10.31 10.10.10.32 10.10.10.33; do
    ./oplog.sh ./scripts/bmc-power.sh on "$ip" claude Claude123
done
```

OS が SSH 応答するまで約 130〜140 秒。

### 2. プローブスクリプト転送・実行

`tmp/storagechk/probe_storage.sh` (添付参照) を `scp` で各機の `/tmp/probe_storage.sh` に転送し、`ssh -F ssh/config pveN sh /tmp/probe_storage.sh` で実行。

スクリプトは `lsblk`, `pvs/vgs/lvs`, `zpool`, `lspci`, `smartctl -i`, `/proc/mdstat`, `mount` を順次取得する。

### 3. シャットダウン

```sh
for h in pve10 pve11 pve12 pve13; do
    ./oplog.sh ssh -F ssh/config "$h" systemctl poweroff
done
```

BMC 側で `Off` を確認後、作業終了。

## 添付ファイル

- [10号機プローブ出力](attachment/2026-05-03_224709_server10-13_storage_inventory/pve10_storage.txt)
- [11号機プローブ出力](attachment/2026-05-03_224709_server10-13_storage_inventory/pve11_storage.txt)
- [12号機プローブ出力](attachment/2026-05-03_224709_server10-13_storage_inventory/pve12_storage.txt)
- [13号機プローブ出力](attachment/2026-05-03_224709_server10-13_storage_inventory/pve13_storage.txt)
- [プローブスクリプト](attachment/2026-05-03_224709_server10-13_storage_inventory/probe_storage.sh)

## 今後の課題候補

- 12/13号機のデータ HDD を 520B → 512B にリフォーマット (`sg_format`) → 新規 issue 化
- 10-13号機の LINSTOR/Ceph 参加判断 (IB 接続性確認後)
- メモリ `server10_lsi_hba_oprom.md` の OS ディスク経路記述を精査
