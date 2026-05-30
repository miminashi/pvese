# Phase 13: TX1320 RAID10 OS install — SOL silence 真因切り分け 3 経路

## Context

[Phase 12 (2026-05-22 phase12-111602)](../../projects/pvese/report/2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed.md) で `quiet` 削除 + `earlyprintk=ttyS0,115200n8 loglevel=8 ignore_loglevel` 投入後も 600s 観測で kernel printk **0 行**、 OEM Screenshot で VGA も `Booting 'Automated Install'` で凍結を確定観測。 ipmitool SOL は 114 回再接続 (= ~5s/cycle warm-reset loop 継続)。

残仮説は二択に絞り込み完了:

- **仮説 12**: kernel startup 内部 hang (printk init 前で死亡 — VGA も SOL も書き込み始める前に triple-fault)
- **仮説 13**: D3373 SOL UART bridge + EFI ConOut が UEFI ExitBootServices で detach (kernel printk は出るが iRMC に届かない)

**目標**: training-tx1320 への OS install 完遂 (preseed 完走 + RAID10 + SSH login)。
**Phase 13 直接目標**: ユーザ指示の最優先 3 経路で SOL silence の真因を切り分け、 可能なら本 phase で boot 成功まで持っていく。

## 環境情報

- 機器: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / Mainboard D3373 / BIOS V5.0.0.11 R1.22.0 / iRMC S4 FW 9.08F / BMC 10.254.254.9)
- セッション tmp: `tmp/59a84357/` (session 59a84357-c76e-4f9a-80da-09f7efd52248)
- Virtual Media: iRMC OEM NFS (`10.1.6.6:/var/samba/public`、 [[training-tx1320-nfs-solved]] 経路)
- 既存 ISO:
  - `/var/samba/public/debian-13.3.0-amd64-netinst.iso` (stock、 wrapper 経由なし baseline 用)
  - `/var/samba/public/debian-training-tx1320-raid10.iso` (Phase 12 build、 800 MB、 console=tty0 含む — rollback 用に保全)
- 観測ツール:
  - `.venv/bin/python scripts/sol-monitor.py` (orchestrate monitor wrapper bug 回避のため直接起動)
  - `scripts/irmc-oem-screenshot.sh` (Phase 8 で発見した真の VGA capture 経路、 KVM canvas artifact を完全回避)
- BMC 前処理 (deploy 毎):
  - `ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload enable 2 4` (毎回必要)
  - boot-override は orchestrate.sh deploy が自動 (BMC_BOOT_OVERRIDE_NO_DISABLED=1)

## 判定基準 (Phase 11 教訓を踏襲)

| 観測 | 結果 |
|------|------|
| `grep -c "Linux version" sol.log` | **>= 1** で kernel printk 到達 = SOL UART 生きてる |
| `grep -c "Booting 'Automated Install'" sol.log` | **1 回のみ** = boot 進行中 / **N>1** = warm-reset loop |
| `grep -c "Loading bootloader" sol.log` | **>0** で GRUB stage triple-fault |
| OEM Screenshot t=540s が welcome 画面 | kernel boot 成功 |
| OEM Screenshot t=540s が `Booting...` 凍結 | kernel jump 後 hang |
| ipmitool SOL session reconnects | warm-reset cycle 数の指標 (Phase 12: 114 / 600s) |

## Step 0: 環境準備 + baseline

1. `mkdir -p tmp/59a84357/{stepA,stepB,stepC}`
2. iRMC baseline 確認 (give-up state チェック):
   - `./scripts/bmc-power.sh status 10.254.254.9 claude Claude123` (PowerState 確認)
   - `ping -c 3 10.254.254.9` (iRMC が応答するか)
3. 直前の cmdline (Phase 12 patch 後) を確認:
   - `git diff scripts/remaster-debian-iso.sh` で uncommitted 状態を保存

## Step A: `console=tty0` 削除版 ISO で再 boot — 最優先

**仮説**: VGA console init で kernel が早期死亡している可能性。 `console=tty0` を抜けば kernel は VGA framebuffer を触らず ttyS0 のみで printk 出力。 これで Linux version が SOL に出れば仮説 13a 確定。

### 実施手順

1. `scripts/remaster-debian-iso.sh` の cmdline 4 箇所 (L124 / L134 / L138 / L197) から **`console=tty0 ` のみ削除** (`console=ttyS${SERIAL_UNIT},115200n8` は残す):
   - L138 は `install` label で元から `console=tty0` を含まないため変更不要 (L124/L134/L197 の 3 箇所)
2. `SKIP_STORCLI_FETCH=1 ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml`
   - 新 ISO は `/var/samba/public/debian-training-tx1320-raid10.iso` を上書き
3. ISO 内 grub.cfg 抽出して cmdline 確認 (`xorriso -indev OUTPUT.iso -extract /boot/grub/grub.cfg tmp/59a84357/stepA-grub.cfg`)
4. deploy:
   - `./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml`
5. SOL 監視 (600s) を background で起動 + 並行で OEM Screenshot loop:
   - `.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file tmp/59a84357/stepA-sol.log --timeout 600 --powerstate-interval 30`
   - OEM Screenshot at t=60, 120, 180, 300, 420, 540s → `tmp/59a84357/stepA/screenshot-tNN.jpg`
6. 判定:
   - **`Linux version` 出現** → 仮説 13a 確定。 さらに boot 継続観測して preseed 進行確認 → 成功なら Phase 13 ゴール達成
   - **SOL 沈黙継続** → Step B へ

## Step B: stock Debian 13.3.0 netinst ISO を直接 NFS attach (wrapper 経由なし baseline)

**仮説**: wrapper の cmdline / preseed injection / EFI rebuild のいずれかが triple-fault の真因。 stock ISO は preseed なし + serial console 設定なし + 完全 unmodified なので、 これが boot するなら真因は wrapper 側。

### 実施手順

1. iRMC OEM Virtual Media に stock ISO を attach:
   - `./scripts/irmc-virtualmedia.sh --share-type=NFS config 10.254.254.9 claude Claude123 10.1.6.6 /var/samba/public debian-13.3.0-amd64-netinst.iso`
   - `./scripts/irmc-virtualmedia.sh connect-cd 10.254.254.9 claude Claude123`
   - `./scripts/irmc-virtualmedia.sh --share-type=NFS mount 10.254.254.9 claude Claude123` (DisconnectCD 待ち)
2. boot-override + power cycle:
   - `BMC_BOOT_OVERRIDE_NO_DISABLED=1 ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI`
   - `./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123`
   - `./scripts/bmc-power.sh on 10.254.254.9 claude Claude123`
3. 観測 (stock ISO は SOL 出力なしなので OEM Screenshot 中心):
   - `ipmitool ... sol payload enable 2 4` (念のため)
   - SOL 600s 監視 → `tmp/59a84357/stepB-sol.log`
   - OEM Screenshot at t=60, 120, 240, 360, 480, 600s → `tmp/59a84357/stepB/screenshot-tNN.jpg`
4. 判定:
   - **OEM Screenshot に Debian Installer の Welcome / Language Select 画面 (青ベースの GUI または text dialog)** → kernel boot 成功 → 真因は wrapper 側 → 次セッションで preseed/cmdline を 1 つずつ追加して bisect
   - **`Booting Debian ...` 凍結 + warm-reset cycle** → kernel 自体が D3373 + iRMC NFS+UEFI 経路で死亡 → Step C へ

## Step C: Debian 12 (bookworm) netinst ISO で base 互換性検証

**仮説**: Debian 13 kernel 6.12 × D3373 UEFI ExitBootServices に固有の問題なら、 Debian 12 (kernel 6.1.x) では boot する。 boot すれば真因確定 + Debian 12 で先に install 完遂する代替経路も検討可能。

### 実施手順

1. Debian 12 netinst ISO を playground (10.1.6.6) に配置 (10.1.6.6 はインターネット可):
   - `ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 'wget -O /tmp/debian12.iso https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso'`
   - sha256 検証 (公式 SHA256SUMS を別途取得)
   - `sudo mv /tmp/debian12.iso /var/samba/public/debian-12.5.0-amd64-netinst.iso`
   - ※ 12.5.0 が current でなければ `wget -q -O - https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -oE 'debian-12\.[0-9]+\.[0-9]+-amd64-netinst\.iso' | sort -u | tail -1` で確認
2. NFS attach (Step B と同じ手順、 ImageName だけ変更):
   - `./scripts/irmc-virtualmedia.sh --share-type=NFS config 10.254.254.9 claude Claude123 10.1.6.6 /var/samba/public debian-12.5.0-amd64-netinst.iso`
   - 以降 Step B と同様
3. 観測:
   - SOL 600s → `tmp/59a84357/stepC-sol.log`
   - OEM Screenshot at t=60, 120, 240, 360, 480, 600s → `tmp/59a84357/stepC/screenshot-tNN.jpg`
4. 判定:
   - **welcome 画面到達** → 真因 = Debian 13 kernel 6.12 固有 → Phase 14 で `nomodeset` `nokaslr` `pci=nocrs` 等の kernel option bisect、 並行で Debian 12 ベースで install 完遂を目指す
   - **同じく triple-fault loop** → kernel 非依存、 D3373 + iRMC NFS+UEFI HW/FW 問題 (仮説 13)。 USB stick boot や DVD physical media (現地操作) が次の検討候補

## Step D: 結果集約 + 次アクション決定

- Step A-C の結果から Phase 13 結論を作成:
  - 仮説 12 vs 13 の優劣
  - boot 成功した経路があれば、 そのまま preseed 完走 → SSH login 確認まで継続 (時間あれば)
- レポート作成: `report/2026-05-22_<HHMMSS>_tx1320_raid10_phase13_console_bisect_baseline.md`
- memory `training_tx1320_kernel_silent_post_grub.md` Phase 13 セクション追加
- 仮説 13 (HW/FW 制約) が濃厚なら issue #71 を「物理 USB media 必須」へ更新検討

## Critical files / scripts

| 用途 | パス |
|------|------|
| cmdline 編集 (Step A のみ) | `scripts/remaster-debian-iso.sh` L124 / L134 / L197 (`console=tty0 ` を削除) |
| ISO build | `scripts/tx1320-raid10-orchestrate.sh build` |
| ISO deploy (NFS attach + boot-override + power cycle) | `scripts/tx1320-raid10-orchestrate.sh deploy` (Step A) / `scripts/irmc-virtualmedia.sh` 直接 (Step B/C) |
| SOL 監視 | `.venv/bin/python scripts/sol-monitor.py` (orchestrate monitor wrapper bug 回避) |
| OEM Screenshot | `scripts/irmc-oem-screenshot.sh` (真の VGA capture、 canvas artifact なし) |
| 電源操作 | `scripts/bmc-power.sh` (BMC_BOOT_OVERRIDE_NO_DISABLED=1 + POWER_ON_RESET_TYPE=On 必須、 config で export 済) |
| 設定 | `config/training_tx1320.yml` (SERIAL_UNIT=0、 virtual_media_type=nfs、 nfs_host=10.1.6.6) |

## Verification

Phase 13 最終 verification:

1. **目標達成判定 (Step A or B or C のいずれかが成功した場合)**:
   - SOL log に `Linux version 6.x.x-amd64` が出現
   - OEM Screenshot で installer welcome 画面または preseed 進行中の dialog
   - (preseed 完走を待てば) `ssh root@<dhcp_ip>` で接続成功 + `lsblk` で /dev/sda RAID10 VD (~1.8 TB) 確認
2. **失敗時の confirmation**:
   - Step A-C 全てで `Booting` 反復 + screenshot 凍結 + PowerState=On 継続 を観測
   - sol-monitor.py の session reconnect 回数が Phase 12 と同等 (~100+ / 600s)
3. **レポート + memory 更新**:
   - `report/2026-05-22_*_tx1320_raid10_phase13_*.md` 作成 (REPORT.md フォーマット)
   - memory `training_tx1320_kernel_silent_post_grub.md` Phase 13 セクション追記

## Risk & contingency

- **iRMC give-up state**: Step 0 の ping/status で異常時は physical power cycle 検討 (ユーザ依頼)
- **Phase 12 ISO 上書き**: Step A の build で `/var/samba/public/debian-training-tx1320-raid10.iso` が上書きされるので、 必要なら事前に backup 名でコピー
- **`irmc-bios.py backup` 副作用**: 本 Phase は BIOS backup を実施しない (cmdline / Virtual Media 切替のみ)。 BIOS 設定は Phase 12 と同一を維持
- **playground 10.1.6.6 disk 容量**: Debian 12 ISO ~700 MB 追加、 既存 ISO 群と合わせて余裕あり (Step 0 で `df -h /var/samba/public` 確認)
- **Step A での cmdline patch revert**: Phase 5 の git checkout 失敗教訓により、 patch は **逆 sed で戻す**。 patch 内容は session 終了時にコミット可否をユーザに確認
- **`orchestrate monitor` wrapper bug**: 本 Phase でも `sol-monitor.py` 直接起動で回避継続 (修正は別 issue)

## 関連 memory / レポート

- [Phase 12 (2026-05-22 phase12-111602): SOL silence 確定](../../projects/pvese/report/2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed.md)
- [Phase 11 (2026-05-22 phase11-084821): Phase 10 誤判定発覚](../../projects/pvese/report/2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed.md)
- [Phase 9 (2026-05-22 phase9-060436): stock 13.3.0 ISO 直接 boot で wrapper cmdline が真因確定](../../projects/pvese/report/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated.md)
- memory `training-tx1320-kernel-silent-post-grub` (Phase 3-12 経緯、 Phase 13 で更新予定)
- memory `training-tx1320-nfs-solved` (NFS attach 経路、 Step B/C で流用)
- memory `training-tx1320-irmc-kvm-framebuffer-artifact` (OEM Screenshot は真の VGA capture)
- memory `playground-10-1-6-6` (Debian 12 download host、 NFS export host)
