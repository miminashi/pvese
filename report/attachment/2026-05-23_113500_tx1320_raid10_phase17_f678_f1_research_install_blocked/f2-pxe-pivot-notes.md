# F2 PXE pivot 事前調査メモ (Phase 18 用、 本セッションでは実装しない)

調査日: 2026-05-23 (Phase 17 セッション内、 implementation は次セッション)

## 目的

iRMC OEM Virtual Media を完全に bypass し、 PXE/iPXE 経由で Debian 13.3 installer を boot することで、 FW 9.08F の USB redirector 累積劣化問題を回避する。

## 既存資産 (本プロジェクト内)

### tftp-server skill
- `.claude/skills/tftp-server/SKILL.md` (jumanjiman/tftp-hpa Docker コンテナ)
- iDRAC FW update で使用実績あり
- 簡易 TFTP セットアップに使える

### irmc-bios.py
- WinSCU XML 経由で BIOS 設定変更可能
- `LaunchPxeOpRomPolicy: "UEFI only"` は既に `config/training_tx1320.yml` に定義済
- `apply-config` で BIOS に反映可能

### bmc-power.sh
- `boot-override Pxe UEFI` をサポート (iRMC Redfish の BootSourceOverrideTarget AllowableValues に "Pxe" が含まれる前提)

### playground 10.1.6.6
- Ubuntu 24.04、 root 権限自由
- 現在 NFS server として使用中 (/var/samba/public)
- dnsmasq / TFTP / HTTP を立てる host 候補

## 必要な新規セットアップ

### A. ネットワーク確認

training-tx1320 (10.254.254.0/24 管理 + 192.168.33.0/24 DHCP) と playground (10.1.6.6) の到達性を確認:
- playground 10.1.6.6 から 10.254.254.9 (iRMC) への ping = 既に到達確認済 (Phase 16)
- training-tx1320 OS-level (= Debian d-i) からは host NIC で出るが、 管理 IP セグメント (10.254.254.0/24) と インターネット側 (192.168.33.0/24) のどちらに乗るかは BIOS PXE boot order 次第

### B. dnsmasq セットアップ (playground 10.1.6.6 上)

`/etc/dnsmasq.d/tx1320-pxe.conf` 雛形:
```
# DHCP 範囲 (10.254.254.0/24 専用、 既存 DHCP との衝突回避のため stand-alone subnet にするのが安全)
# あるいは proxy-DHCP mode で既存 DHCP server (もし lab に存在するなら) と共存
# port=0      # DNS 無効化、 DHCP/TFTP のみ
# interface=ensX  # playground 側 NIC を指定
# bind-interfaces

# Option 1: 専用 DHCP (lab 内に他 DHCP server がない場合)
# dhcp-range=10.254.254.100,10.254.254.150,255.255.255.0,12h
# dhcp-option=3,10.254.254.1    # gateway
# dhcp-option=6,10.254.254.1    # DNS

# TFTP / PXE
enable-tftp
tftp-root=/var/lib/tftpboot
dhcp-boot=ipxe.efi          # UEFI PXE 用 iPXE
# dhcp-boot=pxelinux.0       # Legacy BIOS PXE 用 (TX1320 は CSM Disabled なので未使用)
```

### C. Debian 13 netboot 取得

```sh
mkdir -p /var/lib/tftpboot/debian-13-amd64
cd /var/lib/tftpboot/debian-13-amd64
wget https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/netboot.tar.gz
tar -xzf netboot.tar.gz
```

netboot.tar.gz の中身 (実機での確認必要):
- `debian-installer/amd64/grubx64.efi` (UEFI PXE bootloader)
- `debian-installer/amd64/linux` (kernel)
- `debian-installer/amd64/initrd.gz`
- `debian-installer/amd64/grub/grub.cfg`

### D. preseed.cfg の HTTP 配信化

現在は ISO 内 cdrom:///preseed.cfg として配信。 PXE 経路では HTTP 経由に変更:

apache2 or nginx でステートレス配信:
```
/var/www/html/preseed/training-tx1320.cfg
```

preseed kernel cmdline に追加:
```
preseed/url=http://10.1.6.6/preseed/training-tx1320.cfg
```

`preseed/preseed.cfg.template` の構造を確認し、 cdrom:// 依存箇所を HTTP 対応 (apt mirror など) に書き換える必要あり。

### E. RAID10 storcli の HTTP 配信化

現在は ISO bundle に storcli64.bin を含めている。 PXE 経路では:
- `/var/www/html/firmware/storcli64.bin` (HTTP 配信)
- preseed/early_command で `wget http://10.1.6.6/firmware/storcli64.bin -O /tmp/storcli64.bin` して setup-raid10-storcli.sh と同じ処理を実行
- もしくは setup-raid10-storcli.sh も HTTP 経由で配信して chained execution

### F. BIOS PXE 有効化 + boot-override

```sh
./scripts/irmc-bios.py apply-config config/training_tx1320.yml --restore-now
# LaunchPxeOpRomPolicy: "UEFI only" が反映される
# boot-override Pxe UEFI
./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Pxe UEFI
```

注意: TX1320 M3 の BIOS で `Pxe` AllowableValues が含まれているか事前確認必須 (Redfish `/Systems/0` の BootSourceOverrideTarget@Redfish.AllowableValues を grep)。

## リスク

1. **DHCP server 重複**: 10.254.254.0/24 セグメントに既存 DHCP server があるか不明。 lab 環境では多くの場合 stand-alone なので OK だが、 事前確認必須
2. **playground のネットワーク到達性**: playground (10.1.6.6) が training-tx1320 の管理側 (10.254.254.0/24) と DHCP 側 (192.168.33.0/24) のどちらから到達可能か実機で確認必要
3. **BIOS PXE Boot timeout**: TX1320 BIOS の PXE timeout が短すぎる場合、 DHCP 取得失敗で内部 disk に fallback → 元の問題 (空 disk で stuck) 再発の可能性
4. **TFTP 高 latency**: 拠点間 250-330ms 高 latency が TFTP throughput を impacts → kernel/initrd の load に長時間かかる可能性。 TFTP は block-by-block ack のため latency 敏感

## A/B test の可能性

NFS Virtual Media は保持したまま boot-override Pxe に変更すれば、 PXE と NFS の同時試行が可能。 失敗時は boot-override Cd に戻すだけ。

## 実装フェーズ案 (Phase 18 で)

| Phase | 内容 | 工数 |
|-------|------|------|
| 18-1 | playground 上に dnsmasq セットアップ + DHCP/TFTP テスト | 30 min |
| 18-2 | Debian 13 netboot 取得 + TFTP root に配置 | 15 min |
| 18-3 | preseed.cfg を HTTP 配信用に修正 + apache2/nginx で配信 | 30 min |
| 18-4 | storcli64.bin の HTTP 配信 + preseed/early_command 修正 | 15 min |
| 18-5 | TX1320 BIOS で PXE boot 有効化 + Pxe AllowableValues 確認 | 15 min |
| 18-6 | deploy 試行 + SOL monitor で kernel boot 確認 | 30 min |
| 18-7 | install 完遂検証 (SSH login) | 15 min |
| | **合計 (1 attempt)** | **~150 min** |

retry / debugging が入れば +1-2 時間。
