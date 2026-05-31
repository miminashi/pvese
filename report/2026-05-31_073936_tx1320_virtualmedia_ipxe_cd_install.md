# TX1320 VirtualMedia 経由 OS インストール完遂レポート (iPXE-on-CD)

- **実施日時**: 2026年5月31日 16:39 (JST)
- **セッション**: vmnfs531
- **対象**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F)
- **課題**: #71 (training-tx1320 NFS Virtual Media 本格統合 + OS install 完遂)

## 添付ファイル

- [実装プラン](attachment/2026-05-31_073936_tx1320_virtualmedia_ipxe_cd_install/plan.md)

## 前提・目的

- **背景**: PXE 経路 ([Phase 19](2026-05-30_050830_tx1320_raid10_phase19_pxe_autonomous_ssh.md) / [10-run](2026-05-30_130726_tx1320_pxe_10run_robustness.md)) で OS install は完遂済みだが、PXE は **OpenWrt ルータへの特別設定 (dnsmasq ローカル TFTP + `dhcp_boot=ipxe.efi`)** を要する依存があった。
- **目的**: VirtualMedia 経由のインストールを再挑戦し、**OpenWrt への特別設定依存を排除**する。
- ユーザ判断: 「VirtualMedia から起動して PXE 相当のことをやる」方針を採用。
- 制約: 別拠点設置、リモート操作のみ (長時間 PSU 切断は可だが今回は不要だった)。

## 環境情報

- iRMC S4 FW 9.69F / SDR 3.18、BIOS V5.0.0.11 R1.22.0 for D3373-B1x (2018-12-18)
- BMC `10.254.254.9` (HTTPS + `--ciphers DEFAULT@SECLEVEL=0`)
- ストレージ: PRAID EP400i (LSI MegaRAID SAS3008) / SAS HDD 900GB × 4 → HW RAID10 Optl 1.635 TB
- NIC: eno1 (192.168.33 拠点 LAN, OpenWrt NAT 背後)、eno2 (10.0.0.0/8 dark-net, claude 到達可)
- playground `10.1.6.6` (Ubuntu, nginx + NFS export `/var/samba/public` + embed ipxe.efi)
- 結果: Debian 13 (hostname `tx1320`)、`root@10.254.254.20` (eno2) で SSH 到達

## 結果サマリ

**VirtualMedia 経由で Debian 13 + HW RAID10 install を完遂**。物理操作なし・OpenWrt 特別設定なしで `ssh root@10.254.254.20` 到達。

経路: `iRMC VirtualMedia (NFS) で ipxe-tx1320.iso を attach → boot-override Cd → iPXE 起動 → DHCP(OpenWrt 通常) → 153.127.75.11 から kernel/initrd → playground HTTP から preseed/storcli → iPXE loader で kernel 起動 → d-i → storcli RAID10 再構築 → base/GRUB → auto-poweroff → boot-override Hdd → SSH`。

検証: `storcli64 /c0/vall show` = RAID10 Optl 1.635 TB、4 drives (252:0-3) all Onln。

## 突破した壁と真因

### 1. CD メディアが host/firmware に提示されない (USB redirector 劣化)
- Redfish 上は `ConnectCD` 成功 (HTTP 204) かつ `IsAnyVirtualMediaActive:true` を返すのに、host 側 `/dev/sr0` は "No medium found" (stale)。Phase 15-18 を阻んだ壁。
- **対策 (新発見)**: `POST /redfish/v1/Managers/iRMC/Actions/Oem/FTSManager.VirtualMediaServiceRestart` body `{"VirtualMediaType":"CD"}` で Virtual Media worker を再起動するとメディア提示が復活。

### 2. iRMC S4 FW 9.69F の VirtualMedia 操作順序
- **ConnectCD は `PowerState=On` 必須** (Off だと `Fujitsu.1.0.ActionParameterValueNotInList` HTTP 400)。接続済みなら allowable が `DisconnectCD` になり ConnectCD は 400。接続は ForceOff をまたいで持続。
- **boot-override Cd は `PowerState=Off` で設定 → PowerOn** でないと honor されない (On 中設定 + cycle は内蔵ディスク起動に化ける)。

### 3. GRUB 2.12 → Debian 13 (6.12) kernel の EFI ハンドオフ不可 (核心)
- 当 firmware では GRUB 2.12 (未署名 grub-mkstandalone も純正 shim 経由も) が kernel を firmware `StartImage` で起動しようとして `start_image() returned 0x8000000000000001` (EFI_LOAD_ERROR) で失敗 → kernel printk ゼロのまま GRUB に戻る triple-fault reset loop。
- **PXE が成功するのは iPXE が独自 loader (StartImage 非経由) で kernel を起動するから**。
- → **full-ISO の VirtualMedia boot は当 firmware では dead end。iPXE を CD で起動するのが解**。
- 副産物: `scripts/remaster-debian-iso.sh` に `PVESE_KEEP_ORIG_EFI=1` (Option B を skip し純正 shim efi.img 保持) を追加したが、shim でも 6.12 kernel は起動せず = full-ISO 経路は救済不可。env-gate は無害 (default 0)。

### 4. 内蔵 OS のフォールバック起動 (ユーザ要望「毎回ディスク初期化」と関連)
- ディスクに残る旧 install が内蔵起動してしまう問題は、起動中 OS に SSH して `efibootmgr -B <debian>` + `dd if=/dev/zero of=/dev/sda bs=1M count=50` (GPT+ESP) + 末尾 backup GPT 消去で起動不能化 → CD/iPXE 起動を強制。
- RAID10 VD 自体は install の `partman/early_command` が storcli で delete+create で毎回再構築 (= 要望を満たす)。

## 再現方法

### Step 1: iPXE-on-CD ISO のビルド (playground 上)
embed 済み `ipxe.efi` (pxe-deploy skill の followup 版、`interface=eno1`、playground `/var/www/html/ipxe.efi`) を最小 UEFI ISO の `/EFI/BOOT/BOOTX64.EFI` として焼く:
```sh
# tmp/vmnfs531/build-ipxe-iso.sh を playground で実行 (要旨)
mkfs.vfat で efi.img 作成 → mcopy ipxe.efi → ::/EFI/BOOT/BOOTX64.EFI
xorriso -as mkisofs -V IPXE_TX1320 -J -R -e efi.img -no-emul-boot -o ipxe-tx1320.iso <isoroot>
→ /var/samba/public/ipxe-tx1320.iso (= 10.1.6.6 NFS export, ~5.7MB)
```

### Step 2: VirtualMedia deploy (env を export してから)
```sh
export BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
export POWER_ON_RESET_TYPE=On BMC_PATCH_REQUIRES_ETAG=1 BMC_BOOT_OVERRIDE_NO_DISABLED=1
# tmp/vmnfs531/deploy-ipxe.sh の流れ:
./scripts/irmc-virtualmedia.sh disconnect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS config 10.254.254.9 claude Claude123 10.1.6.6 /var/samba/public ipxe-tx1320.iso
curl ... -X POST .../FTSManager.VirtualMediaServiceRestart -d '{"VirtualMediaType":"CD"}'   # 204
./scripts/bmc-power.sh on 10.254.254.9 claude Claude123      # ConnectCD は On 必須
./scripts/irmc-virtualmedia.sh connect-cd 10.254.254.9 claude Claude123                      # 204
./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123 ; (PowerState=Off を polling)
./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI                    # Off で設定
./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
```

### Step 3: 監視
```sh
.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file install.log --timeout 1800
# playground nginx access.log を tail (preseed/storcli/phonehome GET が真の進捗)
# 完遂判定: sol-monitor の POWER_DOWN→PowerState Off + nginx phonehome GET
```

### Step 4: install 完了後の disk boot + SSH
```sh
./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Hdd UEFI ; ./scripts/bmc-power.sh on ...
ip neigh | grep 4c:52:62:14:de:f0    # eno2 dark-net IP を特定 (今回 10.254.254.20)
ssh -F ssh/config root@<IP>
# PXE エントリ削除 (ユーザ要望): efibootmgr で UEFI: IP4/IP6 エントリを -B
```

## 既知の注意点・次アクション

- iRMC firmware は起動時に NIC の UEFI PXE エントリを自動再生成しうる (削除後の再確認が必要)。
- 成果物は `tmp/vmnfs531/` に未コミット (build-ipxe-iso.sh / deploy-ipxe.sh / wipe-disk.sh)。`remaster-debian-iso.sh` の `PVESE_KEEP_ORIG_EFI` + `tx1320-raid10-orchestrate.sh` の同 export も未コミット。
- **次セッション**: iPXE-on-CD を `scripts/` + skill (pxe-deploy 拡張 or 新規) に正式化してコミット。OpenWrt TFTP 不要なので cross-site + USB redirector 劣化機種の第一選択になりうる。

## 参照

- [Phase 1-19 総括](2026-05-30_053607_tx1320_raid10_overview_phase1-19_summary.md)
- [Phase 19 PXE autonomous SSH](2026-05-30_050830_tx1320_raid10_phase19_pxe_autonomous_ssh.md)
- [PXE 10-run robustness](2026-05-30_130726_tx1320_pxe_10run_robustness.md)
- メモリ: `training_tx1320_virtualmedia_ipxe_cd.md`
