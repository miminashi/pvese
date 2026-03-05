# iDRAC7 ブート順序制御の調査と自動化

- **実施日時**: 2026年3月5日 20:00

## 前提・目的

R320 (7号機) の preseed 自動インストール後、OS ブートで「No boot device available」が発生していた。
手動で BIOS に入りブート順序を変更すれば起動できたが、この手順を racadm から自動化し、
os-setup スキルの Phase 6 (post-install-config) に組み込む。

### 参照レポート

- [R320 iDRAC セットアップ](2026-03-02_052246_dell_r320_idrac_setup.md)
- [iDRAC7 FW アップグレード](2026-03-02_143000_idrac7_firmware_upgrade.md)
- [R320 VNC ブランク画面修正](2026-03-05_174316_r320_vnc_blank_screen_fix.md)

## 環境情報

- サーバ: DELL PowerEdge R320 (7号機)
- iDRAC: FW 2.65.65.65 (Build 15)
- BIOS: 2.3.3
- ストレージ: PERC H310 (RAID.Integrated.1-1)
- OS: Debian 13.3 (Trixie) — preseed 自動インストール

## 調査結果

### Step 1: BIOS ブート設定の確認

**racadm get BIOS.BiosBootSettings** がサポートされていることを確認:

```
[Key=BIOS.Setup.1-1#BiosBootSettings]
BootMode=Bios
BootSeq=HardDisk.List.1-1,NIC.Embedded.1-1-1,Optical.SATAEmbedded.E-1,Unknown.Slot.1-1,Floppy.iDRACVirtual.1-1,Optical.iDRACVirtual.1-1
BootSeqRetry=Disabled
HddSeq=RAID.Integrated.1-1
```

**iDRAC ServerBoot 設定**:

```
[Key=iDRAC.Embedded.1#ServerBoot.1]
BootOnce=Enabled
FirstBootDevice=Normal
```

重要な発見:
- BootSeq は既に **HardDisk.List.1-1 が最優先**
- `BootOnce=Enabled` + `FirstBootDevice=Normal` が設定されていた

### Step 2: HDD ブート試行

手順:
1. VirtualMedia をアンマウント: `racadm remoteimage -d`
2. BootOnce を無効化: `racadm set iDRAC.ServerBoot.BootOnce Disabled`
3. 電源 ON: `ipmitool chassis power on`

結果: **OS ブート成功**

VNC スクリーンショットで確認:
- POST: 「Lifecycle Controller: Collecting System Inventory...」（約 2-3 分）
- ブート後: Debian 13 ログインプロンプト表示

```
Debian GNU/Linux 13 ayase-web-service-7 tty1
ayase-web-service-7 login:
```

ACPI Error が表示されるが動作に影響なし:
```
ACPI Error: AE_NOT_EXIST, Returned by Handler for [IPMI]
ACPI Error: Region IPMI (ID=7) has no handler
```

### Step 3: 永続的ブート順序変更

`racadm set BIOS.BiosBootSettings.BootSeq` + `racadm jobqueue create BIOS.Setup.1-1` で
永続的な BIOS 変更が可能であることを確認。ただし、現在の BootSeq は既に正しい順序のため変更不要。

## 根本原因の分析

「No boot device available」の原因:

1. os-setup Phase 5 で VirtualMedia ブートのために `cfgServerBootOnce=1` + `cfgServerFirstBootDevice=VCD-DVD` を設定
2. preseed インストール完了後、自動 power off
3. 次回 power on 時に **BootOnce 設定が残った状態**で起動
4. VirtualMedia はアンマウント済みだが、BootOnce=VCD-DVD が有効なため、存在しない VCD-DVD デバイスからブートしようとして失敗

解決策: **インストール完了後に boot-reset を実行する**（BootOnce=Disabled + FirstBootDevice=Normal）。

## 成果物

### 1. idrac-virtualmedia.sh にブート制御コマンド追加

`scripts/idrac-virtualmedia.sh` に以下のサブコマンドを追加:

| コマンド | 説明 |
|---------|------|
| `boot-once <bmc_ip> <device>` | 一時ブートデバイス設定（BootOnce=Enabled） |
| `boot-reset <bmc_ip>` | boot-once 解除（BootOnce=Disabled, FirstBootDevice=Normal） |
| `boot-status <bmc_ip>` | 現在のブート設定表示 |

FirstBootDevice の有効な値: `Normal`, `PXE`, `BIOS`, `VCD-DVD`, `Floppy`, `HDD`

### 2. idrac7 SKILL.md にブート制御セクション追加

`.claude/skills/idrac7/SKILL.md` に「ブート制御」セクションを追加:
- スクリプトサブコマンドの使い方
- FirstBootDevice の有効な値一覧
- VirtualMedia → HDD 切り替え手順
- 永続的 BootSeq 変更方法
- R320 固有の注意事項

### 3. os-setup SKILL.md Phase 6 に 7号機手順追記

Phase 6 のステップ 1「VirtualMedia アンマウント + Boot Override 解除」に iDRAC7 (7号機) 向けの手順を追加:

```sh
./scripts/idrac-virtualmedia.sh umount 10.10.10.120
./scripts/idrac-virtualmedia.sh boot-reset 10.10.10.120
```

## 再現方法

### インストール〜HDD ブートの全フロー

```sh
# Phase 5: VirtualMedia ブートで preseed インストール
./scripts/idrac-virtualmedia.sh mount 10.10.10.120 "//10.1.6.1/public/debian-preseed.iso"
./scripts/idrac-virtualmedia.sh boot-once 10.10.10.120 VCD-DVD
ipmitool -I lanplus -H 10.10.10.120 -U claude -P Claude123 chassis power on
# ... preseed インストール完了 → 自動 power off ...

# Phase 6: HDD ブート
./scripts/idrac-virtualmedia.sh umount 10.10.10.120
./scripts/idrac-virtualmedia.sh boot-reset 10.10.10.120
ipmitool -I lanplus -H 10.10.10.120 -U claude -P Claude123 chassis power on
# R320 POST は遅い（2-3 分）。OS ブート後 SSH 接続可能。
```

## 備考

- R320 の POST は遅い（Lifecycle Controller: Collecting System Inventory で 2-3 分）
- iDRAC7 FW 2.65 は `racadm get/set BIOS.*` 新構文と `racadm getconfig/config` 旧構文の両方をサポート
- `cfgServerBootOnce`（旧構文）と `iDRAC.ServerBoot.BootOnce`（新構文）は同じ設定を参照する
