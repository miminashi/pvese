---
name: pxe-deploy
description: "PXE/netboot 経由で Debian + HW RAID10 を自動インストール (OpenWrt ローカル TFTP + embed ipxe.efi + IPv4 リテラル mirror)。BMC USB redirector が累積劣化した機種 (TX1320 M3 等) や、 cross-site 拠点の install に使う。phase 19 で training-tx1320 で完遂、 物理操作なしで自力 SSH まで到達。"
argument-hint: "<config_file>"
---

# PXE deploy スキル

BMC VirtualMedia (CD/USB redirector) を使わずに **PXE/netboot** で OS install する経路。 BMC USB redirector の累積劣化 (`os-setup` 経路が失敗する機種) や、 host が cross-site 拠点にあって install ISO の大容量 cross-site 転送が間欠 loss で失敗するケースに使う。 Phase 19 で training-tx1320 にて完遂、 **claude が物理操作なしで自力 SSH 到達**まで達成 (commit `dbb936a`、 [phase19 総括](../../../report/2026-05-30_053607_tx1320_raid10_overview_phase1-19_summary.md))。

## 適用判断 (os-setup との使い分け)

| 状況 | 推奨経路 |
|------|---------|
| Supermicro / iDRAC で BMC VirtualMedia 健全、 同一拠点 | **os-setup スキル** (BMC ISO mount + preseed、 短時間で完遂) |
| iRMC S4 で **USB redirector 累積劣化** (POST 99 stuck、 FW update でも回復せず) | **本 skill** (PXE pivot で完全 bypass) |
| **cross-site 設置**で大容量 ISO 転送が間欠 loss で破綻 (138KB 帯で時間 RST) | **本 skill** (kernel/initrd は host のインターネット経由で公開 mirror から取得) |
| **闇ネット (10.0.0.0/8) 経由で SSH 検証**したい (NAT 背後 LAN 不達) | **本 skill** (両 NIC DHCP + ip neigh で dark-net IP 特定) |

## アーキテクチャ

```
OpenWrt (拠点 LAN gateway) ──ローカル TFTP──→ 完全 embed ipxe.efi (chainload なし)
                                                 │ 再 DHCP で gateway 付き lease 取得
                                                 ▼
ftp.jp.debian.org 153.127.75.11 (IPv4 リテラル) ──→ kernel + initrd (host インターネット経由、 cross-site 回避)
                                                 ▼
d-i ──→ preseed http://<playground>/preseed/...  (cross-site 小容量 12KB のみ、 link 劣化でも完走)
     ──→ storcli64.bin http://<playground>/firmware/  (d-i busybox wget で 8MB 完走、 iPXE と違い堅牢)
     ──→ base system deb.debian.org (host インターネット、 公開 mirror)
     ──→ phone-home (任意、 nginx access.log で IP 受信、 cross-site 不通時は ip neigh で代替)
     ──→ poweroff
install 後: boot-override=Hdd で disk boot ──→ eno2 闇ネット IP で claude 自力 SSH
```

## 前提・依存

- **OpenWrt** (host の拠点 LAN gateway): dnsmasq でローカル TFTP 配信、 1.16 MB の ipxe.efi を `/tmp/tftp/` に置く (tmpfs、 OpenWrt 再起動で消えるので再配置必要)。 dnsmasq 設定: `enable_tftp=1`、 `tftp_root=/tmp/tftp`、 `dhcp_boot=ipxe.efi` (server 省略=dnsmasq 自身)
- **playground** (cross-site の任意ホスト、 例: 10.1.6.6): nginx で `/preseed/<host>.cfg` + `/firmware/{storcli64.bin,setup-raid10-storcli.sh,phonehome-setup.sh}` + `/ipxe.efi` 配信。 iPXE build 環境 (`/tmp/ipxe-build/ipxe/src/` の git clone) も置く
- **iRMC BIOS**: `NetworkStack=Enabled` + `IPv4PxeSupport=Enabled` 必須 (`irmc-bios-raid` skill の `bios apply-config` で BSPBR 経由設定)。 これが Disabled だと UEFI PXE boot option が生成されず boot-override Pxe が BIOS Setup に落ちる
- **config**: `network_mode: dhcp` + `static_iface: <PXE NIC>` + `dhcp_secondary_iface: <別 NIC>` を `config/<host>.yml` に設定 (両 NIC DHCP で闇ネット側 NIC が IP 取得)
- **依存スクリプト**: `scripts/generate-preseed.sh --pxe` (cdrom 依存削除 + HTTP storcli fetch + phone-home setup)、 `scripts/bmc-power.sh` (boot-override)、 `scripts/sol-monitor.py` (完遂判定)、 `scripts/irmc-oem-screenshot.sh` (実画面確認)

## 手順 (Phase 19 で実証された sequence)

### Step 0: 事前確認
- iRMC Virtual Media を全 disconnect (`scripts/irmc-virtualmedia.sh disconnect-cd`、 PXE 経路では使わず redirector 状態を clean に)
- BootSourceOverrideTarget@Redfish.AllowableValues に `"Pxe"` が含まれることを確認
- host NIC MAC を取得 (`config/<host>.yml` に記載、 または iRMC EthernetInterfaces で `MACAddress` 確認)

### Step 1: BIOS PXE 有効化 (1 回限り、 BSPBR cycle 必要)
config の `bios_settings.supported` に追加:
```yaml
NetworkStack: "Enabled"
IPv4PxeSupport: "Enabled"
```
`irmc-bios-raid` skill の bios apply-config で BSPBR backup → edit → restore → cycle (boot phase で適用)。

### Step 2: playground HTTP / iPXE build セットアップ
- `apt install nginx ipxe` + nginx で `/var/www/html/` 配信 (`autoindex on`)
- iPXE をビルド (詳細は本 skill の「embed ipxe.efi のビルド」参照)

### Step 3: OpenWrt 設定 (UCI、 user 側)
```
uci set dhcp.@dnsmasq[0].enable_tftp='1'
uci set dhcp.@dnsmasq[0].tftp_root='/tmp/tftp'
uci set dhcp.@dnsmasq[0].dhcp_boot='ipxe.efi'   # server 省略=dnsmasq 自身
uci commit dhcp
/etc/init.d/dnsmasq restart
wget http://<playground>/ipxe.efi -O /tmp/tftp/ipxe.efi   # OpenWrt 再起動で再配置必要
```

### Step 4: preseed 生成 + 配置
```sh
./scripts/generate-preseed.sh --pxe config/<host>.yml > /tmp/<host>.cfg
scp /tmp/<host>.cfg ubuntu@<playground>:/tmp/  &&  ssh ... sudo mv /tmp/<host>.cfg /var/www/html/preseed/<host>.cfg
# storcli64.bin + setup-raid10-storcli.sh + phonehome-setup.sh も /var/www/html/firmware/ に配置
```

### Step 5: deploy + 監視
```sh
./oplog.sh ./scripts/bmc-power.sh boot-override <BMC_IP> claude Claude123 Pxe UEFI
./oplog.sh ./scripts/bmc-power.sh forceoff <BMC_IP> ...   # sleep 30
./oplog.sh ./scripts/bmc-power.sh on <BMC_IP> ...
.venv/bin/python scripts/sol-monitor.py --bmc-ip ... --log-file install.log --timeout 2700
# nginx access.log を tail で並行観察 (preseed/firmware/phonehome fetch が真の進捗)
```
**要所で OEM screenshot を撮影** (DHCP→gateway→kernel fetch→d-i→login prompt)。 sol-monitor の stage 検出は SOL ring buffer replay で誤検出するので、 真の進捗は nginx fetch で判定。

### Step 6: install 完遂後 disk boot
```sh
./oplog.sh ./scripts/bmc-power.sh boot-override <BMC_IP> ... Hdd UEFI   # PXE loop 回避
./oplog.sh ./scripts/bmc-power.sh on <BMC_IP> ...
```

### Step 7: host IP 特定 + SSH
phone-home が cross-site 不通で届かなくても OK:
```sh
ssh playground "ip neigh | grep <eno2-MAC>"   # 闇ネット IP を特定
# または: 自 host で `ip neigh | grep <eno2-MAC>`
ssh -F ssh/config -i ssh/id_ed25519 root@<dark-net-IP> "lsblk; /usr/local/bin/storcli64 /c0/vall show || (wget -O /usr/local/bin/storcli64 http://<playground>/firmware/storcli64.bin && chmod +x /usr/local/bin/storcli64 && /usr/local/bin/storcli64 /c0/vall show)"
```

## Phase 19 で突破した 9 つの壁 (再利用知見)

| # | 壁 | 真因 | 対策 |
|---|----|------|------|
| 1 | boot-override Pxe が BIOS Setup に落ちる | BIOS `NetworkStack: Disabled` | BSPBR で `NetworkStack=Enabled` + `IPv4PxeSupport=Enabled` |
| 2 | TFTP RRQ 反復、 ipxe.efi 転送失敗 | **TFTP-through-NAT** (data の新 port が SNAT で ICMP reject) | OpenWrt **dnsmasq ローカル TFTP** で配信 (NAT 越え不要、 同一 segment) |
| 3 | d-i netcfg segfault | cmdline `interface=eth0` が renamed `eno1` と不一致 | `interface=auto` |
| 4 | "Continue without default route?" で停止 | 闇ネット DHCP が gateway 通知せず、 preseed 適用前に dialog | cmdline `netcfg/no_default_route=true` |
| 5 | iPXE chainboot 失敗 (iPXE>) | boot script を cross-site から chainload → 間欠 100% loss で 443B 取得失敗 | **全 boot ロジックを ipxe.efi に embed** (chainload 排除) |
| 6 | iPXE kernel fetch が ~138KB で `Connection reset` | **cross-site リンク劣化** (時間ベース RST、 iPXE HTTP 固有。 d-i wget は同リンクで 8MB 完走) | kernel/initrd を **ftp.jp.debian.org (host インターネット経由)** から取得 |
| 7 | deb.debian.org で `Network unreachable` | iPXE が dual-stack の AAAA(IPv6) / DNS で詰まる (OpenWrt 自体は到達可) | **IPv4 リテラル `153.127.75.11`** を直書き (CDN は Host ヘッダ依存で IP 不可、 実 mirror の IP) |
| 8 | DHCP レース (gateway 有/無) | host NIC segment に 2 DHCP (拠点 LAN gateway 有 / 闇ネット gateway 無) | iPXE `isset ${net0/gateway} \|\| goto re-dhcp` で gateway 付き lease 取得まで再 DHCP |
| 9 | installed host の IP 特定 (自力 SSH) | phone-home は cross-site 不達、 だが片方の NIC が闇ネット IP 取得 | **`ip neigh \| grep <eno2-MAC>`** で playground/local ARP から特定 |

## embed ipxe.efi のビルド (playground 上)

```sh
# iPXE source を /tmp/ipxe-build/ に clone (初回のみ)
apt install -y build-essential liblzma-dev mtools git
git clone --depth 1 https://github.com/ipxe/ipxe.git /tmp/ipxe-build/ipxe
```

embed する boot script `tx1320-embed.ipxe` (キモ: 再 DHCP→gateway→IPv4 リテラルから kernel/initrd):

```
#!ipxe
echo === pvese embedded iPXE ===
:dl
echo Acquiring DHCP (need gateway for internet)...
dhcp net0 || goto slow
echo IP=${net0/ip} GW=${net0/gateway}
isset ${net0/gateway} || goto nogw
kernel http://153.127.75.11/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux auto=true priority=critical preseed/url=http://<playground>/preseed/<host>.cfg interface=auto netcfg/no_default_route=true hostname=<host> domain=local console=ttyS0,115200n8 earlyprintk=ttyS0,115200n8 loglevel=8 ignore_loglevel || goto retry
initrd http://153.127.75.11/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz || goto retry
boot || shell
:nogw
sleep 3
goto dl
:slow
sleep 5
goto dl
:retry
sleep 5
goto dl
```

ビルド + 公開:
```sh
cd /tmp/ipxe-build/ipxe/src
cp tx1320-embed.ipxe ./
make -j$(nproc) bin-x86_64-efi/ipxe.efi EMBED=tx1320-embed.ipxe
sudo cp bin-x86_64-efi/ipxe.efi /var/www/html/ipxe.efi    # OpenWrt が wget で取得する HTTP 公開
```

## iPXE script の落とし穴 (重要)

1. **失敗コマンドに `||` がないと script 全体 abort** — `kernel ... && initrd ... && goto ok` は kernel 失敗で script 終了する。 `kernel ... || goto retry` で `||` で受けるのが正。
2. **`set <custom>`/`inc` は "Operation not supported"** で使えない build がある。 built-in (`${net0/ip}` / `${net0/gateway}` / `isset` / `goto` / `:label` / `sleep` / `dhcp net0`) は可。
3. **cross-site 大容量は iPXE で取らない** — iPXE HTTP は高 latency・間欠 loss で時間ベース RST (~138KB)。 d-i busybox wget は同リンクで 8MB 完走できる。 大容量は公開 mirror の IPv4 リテラル or d-i wget に委ねる。
4. **dual-stack ホスト名で AAAA(IPv6) に詰まる** → IPv4 リテラル直書き。 CDN は Host ヘッダ依存で IP 直指定不可なので、 実 mirror の IP を使う (ftp.jp.debian.org=153.127.75.11 等、 Apache で IP 直で netboot 配信)。
5. **chainload は cross-site で脆弱** — 間欠 100% loss で 443B の boot script すら取得失敗 → iPXE> shell。 全ロジックを ipxe.efi に embed して cross-site 依存を排除。

## ネットワークトポロジ (training-tx1320 で確定)

- **192.168.33.0/24** = 拠点 LAN。 OpenWrt が DHCP + gateway + internet 提供。 **OpenWrt NAT 背後で claude 拠点からは不達**。
- **10.0.0.0/8 (闇ネット)** = 両拠点アクセス可の広域イーサ。 **gateway を通知しない** (= 壁 4 "no default route" の原因)。 PXE 直後の chainload で 10.x ホストにつなぐと初動には OK だが大容量は不可。
- host eno1 = 拠点 LAN (PXE NIC、 internet あり、 local 不達)、 host eno2 = 闇ネット (gateway 無し、 **claude local から到達可**、 dark-net 経由で SSH)。
- **どちらの segment に LAN ポートが繋がっているか** は受け取る DHCP で判別 (gateway 付き=拠点 LAN / gateway なし=闇ネット)。
- **claude → host SSH は eno2 の闇ネット IP 経由**。 IP は `ip neigh | grep <eno2-MAC>` で特定 (DHCP のため reboot 変動)。

## 他機種への汎化ポイント

- **iRMC S4 全般** (TX1320 M3 / RX1330 M3 / 等の D3373 派生): 本 skill そのまま使える見込み。 BIOS は BSPBR XML で `NetworkStack` を有効化、 SOL は ttyS0、 OEM screenshot で実画面確認。
- **iDRAC / Supermicro**: BMC USB redirector が健全なら `os-setup` skill のほうが速い。 ただし cross-site / 間欠 loss 環境では本 skill の PXE pivot を検討。
- **異なる Linux distro**: kernel/initrd の取得元 (ftp.jp.debian.org) を該当 distro の公開 mirror IPv4 に差し替え、 preseed/kickstart の HTTP path を該当ファイルに差し替える。

## 関連 skill / report / memory

- `os-setup` skill — BMC VirtualMedia 経由の従来 install (Supermicro/iDRAC で第一選択、 iRMC S4 で USB redirector 健全なら可)
- `irmc-bios-raid` skill — BIOS BSPBR (NetworkStack 有効化) + storcli + iRMC FW update
- 総括 report: `report/2026-05-30_053607_tx1320_raid10_overview_phase1-19_summary.md` (Phase 1-19 横断索引)
- Phase 19 詳細: `report/2026-05-30_050830_tx1320_raid10_phase19_pxe_autonomous_ssh.md`、 memory `training_tx1320_phase19_pxe_autonomous_ssh.md`
