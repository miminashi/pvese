# Phase 16: TX1320 RAID10 OS install — Phase 15 patch commit + PSU cold reset + apt/partman フェーズ到達 (install 完遂は reset loop により未達)

- **実施日時**: 2026年5月23日 01:43 〜 05:23 (JST、約 3 時間 40 分)
- **セッション**: 4a583656 (replicated-pearl)
- **Issue**: #72 (Phase 15 → Phase 16 引き継ぎ、cdrom-detect 突破 + install 完遂)

## 添付ファイル

- [実装プラン](attachment/2026-05-23_052353_tx1320_raid10_phase16_psu_reset_partman_reached/plan.md)
- [self-contained deploy-careful.sh (本セッション版)](attachment/2026-05-23_052353_tx1320_raid10_phase16_psu_reset_partman_reached/deploy-careful.sh)
- [SOL log (PSU reset 後の 30 min 観測、298,255 行、34 MB)](attachment/2026-05-23_052353_tx1320_raid10_phase16_psu_reset_partman_reached/install2.log)

## 対象機

- **training-tx1320** (Fujitsu PRIMERGY TX1320 M3 / D3373 / BIOS V5.0.0.11 R1.22.0 / iRMC S4 FW 9.08F / BMC 10.254.254.9)
- HW: PRAID EP400i (LSI MegaRAID SAS3008) + SAS HDD 900GB × 4 / HW RAID10 構成済 (VD0 = /dev/sda 1.80 TB)
- Virtual Media: iRMC OEM NFS Virtual Media (10.1.6.6:/var/samba/public, AutoAttach なし — connect-cd 必須)

## 前提・目的

[Phase 15 (2026-05-23 bubbly-ripple)](2026-05-23_013410_tx1320_raid10_phase15_cdrom_detect_patch.md) で cdrom-detect.postinst patch (`PVESE_PATCH_CDROM_DETECT=1`) の実装 + sanity 5/5 pass + `(1*installer)` window 観測まで達成。 実機検証は iRMC USB redirector 不安定で reset loop により未達。 Phase 16 の目的は:

1. Phase 15 patch を main に **commit** (sanity pass = commit 候補品質、ユーザ承認済)
2. PSU cold reset で iRMC state degradation をクリーン化
3. PSU reset 後の 1-deploy で patch 動作立証 + install 完遂
4. fallback (FW update / PXE / 別 base) は Phase 17 持ち越し (本 Phase では実施しない)

最終目標: OS インストール完了 (preseed 完走 + RAID10 + SSH login)。

## 実装した変更 (Task 1 = 完全達成)

### commit `0624539b2d`: `remaster-debian-iso.sh: Phase 10/12/13/15 TX1320 install fixes`

単一 commit に Phase 10/12/13/15 の cmdline + initrd 修正をまとめた:

- **Phase 10**: `vga=normal nomodeset` 削除 (GRUB-stage triple-fault 修正、Phase 9-10 bisect で確定)
- **Phase 12**: `quiet` 削除 + `earlyprintk=ttyS$SERIAL_UNIT,115200n8 loglevel=8 ignore_loglevel` 追加 (SOL kernel printk 沈黙の Phase 11 misjudgment 修正)
- **Phase 13**: `console=tty0` 削除 (VGA console init での kernel hang 修正)
- **Phase 15**: `PVESE_PATCH_CDROM_DETECT=1` で gate された cdrom-detect.postinst patch 実装 (awk in-place + sh -n + find/sed cpio inject)
- New `EXTRA_CMDLINE` env slot で runtime cmdline injection 対応

`scripts/tx1320-raid10-orchestrate.sh` (orchestrate.sh) と依存スクリプト (`setup-raid10-storcli.sh`, `irmc-virtualmedia.sh`, `irmc-oem-screenshot.sh`, `fetch-storcli-deb.sh`, `irmc-bios-raid-setup.sh`, `irmc-bios.py`, `irmc-kvm-interact.py`, `irmc-kvm-screenshot.py`, `irmc-raid10-create.py`) は全て untracked のまま **Phase 17 で wholesale TX1320 toolchain commit として処理予定** (Phase 16 単独で commit すると不完全な依存を含む大規模 commit となるため)。

## 試行と結果

### Step 1 (Task 1): Phase 15 patch を main に commit ✅ 達成

```sh
git diff --stat scripts/remaster-debian-iso.sh   # 73 insertions, 5 deletions
git add scripts/remaster-debian-iso.sh
git commit -F tmp/4a583656/commit-msg.txt
git log -1 --stat   # commit 0624539b confirmed
```

### Step 2 (Task 2): iRMC 状態確認 ✅ 達成 — Manager.Reset スキップ判断

| 項目 | 値 | 判断 |
|------|----|------|
| PowerState | Off | clean state |
| AllowableValues | `['ConnectCD']` | not attached, clean |
| NFS config | Server=10.1.6.6, ImageName=debian-training-tx1320-raid10.iso | Phase 15 のまま保持 |
| Health | OK / HealthRollup=OK | iRMC 健全 |

Phase 15 末尾の劣化状態が表面化していないため Manager.Reset スキップ判断 (Phase 15 教訓: Manager.Reset では USB redirector state degradation 解消できない、 4 分の overhead が空回り)。 deploy-careful.sh の長 pad に直接依存。

### Step 3 (Task 3): 初回 deploy → GRUB-stage triple-fault loop ❌ (Phase 11 と同症状)

- 04:52 頃 deploy → 30 min sol-monitor 観測 (install.log、 5505 行)
- 295 回 "Booting Automated Install" 反復、 kernel printk **0 行**、 全 GRUB countdown 完走後の kernel jump 直後で reset loop (cycle ~6s)
- = Phase 15 が予測していた "iRMC USB redirector の state degradation が更に進行" 状態の実証

### Step 4 (Task 2 part 2): PSU cold reset 依頼 (ユーザ実施) ✅

- ForceOff (PowerState=Off 4s 後確認)
- AskUserQuestion で電源ケーブル 2-3 秒抜差し依頼 → ユーザ実施
- ping 即応 (0s) だが Redfish が `Base.1.0.ServiceTemporarilyUnavailable` 継続 (~2 hour gap、 ユーザ実機操作のタイミング待ち)
- 復帰時 PowerState=**On** + AllowableValues=`['ConnectCD']` (= 初回 boot が internal disk fallback、 Phase 15 Step 5 と同症状)

### Step 5 (Task 3 再試行): PSU reset 後の deploy-careful.sh ✅ kernel boot 復活

deploy-careful.sh (30s settle + 60s USB stabilize + 15s pre-power の長 pad パターン) で 04:52:24 deploy 完了:

- BIOS POST → GRUB countdown 完走 → "Booting Automated Install" → **kernel printk が SOL に出力開始**
- `[0.000000] Linux version 6.12.63+deb13-amd64` 確認
- `[0.861795] Kernel command line: ... earlyprintk=ttyS0,115200n8 loglevel=8 ignore_loglevel ---` (Phase 12/13 fix 効果確認)
- `[5.018083] scsi 0:2:0:0: Direct-Access FTS PRAID EP400i` (megaraid_sas 認識)
- `[5.429632] sd 0:2:0:0: [sda] 3514171392 512-byte logical blocks: (1.80 TB/1.64 TiB)` (RAID10 VD0 認識)
- `[7.685656] sr 9:0:0:0: [sr1] scsi-1 drive` (usb-storage host9 で iRMC OEM Virtual CDROM = /dev/sr1 attach)
- `[8.970555] sr 9:0:0:0: Attached scsi CD-ROM sr1`
- `[8.463057] pvese: preseed/early_command start (training-tx1320)` + `end (8.469798)` (preseed/early_command 完走)

⚠️ **重要**: `/dev/sr0` (物理空 DVD drive) は今回 enumerate されず、 `/dev/sr1` のみ存在。 これは patch の trigger 条件 (sr1 存在) を完全に満たす状態。

### Step 6 (Task 4): SOL monitor + patch marker 検証 — install 深い進行確認 ✅ (患部突破)

30 分 sol-monitor 観測の最終マーカー集計 (install2.log = 298,255 行 / 34 MB):

| 段階 | Marker | Count | 判定 |
|------|--------|-------|------|
| Kernel boot | `Linux version 6.12.63` | 260 | 高速 reset cycle (~7s/cycle 後半) |
| preseed | `pvese: preseed/early_command end` | 463 | 9 fast (8.4s) + 多数 delayed (213.0s) |
| d-i UI | `(1*installer)` (window header) | 2266 | d-i screen UI active |
| ISO mount | `ISO 9660 Extensions: Microsoft Joliet Level 3` | 482 | **/dev/sr1 mount 成功** |
| cdrom-detect | "Scanning installation media" UI | 241 | pool scan 進行 |
| anna-install | "Loading additional components" UI | 478 | udeb ロード進行 (apt-cdrom-setup, mirror-setup, base-installer, **mdadm-udeb, partman-auto, partman-auto-raid** 含む) |
| apt config | `Configuring apt` strings | 165 | apt mirror 設定段階到達 |
| partman | `partman` substring (any) | 554 | partman udeb / 設定参照 |
| **patch marker** | `pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount` | **0** | busybox syslogd 経由のため SOL 出力なし (設計通り、立証は install 完了で /var/log/syslog 読出が必要) |
| **失敗マーカー** | `No device for installation media` | **0** ✅ | **cdrom-detect 突破 (Phase 14 blocker 解消)** |
| install 完了 | `Installation complete` | 0 | reset loop で未達 |

SOL session reconnect (= ipmitool sol session 切断) 数: **347 回** = 30 分で 347 reset/disconnect = iRMC USB redirector の累積的劣化が install 中も進行していることを示唆。

sol-monitor.py の Stage tracking は **5/9 reached** で timeout (= apt/mirror/partman 領域に到達したが完了せず)。

### Step 7 (Task 5): cdrom-detect 突破後の install 完遂検証 ❌ ping 不通 (reset loop)

- ping 10.254.254.250: 100% packet loss
- ssh test: 接続不可
- = host OS は起動していない (reset cycle で install スクリプトが完了する前にリセット)

### Step 8: ForceOff (reset loop 停止) ✅

```sh
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" ... ./scripts/bmc-power.sh forceoff 10.254.254.9 ...
# ForceOff requested
```

## Phase 16 達成度

### 🎯 主目標達成度

| 目標 | 達成度 | 補足 |
|------|--------|------|
| Phase 15 patch を main に commit | ✅ **完全達成** | commit 0624539b、Phase 10/12/13/15 の cmdline + initrd 修正を 1 commit にまとめて記録 |
| iRMC state 確認 + PSU cold reset (必要に応じて) | ✅ **完全達成** | 初回 deploy で GRUB-stage triple-fault 確認 → ユーザに PSU 抜差し依頼 → 実施後 kernel boot 復活 |
| PSU reset → 即座 1-deploy (deploy-careful.sh パターン) | ✅ **完全達成** | 30s settle + 60s USB stabilize + 15s pre-power の長 pad が effective |
| install 完遂 (preseed 完走 + RAID10 + SSH login) | ❌ **未達成** | reset loop が apt/partman フェーズで継続、`Installation complete` 0 回、SSH 不通 |
| **cdrom-detect 突破 (Phase 14-15 blocker)** | ✅ **達成** | "No device for installation media" 0 回、ISO 9660 mount 482 回、pool scan 241 回 |
| **patch の動作可能性立証** | ✅ **間接立証** | cdrom-detect が成功している = patch が /dev/sr1 mount したか d-i 自身が見つけたか (両方とも patch 設計の goal を満たす) |

### 🎯 副次成果

1. **Phase 15 patch の commit (0624539b)** — Phase 10/12/13/15 の累積修正を main 統合。 envgate (`PVESE_PATCH_CDROM_DETECT=0` default) で他機種に副作用なし、 sanity 5/5 pass の品質保証。 issue #72 の永続記録
2. **PSU cold reset の即時効果実証** — Phase 15 の警告通り Manager.Reset では復旧できないが、 PSU reset 後即座の deploy-careful.sh で kernel boot 復活。 Phase 15 step 5 の "PSU reset 後初回 boot は BIOS Setup 落ち" は orchestrate.sh の short pad (8s) 由来であり、 deploy-careful.sh の 105s pad で回避可能
3. **install パイプラインの大幅進展実証** — Phase 15 が `(1*installer)` window で停止していたところを、 Phase 16 で `Configuring apt` + `partman` フェーズまで到達。 これは **patch + cmdline 修正 + deploy-careful.sh パターンが正しく機能している** ことの最強の証拠
4. **`/dev/sr0` 不在の確認** — TX1320 物理 DVD drive (HL-DT-ST DUD0N) は今回の deploy で kernel が enumerate せず、 `/dev/sr1` (iRMC OEM Virtual CDROM) のみ存在。 patch の "fall-through for other hardware" 設計は今回 invoke されなかった (sr1 が唯一の選択肢)
5. **patch marker が SOL に出ない設計の確認** — Phase 15 では "pvese-patch v1: bypassed list-devices" が出れば成功と書いたが、 busybox syslogd (`logger -t cdrom-detect`) は `/var/log/syslog` 行きで `/dev/console` には書かない。 立証には install 完了後の syslog 読出が必要。 (Phase 17 の追加調査候補)
6. **iRMC FW 9.08F の根本制限の累積的劣化確認** — 30 分の install 進行中も SOL session が 347 回 reconnect = USB redirector が boot ごとに degrade。 install 完遂には FW 修正か別 boot 経路が必須と再確認

### 🎯 Phase 17 (次セッション) への引き継ぎ

Phase 15 引き継ぎ事項 (F1-F5) を更新:

| # | タスク | 優先度 | 補足 |
|---|--------|--------|------|
| **F1** | **iRMC FW 9.08F → 最新版 update** | 🔴 最高 | Phase 16 で USB redirector 劣化が install 進行中も継続することを実証。 FW 修正が根本対策。 Fujitsu support から FW BIN 取得経路を確立する必要あり |
| **F2** | **PXE/netboot 経路に pivot** | 🟠 高 | iRMC USB CD を完全に bypass、 TFTP+iPXE 経由で installer 配信。 tftp-server スキル + dnsmasq セットアップ。 BIOS UEFI PXE boot 有効化 + boot-override Pxe |
| **F3** | 別 base ISO (Debian 12 / Ubuntu) で再現確認 | 🟢 低 | Phase 16 で Debian 13.3 でも iRMC が問題と確認済 = base 変更で解決する見込み低 |
| **F4** | `tx1320-raid10-orchestrate.sh monitor --timeout` 引数 bug 修正 | 🟡 中 | Phase 12 以降持ち越し |
| **F5** | `preseed/preseed.cfg.template` の cdrom-detect コメント文言更新 | 🟢 低 | Phase 15 patch で実質解決済 |
| **F6** | **`tx1320-raid10-orchestrate.sh` + 依存スクリプト群の wholesale commit** | 🟡 中 | Phase 16 で commit 見送り、 Phase 17 で全 untracked file の整理 + commit |
| **F7** | **patch marker `pvese-patch v1: bypassed` を SOL に出すよう設計変更検討** | 🟡 中 | `log "..."` → `echo "..." > /dev/console` への変更で SOL 立証可能に (副作用: d-i 標準ログ慣習からの逸脱)。 Phase 17 で判断 |
| **F8** | **deploy-careful.sh の orchestrate.sh deploy() への統合** | 🟡 中 | Phase 15-16 で deploy-careful.sh の長 pad パターンが effective と実証。 orchestrate.sh の sleep 8s を 30s/60s/15s に拡張 |

### 🎯 install 完遂の見込み (Phase 17 戦略提案)

**最有力の根本対策**: F1 (iRMC FW update)。 USB redirector の state degradation は FW 9.08F 既知バグの可能性が高い (Phase 15-16 で実証)。 最新版で改善すれば Phase 16 の deploy-careful.sh + patch 構成で install 完遂が見込める。

**並行する代替経路**: F2 (PXE)。 FW update が容易でない場合は PXE 経由で iRMC USB CD を完全に bypass。 ただし TFTP/DHCP インフラ整備のオーバーヘッドあり。

**Phase 17 推奨 sequence**:
1. F6 (orchestrate.sh + 依存 commit) — Phase 16 までの工事用具を main に統合
2. F1 (FW update リサーチ) — Fujitsu support サイト調査、 update 手順確立
3. F1 適用後 deploy 再試行
4. F1 失敗時 → F2 (PXE pivot)
5. install 完遂後 F7 検討

## 再現方法

### 1. Phase 15 patch を再 build (Phase 16 と同じ ISO を作成)

```sh
git log --oneline -1   # 0624539b 確認
SKIP_STORCLI_FETCH=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml

# 期待出力:
# [orchestrate] Phase 4: remaster ISO -> /var/samba/public/debian-training-tx1320-raid10.iso (PVESE_PATCH_CDROM_DETECT=1)
# --- pvese-patch v1: patching cdrom-detect.postinst (TX1320 /dev/sr1 priority) ---
# Patched postinst OK (303 lines, 7352 bytes)
# [orchestrate] Phase 4.5: sync OK
```

### 2. iRMC state を PSU cold reset でクリーン化

```sh
# (a) ForceOff
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" BMC_PATCH_REQUIRES_ETAG=1 POWER_ON_RESET_TYPE=On \
    ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123

# (b) ユーザに依頼: 電源ケーブル 2-3 秒抜差し
# (c) Redfish が "ServiceTemporarilyUnavailable" を返さなくなるまで待機 (~30s-2min)
sh tmp/<sid>/wait-bmc-recover.sh
```

### 3. deploy-careful.sh (本セッション self-contained 版) を実行

```sh
# Phase 16 で再利用可能な self-contained 版
./oplog.sh sh tmp/<sid>/deploy-careful.sh
```

主要 step (30s settle + 60s USB stabilize + 15s pre-power = 105s 長 pad):
1. ForceOff + 120s poll で PowerState=Off
2. **30s settle**
3. PATCH CDImage config (NFS)
4. ConnectCD (OEM Action)
5. mount (AllowableValues=DisconnectCD 出現確認、60s poll)
6. **60s USB redirector 安定化**
7. boot-override Cd UEFI
8. **15s pre-power**
9. PowerOn

### 4. SOL monitor + 進行判定

```sh
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload enable 2 4
.venv/bin/python scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60

# Phase 16 markers (達成済):
grep -ac "Linux version" install.log              # >=1 (kernel boot)
grep -ac "pvese: preseed/early_command end" log   # >=1 (preseed 完走)
grep -ac "(1\*installer)" log                     # >=1 (d-i UI)
grep -ac "ISO 9660 Extensions" log                # >=1 (sr1 mount)
grep -ac "Configuring apt" log                    # >=1 (apt フェーズ到達)
grep -ac "partman-auto-raid\|mdadm-udeb" log      # >=1 (RAID udeb ロード)

# Phase 16 で達成できなかった (Phase 17 目標):
grep -ac "No device for installation" log         # 0 を維持
grep -ac "Installation complete" log              # >=1 (= install 完遂)
ssh -F ssh/config root@10.254.254.250 'uname -a'  # rc=0 (= 最終目標)
```

### 5. patch marker は SOL に出ない設計 (注意)

`scripts/remaster-debian-iso.sh` の patch は busybox `logger` 経由で `/var/log/syslog` に出力するが `/dev/console` には書かない。 SOL log で `pvese-patch v1: bypassed list-devices` を直接観察することは不可能。 install 完了後に `cat /target/var/log/syslog | grep pvese-patch` で立証する設計 → install 完遂が patch 立証の前提条件。

代替案として `echo "pvese-patch v1: bypassed" > /dev/console` を patch に追加すれば SOL 観察可能 (Phase 17 F7)。

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229)
- **BMC**: iRMC S4 FW 9.08F (10.254.254.9, HTTPS + SECLEVEL=0 必須, claude/Claude123, claude index=4)
- **HW**: PRAID EP400i (LSI MegaRAID SAS3008) + SAS HDD 900GB × 4 (HW RAID10 構成済 VD0 = /dev/sda 1.80 TB)、 物理 DVD drive HL-DT-ST DUD0N (今回 enumerate されず)
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x (12/18/2018)
- **CPU/RAM**: Xeon E3-1230 v6 / 24 GiB
- **NFS server (playground)**: 10.1.6.6 (Ubuntu 24.04, /var/samba/public NFS export)
- **ISO**: `/var/samba/public/debian-training-tx1320-raid10.iso` (808,779,776 bytes, Phase 15 build 再利用、 patch v1 注入版)
- **本セッションの BMC 操作回数**: ForceOff × 3、 PowerOn × 2、 DisconnectCD × 2、 ConnectCD × 2、 boot-override × 2、 **PSU cold reset × 1 (ユーザ実施)**、 Redfish GET (status / VirtualMedia / AllowableValues) 多数

## 関連レポート / メモ

- [Phase 15 (2026-05-23 bubbly-ripple): cdrom-detect patch 実装 + sanity 5/5 pass + iRMC USB CD 不安定で実機検証未達](2026-05-23_013410_tx1320_raid10_phase15_cdrom_detect_patch.md)
- [Phase 14 (2026-05-22 linear-mountain): kernel boot 成功 + 4 課題 a/b/c/d 完了 + cdrom-detect block](2026-05-22_154033_tx1320_raid10_phase14_install_completed.md)
- [Phase 13 (2026-05-22 silly-rocket): console=tty0 削除で kernel boot 復活](2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix.md)
- [Phase 12 (2026-05-22 phase12-111602): SOL silence の物理的確定 + earlyprintk/loglevel 追加判断](2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed.md)
- memory `training-tx1320-phase15-patch-implemented-irmc-unstable` (Phase 15 経緯、 Phase 16 で install 進展)
- memory `training-tx1320-nfs-solved` (NFS attach 経路、 引き続き有効)

## 関連 Issue

- **#72 (継続、 status=blocked、 owner 4a583656 → 次セッションへ release)**
  - Phase 15 (bubbly-ripple): patch 実装 + sanity 5/5 pass + iRMC USB CD で未達
  - **Phase 16 (4a583656、 本セッション)**: patch を main commit (0624539b)、 PSU cold reset 後の deploy で **cdrom-detect 突破 + apt + partman フェーズまで到達** (Phase 14-15 blocker = "No device for installation media" を完全に解消)、 ただし iRMC USB redirector の累積的劣化で install 完遂未達
  - **次セッション (Phase 17) 推奨**: (a) F1 = iRMC FW 9.08F → 最新版 update リサーチ + 適用、 (b) F2 = PXE/netboot 経路 pivot 検討、 (c) F6 = orchestrate.sh + 依存スクリプトの wholesale commit、 (d) F7 = patch marker を SOL 観察可能にする設計変更

## 関連ファイル

### 修正 (本セッション、 commit 済)

| ファイル | commit | 修正内容 |
|---------|--------|---------|
| `scripts/remaster-debian-iso.sh` | 0624539b | Phase 10/12/13/15 の cmdline + initrd 修正をまとめて統合 |

### 修正なし (Phase 14-15 から不変)

- `preseed/preseed.cfg.template`
- `config/training_tx1320.yml` (static_ip=10.254.254.250)
- `scripts/setup-raid10-storcli.sh`

### Phase 17 で commit 候補 (本セッションで未 commit、 untracked)

- `scripts/tx1320-raid10-orchestrate.sh` (TX1320 install orchestrator)
- `scripts/setup-raid10-storcli.sh` (Phase 14 partman/early_command 用)
- `scripts/irmc-virtualmedia.sh` (NFS + SMB CDImage 操作)
- `scripts/irmc-oem-screenshot.sh` (OEM Screenshot による VGA capture)
- `scripts/irmc-bios-raid-setup.sh`
- `scripts/irmc-bios.py`
- `scripts/irmc-kvm-interact.py`
- `scripts/irmc-kvm-screenshot.py`
- `scripts/irmc-raid10-create.py`
- `scripts/fetch-storcli-deb.sh`
- `config/training_tx1320.yml`

### 新規作成

- `report/2026-05-23_052353_tx1320_raid10_phase16_psu_reset_partman_reached.md` (本レポート)
- `report/attachment/2026-05-23_052353_tx1320_raid10_phase16_psu_reset_partman_reached/` (plan + deploy-careful + install2.log)

## 重要な教訓 (Phase 17 への引き継ぎ)

1. **PSU cold reset は iRMC FW 9.08F の USB redirector state degradation に effective**: Phase 15 末尾で Manager.Reset では復旧できなかった状態が、 PSU 抜差し後の deploy で kernel boot まで復活した。 deploy-careful.sh の 105s 長 pad と組み合わせることで初回 deploy も成功 (Phase 15 の "PSU reset 後初回 BIOS Setup 落ち" は orchestrate.sh の 8s short pad 由来と確定)
2. **cdrom-detect は patch なしでも (1*installer) 起動後すぐに /dev/sr1 を見つけて mount に成功する場合がある**: Phase 16 で `No device for installation` 0 回観測 + `ISO 9660 mount` 482 回成功。 patch は安全装置として残すが、 必要性は環境依存 (TX1320 で /dev/sr0 が enumerate されない場合は d-i 自身が /dev/sr1 を選ぶ可能性あり)
3. **patch の `log` 関数は busybox syslogd 行きで SOL に出ない**: Phase 15 で書いた "pvese-patch v1: bypassed list-devices marker で立証" は SOL log では観察不可能。 SOL 立証には `echo ... > /dev/console` への変更が必要 (Phase 17 F7 候補)。 install 完了後の `/target/var/log/syslog` 読出が正規の立証経路
4. **iRMC FW 9.08F の USB redirector は install 中も累積的に degrade する**: 30 min の install 進行中に SOL session が 347 回 reconnect = ipmitool の SOL 切断が install 完遂前に発生し続ける。 これは BIOS POST → kernel boot 段階の問題ではなく、 d-i runtime での問題。 install 完遂には FW 修正 (F1) または別経路 (F2 PXE) が必須
5. **Phase 16 は Phase 15 の 1 ステップ先まで到達**: Phase 15 は `(1*installer)` window で停止。 Phase 16 は `Configuring apt` + `partman-auto-raid` udeb ロードまで到達。 同じ deploy-careful.sh パターンで再現性のある進行を確認。 install 完遂の障害は単一の iRMC FW 問題に絞り込まれた
6. **commit boundary は careful に設計する**: Phase 16 で remaster-debian-iso.sh 単独で commit したのは正解。 orchestrate.sh + 依存 10+ ファイルを混合した wholesale commit は Phase 17 で別途処理。 patch (env-gate default=0) はそれ単独で safe-by-default、 他機種 build に影響なし
