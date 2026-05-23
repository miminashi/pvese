# Phase 18: TX1320 RAID10 OS install — iRMC S4 FW 9.08F → 9.69F update 完遂 + scripts/irmc-fw-update.sh 新規 + irmc-virtualmedia.sh API rename 適応、 BIOS POST 99 stuck は FW level では解消せず

- **実施日時**: 2026-05-23 12:00 〜 14:30 (JST) 約 2.5 時間
- **セッション**: e828c12b (zazzy-dawn)
- **Issue**: #72 (Phase 14-17 引き継ぎ、 USB redirector 問題による install ブロック)

## 添付ファイル

- [実装プラン](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/plan.md)
- [9.21F flash log (kill 前途中、 BMC 復活 wait まで)](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/9.21F-flash.log)
- [9.69F flash log (完遂)](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/9.69F-flash.log)
- [Pre-update manager.json (FW 9.08F)](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/pre-update-manager.json)
- [Pre-update FirmwareInventory (SDR 3.16)](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/pre-update-firmware-inventory.json)
- [Post-9.69F manager.json](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/post-9.69F-manager.json)
- [Post-9.69F FirmwareInventory (SDR 3.18)](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/post-9.69F-firmware-inventory.json)
- [Screenshot: 1st deploy → BIOS POST 99 stuck (FW update 直後)](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/screen-deploy1-post-99-stuck.jpg)
- [Screenshot: PSU reset 後の Aptio Setup Utility (POST 99 突破)](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/screen-post-psu-reset-bios-setup.jpg)
- [Screenshot: 2nd deploy → BIOS POST 99 stuck 再現](attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/screen-deploy2-post-99-stuck.jpg)

## 対象機

- **training-tx1320** (Fujitsu PRIMERGY TX1320 M3 / D3373-B1 / BIOS V5.0.0.11 R1.22.0 / BMC 10.254.254.9)
- iRMC S4 **FW 9.08F → 9.69F_sdr03.18** (本セッション update 完遂)
- SDR Version: **3.16 → 3.18**
- HW: PRAID EP400i (LSI MegaRAID SAS3008) + SAS HDD 900GB × 4 / HW RAID10 構成済 (VD0 = /dev/sda 1.80 TB)
- Virtual Media: iRMC OEM NFS Virtual Media (10.1.6.6:/var/samba/public)

## 前提・目的

Phase 17 (2026-05-23 0dfdbfdc / wise-book) で USB redirector 累積劣化により install が 3 deploy attempts 全て BIOS POST 99 stuck で未達。 ユーザは 2026-05-23 に BMC ブリックリスクを認識した上で **F1 iRMC FW 9.08F → 9.69F update 実施を明示承認**。

Phase 18 の sequence (ユーザ判断確認済):
1. **段階 update** (9.08F → 9.21F → 9.69F) で 14 ヶ月分の jump を半分に分割し中間検証可能化
2. **chassis ForceOff** 状態で update (host OS 無し)
3. `scripts/irmc-fw-update.sh` は **動作実証後に main commit** (Phase 17 Option B 踏襲)

## 達成事項

### 🎯 18-A: FW download + 7z extract (15 min)

| BIN | サイズ | 配置先 |
|-----|--------|--------|
| 9.21F | 31,457,408 bytes (D3373-B1_09.21F_sdr03.17.bin) | tmp/e828c12b/9.21F-bin/ |
| 9.69F | 31,457,416 bytes (D3373-B1_09.69F_sdr03.18.bin) | tmp/e828c12b/9.69F-bin/ |

- 公開 directory `https://support.ts.fujitsu.com/globalflash/ManagementController/iRMC%20S4-TX13x0M3/` から両方の .exe (各 ~72 MB) を wget で 1 分以内に取得
- `.exe` は PE → embedded zip 構造、 7z で展開
- 内側に Fujitsu ASP **`.scexe`** (bash script + gzip-tar archive、 line 4150 以降に archive) があり、 `extract-scexe.sh` を作成して BIN ファイルを抽出
- `rel_note.txt` に TX1320 M3 互換性問題の記載なし → 段階 update 続行で OK 判定

### 🎯 18-B: Pre-update state capture (10 min)

`tmp/e828c12b/pre-update/` に 6 ファイル保存:

| 項目 | Pre-update (9.08F) |
|------|--------------------|
| FirmwareVersion | 9.08F |
| BMCFirmware | 9.08F |
| **SDRRVersion** | **3.16** |
| BMCFirmwareRunning | LowFWImage |
| Account 4 | claude/Administrator |
| Network | 10.254.254.9 (DHCP) |
| BiosVersion | V5.0.0.11 R1.22.0 for D3373-B1x |
| PowerState | Off |

BIOS XML backup は PowerState=Off 中 (BIOS POST が走らないと backup 不可) のため skip。 plan の通り best-effort。

### 🎯 18-C-1: `scripts/irmc-fw-update.sh` 実装 (commit `aeb6a0e`、 363 LOC)

サブコマンド: `version`, `upload`, `progress`, `wait`, `wait-reboot`, `flash`。

**重要な発見**: `/irmcupdate` endpoint は multipart/form-data field 名 **`"file"`** を期待 (`"data"`, `"firmware"`, `"flashfile"`, `"image"`, `"fwfile"`, `"bin"`, `"payload"`, `"upload"` 全てが `<Value>6</Value> "File not provided"` で reject、 `"file"` のみ content validation 段階に到達)。 dummy 4KB ファイルで empirical 検証。

- iRMC HTTPS + `--ciphers DEFAULT@SECLEVEL=0` 必須
- `/irmcprogress` XML response: `<Value>0</Value>` = idle、 8 = programming N%、 9 = "FLASH successful"
- `wait` phase が BMC drop を観測した場合 stdout に `WAIT_SAW_DROP=1` 出力 → `flash` wrapper が wait-reboot に `--already-rebooted=1` 渡して短絡化
- `flashSelect=255` で両 image (low+high) 書込 = redundant store fallback

### 🎯 18-C-2: 9.21F flash → mini-verify (5 min)

| Phase | 時間 | 結果 |
|-------|------|------|
| Upload (multipart `file=@...`) | 81s | HTTP 200, `<Value>0</Value> "No Error"` |
| Server-side FLASH 2%→100% | 210s (~3.5 min) | value=8 推移、 14% / 30s |
| BMC reboot | 150-180s | curl rc=28→rc=7 (timeout→refused) |
| BMC return | t=390s | progress=0 "No update in progress" |

**mini-verify (post-9.21F)**:
- FirmwareVersion: **9.21F** (was 9.08F)
- SDRRVersion: **3.17** (was 3.16)
- claude user / Administrator preserved
- Network 10.254.254.9 preserved
- BIOS V5.0.0.11 R1.22.0 preserved (BIOS は更新対象外)

### 🎯 18-C-3: 9.69F flash → verify (5 min)

| Phase | 時間 | 結果 |
|-------|------|------|
| Upload | 83s | HTTP 200, `<Value>0</Value> "No Error"` |
| Server-side FLASH 2%→100% | 210s | 同じ progression |
| **Value=9 観測** | t=210s | "FLASH successful. You may need to reboot" (新発見、 9.21F では未観測) |
| BMC reboot | 540s = 9 min (= 9.21F の倍以上) | progress=0 確認、 saw_drop=1 |
| BMC return | t=540s + 短絡 | --already-rebooted=1 で wait-reboot 即時完了 |

**post-update 完全 verify (`scripts/post-update-verify.sh`)**:
- FirmwareVersion: **9.69F** ✓
- BMCFirmware: **9.69F** ✓
- **SDRRVersion: 3.18** ✓ (was 3.17)
- BMCFirmwareRunning: LowFWImage (consistent)
- BiosVersion: V5.0.0.11 R1.22.0 ✓ (preserved)
- Account 4 (claude/Administrator) ✓ (preserved)
- Network 10.254.254.9 ✓ (preserved)
- PowerState: Off ✓ (deploy-ready)

→ Phase 18A-D **完全成功**。 ブリック・auth/network/BIOS drift 全て無し。

### 🎯 18-E-Fix: `scripts/irmc-virtualmedia.sh` FTSVirtualMediaAction 適応 (commit `86f9f7e`)

deploy 試行で **新 FW 9.69F が ConnectCD で HTTP 400** 返却:

```
"MessageId":"Base.1.5.ActionParameterMissing",
"Message":"The action FTSComputerSystem.VirtualMedia requires the parameter FTSVirtualMediaAction to be present in the request body."
```

`/redfish/v1/Systems/0` Action info を確認すると、 OEM Actions が schema-qualified 名に統一されていた:
- `FTSResetType` (was `ResetType` for OEM Reset)
- `FTSScreenshotType` (was `ScreenshotType`)
- **`FTSVirtualMediaAction`** (was `VirtualMediaAction`)

`irmc_oem_action()` payload を `{"FTSVirtualMediaAction":"ConnectCD"}` に変更、 ConnectCD HTTP 204 OK 復活。

### 🎯 副次成果

- **iRMC FW Aux Rev decoding**: IPMI `mc info` Aux FW Rev `0x09 0x45 0x00 0x46` = BCD `09.69.00.46` ('F' ASCII) で **HTTPS Redfish 起動前に IPMI 経由で FW version 確認可能**
- **Redfish `ServiceTemporarilyUnavailable`**: FW reboot 後の早期 Redfish access は HTTP 503 (= JSON body with `MessageId=ServiceTemporarilyUnavailable`)。 完全 ready まで 60-180s 追加要
- **FW update 中 PowerState 監視**: PowerState=Off の iRMC reboot は chassis に影響無し (host fan・LED unchanged)、 FW 9.21F でも 9.69F でも同じ挙動
- **scexe extract 手順** (`tmp/e828c12b/extract-scexe.sh`): Fujitsu ASP scexe → bash + gzip-tar 構造解析、 line `############### Do not modify or delete this line!` + 1 = archive 開始

## install 完遂未達 (BIOS POST 99 stuck 再現)

Phase 18 deploy 2 attempts:

| Attempt | 前処理 | iRMC state | BIOS POST 結果 | SOL kernel printk |
|---------|--------|-----------|-----------------|-------------------|
| 1 (FW 9.69F 直後、 PSU reset 無し) | FW flash 完了 + chassis Off | 9.69F + Redfish OK | **POST 99 stuck** (Press F2 message visible) | **0 行** (Session operational 反復のみ) |
| 2 (PSU cold reset 30-60秒 後) | ユーザ実施 PSU 切断 → 再接続 → BMC 復活 | 9.69F 維持、 Aptio Setup 画面で起動 → ForceOff → deploy | **POST 99 stuck 再現** (Press F2 visible、 OEM Screenshot で確認) | **0 行** |

### Phase 17 との比較

| 観点 | Phase 17 (FW 9.08F) | Phase 18 (FW 9.69F) |
|------|----------------------|----------------------|
| FW update | リサーチのみ | 9.08F → 9.21F → 9.69F 完遂 |
| Deploy attempts | 3 (PSU reset 前/2-3秒/10-15秒) | 2 (FW update 直後/PSU reset 30-60秒 後) |
| BIOS POST 99 stuck | 3/3 attempts | 2/2 attempts |
| OEM API breaking change | N/A (9.08F 安定) | **VirtualMediaAction → FTSVirtualMediaAction** |
| install 完遂 | ❌ 未達 | ❌ 未達 |

### 失敗分析

- **FW update は技術的に完全成功** (9.08F→9.21F→9.69F、 auth/network/BIOS drift 無し、 ブリック無し) だが、 **BIOS POST 99 stuck という症状自体は FW 9.69F でも再現** = USB redirector 累積劣化問題は iRMC FW level では解消しない可能性
- PSU cold reset (30-60秒) でも一時的に Aptio Setup Utility (BIOS POST 99 突破画面) に到達したのみで、 deploy 経由の boot-override は POST 99 で stuck
- 仮説 1: BIOS V5.0.0.11 R1.22.0 (2018-12-18 R1.22.0) 自体に USB redirector 認識遅延の bug があり、 iRMC FW 更新では fix されない
- 仮説 2: iRMC FW 9.69F でも boot-override Cd UEFI Once が PSU cycle 後に reset される (Aptio Setup Utility 起動が証拠 — 通常起動なら boot ROM が CD redirector を試す)

## Phase 18 達成度サマリー

| 目標 | 達成度 | 補足 |
|------|--------|------|
| 18A: FW download + extract | ✅ **完全達成** | 9.21F + 9.69F BIN 取得、 ReadMe 互換性 OK |
| 18B: Pre-update state capture | ✅ **完全達成** | 6 ファイル保存 (BIOS XML は PowerState=Off で skip) |
| 18C-1: `scripts/irmc-fw-update.sh` 実装 | ✅ **完全達成** | 363 LOC、 6 subcommand、 commit `aeb6a0e` |
| 18C-2: 9.21F flash + mini-verify | ✅ **完全達成** | FW 9.21F + SDR 3.17 confirmed |
| 18C-3: 9.69F flash + verify | ✅ **完全達成** | FW 9.69F + SDR 3.18 confirmed、 ブリックなし |
| 18D: Post-update verification | ✅ **完全達成** | auth + network + BIOS drift 全保持 |
| 18E-Fix: irmc-virtualmedia.sh API rename | ✅ **完全達成** | commit `86f9f7e`、 FW 9.69F deploy で実証 |
| **18E: install 完遂 (preseed + RAID10 + SSH login)** | ❌ **未達成** | BIOS POST 99 stuck 再現 (PSU reset 後でも) |

## Phase 19 への引き継ぎ

| # | タスク | 優先度 | 補足 |
|---|--------|--------|------|
| **F2** | **PXE/netboot 経路 pivot** | 🔴 最高 | Phase 17 で f2-pxe-pivot-notes.md に設計済 (90-180 min)。 iRMC USB Virtual Media を完全 bypass、 NIC PXE boot 経由で installer 起動。 BIOS POST 99 stuck (USB redirector dead) を回避可能 |
| **F8b** | PSU 完全切断 5+ 分 | 🟠 高 | 30-60秒の PSU disconnect では BIOS POST 99 が完全には解消しない (Phase 18 で実証)。 さらに長い切断で iRMC + Super I/O も完全放電。 hardware-level reset の保険 |
| **F10** | BIOS update (R1.22.0 → 最新) | 🟡 中 | Fujitsu の BIOS update package は別 directory。 ただし TX1320 M3 EOL の可能性あり、 公式 latest が R1.22.0 で停止している場合は skip。 BMC FW と独立した USB redirector 認識 path がある可能性 |
| **F11** | 物理 USB stick boot | 🟡 中 | iRMC Virtual Media を完全に使わず、 USB stick に Debian ISO を焼いて物理装着。 host BIOS が USB stick から boot できれば install 経路復活。 ユーザの現地作業要 |
| **F12** | Replacement BIOS settings (CSM enabled / Legacy boot) | 🟢 低 | UEFI mode の USB redirector が問題なら、 CSM enabled / Legacy mode で USB stack が違う code path を通る可能性。 ただし preseed/ISO は UEFI 前提 |

### Phase 19 推奨 sequence

1. **F2 (PXE pivot)** が最有力。 Phase 17 で詳細設計済 (`f2-pxe-pivot-notes.md`):
   - playground 10.1.6.6 上に dnsmasq + TFTP + HTTP セットアップ (30 min)
   - Debian 13 netboot.tar.gz 配置 (15 min)
   - preseed.cfg を HTTP 配信化、 storcli64.bin も HTTP 配信 (45 min)
   - TX1320 BIOS で PXE boot 有効化 + `boot-override Pxe UEFI` (15 min)
   - deploy + SOL monitor (30 min)
   - 計 ~150 min for 1 attempt
2. F8b (長時間 PSU disconnect) は F2 の前に試す価値あり (low cost)
3. F1 は完了済 (9.69F 適用済)、 F11 はユーザ作業要

## 再現方法

### 1. Phase 18 までの状態確認

```sh
git log --oneline -5
# 期待: 86f9f7e (irmc-virtualmedia FTSVirtualMediaAction), aeb6a0e (irmc-fw-update.sh), ad5c18d (Phase 17 report), a4866ca, b7a0f16
```

### 2. FW download + extract (新規実施時)

```sh
mkdir -p tmp/<sid>/{9.21F,9.69F}
wget -O tmp/<sid>/irmc-9.69F.exe 'https://support.ts.fujitsu.com/globalflash/ManagementController/iRMC%20S4-TX13x0M3/09.69F_sdr03.18/zip_irmc_s4-tx13x0m3_09.69f_sdr03.18.exe'
7z x tmp/<sid>/irmc-9.69F.exe -otmp/<sid>/9.69F/
sh tmp/e828c12b/extract-scexe.sh 'tmp/<sid>/9.69F/...../*.scexe' tmp/<sid>/9.69F-bin/
# 期待: tmp/<sid>/9.69F-bin/D3373-B1_09.69F_sdr03.18.bin (31457416 bytes)
```

### 3. FW flash (post-9.21F → 9.69F)

```sh
IRMC_LOG_DIR=tmp/<sid> ./oplog.sh sh scripts/irmc-fw-update.sh flash 10.254.254.9 claude Claude123 tmp/<sid>/9.69F-bin/D3373-B1_09.69F_sdr03.18.bin --timeout=900 --reboot-timeout=300
```
期待: 全 4 step 完遂、 9 分以内、 `FirmwareVersion after: 9.69F`

### 4. Deploy 試行 (FW 9.69F 後)

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
```
期待: `deploy OK — host is booting from CD UEFI (pad total ~105s)`

### 5. SOL monitor で install 進捗確認

```sh
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload enable 2 4
.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60
```
**Phase 18 で確認した症状**: SOL log に `Session operational. Use ~? for help]` 反復のみで kernel printk 0 行 = BIOS POST 99 stuck。 OEM screenshot で "Press F2 to enter Setup" 画面確認可能。

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229, MainBoard D3373-B1 SN 57662941)
- **BMC**: iRMC S4 **FW 9.69F_sdr03.18** (10.254.254.9, HTTPS + SECLEVEL=0 必須, claude/Claude123 idx=4)
- **HW**: PRAID EP400i (LSI MegaRAID SAS3008) + SAS HDD 900GB × 4 (HW RAID10 VD0 = /dev/sda 1.80 TB)
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x (12/18/2018)
- **CPU/RAM**: Xeon E3-1230 v6 / 24 GiB
- **NFS server (playground)**: 10.1.6.6 (Ubuntu 24.04, /var/samba/public NFS export)
- **ISO**: `/var/samba/public/debian-training-tx1320-raid10.iso` (808 MB, Phase 17 build を継続利用)
- **本セッションの BMC 操作回数**: FW flash × 2 (9.21F + 9.69F)、 ForceOff × 4、 PowerOn × 3、 ConnectCD × 5、 boot-override × 2、 PSU cold reset × 1 (ユーザ実施、 30-60秒)

## 関連レポート / メモ

- [Phase 17 (2026-05-23 wise-book): F6/F7/F8 + F1 リサーチ完遂、 BIOS POST 99 で install ブロック](2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked.md)
- [Phase 16 (2026-05-23 replicated-pearl): patch を main commit + PSU reset で apt/partman 到達](2026-05-23_052353_tx1320_raid10_phase16_psu_reset_partman_reached.md)
- [Phase 15 (2026-05-23 bubbly-ripple): cdrom-detect patch 実装 + sanity 5/5 pass](2026-05-23_013410_tx1320_raid10_phase15_cdrom_detect_patch.md)
- memory `training-tx1320-phase16-patch-committed-partman-reached`
- memory `training-tx1320-nfs-solved` (NFS attach 経路、 引き続き有効)
- attachment `f2-pxe-pivot-notes.md` (Phase 17 で作成、 Phase 19 で参照)

## 関連 Issue

- **#72 (継続、 status=active → blocked、 owner phase18-e828c12b → 次セッションへ release)**
  - Phase 16-17: patch commit + USB redirector 累積劣化確認
  - **Phase 18 (e828c12b, 本セッション)**: FW 9.08F→9.21F→9.69F update 完遂 (commit `aeb6a0e`)、 irmc-virtualmedia.sh API rename (commit `86f9f7e`)。 install 完遂は BIOS POST 99 stuck 再現で未達 = FW level での問題解決は限界
  - **次セッション (Phase 19) 推奨**: F2 PXE pivot (最有力)、 F8b 長時間 PSU disconnect (low cost、 先行試行可)

## 関連ファイル

### 修正・新規作成 (本セッション、 commit 済)

| ファイル | commit | LOC | 修正内容 |
|---------|--------|-----|---------|
| `scripts/irmc-fw-update.sh` | `aeb6a0e` | NEW (363) | iRMC S4 FW update CLI (upload/progress/wait/wait-reboot/version/flash) |
| `scripts/irmc-virtualmedia.sh` | `86f9f7e` | +5/-1 | `irmc_oem_action()` payload を `FTSVirtualMediaAction` に rename (FW 9.69F 対応) |

### 一時 (tmp/e828c12b/、 commit しない)

- `tmp/e828c12b/9.21F.exe`, `9.69F.exe` (各 72 MB、 download cache)
- `tmp/e828c12b/9.21F-bin/D3373-B1_09.21F_sdr03.17.bin` (31 MB)
- `tmp/e828c12b/9.69F-bin/D3373-B1_09.69F_sdr03.18.bin` (31 MB)
- `tmp/e828c12b/extract-scexe.sh` (Fujitsu ASP unpack helper)
- `tmp/e828c12b/post-update-verify.sh` (FW + auth + network + BIOS check)
- `tmp/e828c12b/bmc-status.sh` (iRMC env var wrapper)
- `tmp/e828c12b/test-upload-fields.sh` (multipart field name probe)
- `tmp/e828c12b/pre-update/*`, `tmp/e828c12b/post-9.21F/*`, `tmp/e828c12b/post-9.69F/*` (Redfish snapshots)
- `tmp/e828c12b/upload-YYYYMMDD-HHMMSS.log*` (curl flash logs)
- `tmp/e828c12b/screen-*.jpg` (OEM screenshots)
- `tmp/e828c12b/install.log` (SOL monitor — 0 行 kernel printk)

### 新規作成 (report)

- `report/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists.md` (本レポート)
- `report/attachment/2026-05-23_143239_tx1320_raid10_phase18_fw_969_update_bios_99_persists/` (plan + 2 flash logs + 4 Redfish JSON + 3 OEM screenshots)

## 重要な教訓 (Phase 19 への引き継ぎ)

1. **iRMC FW update 単独では USB redirector 累積劣化を解消しない**: Phase 17 で「FW level で問題解決の可能性高」と推定したが、 Phase 18 で 9.08F→9.69F update 後も BIOS POST 99 stuck が再現。 iRMC firmware ではなく BIOS firmware (V5.0.0.11 R1.22.0) や hardware-level の問題の可能性が高い。 F2 PXE pivot が次善策
2. **Fujitsu iRMC S4 FW 9.69F の OEM Redfish API は schema-qualified パラメータ名を必須化**: `VirtualMediaAction` → `FTSVirtualMediaAction`、 `ResetType` → `FTSResetType` (OEM Reset)、 `ScreenshotType` → `FTSScreenshotType`。 9.08F は両形式受容、 9.69F は schema-qualified のみ。 既存スクリプトの段階移行の起点
3. **`/irmcupdate` multipart field name = "file"**: empirical 検証で `data`/`firmware`/`flashfile`/`image`/`fwfile`/`bin`/`payload`/`upload` 全て `<Value>6</Value>` reject、 `file` のみ通過。 Phase 17 リサーチノートの推定は不正確だった
4. **`/irmcprogress` Value=9 = "FLASH successful. You may need to reboot"**: 9.21F flash では未観測 (BMC drop が先)、 9.69F flash で観測 (BMC drop が遅延、 30s window で value=9 を見る機会あり)。 wait phase が value=9 で consecutive_idle=0 リセットされる挙動は許容 (BMC drop が次の poll で発生してから saw_drop=1 → 短絡)
5. **FW update 中・直後の BMC reboot は 8-10 分**: Phase 17 リサーチノートで「60-120 秒」と推定していたが、 実際は 9.21F で ~6 min、 9.69F で ~9 min (両 image 書込 = flashSelect=255 のため)。 `irmc-fw-update.sh` の `--reboot-timeout=600` (default) で吸収可能
6. **PSU cold reset 30-60秒では BIOS POST 99 stuck 完全解消せず**: Phase 18 で PSU 切断 → Aptio Setup Utility 起動を観測したが、 ForceOff + deploy で POST 99 stuck 再現。 hardware-level USB stack の reset には PSU 切断より長時間 (5+ 分?) or chassis 内 super I/O 完全放電が必要な可能性
7. **iRMC FW Aux Rev は BCD 4 バイト**: `0x09 0x45 0x00 0x46` = "9.69" (0x45 = 69 dec) + ASCII 'F' (0x46)。 Redfish HTTPS が unavailable な reboot 直後でも IPMI mc info で FW version 確認可能。 fallback diagnostic 経路として有用
