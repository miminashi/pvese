# Debian 12 自動インストール & Proxmox VE セットアップレポート

- **実施日時**: 2026年2月21日 22:00 〜 2月22日 01:51
- **課題**: #2 (Debian 12 自動インストール & Proxmox VE セットアップ)

## 前提・目的

Supermicro SYS-6019U-TN4R4T サーバに Debian 12 (Bookworm) を Redfish VirtualMedia 経由でリモート自動インストールし、Proxmox VE をセットアップする。

- 背景: pvese プロジェクトの分散ストレージ評価基盤として PVE ノードを構築する
- 目的: preseed による完全自動インストール + PVE 8.x の導入
- 前提条件: BMC (10.10.10.24) にネットワークアクセス可能、Samba 共有で ISO を配信可能

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | Supermicro SYS-6019U-TN4R4T |
| マザーボード | X11DPU |
| BMC IP | 10.10.10.24 (Redfish v1.8.0, FW 01.73.06) |
| CPU | 2x Intel Xeon |
| RAM | 32 GiB |
| NIC | 4x 10GBase-T (eno1np0〜eno4np3) |
| ブートモード | UEFI |
| ストレージ | NVMe (/dev/nvme0n1) |
| ホスト名 | ayase-web-service-4 |

### ネットワーク構成 (最終)

| インターフェース | IP | 設定 |
|-----------------|-----|------|
| eno1np0 | 192.168.39.200/24 | DHCP |
| eno2np1 | 10.10.10.204/8 | static |
| eno3np2 | - | DOWN (ケーブル未接続) |
| eno4np3 | - | DOWN (ケーブル未接続) |

### ソフトウェア

| 項目 | バージョン |
|------|-----------|
| Debian | 12.13 (Bookworm) |
| カーネル | 6.8.12-18-pve |
| pve-manager | 8.4.16 |
| Web UI | https://10.10.10.204:8006 |

## 再現方法

### Step 1: Debian 12 netinst ISO ダウンロード

Debian 12.9.0 (archive) からダウンロードし、SHA256 チェックサムを検証。

```bash
curl -L -o /var/samba/public/debian-12.9.0-amd64-netinst.iso \
  https://cdimage.debian.org/cdimage/archive/12.9.0/amd64/iso-cd/debian-12.9.0-amd64-netinst.iso
```

### Step 2: preseed.cfg 作成

ファイル: `preseed/preseed.cfg`

主要設定:
- ロケール: en_US.UTF-8, タイムゾーン: Asia/Tokyo
- ディスク: /dev/nvme0n1, LVM, atomic レシピ (UEFI/GPT)
- root/debian ユーザー: password `password`
- パッケージ: openssh-server, sudo, curl, wget, gnupg
- シリアルコンソール: console=ttyS1,115200n8 console=tty0
- GRUB EFI removable media: `grub-installer/force-efi-extra-removable boolean true`
- インストール完了後: `debian-installer/exit/poweroff boolean true` (電源オフ)

### Step 3: カスタム ISO リマスター

スクリプト: `scripts/remaster-debian-iso.sh`

Docker (debian:bookworm + xorriso) で実行:
1. xorriso で initrd.gz を抽出
2. preseed.cfg を initrd に cpio で注入
3. grub.cfg, isolinux/txt.cfg, isolinux.cfg をカスタム版に更新
4. preseed.cfg を CD ルートにも配置
5. `xorriso -boot_image any replay` で元の EFI ブート構造を保持したまま再構築

### Step 4: VirtualMedia マウント & ブート

Redfish VirtualMedia API では SMB/HTTP 接続が確立できなかったため、BMC CGI API を使用:

```
# BMC ログイン
POST /cgi/login.cgi  name=claude&pwd=Claude123

# CSRF トークン取得
GET /cgi/url_redirect.cgi?url_name=topmenu → SmcCsrfInsert から取得

# ISO パス設定 (SMB/CIFS)
POST /cgi/op.cgi  op=config_iso&host=10.1.6.1&path=\public\debian-preseed.iso&user=&pwd=

# マウント
POST /cgi/op.cgi  op=mount_iso

# Boot Override (Redfish)
PATCH /redfish/v1/Systems/1  {"Boot":{"BootSourceOverrideEnabled":"Once","BootSourceOverrideTarget":"Cd","BootSourceOverrideMode":"UEFI"}}

# 電源サイクル (ForceOff → On)
POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset  {"ResetType":"ForceOff"}
POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset  {"ResetType":"On"}
```

### Step 5: インストール監視

- Redfish PowerState ポーリング (30秒間隔) で On → Off 遷移を検知
- Web KVM (BMC GUI) でインストーラ画面を目視確認
- ipmitool SOL (ttyS1, 115200bps) でシリアルコンソール接続

### Step 6: ネットワーク設定

SSH (debian ユーザー) でログイン後:
1. sudo NOPASSWD 設定 (`/etc/sudoers.d/debian`)
2. PermitRootLogin yes (`/etc/ssh/sshd_config`)
3. `/etc/network/interfaces` に eno1 (DHCP) + eno2 (10.10.10.204/8 static) を設定

**注意**: PVE カーネル (6.8) で NIC 名が変更された (`eno1` → `eno1np0`, `eno2` → `eno2np1`)。ipmitool SOL 経由で interfaces ファイルを修正。

### Step 7: Proxmox VE インストール

```bash
# /etc/hosts 設定
echo "10.10.10.204  ayase-web-service-4.local ayase-web-service-4" >> /etc/hosts

# PVE リポジトリ追加
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-install-repo.list
wget -q https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
  -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg

# cdrom リポジトリ無効化
sed -i '/^deb cdrom:/s/^/#/' /etc/apt/sources.list

# アップグレード + PVE カーネル
apt-get update && apt-get full-upgrade -y
apt-get install -y proxmox-default-kernel

# GRUB シリアルコンソール設定
# /etc/default/grub に追記:
#   GRUB_CMDLINE_LINUX="console=tty0 console=ttyS1,115200n8"
#   GRUB_TERMINAL="console serial"
#   GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=1 --word=8 --parity=no --stop=1"
update-grub && reboot

# PVE カーネルで再起動後
apt-get install -y proxmox-ve postfix open-iscsi chrony

# Debian カーネル削除
apt-get remove -y linux-image-amd64 'linux-image-6.1*'
update-grub
```

### Step 8: クリーンアップ

- VirtualMedia アンマウント (`op=umount_iso`)
- Boot Override リセット (`BootSourceOverrideEnabled: Disabled`)

## 結果

| 検証項目 | 結果 |
|---------|------|
| カスタム ISO 生成 | OK (`/var/samba/public/debian-preseed.iso`, 633MB) |
| VirtualMedia マウント | OK (BMC CGI API 経由) |
| Debian 自動インストール | OK (preseed による完全自動化、複数回の修正後) |
| SSH 接続 | OK (debian@192.168.39.200, root@10.10.10.204) |
| ネットワーク | OK (eno1np0: 192.168.39.200 DHCP, eno2np1: 10.10.10.204 static) |
| PVE Web UI | OK (https://10.10.10.204:8006, HTTP 200) |
| pveproxy サービス | active |

## 問題と対策

### 1. Redfish VirtualMedia が機能しない

- **症状**: InsertMedia API は成功するが BMC が HTTP/SMB サーバに接続しない
- **対策**: BMC Web UI の JavaScript を解析し、CGI API (`/cgi/op.cgi`) を発見。`op=config_iso` + `op=mount_iso` で SMB/CIFS マウントに成功

### 2. Legacy BIOS ブート失敗

- **症状**: "Reboot and Select proper Boot device" エラー
- **原因**: 全 BootOption が UEFI モードだが、ISO は Legacy のみ対応
- **対策**: ISO リマスタースクリプトを `xorriso -boot_image any replay` 方式に変更し、元の UEFI ブート構造を保持

### 3. preseed が自動応答しない (Select a language 画面)

- **症状**: インストーラが言語選択画面で停止
- **対策**: カーネルパラメータに `auto=true priority=critical locale=en_US.UTF-8 keymap=us` を追加、preseed.cfg を CD ルートにも配置

### 4. インストール完了後に再度インストーラが起動

- **症状**: VirtualMedia が残っているため CD からブートし直す
- **対策**: preseed に `d-i debian-installer/exit/poweroff boolean true` を追加し、インストール後に電源オフ

### 5. GRUB EFI removable media path 質問で停止

- **症状**: "Force GRUB installation to the EFI removable media path?" で preseed が応答しない
- **対策**: `d-i grub-installer/force-efi-extra-removable boolean true` を preseed に追加

### 6. late_command 失敗

- **症状**: `/target/sys/class/net/en*` のグロブが失敗
- **対策**: `in-target sh -c '...'` 内で `/sys/class/net/en*` を使用し、`[ -e "$iface" ] || continue` でグロブ不一致を処理。ただし最終的にも late_command は失敗し、SSH 接続後に手動で sudo/sshd 設定を実施

### 7. POST コード 92 でハング

- **症状**: ForceRestart 後に POST が完了しない
- **対策**: ForceOff → 5〜8秒待機 → On の完全電源サイクルで解消

### 8. PVE カーネルで NIC 名変更

- **症状**: `eno1` → `eno1np0` に変更され、`/etc/network/interfaces` が不一致
- **対策**: ipmitool SOL 経由でログインし、sed で interfaces ファイルのインターフェース名を修正

## 作成・変更ファイル

| ファイル | 操作 |
|---------|------|
| `preseed/preseed.cfg` | 新規作成 — Debian 自動インストール設定 |
| `scripts/remaster-debian-iso.sh` | 新規作成 — Docker 内 ISO リマスタースクリプト |

## 所要時間

| ステップ | 所要時間 (概算) |
|---------|---------------|
| ISO ダウンロード + 検証 | 5分 |
| preseed 作成 | 5分 |
| ISO リマスタースクリプト作成 + ビルド | 15分 |
| VirtualMedia マウント (Redfish 試行 → CGI API 発見) | 30分 |
| インストール試行 (5回、各種修正含む) | 120分 |
| ネットワーク設定 + NIC 名修正 | 15分 |
| Proxmox VE インストール | 20分 |
| クリーンアップ | 2分 |
| **合計** | **約 3.5 時間** |
