# TX1320 M3 OS install 総括 — Phase 1〜19 の真因・対策・成否 (2026-05-16 〜 05-30)

Fujitsu PRIMERGY TX1320 M3 (iRMC S4、 D3373-B1、 別拠点設置) への Debian 13 + HW RAID10 自動 install を、 2 週間・19 フェーズにわたり試行した全記録の横断総括。 **最終的に Phase 19 で PXE pivot により完遂、 claude が物理操作なしで自力 SSH login + RAID10 検証まで達成** (commit `dbb936a`)。

各 Phase の詳細は個別 report (`report/2026-05-*_tx1320_*.md`) と memory (`training_tx1320*.md`) を参照。 本文書はそれらを俯瞰する索引兼総括。

## 1. マスタータイムライン (真因 → 対策 → 成否)

| Phase | 日付 | 取り組み | 真因/発見 | 対策 | 成否 |
|-------|------|---------|----------|------|------|
| 機種登録 | 05-16 | 対応機種登録・BIOS UEFI 化・RAID10 | iRMC S4 の落とし穴 (HTTPS DH 鍵 SECLEVEL=0、 ResetType 動的、 SOL payload enable、 ETag quotes なし) | `bmc-power.sh`/`irmc-*.py` 改修 | ✅ |
| RAID10 KVM | 05-16/17 | KVM HII で RAID10 作成 | Select RAID Level 到達不能、 Profile VD は RAID 0/1/5/6 のみ | **KVM 経路 dead-end → storcli + preseed 経路に転換** | 転換 |
| SMB N1-N6 | 05-17〜21 | iRMC SMB Virtual Media 配信 | SMB silent failure。 真因 = **Samba 4.19.5 smb2_trans2.c typo (SMB1SERVER→WITH_SMB1SERVER)** + iRMC FW 9.08F SMB worker 死亡 | 1 文字 patch build 完遂も iRMC SMB worker 復活せず → **NFS に pivot** | 転換 |
| NFS solved | 05-21 | iRMC OEM NFS Virtual Media | iRMC S4 FW 9.08F は **NFS をサポート** (PATCH ShareType=NFS + ConnectCD) | NFS 経路確立 (SMB worker 死亡を bypass) | ✅ |
| 3-7 | 05-18/22 | kernel が GRUB 後 silent | SOL kernel printk 0 行・KVM 黒画。 当初「kernel hang」と誤解 | 多数の cmdline flag を順次反証 (quiet/earlyprintk/nousb/acpi=off…) | 切り分け |
| **8** | 05-22 | silent hang の正体特定 | **「silent hang」は実は triple-fault reset loop** (SOL 33 GRUB cycle/5分)。 **iRMC OEM Screenshot が真の VGA capture** (KVM canvas は黒画 artifact、 boot 失敗の証拠に使うな) | OEM screenshot で実画面確認、 SOL printk + NFS READ 数のみ信頼 | 🎯発見 |
| **9-10** | 05-22 | triple-fault の隔離 | **`remaster-debian-iso.sh` wrapper の cmdline 内 `vga=normal`/`nomodeset` が triple-fault トリガー** (stock ISO + grub.cfg 6KB 差し替えで再現) | cmdline から削除 | 🎯発見 |
| **11** | 05-22 | Phase 10 検証 | **Phase 10「install boot 成功」は誤判定** (再 deploy で triple-fault 再現、 `Loading bootloader` は GRUB stage のみ、 kernel 後 reset loop は `Booting` 反復が signature) | 誤判定訂正、 真因究明継続 | ⚠️訂正 |
| 12 | 05-22 | SOL 沈黙の物理確認 | console silence を物理確定、 仮説 12 (kernel hang) vs 13 (SOL detach) に絞込 | — | 切り分け |
| **13** | 05-22 | 真因確定 | **`console=tty0` が D3373 kernel hang の真因** (kernel が VGA console init で stuck) | `remaster-debian-iso.sh`/`generate-preseed.sh` から `console=tty0` 削除 → kernel printk 復活 + d-i 起動 | 🎯🎯確定 |
| 14 | 05-22 | kernel boot 再現確立 | playground 同期 / storcli dpkg 廃止 / static IP conflict。 残: **cdrom-detect が物理 DVD sr0 と iRMC 仮想 CD sr1 の fall-through 未対応** | 4 課題解決、 cdrom block 残存 | △ |
| **15** | 05-23 | cdrom-detect patch | sr0 (空 DVD) を先に試して諦め sr1 をスキャンしない | **`PVESE_PATCH_CDROM_DETECT`** (awk in-place patch で sr1 優先 block 挿入、 sanity 5/5) | 🎯実装 |
| 16 | 05-23 | patch 実機 + partman 到達 | PSU cold reset + 105s pad で初回 deploy も kernel boot。 patch で cdrom block 解消、 apt/partman 到達。 ただし USB redirector が install 中も累積劣化 | patch を main commit (0624539b) | △ |
| 17 | 05-23 | F6/F7/F8/F1 research | USB redirector 累積劣化が Phase 16 より深刻化、 3 deploy 全て POST 99 stuck | wholesale commit + F1 (FW 9.69F) リサーチ | △ |
| **16-18** | 05-23 | FW update 経路 | **iRMC USB redirector の累積劣化は FW 9.08F→9.69F update でも解消しない** (BIOS POST 99 stuck 再現)。 BIOS/HW level の問題 | FW update 完遂 (ブリックなし) も install 未達 → **PXE pivot 決定** | ⚠️限界確定 |
| **19** | 05-29/30 | **PXE pivot 完遂** | iRMC USB redirector を完全 bypass。 9-10 の壁を順次突破 (下記 §2) | OpenWrt ローカル TFTP + embed ipxe.efi + ftp.jp IPv4 + dual-NIC DHCP + phone-home | ✅🎉**完遂** |

## 2. Phase 19 が突破した壁 (USB redirector を PXE で完全 bypass)

| # | 壁 | 真因 | 対策 |
|---|----|------|------|
| 1 | boot-override Pxe が BIOS Setup に落ちる | BIOS `NetworkStack: Disabled` で UEFI PXE boot option 未生成 | BSPBR で NetworkStack + IPv4PxeSupport = Enabled |
| 2 | TFTP RRQ 反復、 ipxe.efi 転送失敗 | **TFTP-through-NAT** (data の新 port が SNAT で ICMP reject) | OpenWrt dnsmasq **ローカル TFTP** 配信 (NAT 越え不要) |
| 3 | netcfg segfault | cmdline `interface=eth0` が renamed `eno1` と不一致 | `interface=auto` |
| 4 | "Continue without default route?" で停止 | dark-net DHCP が gateway 通知せず、 preseed 適用前に dialog | cmdline `netcfg/no_default_route=true` |
| 5 | iPXE chainboot 失敗 (iPXE>) | boot script を cross-site から chainload → 間欠 100% loss で 443B 取得失敗 | **全ロジックを ipxe.efi に embed** (chainload 排除) |
| 6 | iPXE kernel fetch が ~138KB で RST | **cross-site リンク劣化** (時間ベース RST、 iPXE HTTP 固有。 d-i wget は同リンクで 8MB 完走) | kernel/initrd を **ftp.jp.debian.org (host インターネット経由)** から取得 |
| 7 | deb.debian.org "Network unreachable" | iPXE が dual-stack の AAAA(IPv6)/DNS で詰まる (OpenWrt 自体は到達可) | **IPv4 リテラル 153.127.75.11** (CDN は Host 依存で不可、 実 mirror の IP) |
| 8 | DHCP レース (gateway 有/無) | eno1 segment に 192.168.33(GW) と dark-net(no-GW) の 2 DHCP | iPXE `isset ${net0/gateway}` で gateway lease 取得まで再 DHCP |
| 9 | installed host の IP 特定 (自力 SSH) | phone-home は cross-site 不達、 だが eno2 が dark-net IP 取得 | **`ip neigh \| grep <eno2 MAC>`** で playground/local ARP から特定 |
| (補) | install 後 PXE loop | NetworkStack 有効化で default boot order が PXE 優先 | install 後は **boot-override=Hdd** で disk boot |

## 3. ネットワークトポロジ (確定)

- **192.168.33.0/24** = tx1320 拠点 LAN。 OpenWrt が DHCP + default gateway + インターネット提供。 **OpenWrt NAT 背後で claude 拠点からは不達**。
- **10.0.0.0/8 (闇ネット)** = 両拠点アクセス可の広域イーサ。 **gateway を通知しない** (= Phase 19 課題 4 "no default route" の原因)。
- **host eno1 (`4c:52:62:14:a5:5c`)** = 192.168.33.x (site LAN、 PXE NIC、 internet あり、 local 不達)。 **host eno2 (`4c:52:62:14:de:f0`)** = 闇ネット (例 10.254.254.4、 gateway なし、 **claude local から到達可**)。
- 「どちらの segment に LAN ポートが繋がっているか」 は **受け取る DHCP で判別** (gateway 付き=192.168.33 / gateway なし=闇ネット)。
- **claude → host SSH は eno2 の闇ネット IP 経由**。 IP は `ip neigh | grep 4c:52:62:14:de:f0` (playground/local) で特定 (DHCP なので reboot 変動)。

## 4. 最終稼働アーキテクチャ (再現用)

```
OpenWrt ローカル TFTP ──→ 完全 embed ipxe.efi (chainload なし)
                             │ 再 DHCP で gateway 付き lease 取得
                             ▼
ftp.jp.debian.org 153.127.75.11 (IPv4 直) ──→ kernel + initrd  (host インターネット経由)
                             ▼
d-i ──→ preseed http://10.1.6.6/... (playground、 12KB、 cross-site 小容量)
     ──→ storcli64.bin http://10.1.6.6/firmware/ (playground、 d-i wget で 8MB 完走) ──→ RAID10
     ──→ base system deb.debian.org (host インターネット)
     ──→ phone-home + 両 NIC DHCP ──→ poweroff
install 後: boot-override=Hdd で disk boot ──→ eno2 闇ネット IP で claude 自力 SSH
```

成果物: `scripts/generate-preseed.sh --pxe` (dhcp/dual-NIC/phonehome)、 `config/training_tx1320.yml`、 `ssh/config` (commit `dbb936a`)。 OpenWrt/playground インフラは Phase 19 report に記録 (repo 外)。

## 5. 横展開できる汎用知見 (他機種・他案件)

1. **iRMC S4 (D3373) の SOL は read-only** (keystroke 注入不可)。 状態判断は **OEM Screenshot (真の VGA capture)** が一次情報。 KVM canvas は黒画 artifact、 boot 失敗の証拠にするな。 進捗は SOL printk + サーバ側 log (nginx/Samba) で判定。
2. **iPXE HTTP は高 latency・間欠 loss リンクで大容量転送が弱い** (時間ベース RST、 dual-stack で IPv6 詰まり、 `set`/`inc` 不可、 失敗には `||` 必須)。 大容量は公開 mirror の IPv4 リテラル or d-i wget に委ね、 iPXE は小容量 (bootloader) に限定。
3. **TFTP は NAT を越えられない** (data 転送が新 port)。 同一 L2 segment でローカル配信するか、 HTTP (単一 TCP) を使う。
4. **`console=tty0` は一部 BIOS/GPU で kernel hang** を起こす。 ヘッドレス install では `console=ttyS0` のみにする。
5. **「silent hang」≠ hang**: triple-fault reset loop の可能性。 SOL の menuentry/GRUB 反復回数 + 実 VGA capture で reset loop を見抜く。 cmdline flag (`vga=`/`nomodeset`/`acpi=`) が triple-fault を誘発しうる。
6. **iRMC USB Virtual Media (redirector) は長時間運用で累積劣化** し、 FW update でも回復しない。 ネットワーク install (PXE) の方が堅牢。
7. **誤判定に注意**: PowerState=On や NFS read 累積は install 成功の証拠にならない (warm-reset loop 中も On に見える)。 真の完遂は **PowerState Off (poweroff) + installer stage + 最終 SSH** で確認。

## 関連

- Phase 別 report: `report/2026-05-*_tx1320_raid10_phase*.md` (Phase 8/9/11/13/15/16/18/19 が要)
- memory: `training_tx1320_phase19_pxe_autonomous_ssh.md` (最終)、 `training_tx1320_kernel_silent_post_grub.md` (Phase 3-13)、 `training_tx1320_phase8_findings.md`、 `training_tx1320_irmc_kvm_framebuffer_artifact.md`、 `training_tx1320_nfs_solved.md`、 `training_tx1320_smb_n6_step1.md`
- Issue #72 (done、 phase19a)
