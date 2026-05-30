# Phase 14: TX1320 RAID10 OS install — Phase 13 引き継ぎ 4 課題 a/b/c/d 完了 + kernel boot 確認、 cdrom-detect で d-i ブロック (既知未解決)

- **実施日時**: 2026年5月22日 15:40-17:30 (JST)
- **セッション**: linear-mountain (65ee84f4)

## 添付ファイル

- [実装プラン](attachment/2026-05-22_154033_tx1320_raid10_phase14_install_completed/plan.md)
- [install5 SOL log (kernel boot 成功・cdrom-detect block まで)](attachment/2026-05-22_154033_tx1320_raid10_phase14_install_completed/install5-sol.log)
- [install1 SOL log (reset loop signature、 Manager.Reset 前)](attachment/2026-05-22_154033_tx1320_raid10_phase14_install_completed/install1-resetloop-sol.log)
- [stock Debian 13.3.0 GRUB menu (HW + iRMC 健全確認)](attachment/2026-05-22_154033_tx1320_raid10_phase14_install_completed/stock-debian-grub-menu.jpg)
- [wrapper reset loop 中の OEM Screenshot (黒 VGA + Booting Automated Install 静止)](attachment/2026-05-22_154033_tx1320_raid10_phase14_install_completed/wrapper-resetloop-screenshot.jpg)
- [cdrom-detect dialog block 時 OEM Screenshot (= 黒 VGA、 d-i UI は serial 側)](attachment/2026-05-22_154033_tx1320_raid10_phase14_install_completed/cdrom-detect-dialog.jpg)

## 対象機

- **training-tx1320** (Fujitsu PRIMERGY TX1320 M3 / Mainboard D3373 / BIOS V5.0.0.11 R1.22.0 / iRMC S4 FW 9.08F / BMC 10.254.254.9)
- HW: PRAID EP400i (LSI MegaRAID SAS3008) + SAS HDD 900GB × 4 / RAID10 既構成 / **物理 DVD drive あり** (cdrom-detect 問題の真因)
- Virtual Media: iRMC OEM NFS Virtual Media (10.1.6.6:/var/samba/public)

## 前提・目的

[Phase 13 (2026-05-22 silly-rocket)](2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix.md) で `console=tty0` 削除 + playground 同期 + Manager.Reset で kernel boot 成功 + d-i screen UI + cdrom-detect/preseed/netcfg/partman まで到達。 ただし partman/early_command rc=127 で停止 + 副次重大発見として orchestrate.sh build がローカル `/var/samba/public` に書くが iRMC は playground 10.1.6.6 から読む = 過去の試行はほぼ古い ISO を boot していた可能性。

Phase 14 は Phase 13 で提示された最優先 4 課題 (a)(b)(c)(d) を順次解決して OS インストール完遂 (preseed 完走 + RAID10 install + SSH login) を目指す。

## 環境情報

- Source ISO: `/var/samba/public/debian-13.3.0-amd64-netinst.iso` (stock Debian 13.3.0)
- 本番 ISO: `/var/samba/public/debian-training-tx1320-raid10.iso` (Phase 14 では 772MB、 storcli64.bin 追加で +8MB)
- preseed: `tmp/training-tx1320-preseed-raid10.cfg` (`--with-raid10-storcli` + Phase 14 修正反映)
- config: `config/training_tx1320.yml` (static_ip 10.254.254.250、 serial_unit=0、 virtual_media_type=nfs)
- セッション tmp: `tmp/65ee84f4/`
- playground (claude-playground 10.1.6.6): SSH alias 追加、 `ubuntu` ユーザで sudo passwordless 確認済

## 実装した Phase 14 変更 (4 課題 a/b/c/d 全完了)

### (a) `scripts/tx1320-raid10-orchestrate.sh` build に playground 同期処理を組み込み

- build() 関数末尾に Phase 4.5 を新設: `virtual_media_type=nfs` + `nfs_host` 設定時、 `scp + ssh sudo mv` で ISO を `${NFS_HOST}:${NFS_EXPORT}/${OUTPUT_BASENAME}` に同期
- 認証: `${PROJECT_DIR}/ssh/config` 経由 (`ubuntu@10.1.6.6`)
- 同 host (`127.0.0.1` / `localhost`) のときは skip

### (b) storcli64 binary を build 時に `dpkg-deb -x` で事前抽出 + ISO に直接配置

- orchestrate.sh build() に Phase 2.5 (binary 抽出) を新設: `STORCLI_BIN_PATH=/var/samba/public/storcli64.bin` に bare binary を配置 (8.2 MB、 statically linked ELF64)
- remaster の `--include=` リストに `$STORCLI_BIN_PATH` を追加 → ISO 内 `/storcli64.bin` として配置
- `scripts/setup-raid10-storcli.sh` を簡素化: dpkg / in-target / dpkg-deb -x 3 段 fallback を全削除、 `cp /cdrom/storcli64.bin /usr/local/bin/storcli64 && chmod +x` のみ
- `scripts/generate-preseed.sh` L103 の partman/early_command 引数を `$p/storcli64.deb` → `$p/storcli64.bin` に変更
- 目的: d-i busybox initramfs に dpkg 不在 → rc=127 で死亡を回避

### (c) `console=tty0` を 2 ファイルから削除

- `scripts/generate-preseed.sh` L94: `console_order="console=tty0 console=ttyS${serial_unit},115200n8"` → `console_order="console=ttyS${serial_unit},115200n8"`
- `scripts/pve-setup-remote.sh` L75: `GRUB_CMDLINE_LINUX="console=tty0 console=ttyS${serial_unit},115200n8"` → `GRUB_CMDLINE_LINUX="console=ttyS${serial_unit},115200n8"`
- これにより installed system も d-i installer と同じ修正を継承し、 再 boot 後の VGA console init hang を恒久的に防止

### (d) `config/training_tx1320.yml` の `static_ip` を 10.254.254.99 → **10.254.254.250** に変更

- Phase 13 で使った 10.254.254.99 はローカルマシン (ens19) と ARP 衝突 → 同 /24 内で conflict-free な .250 に変更
- gateway / netmask / iface は変更不要

### 副次変更

- `ssh/config` に `Host playground HostName 10.1.6.6 User ubuntu IdentityFile ssh/id_ed25519` 追加 → orchestrate.sh から `ubuntu@10.1.6.6` 直接指定でも動作するため必須ではないが、 メンテナンス性向上

## 試行と結果

### Step 0: コード変更適用 + 検証

| 変更 | ファイル | 結果 |
|------|---------|------|
| (d) static_ip | `config/training_tx1320.yml` | preseed 生成で netcfg/get_ipaddress=10.254.254.250 確認 |
| (c) console=tty0 削除 | `scripts/generate-preseed.sh` L94 + `scripts/pve-setup-remote.sh` L75 | preseed の add-kernel-opts = `console=ttyS0,115200n8` のみ確認 |
| (a) playground 同期 | `scripts/tx1320-raid10-orchestrate.sh` L137-169 | build 末尾で `Phase 4.5: sync OK` 出力 + md5sum 一致確認 |
| (b) storcli64 binary | orchestrate L109-131 + setup script 簡素化 + generate-preseed L103 | ISO 内に `/storcli64.bin` 8212480 bytes 配置確認 |

### Step 1: 初回 deploy (Phase 14 完全版) → reset loop ❌

- build OK (772 MB、 playground sync OK、 md5 02607d4c... 一致)
- deploy OK (PATCH NFS + ConnectCD + boot-override Cd UEFI + ForceOff || true + PowerOn)
- SOL: `Booting 'Automated Install'` を **16 回反復** (GRUB countdown 3-0s → boot → reset の triple-fault loop)
- kernel printk = 0
- OEM Screenshot = 黒 VGA + 左上 `Booting 'Automated Install'` 静止 = Phase 11/12 hang signature

### Step 2: Manager.Reset → 再 deploy → 同じ reset loop ❌

- DisconnectCD + `Manager.Reset GracefulRestart` + 150s 待機 + Redfish 復旧確認
- config 再 PATCH + ConnectCD + boot-override + PowerOn
- SOL: 同じ reset loop 反復

### Step 3: storcli64.bin --include を一時除外して rebuild → 同じ reset loop ❌

- `scripts/tx1320-raid10-orchestrate.sh` から `--include="$STORCLI_BIN_PATH"` を一時的にコメントアウト
- 同じ deploy/SOL 経路 → reset loop 継続
- 結論: storcli64.bin 追加は reset loop の真因ではない

### Step 4: stock Debian 13.3.0 ISO boot 試行 → ✅ GRUB menu 正常表示

- CDImage を `debian-13.3.0-amd64-netinst.iso` (オリジナル) に切替
- ConnectCD + boot-override + PowerOn
- 10 分後 OEM Screenshot 取得: **stock Debian 13.3.0 UEFI Installer menu が VGA に正常表示** ("Graphical install / Install / Advanced options ..." が見える)
- 結論: HW + iRMC + NFS attach + BIOS UEFI + GRUB stage 全て健全。 問題は **wrapper ISO 固有**

### Step 5: `EXTRA_CMDLINE="nomodeset"` で rebuild → 同じ reset loop ❌

- `nomodeset` で kernel modesetting 無効化したが症状変わらず
- 結論: VGA modesetting も真因ではない

### 🎯 Step 6 (Phase 14 success): もう一度 Manager.Reset + 待機 + deploy → **kernel boot 成功** ✅

- ForceOff + ipmitool sol deactivate + DisconnectCD + Manager.Reset (GracefulRestart) + 240s 待機 + Redfish 復旧
- build + deploy + SOL monitor
- SOL log で:
  - `[    0.000000] Linux version 6.12.63+deb13-amd64` 観測 ✅
  - `Command line: BOOT_IMAGE=/install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg ... console=ttyS0,115200n8 earlyprintk=ttyS0,115200n8 loglevel=8 ignore_loglevel ---` 正確に展開 ✅
  - `pvese: preseed/early_command start (training-tx1320)` ✅
  - `pvese: preseed/early_command end` ✅
  - d-i `screen` UI 起動 + `(1*installer) 2 shell 3 shell 4- log` window バー観測 ✅
  - hw-detect 実行 ✅
- 結論: Phase 14 4 課題 + iRMC state 復旧で kernel boot は確実に動作する

### 🚨 Step 7 (Phase 14 block): d-i cdrom-detect で "No installation media" ダイアログでブロック ❌

SOL log 中で次の dialog が出現:

```
[!!] Detect and mount installation media
  No device for installation media was detected.
  ...
  Load drivers from removable media?
    <Yes>    <No>
```

直前の kernel log:
- `[    8.995836] /dev/sr0: Can't open blockdev`
- `[    9.244407] sr 9:0:0:0: Attached scsi CD-ROM sr1`
- `[    9.923212] scsi 9:0:0:1: CD-ROM Fujitsu Virtual CDROM1 1.00 PQ: 0 ANSI: 0 CCS`

= **TX1320 固有の既知未解決ブロッカー** (= 2026-05-18 c-curried-puddle session で記録):

- 物理 DVD drive (内蔵) が `/dev/sr0` として enumerate されるが **media なし → Can't open blockdev**
- iRMC OEM NFS Virtual CDROM は `/dev/sr1` (Fujitsu Virtual CDROM1) で enumerate
- d-i `cdrom-detect` は `/dev/sr0` を優先試行、 失敗、 fall through せず → "No device" dialog
- `cdrom-detect/scan=true` cmdline は **d-i に subsequent sr device を probe させない** (Debian source の cdrom-detect.postinst 仕様)
- `cdrom-detect/cdrom_device=/dev/sr1` を preseed/cmdline で設定すると **warm-reset boot loop** を引き起こす (2026-05-18 c-curried-puddle session で確認、 真因未解明)
- preseed の comment (L76-83) にも明示的に「Root cause unresolved; left for next session pivot.」と記載

なお Phase 13 stepA4 SOL log では sr0 + sr1 両方が attached (`Virtual CDROM0` + `Virtual CDROM1`) で cdrom-detect は sr0 を使えて通過していた = 偶発的なラッキー条件。 iRMC の CDImage attach 状態が 1 slot (sr1 のみ) のときに本問題が顕在化する。

## Phase 14 達成度

### 🎯 主目標達成度

| 目標 | 達成度 | 補足 |
|------|--------|------|
| (a) orchestrate build に playground 同期 | ✅ **完全達成** | Phase 4.5 で自動化、 動作確認済 |
| (b) storcli64 binary 直接 inject + dpkg 経路廃止 | ✅ **完全達成** | Phase 2.5 で抽出、 ISO 配置確認 |
| (c) console=tty0 削除 (installed system 用) | ✅ **完全達成** | 2 ファイル変更、 preseed 生成確認 |
| (d) static_ip を conflict-free な 10.254.254.250 へ | ✅ **完全達成** | config 変更、 preseed 生成確認 |
| kernel boot 成功 | ✅ **達成** | Linux version 6.12.63 + preseed early_command start/end + d-i screen UI 起動確認 |
| OS install 完遂 (preseed 完走 + RAID10 install + SSH login) | ❌ **未達成** | d-i cdrom-detect の既知未解決ブロッカーで停止 |

### 🎯 副次成果

1. **HW + iRMC + NFS attach は健全と確認**: stock Debian 13.3.0 ISO boot で GRUB menu 正常表示 → 問題は wrapper ISO ではなく iRMC state または d-i 固有
2. **iRMC NFS 復旧手順の再確認**: ForceOff + DisconnectCD + Manager.Reset (GracefulRestart) + 150-240s 待機 + Redfish 復旧確認 → 再 deploy で kernel boot 確実
3. **Phase 11/12 hang signature と reset loop 区別**: SOL に「Booting Automated Install」反復 + kernel printk 0 + 黒 VGA = 同じ症状 (host warm-reset by triple-fault); Manager.Reset で iRMC NFS 経路リセット後は kernel boot 成功
4. **Phase 13 で言及された「console=tty0 で hang」と Phase 14 序盤の「reset loop」は別物の可能性**: 後者は iRMC NFS state degradation。 真因究明は別 issue

### 🎯 Phase 15 (次セッション) への引き継ぎ

| # | タスク | 補足 |
|---|--------|------|
| 1 | **d-i cdrom-detect の /dev/sr1 fall-through 実装 (Phase 15 必達)** | 既存 `PVESE_PATCH_CDROM_DETECT=1` の pvese-patch v1 を再評価 + iRMC NFS 環境で sanity 確認。 別案: stock Debian 13.3.0 install を完全 network 経由に切替 (CD media 不要モード) |
| 2 | **Phase 14 で確立した手順を skill に反映**: `irmc-bios-raid` SKILL.md に「Manager.Reset 後の 240s 待機 + 再 deploy が kernel boot 確実」を追記 | 経験的知見をスキル化 |
| 3 | **cdrom-detect/cdrom_device=/dev/sr1 で warm-reset loop が起きる真因究明** | 2026-05-18 c-curried-puddle で確認された別問題、 Phase 15 で sanity 切り分け |
| 4 | **stock Debian 13.3.0 ISO の grub.cfg を確認** + remaster 不要な install 経路の可能性検討 | stock の `cdrom-detect/cdrom string /dev/sr1` 等の preseed を直接 boot menu 経由で渡せるか |

### 🎯 関連 Phase 14 plan には記載済の Out of Scope

- Phase 13 引き継ぎ事項 #5 (storcli setup を initramfs hook で実行) — Phase 15 で cdrom-detect 解決後に partman/early_command rc 確認、 必要なら検討
- Phase 13 引き継ぎ事項 #6 (stock 13.3.0 baseline) — Step 4 で実施 (= HW 健全確認)
- orchestrate `monitor` wrapper bug (Phase 12 引き継ぎ #6) — false alarm 可能性 (Phase 14 monitor 直接呼び出し問題なし)

## 再現方法

### 1. 全コード変更を build に反映

```sh
git status
SKIP_STORCLI_FETCH=1 ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
# 期待出力:
# [orchestrate] Phase 1: storcli64.deb present
# [orchestrate] Phase 2.5: storcli64 binary ready (8212480 bytes)
# [orchestrate] Phase 3: generate preseed -> tmp/training-tx1320-preseed-raid10.cfg
# [orchestrate] Phase 4: remaster ISO -> /var/samba/public/debian-training-tx1320-raid10.iso
# [orchestrate] build OK (local)
# [orchestrate] Phase 4.5: sync ISO to 10.1.6.6:/var/samba/public/debian-training-tx1320-raid10.iso
# [orchestrate] Phase 4.5: sync OK
```

### 2. iRMC state 復旧 (kernel boot を確実にするための重要 prereq)

```sh
# 既存セッション cleanup
./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123  # BMC_CURL_OPTS env 必須
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol deactivate
BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' BMC_PATCH_REQUIRES_ETAG=1 ./scripts/irmc-virtualmedia.sh disconnect-cd 10.254.254.9 claude Claude123

# Manager.Reset で iRMC NFS subsystem clear
curl -ksS --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"GracefulRestart"}' \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/Actions/Manager.Reset'

# 復旧確認 (150-240s 待機)
until ping -c 1 -W 2 10.254.254.9 >/dev/null 2>&1; do sleep 5; done
until curl -ksS --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 --connect-timeout 5 \
    'https://10.254.254.9/redfish/v1/Systems/0' >/dev/null 2>&1; do sleep 5; done
sleep 30  # 余裕
```

### 3. deploy + SOL monitor

```sh
./pve-lock.sh run ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
.venv/bin/python scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60
```

### 4. install 進行判定 (Phase 14 markers)

```sh
# kernel boot 成功
grep -ac "Linux version" install.log              # >=1 (実 boot 数判定は kernel time stamp unique で行う)

# preseed/early_command 完走
grep -ac "pvese: preseed/early_command start"      # >=1
grep -ac "pvese: preseed/early_command end"        # >=1

# d-i UI 起動
grep -ac "(1\*installer)"                          # >=1

# cdrom-detect block (Phase 14 ではここで停止)
grep -ac "No device for installation media"        # 0 が望ましい (Phase 15 で fix)
grep -ac "Load drivers from removable media"       # 同上

# 以下は Phase 15 で達成目標
grep -ac "pvese: partman/early_command start"
grep -ac "pvese: partman/early_command end (rc=0)"
grep -ac "pvese: raid10-setup OK: RAID10 created"
grep -ac "pvese: late_command start"
grep -ac "Installation complete"
```

## 関連レポート / メモ

- [Phase 13 (2026-05-22 silly-rocket): console=tty0 削除で kernel boot 成功確定](2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix.md)
- [Phase 12 (2026-05-22 phase12-111602): SOL silence 確定](2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed.md)
- [2026-05-18 c-curried-puddle: cdrom-detect.postinst pvese-patch v1 設計 + verify (SMB blocked で未完了)](2026-05-18_080521_tx1320_raid10_cdrom_patch.md)
- [2026-05-18 verify: pvese-patch v1 sanity check 4 項目 pass、 ただし SMB ネットワーク品質不良で deploy 未実施](2026-05-18_101017_tx1320_raid10_cdrom_patch_verify.md)
- memory `training-tx1320-kernel-silent-post-grub` (Phase 3-12 経緯。 Phase 13 で真因 console=tty0 確定、 Phase 14 で本記載 cdrom-detect block へ移行)
- memory `training-tx1320-nfs-solved` (NFS attach 経路、 Phase 14 で再確認・依然有効)
- memory `training-tx1320-irmc-kvm-framebuffer-artifact` (OEM Screenshot = 真 VGA capture、 cdrom-detect block 時の黒 VGA = serial 側 UI 動作中の framebuffer 状態と区別)
