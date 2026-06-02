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

## iPXE-on-CD variant (Virtual Media 経由、OpenWrt TFTP 不要)

firmware PXE-ROM boot は OpenWrt 側に **dnsmasq ローカル TFTP + `dhcp_boot=ipxe.efi`** の設定を要する。
この OpenWrt 特別設定への依存を排除したい場合 (または PXE NIC が boot order に無い場合)、**同じ embed ipxe.efi を
最小 UEFI ISO に焼いて BMC Virtual Media で起動**する。iPXE が起動した後は通常の PXE 経路と全く同じ
(DHCP→IPv4 リテラル mirror から kernel/initrd→playground HTTP から preseed/storcli→iPXE loader で kernel 起動)。
OpenWrt は **通常 DHCP リースを配るだけ** でよい。2026-05-31 (vmnfs531) に training-tx1320 で完遂
([report](../../../report/2026-05-31_073936_tx1320_virtualmedia_ipxe_cd_install.md))。

```
BMC Virtual Media (NFS/SMB) ──→ ipxe-<host>.iso (bootx64.efi = embed ipxe.efi)
                                  │ boot-override Cd → iPXE 起動 (firmware StartImage を使わない)
                                  ▼   以降は上の「アーキテクチャ」と同一 (DHCP→mirror→preseed→install)
```

**なぜ full Debian ISO の Virtual Media boot ではダメか**: 古い UEFI firmware (例 Fujitsu D3373 BIOS R1.22.0 2018 /
iRMC S4 FW 9.69F) では **GRUB 2.12 が Debian 13 の 6.12 kernel を起動できない**。GRUB は kernel を firmware の
`StartImage` (LoadImage) 経由で起動しようとし、firmware が `start_image() returned 0x8000000000000001`
(EFI_LOAD_ERROR) で拒否 → kernel printk ゼロのまま GRUB に戻る triple-fault reset loop。standalone grub も
純正 shim 経由の grub も同じ (shim は無言で GRUB に戻る)。**iPXE は独自 loader で kernel を起動するため回避できる**
(= PXE が成功する理由)。よって full-ISO Virtual Media は当該 firmware では dead end、iPXE-on-CD が正解。

### 手順
```sh
# 1. embed ipxe.efi を最小 UEFI ISO に焼く (playground の ipxe.efi を取得して)
scp playground:/var/www/html/ipxe.efi tmp/<sid>/ipxe.efi
./scripts/build-ipxe-iso.sh tmp/<sid>/ipxe.efi tmp/<sid>/ipxe-<host>.iso
# BMC が読む場所 (iRMC の NFS export = playground:/var/samba/public) に置く
scp tmp/<sid>/ipxe-<host>.iso playground:/tmp/ && ssh playground "sudo mv /tmp/ipxe-<host>.iso /var/samba/public/"

# 2. Virtual Media で attach + boot (config 駆動)
./scripts/irmc-ipxe-cd-deploy.sh config/<host>.yml ipxe-<host>.iso
# → DisconnectCD → config(NFS) → VirtualMediaServiceRestart → On → ConnectCD → ForceOff → boot-override Cd → On

# 3. 監視 (PXE 経路と同じ。SOL kernel printk + nginx fetch が真の進捗)
.venv/bin/python scripts/sol-monitor.py --bmc-ip <ip> --bmc-user claude --bmc-pass <pass> --log-file install.log --timeout 1800

# 4. install 完遂後 disk boot
export BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" BMC_PATCH_REQUIRES_ETAG=1 BMC_BOOT_OVERRIDE_NO_DISABLED=1 POWER_ON_RESET_TYPE=On
./scripts/bmc-power.sh boot-override <ip> claude <pass> Hdd UEFI ; ./scripts/bmc-power.sh on <ip> claude <pass>
```

### iRMC S4 FW 9.69F Virtual Media の落とし穴 (iPXE-on-CD でも full-ISO でも共通)
- 🎯 **CD メディアが host に提示されない (USB redirector 劣化)**: Redfish は `ConnectCD` 204 + `IsAnyVirtualMediaActive:true`
  を返すのに host 側 `/dev/sr0` は "No medium found"。対策 = `POST /redfish/v1/Managers/iRMC/Actions/Oem/FTSManager.VirtualMediaServiceRestart`
  body `{"VirtualMediaType":"CD"}` で Virtual Media worker を再起動 (`irmc-ipxe-cd-deploy.sh` が自動実行)。
- 🎯 **ConnectCD は `PowerState=On` 必須** (Off だと HTTP 400 `ActionParameterValueNotInList`)。接続済みなら allowable が `DisconnectCD`。接続は ForceOff をまたいで持続。
- 🎯 **boot-override Cd は `PowerState=Off` で設定 → PowerOn** の順 (On 中設定 + cycle は内蔵ディスク起動に化ける)。
- ISO 差し替え時は DisconnectCD → config → VirtualMediaServiceRestart → On → ConnectCD で fresh に張り直す (古いハンドルは stale)。
- iRMC S4 は `/redfish/v1/Systems/0/BootOptions` 未提供 (boot-next で CD 直接指定不可、boot-override の class 指定のみ)。

### iPXE-on-CD 10-run 堅牢性検証 (2026-06-02 r10hiicd、各 install 前に BIOS HII で RAID Clear)

training-tx1320 に対し「BIOS HII Clear Configuration → iPXE-CD deploy → preseed+storcli RAID10 → 検証」を **10 回連続ре反復し 10/10 成功** (RAID10 Optl 1.635TB を全 run で SSH 裏取り、 report `2026-06-02_122133_tx1320_ipxe_cd_hii_clear_10run`)。観察:
- **deploy 再試行 0/10** — `irmc-ipxe-cd-deploy.sh` の VirtualMediaServiceRestart で USB redirector 劣化を毎回回避。10 連続 deploy で CD 提示失敗ゼロ (Phase 15-18 の劣化問題は本経路では再現せず)。
- **`interface=auto` のままでも #15 (d-i netcfg stuck) は 0/10** — 本検証で使った embed ipxe.efi は旧 `interface=auto` 版だったが netcfg stuck は一度も起きなかった。これは #15 が **タイミング依存の非決定的事象** (eno2 link-up が netcfg と重なるか) であることを裏付ける。PXE-TFTP 経路の 10-run では同じ `interface=auto` で 30% 発生したのと対照的。**ただし `interface=eno1` 固定 (決定論的解消) は引き続き推奨** — 0/10 は「起きなかった」であって「起きない」ではない。
- 各 install ~8-10min (preseed GET → phonehome → auto-poweroff)、 総時間 ~25-30min/run (BIOS Clear + POST + install + disk boot + 検証)。
- install 中は kernel cmdline `console=ttyS0` のため **VGA はブランク** (d-i は SOL に出る)。OEM screenshot で d-i は撮れない → 進捗は SOL log + playground nginx access.log (preseed/storcli/phonehome GET) が一次情報。installed system は VGA tty1 に getty が出る (login プロンプト撮影可)。

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
# iRMC は bmc-power.sh 呼び出し前に config の bmc env を export する (#10)。
# これを忘れると cipher なしで TLS 失敗 → rc=52 (empty reply)。
export BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
export BMC_PATCH_REQUIRES_ETAG=1 BMC_BOOT_OVERRIDE_NO_DISABLED=1 POWER_ON_RESET_TYPE=On

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
kernel http://153.127.75.11/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux auto=true priority=critical preseed/url=http://<playground>/preseed/<host>.cfg interface=eno1 netcfg/no_default_route=true hostname=<host> domain=local console=ttyS0,115200n8 earlyprintk=ttyS0,115200n8 loglevel=8 ignore_loglevel || goto retry
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
6. **dual-NIC host は kernel cmdline `interface=<PXE NIC>` で install NIC を固定する** (TX1320 は `interface=eno1`)。 `interface=auto` だと、 install NIC でない方の NIC (例: eno2=dark-net) の link-up が d-i netcfg 中に発生したとき、 d-i が 2 NIC 両方に IPv6 autoconfiguration を実行して timeout が累積し、 preseed GET が来ず netcfg がスタックする (10-run 検証の落とし穴 #15、 発生率 30%)。 PXE NIC は embed iPXE の `isset ${net0/gateway} || goto nogw` で gateway-bearing な site LAN ポート (= eno1) に確定するので、 そこへ固定すれば netcfg は反対側 NIC を完全に無視する。 **preseed 内の `netcfg/choose_interface` では間に合わない** (preseed はネットワーク越し取得 = netcfg が走り終わった後にしか読まれない) — cmdline が唯一のレバー。

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

## 反復実行ログ (堅牢性検証 × 10 回、Run 10 完了 — 全10回完遂)

| 回 | 結果 | BIOS POST | preseed GET | storcli GET | phonehome GET | PowerOff | 総時間 | NW retry | 失敗モード/新落とし穴 |
|----|------|-----------|-------------|-------------|---------------|----------|--------|----------|---------------------|
| 1 | ✅ | t+60s | 23:25:20 | 23:26:02 | 23:32:43 | ~23:32 | ~12min | 0 | bmc-power.sh boot-override rc=52 (curl -L + PATCH 競合)。直接 curl PATCH で回避 |
| 2 | ✅ | t+240s | 00:00:15 (+3m12s) | 00:00:56 (+3m53s) | 00:07:41 (+10m38s) | ~00:07:43 | ~10m40s | 0 | eno2 DHCP IP が前回 (10.254.254.6) から変動 → 10.254.254.7 (#12 再確認)。Run 1 より ~2min 速い (9.8min で GRUB stage) |
| 3 | ✅ | t+180s | 00:22:22 (+3m10s) | 00:23:05 (+3m53s) | 00:29:38 (+10m26s) | 00:30:11 (+10m59s) | ~26min | 0 | eno2 DHCP 取得が disk boot 後 ~14min 遅延 (allow-hotplug eno2 + ケーブル既接続でリンクアップイベント不発生の可能性)。IP=10.254.254.8 (Run 1/2 と異なる)。`arp-scan 10.254.254.0/24` or 1-30 brute-ping で特定 |
| 4 | ✅ | t+60s | 00:56:33 (+3m5s) | 00:57:14 (+3m46s) | 01:03:58 (+10m30s) | 01:03:34 (+10m6s) | ~15min | 0 | eno2 DHCP 即時取得 (~3min) で最速 SSH。IP=10.254.254.10 (毎回変動確認)。BIOS POST 99 t+60s は Run 1 と同じ高速パターン |
| 5 | ✅ | t+92s | 01:15:43 (+2m57s) | 01:16:25 (+3m39s) | 01:23:19 (+10m33s) | ~01:23:45 (+10m59s) | ~15m24s | 0 | BIOS POST t+92s (Run 1/4 の 60s より若干遅め)。eno2 DHCP disk boot後 ~3m53s (即時)。IP=10.254.254.11 (毎回変動確認) |
| 6 | ✅ (retry 1) | t+117s | 02:04:27 (+3m30s) [retry] | 02:05:17 (+4m20s) [retry] | 02:12:41 (+11m44s) [retry] | 02:13:08 (+12m11s) [retry] | ~18min (retry込み) | 0 | **落とし穴 #15**: 1 回目 attempt で d-i が 25min 超 network detection stuck (preseed GET なし)。eno2 link-up 遅延が d-i netcfg 途中に発生し IPv6 autoconfiguration が 2 NIC 分重複実行。ForceOff → retry で即時解消。retry は +3m30s で preseed GET (通常通り) |
| 7 | ✅ | t+~180s | 02:28:14 (+3m11s) | 02:28:56 (+3m53s) | 02:35:37 (+10m34s) | 02:36:36 (+11m33s) | ~15min | 0 | install retry なし。安定した中間パターン。BIOS POST t+180s (Run 3 と同等)。eno2 DHCP disk boot後 ~2m49s (即時)。IP=10.254.254.13 |
| 8 | ✅ (retry 1) | t+~120-180s | 02:59:05 (+3m17s) [retry] | 02:59:48 (+4m00s) [retry] | 03:06:54 (+11m06s) [retry] | 03:07:20 (+11m32s) [retry] | ~19min (retry込み) | 0 | **落とし穴 #15 再発**: 1回目 attempt で d-i が ~7min netcfg stuck (DNS dialog waiting: DHCP 成功後に [!!] Configure the network で Name server addresses入力待ち、preseed GET 来ず)。SOL log で "Configuring the network with DHCP" + "Network autoconfiguration has succeeded" + DNS dialog の VT100 escape sequence 確認。ForceOff → retry で即時解消。retry は +3m17s で preseed GET (Run 6 と同パターン)。eno2 DHCP disk boot後 ~3m19s (即時)。IP=10.254.254.14 |
| 9 | ✅ (retry 1) | t+~120s | 03:31:08 (+3m48s) [retry] | 03:31:49 (+4m29s) [retry] | 03:38:39 (+11m19s) [retry] | ~03:39:00 (+11m40s) [retry] | ~25min (retry込み) | 0 | **落とし穴 #15 再発 (3回目)**: 1回目 attempt で d-i が DETECTING_NETWORK stuck (SOL 2.4min で stage 2/9、5min間動かず)。ForceOff → retry で即時解消。retry は +3m48s で preseed GET (Run 6/8 と同パターン)。eno2 DHCP disk boot後 ~4m20s (即時寄り)。IP=10.254.254.15 |
| 10 | ✅ | t+120s | 03:52:43 (+3m03s) | 03:53:25 (+3m45s) | 04:00:35 (+10m55s) | 04:01:35 (+11m55s) | ~14-15min | 0 | install retry なし (#15 なし)。BIOS POST t+120s。iPXE t+180s で kernel 61%/t+240s で initrd 94%/kernel OK。DETECTING_NETWORK(+2.8m)→CONFIGURING_APT(+3.8m)→INSTALLING_SOFTWARE(+8.2m)→INSTALLING_GRUB(+10.4m)→POWER_DOWN(+11.4m)。eno2 DHCP disk boot後 ~2-3min。IP=10.254.254.16 |

### Run 1 詳細 (2026-05-30 fef9f9e2)

- **Power On**: 23:20 UTC
- **BIOS POST 99 通過**: t+60s (screenshot: "Press F2 to enter Setup")
- **d-i kernel boot**: t+120s (SOL: Linux 6.12.86+deb13-amd64)
- **preseed GET**: 23:25:20 (5m後)
- **storcli64.bin + setup-raid10-storcli.sh GET**: 23:26:02 (42s後)
- **RAID10 created**: kernel t=96s (pvese markers: "raid10-setup OK")
- **phonehome-setup.sh GET**: 23:32:43 (6m41s後)
- **PowerOff**: ~23:32:45 (sol-monitor rc=0)
- **disk boot + login prompt**: OEM screenshot で "Debian GNU/Linux 13 tx1320 tty1"
- **eno2 IP**: 10.254.254.6 (Phase 19 の 10.254.254.4 と異なる — DHCP 変動確認)
- **RAID10 検証**: `storcli64 /c0/vall show` → RAID10 Optl 1.635 TB ✓、`storcli64 /c0/dall show` → 4 drives all Onln (252:0-3) ✓、lsblk sda 1.6T ✓

### 新落とし穴 (Run 1 で判明)

| # | 現象 | 真因 | 対策 |
|---|------|------|------|
| 10 | `bmc-power.sh boot-override` が rc=52 (empty reply) で失敗 | **真因は `-L` ではなく iRMC 用 env (特に `BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"`) の未 export。** iRMC S4 は古い DH 鍵のため cipher option なしだと TLS handshake が失敗し empty reply (rc=52) になる。10-run 当時の `-L` 原因説は誤診 (検証: 同 env で PATCH に `-L` あり/なし両方 http=200・rc=0、iRMC `/redfish/v1/Systems/0` は 301 しない。逆に `-L` は NX-3060-G5 11/12号機の末尾 `/` 301 follow に必要なので削除してはならない) | **`scripts/bmc-power.sh` を呼ぶ前に config の bmc env を export する** (下記 Step 5 のコマンド例参照、`irmc-bios-raid-setup.sh` の `load_config()` と同じ 5 変数: `BMC_SCHEME` / `BMC_CURL_OPTS` / `POWER_ON_RESET_TYPE` / `BMC_PATCH_REQUIRES_ETAG` / `BMC_BOOT_OVERRIDE_NO_DISABLED`)。export すれば `./scripts/bmc-power.sh boot-override` が単体で rc=0、tmp 直 curl 回避は不要 |
| 11 | `./scripts/irmc-virtualmedia.sh disconnect-cd` が 400 エラー | iRMC FW 9.69F で OEM action 名が変更 (`DisconnectCD` → 不明)。ただし PXE 経路では Virtual Media が既に inactive なので無視可 | PXE 経路では `IsAnyVirtualMediaActive: false` を確認して disconnect をスキップ可 |
| 12 | eno2 DHCP IP が再起動で変動 (10.254.254.4 → 10.254.254.6) | dark-net DHCP はリース固定なし | IP特定は必ず `ip neigh | grep 4c:52:62:14:de:f0` で毎回確認。ssh/config に複数 IP を列挙 |
| 13 | `ssh -F ssh/config root@<eno2-IP>` が Permission denied | ssh/config の `training-tx1320` Host は HostName 10.254.254.4 固定で、動的 IP (10.254.254.6 等) にはマッチしない → IdentityFile が適用されない | `ssh -i ssh/id_ed25519` を明示するか ssh/config Host に `10.254.254.*` ワイルドカードを追加 |
| 14 | disk boot 後 eno2 DHCP 取得が 15 分以上遅延 (Run 3) | `allow-hotplug eno2` はリンクアップイベントを検出してから DHCP を開始する。ケーブルが起動前から接続されていると初回リンクアップイベントが発生しない場合がある → dhcpcd が長時間 DHCP を試みた後に取得 | **恒久対策済み: `scripts/generate-preseed.sh` の late_network で `dhcp_secondary_iface` を `allow-hotplug` → `auto` に変更 (起動時に link-up イベント非依存で DHCP)。常時配線された dark-net ポートのみ対象。** 旧 ISO の場合は ARP 未出現時 `1-30 brute-ping` / `arp-scan 10.254.254.0/24` で特定 |
| 15 | d-i install で preseed GET が 25 分以上来ない (Run 6 初回 attempt) | eno2 の link-up が d-i netcfg 開始後に発生した場合、d-i が 2 NIC 両方に対して IPv6 autoconfiguration (Waiting for link-local → Attempting IPv6) を実行する。各 NIC のタイムアウトが累積し netcfg が長時間スタックする。イベント発生は非決定的 (前回 install のためケーブルが接続済み＋起動タイミングによる) | **恒久対策済み: embed iPXE の kernel cmdline を `interface=auto` → `interface=eno1` に変更し install NIC を固定 (上記「iPXE script の落とし穴」#6)。** ipxe.efi 再ビルド + 再配置が必要。固定後は netcfg が eno2 を無視するため #15 は発生しない。暫定回避は従来通り ForceOff → retry (2 回目 attempt は +3m30s で preseed GET) |

### Run 3 詳細 (2026-05-30 fef9f9e2)

- **Power On**: 00:19:12 UTC
- **BIOS POST 92 → 99**: t+120s → t+180s
- **iPXE**: t+240s (DHCP ok IP=192.168.33.11 GW=192.168.33.1、kernel ok、initrd 42%→完了)
- **d-i kernel boot**: t+~300s (SOL: Linux 6.12.86+deb13-amd64、DETECTING_NETWORK +2.4min)
- **preseed GET**: 00:22:22 UTC (+3m10s)
- **storcli64.bin + setup-raid10-storcli.sh GET**: 00:23:05 UTC (+3m53s)
- **SOL stages**: DETECTING_NETWORK(+2.4m) → CONFIGURING_APT(+3.4m) → INSTALLING_SOFTWARE(+7.8m) → INSTALLING_GRUB(+9.6m) → PowerOff(+10.5m)
- **phonehome-setup.sh GET**: 00:29:38 UTC (+10m26s)
- **PowerOff**: 00:30:11 UTC (sol-monitor rc=0, +10m59s)
- **disk boot Power On**: 00:30:42 UTC
- **login prompt**: OEM screenshot で "Debian GNU/Linux 13 tx1320 tty1" (disk boot +~3m)
- **eno2 IP 取得**: disk boot +14m52s → 10.254.254.8 (10.254.254.1-30 brute-ping で発見)
- **SSH 到達**: 00:45:34 UTC (root@10.254.254.8)
- **総時間**: ~26min22s (install Power On → SSH 到達)
- **RAID10 検証**: RAID10 Optl 1.635 TB ✓、4 drives all Onln (252:0-3) ✓、lsblk sda 1.6T ✓
- **NW retry**: 0
- **新発見**: eno2 DHCP 遅延 (~15min)。allow-hotplug eno2 + ケーブル既接続環境でリンクアップイベント不発生可能性 (#14)

### Run 5 詳細 (2026-05-30 fef9f9e2)

- **Power On**: 01:12:46 UTC
- **BIOS POST 99**: t+92s (~01:14:18)
- **iPXE**: 192.168.33.11 GW=192.168.33.1 (first DHCP)、kernel fetch from 153.127.75.11
- **d-i kernel boot**: t+~150s (SOL: DETECTING_NETWORK t+2.6min)
- **preseed GET**: 01:15:43 UTC (+2m57s)
- **storcli64.bin + setup-raid10-storcli.sh GET**: 01:16:25/26 UTC (+3m39s)
- **SOL stages**: DETECTING_NETWORK(+2.6m) → CONFIGURING_APT(+3.5m) → INSTALLING_SOFTWARE(+8.0m) → INSTALLING_GRUB(+9.8m) → POWER_DOWN(+10.8m)
- **phonehome-setup.sh GET**: 01:23:19 UTC (+10m33s)
- **PowerOff**: ~01:23:45 UTC (sol-monitor rc=0, +10m59s)
- **disk boot Power On**: 01:24:17 UTC
- **login prompt**: OEM screenshot で "Debian GNU/Linux 13 tx1320 tty1" (disk boot +~3m30s)
- **eno2 IP 取得**: disk boot +3m53s → 10.254.254.11 (find-ip.sh / local ARP)
- **SSH 到達**: 01:28:10 UTC (root@10.254.254.11)
- **総時間**: ~15m24s (install Power On → SSH 到達)
- **RAID10 検証**: RAID10 Optl 1.635 TB ✓、lsblk sda 1.6T ✓
- **NW retry**: 0
- **新発見**: なし。Run 1-4 パターン内で安定完遂

### タイミング目安 (Run 1-10 実測)

| フェーズ | Run 1 (23:20 UTC) | Run 2 (23:57 UTC) | Run 3 (00:19 UTC) | Run 4 (00:53 UTC) | Run 5 (01:12 UTC) | Run 6 retry (02:00 UTC) | Run 7 (02:25 UTC) | Run 8 retry (02:55 UTC) | Run 9 retry (03:27 UTC) | Run 10 (03:49 UTC) |
|---------|------------------|------------------|------------------|------------------|------------------|--------------------------|-------------------|------------------------|------------------------|-------------------|
| BIOS POST 99 (iPXE loading) | t+60s | t+240s | t+180s | t+60s | t+92s | t+103s | t+~180s | t+~120-180s | t+~120s | t+120s |
| iPXE DHCP+kernel fetch 開始 | t+120s 前後 | t+360s | t+240s (initrd 42% 観測) | t+120s 前後 | t+~150s | t+163s (kernel 44%) | t+~240s | t+~360s (kernel+initrd OK) | t+~141s (kernel/initrd OK) | t+180s (kernel 61%)、t+240s (initrd 94%) |
| preseed GET | +5m20s | +3m12s | +3m10s | +3m5s | +2m57s | +3m30s | +3m11s | +3m17s | +3m48s | +3m03s |
| storcli64.bin GET | +6m02s | +3m53s | +3m53s | +3m46s | +3m39s | +4m20s | +3m53s | +4m00s | +4m29s | +3m45s |
| RAID10 作成完了 | +6m36s | +4m | ~+5m | ~+4m | ~+4m | ~+4.5m | ~+4m | ~+4m30s | ~+5m | ~+4m |
| phonehome GET + PowerOff | +12m43s | +10m38s | +10m26s (+10m59s Off) | +10m30s (+10m6s Off) | +10m33s (+10m59s Off) | +11m44s (+12m11s Off) | +10m34s (+11m33s Off) | +11m06s (+11m32s Off) | +11m19s (+11m40s Off) | +10m55s (+11m55s Off) |
| disk boot → login prompt | +20m (PowerOff後 ~7m) | +25m (PowerOff後 ~14m) | +14m (PowerOff後 ~3m) | +13m (PowerOff後 ~3m) | +15m (PowerOff後 ~4m) | PowerOff後 ~3m (login at 02:16:47) | PowerOff後 ~2m29s | PowerOff後 ~2m15s | PowerOff後 ~3m33s | PowerOff後 ~2m (login at 04:03) |
| eno2 DHCP 取得 (ARP 観測) | disk boot後 ~3-4m | disk boot後 ~5-6m | disk boot後 **~15m** (IP=.8) | disk boot後 **即時** (IP=.10) | disk boot後 ~3m53s (IP=.11) | disk boot後 ~3m (IP=.12) | disk boot後 ~2m49s (IP=.13) | disk boot後 ~3m19s (IP=.14) | disk boot後 ~4m20s (IP=.15) | disk boot後 ~2-3m (IP=.16) |
| **備考** | BIOS POST t+60s (高速) | t+240s (可変) | eno2 DHCP 遅延大 (allow-hotplug 問題) | 最速 ~15min 総時間、DHCP 即時取得 | 安定した中間パターン。DHCP 即時-標準 | 1回目 attempt で d-i 25min stuck (#15)。retry で正常完走 | 安定した中間パターン。install retry なし、BIOS POST t+180s | #15 再発 (DNS dialog stuck)。retry で正常完走。eno2=.14 (新アドレス) | #15 再発 (DETECTING_NETWORK ~5min stuck)。retry で正常完走。eno2=.15 (新アドレス) | install retry なし (#15 なし)。~14-15min で最速クラス完遂。eno2=.16 |

### 10回サマリ (Run 1-10 統計)

| 項目 | 値 |
|------|-----|
| 成功率 | 10/10 (100%) |
| install retry あり | 3回 (Run 6/8/9、すべて落とし穴 #15 = d-i netcfg stuck) |
| install retry なし | 7回 (Run 1/2/3/4/5/7/10) |
| 落とし穴 #15 発生率 | 30% (3/10) |
| 総時間 (install PowerOn → SSH 到達) | 最短 ~13min (Run 4)、最長 ~26min (Run 3 = eno2 DHCP 15min 遅延)、retry なし median ~15min、retry あり ~18-25min |
| eno2 DHCP 遅延 (15min超) | 1回 (Run 3) ← `allow-hotplug` + ケーブル既接続でリンクアップイベント不発生 |
| NW retry (bmc/playground 操作) | 0回 (全10回) — インフラが極めて安定 |
| **結論** | PXE 経路は 10回全成功、100% 再現性。最大ブロッカーは落とし穴 #15 (d-i netcfg stuck, 30%)。ForceOff+retry で即座に回避できるため実用上問題なし。標準総時間 13-15min。 |

## フォローアップ恒久対策の実機検証 (2026-05-31)

10-run 検証のフォローアップとして #15 / #14 / #10 を恒久対策し、実機 PXE install で検証した (report `2026-05-31_*_tx1320_pxe_followup_*.md`)。

- **#15 (cmdline `interface=eno1`)**: 3 回連続で **preseed GET が初回 attempt のみで +3-4 分以内に到達** (Run F1 +3m19s / F2 +4m9s / F3 +4m9s)。10-run で 30% 発生していた d-i netcfg stuck は **0/3 (= 0%)**。`interface=eno1` で netcfg が eno2 を完全に無視するため dual-NIC IPv6 autoconfig が物理的に起きない (決定論的解消)。
- **#14 (`auto eno2`)**: disk boot 後 eno2 DHCP が **+2.5-3 分で取得** (Run F1 10.254.254.16 / F3 .18)。10-run Run3 の 15 分遅延は再現せず。installed-system の `/etc/network/interfaces` が `auto eno2` であることを SSH で確認。
- **#10 (env export)**: `BMC_SCHEME` / `BMC_CURL_OPTS` / `BMC_PATCH_REQUIRES_ETAG` / `BMC_BOOT_OVERRIDE_NO_DISABLED` / `POWER_ON_RESET_TYPE` を export すれば `./scripts/bmc-power.sh boot-override` が rc=0。真因は `-L` ではなく cipher env 未設定 (上記 #10 表参照)。
- **phonehome バグ (`&&`→`;`)**: late_command の phonehome 行が正しく生成され、SSH publickey (= authorized_keys) も保持されることを確認。
- install 本体は全 run で完遂 (preseed → storcli RAID10 Optl 1.635 TB → apt → GRUB → auto-poweroff → disk boot → SSH)。本検証環境では apt/base が遅く install 時間 ~19-21min (10-run の ~11min より遅いが健全)。
- **検証時の注意**: 完遂判定は **install 自身の auto-poweroff (PowerState=Off) + phonehome GET** を待つこと。固定時間での proactive ForceOff は finish-install の sync を中断し authorized_keys 等の遅延書込みを失わせる (Run F2 で再現、SSH publickey 不通 + 但し OEM screenshot は login prompt 到達)。

### 運用上の追加知見 (フォローアップ検証で判明)

- **phonehome は end-to-end で動作する (修正後)** — `;` 修正で in-target の `phonehome-setup.sh` が実行され、first-boot systemd oneshot (`pvese-phonehome.service`) が disk boot 後に `GET /phonehome?host=...&ips=...` で報告する。nginx access.log で確認可。
- **🚨 phonehome の eno2 値は link-local (169.254.x) になりうる** — phonehome は `network-online.target`+10s 後の最初の成功 curl で exit する。eno1 (site LAN) が先に online を満たすため、eno2 の DHCP 完了前に発火すると eno2 を APIPA で報告する。**SSH 到達用の dark-net IP は phonehome を当てにせず `ip neigh | grep <eno2-MAC>` で再確認**する (eno2 lease 自体は auto 化で disk boot +3 分以内に来る)。
- **🚨 iRMC ForceOff 後は PowerState=Off をポーリングしてから on** — iRMC は PowerState=On のとき `ResetType=On` を拒否する (`Fujitsu.1.0.ActionParameterValueNotInList`)。`ForceOff → 固定 sleep → on` は sleep が不足すると失敗する。Off になるまでポーリング (例: 5s × 最大 120s) してから power on すること (`tx1320-raid10-orchestrate.sh` / 本検証の `run-cycle.sh` はこの方式)。
- **⚠️ `generate-preseed.sh` の awk `esc()` は `&` 未対応の潜在バグ** — phonehome は `&&`→`;` で回避済みだが、esc() 自体は `&` を正しくエスケープしない。late_network や preseed 値に `&` を入れると gsub 置換で `%%...%%` に化ける。**late_network に `&` を使わないこと** (根本修正は別 issue)。
- **installed hostname は `tx1320`** (config の `training-tx1320` ではない)。stale ARP に旧 lease が同 MAC で残るため、IP 特定後は `ssh ... hostname` で live 系を確認する。
