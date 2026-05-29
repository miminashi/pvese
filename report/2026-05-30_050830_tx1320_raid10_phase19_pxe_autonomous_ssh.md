# Phase 19: TX1320 RAID10 OS install — F2 PXE pivot 完遂 + claude 自力 SSH 到達達成

- **実施日時**: 2026-05-29 〜 05-30 (JST) 約 1.5 日 (拠点間リンク劣化により多数イテレーション)
- **セッション**: phase19a (concurrent-rabbit)
- **Issue**: #72 (Phase 14-18 引き継ぎ、 USB redirector による install ブロック)
- **結果**: ✅ **Debian 13 install 完遂 + RAID10 Optimal + claude が物理操作なしで自力 SSH login 達成**

## 目的

Phase 18 で iRMC FW 9.69F update 後も BIOS POST 99 stuck (USB redirector 累積劣化) が再現し、 iRMC OEM Virtual Media 経由の install は限界と確定。 Phase 19 で **PXE pivot** に切替え、 USB redirector を完全 bypass。 最終的にユーザ目標が「claude が物理操作なしで自力 SSH login + RAID10 検証まで遂行」に拡張された。

## 最終到達状態

```
$ ssh -F ssh/config -i ssh/id_ed25519 root@10.254.254.4
hostname: tx1320  /  OS: Debian GNU/Linux 13 (trixie)
eno1=192.168.33.11/24 (site LAN)   eno2=10.254.254.4/8 (dark-net, claude 到達可)
sda 1.6T (RAID10 VD0) → ESP + /boot + LVM tx1320-vg (root 1.61t / + swap 23.9G)

$ storcli64 /c0/vall show
0/0  RAID10  Optl  RW  1.635 TB        ← VD0 Optimal
252:0-3  Onln  837.843 GB SAS HDD ST900MM0168 × 4   ← 4 drives all Online
```

## アーキテクチャ (cross-site PXE)

| コンポーネント | 配置 | 役割 |
|--------------|------|------|
| OpenWrt ルータ (192.168.33.1 / dark-net 10.1.5.1) | tx1320 拠点 | DHCP + **ローカル TFTP (ipxe.efi 配信)** |
| playground 10.1.6.6 | claude 拠点 (dark-net) | HTTP (preseed + storcli + phonehome) |
| ftp.jp.debian.org 153.127.75.11 | 公開 mirror | kernel + initrd (host インターネット経由) |
| training-tx1320 | tx1320 拠点 | install 対象 (eno1=site LAN, eno2=dark-net) |

**最終 boot 経路**: OpenWrt ローカル TFTP → 完全 embed ipxe.efi → gateway 付き lease 取得まで再 DHCP → ftp.jp.debian.org (IPv4 直) から kernel/initrd → d-i → preseed (playground) → storcli RAID10 → base system (deb.debian.org) → phone-home → poweroff。

## 解決した課題 (時系列)

| # | 課題 | 真因 | 対策 |
|---|------|------|------|
| 1 | boot-override Pxe が BIOS Setup に落ちる | **BIOS `NetworkStack: Disabled`** で UEFI PXE boot option が生成されない | `irmc-bios.py` BSPBR で NetworkStack=Enabled + IPv4PxeSupport=Enabled (config 追加) |
| 2 | TFTP RRQ 反復、 ipxe.efi 転送失敗 | **TFTP-through-NAT** (data 転送に新 port → SNAT 10.1.5.1 が conntrack なしで ICMP reject) | **OpenWrt dnsmasq ローカル TFTP** で ipxe.efi 配信 (NAT 越え不要) |
| 3 | netcfg segfault → install 停止 | cmdline `interface=eth0` が renamed `eno1` と不一致 | `interface=auto` |
| 4 | "Continue without a default route?" で停止 | dark-net DHCP が gateway を通知しない (preseed 適用前に dialog) | cmdline `netcfg/no_default_route=true` |
| 5 | installed system が unreachable | config `static_iface=eth0`、 static IP が実 segment と不一致 | `network_mode=dhcp` + `static_iface=eno1` + 両 NIC DHCP |
| 6 | iPXE chainboot 失敗 (iPXE>) | boot script を cross-site playground から chainload → 間欠 100% loss で 443B 取得すら失敗 | **全 boot ロジックを ipxe.efi に embed** (chainload 排除) |
| 7 | iPXE kernel fetch が ~138KB で Connection reset | **cross-site リンク劣化** (時間ベース RST、 iPXE HTTP 固有) | kernel/initrd を **ftp.jp.debian.org から取得** (host インターネット経由、 cross-site 回避) |
| 8 | deb.debian.org が "Network unreachable" | iPXE が AAAA(IPv6)/DNS で詰まる (OpenWrt 自体は到達可) | **IPv4 リテラル 153.127.75.11** で DNS/IPv6 をバイパス |
| 9 | DHCP レース (gateway 有/無) | eno1 segment に 192.168.33(GW) と dark-net(no-GW) の 2 DHCP | iPXE で **`isset ${net0/gateway}` で gateway 付き lease 取得まで再 DHCP** |
| 10 | installed host の IP 特定 (自力 SSH) | phone-home は cross-site 不達、 だが eno2 が dark-net IP 取得 | **`ip neigh \| grep <eno2 MAC>`** で playground/local ARP から 10.254.254.4 を特定 |

## 重要な技術的発見

1. **iPXE HTTP は cross-site 劣化リンクで ~138KB で時間ベース RST**。 一方 **d-i busybox wget は同リンクで 8MB 完走** (storcli64.bin)。 iPXE HTTP は TCP window/timeout が弱い。 → 大容量は iPXE で取らず、 公開 mirror (IPv4 直) か d-i wget に委ねる。
2. **iPXE は dual-stack ホスト名で AAAA(IPv6) に詰まり "Network unreachable"**。 IPv4 リテラル IP で回避 (CDN は Host ヘッダ依存なので実 mirror の IP を使う: ftp.jp.debian.org=153.127.75.11)。
3. **iPXE script の失敗ハンドリング**: 失敗コマンドに `||` がないと **script 全体が abort** する (`kernel ... && ... && goto ok` は不可、 `kernel ... || goto retry` が正)。 また **`set <custom> <val>` / `inc` は "Operation not supported"** で使えない build がある (built-in `${net0/...}` / `isset` / `goto` / `sleep` は可)。
4. **TFTP-through-NAT は ICMP reject** (`tftpd: read: Connection refused`)。 data 転送が新 port を使うため SNAT/firewall に阻まれる。 NAT 越えが必要なら HTTP (単一 TCP) を使うか、 同一 segment でローカル配信。
5. **dark-net (10.0.0.0/8) は両拠点アクセス可**。 host の片方の NIC (eno2) が dark-net DHCP で IP を引けば claude から直接到達できる。 IP 特定は ARP テーブル (`ip neigh`) が確実 (phone-home の cross-site 不達を回避)。
6. **OEM screenshot (`scripts/irmc-oem-screenshot.sh`) が状態判断の一次情報**。 SOL は read-only (keystroke 注入不可、 D3373 制約)、 KVM canvas は黒画 artifact。 OEM screenshot は真の VGA capture で iPXE prompt / DHCP / kernel fetch / d-i / login prompt を確実に判別できた。

## scripts/config 変更 (commit)

| ファイル | 変更 |
|---------|------|
| `scripts/generate-preseed.sh` | `--pxe[=BASE_URL]` flag (cdrom 依存削除 + storcli HTTP fetch)、 `network_mode: dhcp` 対応、 `dhcp_secondary_iface` (両 NIC DHCP)、 PXE 時 phone-home setup |
| `config/training_tx1320.yml` | BIOS `NetworkStack/IPv4PxeSupport: Enabled`、 `network_mode: dhcp`、 `static_iface: eno1`、 `dhcp_secondary_iface: eno2` |
| `ssh/config` | `Host training-tx1320` (10.254.254.4) |

## playground / OpenWrt インフラ (repo 外、 本レポートに記録)

- **playground 10.1.6.6**: `tftpd-hpa` (未使用化)、 `nginx` (`/var/www/html/`: preseed/firmware/phonehome)、 iPXE build 環境 (`/tmp/ipxe-build/`)。 完全 embed ipxe.efi のビルド元
- **OpenWrt**: dnsmasq `dhcp_boot=ipxe.efi` (ローカル TFTP)、 `enable_tftp=1` `tftp_root=/tmp/tftp`、 `/tmp/tftp/ipxe.efi` (完全 embed 版、 reboot で消えるので要再配置)
- **embed ipxe.efi のロジック**: 再 DHCP→gateway 確認→ftp.jp.debian.org(IPv4) から kernel/initrd→preseed=playground

## 再現方法 (次回 deploy)

1. OpenWrt `/tmp/tftp/ipxe.efi` が存在するか確認 (tmpfs、 reboot で消失 → `wget http://10.1.6.6/ipxe.efi -O /tmp/tftp/ipxe.efi`)
2. playground nginx が preseed/firmware/phonehome を配信中か確認 (`curl -sI http://10.1.6.6/preseed/training-tx1320.cfg`)
3. `./oplog.sh sh tmp/<sid>/deploy-pxe2.sh` 相当 (boot-override Pxe + force-off + on)
4. OEM screenshot で DHCP→gateway→kernel fetch→d-i を確認、 sol-monitor で完遂 (PowerState Off)
5. boot-override Hdd + power on で disk boot (PXE loop 回避)
6. `ssh playground "ip neigh | grep 4c:52:62:14:de:f0"` で eno2 dark-net IP 特定 → `ssh root@<IP>` で検証

## 残課題 / 注意

- **storcli64 は installed system に未配置** (installer 環境のみ)。 検証時は playground から `wget -O /usr/local/bin/storcli64 http://10.1.6.6/firmware/storcli64.bin` で取得 (host が dark-net 経由で到達可)
- **eno2 の dark-net IP (10.254.254.4) は DHCP** で reboot 変動しうる。 固定したい場合は OpenWrt 側 static lease か installed 側 static 設定 (ただし segment 特定が前提)
- **OpenWrt /tmp/tftp は tmpfs**。 OpenWrt reboot で ipxe.efi 消失 → 再配置必要 (kernel/initrd は ftp.jp 直なので OpenWrt 容量不要)
- 拠点間リンクは劣化期があり、 大容量 cross-site 転送は不安定。 設計上 cross-site は小容量 (preseed 12KB) のみに限定済
