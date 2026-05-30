# TX1320 M3 NFS install Phase 6 — 仮説 8 (HDImage) + 仮説 10 (GRUB kernel image read) 切り分け

## Context

training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F) への OS install は、Phase 2 で iRMC OEM NFS Virtual Media 経由 attach を確立したものの、Phase 3-5 で「GRUB → kernel jump 直後の SOL/VGA 凍結 + kernel printk 0 行」が継続している。

Phase 3-5 で以下を反証済:

| 仮説 | 状態 |
|---|---|
| 1: `quiet` 抑制 | ❌ Phase 3 反証 |
| 2a: console 経路のみ死亡 | ❌ Phase 3 反証 (VGA 更新も 0) |
| 7: USB controller quirk | ❌ Phase 5 反証 (`nousb` で kernel printk 0 維持) |
| 9: UEFI ConOut → console handoff race | ❌ Phase 5 反証 (`console=tty0` 除去で症状不変) |

残候補は **仮説 6 (iRMC NFS USB-CD timing)、仮説 8 (NFS Virtual Media 経路固有)、仮説 10 (GRUB が kernel image を不完全 load)**。Phase 6 ではユーザ最優先指示に基づき、安価な仮説 8 確認 → 本命の仮説 10 切り分けを実施。

仮説 10 が成立すれば iRMC USB CD-ROM emulation の read 不全が確定し、対策は HDImage / 別経路への切替 or NFS server 側 read profile の調整に向かう。反証されれば「kernel image は健全に load されているのに startup 直後で死ぬ」が確定し、仮説 6 (USB-CD long-read stall) や iter6/7 ACPI cmdline 経路へ進む方針が固まる。

## スコープ

### 実施 (本セッション)
- **Phase 6a**: iRMC HDImage NFS attach 試行 (PATCH + Members 確認のみ、~10 分)
- **Phase 6b**: GRUB shell に降りて kernel image の `ls` size 比較 + `cat` 完走確認 (~45 分)
- レポート作成 + memory 更新

### 次セッション送り
- iter6/7/8 cmdline (`acpi=off noapic` / `pci=noacpi nolapic` / `earlyprintk=efi,keep`)
- iter5 KVM 完全黒画 (2724 B × 5) の追加調査
- 仮説 6 (iRMC NFS USB-CD long-read stall) — Phase 6b 結果次第で次セッション最優先化
- orchestrate.sh deploy への locator screenshot 統合
- SMB session #6 再現 (iRMC FW reflash 必要)

## ユーザ確認済決定事項

| 項目 | 決定 |
|---|---|
| GRUB countdown | `set timeout=3` を **`set timeout=300` に延長** (ISO rebuild 1 回、終了後 sed 戻し) |
| HDImage 試行範囲 | PATCH + status / Members 確認のみ。Power on + boot 試行はしない |

## 環境情報

| 項目 | 値 |
|---|---|
| iRMC IP | 10.254.254.9 |
| iRMC FW | S4 9.08F |
| iRMC creds | claude / Claude123 (index 4) |
| Redfish | HTTPS + `--ciphers DEFAULT@SECLEVEL=0` 必須 |
| NFS server | 10.1.6.6 (export `/var/samba/public`、ImageName `debian-training-tx1320-raid10.iso`) |
| ISO 既知サイズ | ~764 MB |
| 既知 USB attach 経路 | NFS + CDImage のみ (HDImage は MaxDev=0 でブロック既知、本 phase で再確認) |
| BIOS POST 所要時間 | ~150 秒 (Phase 5 観測) |

## 実施手順

### Step 0: セッション準備

1. session-id 取得: Glob で `/home/ubuntu/.claude/transcripts/*.jsonl` の最新 UUID 先頭 8 文字 → `<SID>`
2. `mkdir -p tmp/<SID>`
3. `./issue.sh start 71 --owner <SID>` (Phase 5 では active のまま終わっているはず — 状態次第で `start` か `note` を選択)
4. git status / `git diff scripts/remaster-debian-iso.sh > tmp/<SID>/pre-patch.diff` で **必ず先行保存** (本セッション開始時は M なしの確認済だが、Step 4 cmdline patch 適用前にも改めて diff 取得)
5. iRMC NFS CDImage 現状確認:
   ```
   BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
     ./scripts/irmc-virtualmedia.sh --share-type=NFS status \
     10.254.254.9 claude Claude123
   ```
   期待値: `RemoteMountEnabled=true`、`CDImage.ImageName=debian-training-tx1320-raid10.iso`、PowerState=Off

### Step 1: Phase 6a — HDImage NFS attach 試行 (~10 分)

#### 1a. HDImage PATCH 試行

```
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/irmc-virtualmedia.sh --share-type=NFS --type=HD config \
  10.254.254.9 claude Claude123 10.1.6.6 /var/samba/public debian-training-tx1320-raid10.iso
```

応答 HTTP code + JSON を tmp/<SID>/hdimage-patch.json に記録。

#### 1b. HDImage status 確認

```
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS --type=HD status \
  10.254.254.9 claude Claude123 | tee tmp/<SID>/hdimage-status.json
```

確認項目:
- `HDImage.RemoteMountEnabled` の値
- `HDImage.ImageName` の反映
- `HDImage.ShareType` = NFS が受理されたか
- `MaximumNumberOfDevices` (0 のままなら memory 通り blocked)

#### 1c. Manager-level Members (USB device 列挙)

`/redfish/v1/Managers/iRMC/VirtualMedia` または相当の endpoint を直接 GET し、Members 配列の長さを記録:

```
curl -ks --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
  https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia \
  | tee tmp/<SID>/manager-vm-members.json
```

(endpoint 正確な path は status 出力 + Redfish service root で再確認)

#### 1d. Phase 6a 判定

| 観測 | 解釈 |
|---|---|
| Members 長 ≥ 1 で新 HDD USB device 出現 | 🎉 仮説 8 反証 (NFS Virtual Media 経路固有ではない、CDImage 固有の問題)。次は Power on + boot 試行へ拡張 (本セッション外) |
| Members 0 のまま、status の HDImage は反映するが MaxDev=0 | ✅ memory 通り HDImage 完全 blocked 再確認 → 仮説 8 のうち HDImage 路線閉鎖。CDImage 維持で 6b へ |
| PATCH 失敗 (4xx/5xx) | HDImage は PATCH 自体が reject の可能性。応答コードと body を tmp に保存して memory 更新後 6b へ |

#### 1e. 後始末

HDImage 側設定を残しても CDImage の attach に影響しないことを memory `training_tx1320_hdimage_blocked` で確認済 (Manager-level members=0 のため副作用なし)。明示的なリセットは不要だが、念のため Phase 6b の前に CDImage 側 status を再確認:

```
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS status \
  10.254.254.9 claude Claude123
```

`CDImage.RemoteMountEnabled=true` の維持を確認。

### Step 2: Phase 6b — GRUB shell kernel image read 検証 (~45 分)

#### 2a. cmdline patch (GRUB timeout 延長)

```
git diff scripts/remaster-debian-iso.sh > tmp/<SID>/pre-grub-patch.diff
sed -i 's|set timeout=3|set timeout=300|g' scripts/remaster-debian-iso.sh
sed -i 's|timeout 30$|timeout 3000|g' scripts/remaster-debian-iso.sh   # ISOLINUX legacy (30 = 3 秒, 3000 = 300 秒)
```

確認: `grep -n "timeout" scripts/remaster-debian-iso.sh` で UEFI grub.cfg / ISOLINUX 両方が修正されたことを確認。

⚠️ **Phase 5 教訓**: cmdline patch 戻しは `git checkout` ではなく逆 sed を使う。本セッション開始時 git status で `scripts/remaster-debian-iso.sh` は M なし → 安全。

#### 2b. ISO build + sanity 検証

```
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
sha256sum /var/samba/public/debian-training-tx1320-raid10.iso \
  | tee tmp/<SID>/iter-grub-local-sha256.txt
```

#### 2c. local 内 vmlinuz / initrd.gz 抽出 + size 記録 (比較基準)

```
xorriso -osirrox on -indev /var/samba/public/debian-training-tx1320-raid10.iso \
  -extract /install.amd/vmlinuz tmp/<SID>/local-vmlinuz
xorriso -osirrox on -indev /var/samba/public/debian-training-tx1320-raid10.iso \
  -extract /install.amd/initrd.gz tmp/<SID>/local-initrd.gz
stat -c '%n %s' tmp/<SID>/local-vmlinuz tmp/<SID>/local-initrd.gz \
  | tee tmp/<SID>/local-image-sizes.txt
```

(xorriso オプション群は複雑なため Write でラッパースクリプト化 → `sh tmp/<SID>/extract.sh`)

#### 2d. NFS export publish + remote sha256 確認

```
scp -F ssh/config /var/samba/public/debian-training-tx1320-raid10.iso \
  ubuntu@10.1.6.6:/var/samba/public/debian-training-tx1320-raid10.iso
ssh -F ssh/config ubuntu@10.1.6.6 \
  sha256sum /var/samba/public/debian-training-tx1320-raid10.iso \
  | tee tmp/<SID>/iter-grub-remote-sha256.txt
```

local と一致確認 (truncation なし)。

#### 2e. iRMC USB CD-ROM cache reload

```
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd \
  10.254.254.9 claude Claude123
sleep 3
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd \
  10.254.254.9 claude Claude123
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS mount \
  10.254.254.9 claude Claude123
```

#### 2f. SOL background capture 開始

```
.venv/bin/python scripts/sol-monitor.py 10.254.254.9 claude Claude123 \
  > tmp/<SID>/sol-grub.log
```

(run_in_background=true で発火、capture 開始確認)

#### 2g. boot-override + Power On

```
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  BMC_PATCH_REQUIRES_ETAG=1 BMC_BOOT_OVERRIDE_NO_DISABLED=1 \
  ./oplog.sh ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI
date +%s | tee tmp/<SID>/grub-boot-t0.txt
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' POWER_ON_RESET_TYPE=On \
  ./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
```

#### 2h. GRUB menu 出現待機 + sendkeys:c + GRUB shell コマンド発行

SOL を tail して `GNU GRUB` 出現を検知 → 即座に KVM shell で `sendkeys:c` 発火。

ラッパースクリプト `tmp/<SID>/grub-interact.sh`:

```sh
.venv/bin/python scripts/irmc-kvm-interact.py \
  --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
  --capture-mode=locator --focus-mode=hittest --timeout 600 \
  shell "wait:140; \
         screenshot:tmp/<SID>/kvm-grub-pre.png; \
         wait:30; \
         screenshot:tmp/<SID>/kvm-grub-menu.png; \
         sendkeys:c; \
         wait:3; \
         screenshot:tmp/<SID>/kvm-grub-shell.png; \
         type:ls (cd0)/install.amd/vmlinuz; \
         sendkeys:Enter; \
         wait:5; \
         screenshot:tmp/<SID>/kvm-grub-ls-vmlinuz.png; \
         type:ls (cd0)/install.amd/initrd.gz; \
         sendkeys:Enter; \
         wait:5; \
         screenshot:tmp/<SID>/kvm-grub-ls-initrd.png; \
         type:cat (cd0)/install.amd/vmlinuz; \
         sendkeys:Enter; \
         wait:60; \
         screenshot:tmp/<SID>/kvm-grub-cat-mid.png; \
         wait:60; \
         screenshot:tmp/<SID>/kvm-grub-cat-late.png"
```

⚠️ Power on 後 `wait:140` でちょうど BIOS POST 直前完了を狙う (Phase 5 観測 +150s で GRUB countdown)。menu 表示が遅れたら `sendkeys:c` が menu 外で発火する可能性があるため、screenshot で実際の画面状態を後で振り返って確認。

⚠️ GRUB menu 表示中の `c` は「Command line entry」コマンド。auto-select されると effective でなくなるため timeout=300 設定で countdown 凍結 → 手動 `c` が安全。

#### 2i. SOL から GRUB shell 出力抽出

GRUB shell の `ls` 出力は serial console に流れる。`tmp/<SID>/sol-grub.log` を grep:

```
grep -A 1 -E '(install\.amd/vmlinuz|install\.amd/initrd\.gz)' tmp/<SID>/sol-grub.log \
  | tee tmp/<SID>/grub-ls-output.txt
```

`cat (cd0)/install.amd/vmlinuz` は binary なので SOL log に control char が大量に流出する。`wc -c` で大まかな byte 数を測る:

```
wc -c tmp/<SID>/sol-grub.log
```

(完璧な byte 計測は無理だが、流出停止 = GRUB の read が hang した sign)

#### 2j. Phase 6b 判定

| 観測 | 解釈 |
|---|---|
| GRUB `ls` 報告 size = local vmlinuz size と完全一致 + `cat` も停止せず流出継続 (60 秒間で MB 単位の SOL データ) | ✅ kernel image 完全性 OK → 仮説 10 反証 → kernel startup 内部の問題が確定 (仮説 6, ACPI/PCI quirk へ進む) |
| GRUB `ls` 報告 size が local より小さい | ❌ iRMC USB CD-ROM emulation 経由の read truncation 確定 → 仮説 10 |
| `cat` 出力が途中で stall (60-120 秒間で流出停止) | ❌ iRMC USB-CD long-read stall 確定 → 仮説 6 + 10 の交差 |
| `c` キーが GRUB shell に入らない / menu 上で別動作 | KVM 入力経路問題。`type:` で `c` を改めて送る or KEY_MODE=dispatch-event で再試行 |

#### 2k. 後始末

```
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
sed -i 's|set timeout=300|set timeout=3|g' scripts/remaster-debian-iso.sh
sed -i 's|^timeout 3000$|timeout 30|g' scripts/remaster-debian-iso.sh
git diff scripts/remaster-debian-iso.sh   # 復元確認 (= 空 diff 期待)
```

⚠️ `git checkout` は使わない (Phase 5 教訓)。逆 sed で patch 戻し。

### Step 3: レポート作成

`report/2026-05-22_HHMMSS_tx1320_raid10_phase6_grub_shell.md` を REPORT.md フォーマットで作成。

- 添付: HDImage status JSON、Manager Members JSON、grub-interact ログ、SOL log、KVM screenshot 群、local image sizes
- 仮説マトリクス更新 (#8, #10 の Phase 6 判定列)
- 次セッション課題: 6a/6b 結果に応じて (仮説 6 検証 / iter6-8 cmdline / orchestrate.sh 統合)

### Step 4: memory 更新

- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320_kernel_silent_post_grub.md`
  - Phase 6 結果セクション追記
  - 仮説マトリクスの #8 / #10 を Phase 6 判定で確定 or 候補維持
  - 「Phase 6 (次セッション) 課題」を Phase 7 用に置換
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320_hdimage_blocked.md`
  - Phase 6 で NFS + HDImage を試行した結果を追記 (新観測か再確認か)
- `MEMORY.md` の Phase 5 行を Phase 6 化

## 検証 (end-to-end)

本 phase 自体が検証フェーズのため、追加の検証は以下:

1. Phase 6a 後、`./scripts/irmc-virtualmedia.sh --share-type=NFS status` で CDImage 側が壊れていないこと
2. Phase 6b 後、`git diff scripts/remaster-debian-iso.sh` が空であること (patch 戻し確認)
3. Phase 6b 後、`./scripts/bmc-power.sh status` で PowerState=Off
4. Phase 6b 後、`./scripts/irmc-virtualmedia.sh --share-type=NFS status` で `RemoteMountEnabled=true` + CDImage 維持

## 主要参照ファイル

| ファイル | 用途 |
|---|---|
| `scripts/irmc-virtualmedia.sh` | NFS Virtual Media config / connect-cd / mount / status (`--type=CD|HD` 切替対応) |
| `scripts/bmc-power.sh` | boot-override Cd UEFI / on / forceoff (Redfish SECLEVEL=0 経由) |
| `scripts/irmc-kvm-interact.py` | KVM Playwright 自動操作 (`shell` サブコマンドで `wait:`, `screenshot:`, `sendkeys:`, `type:`) |
| `scripts/sol-monitor.py` | SOL ipmitool 経由 passive capture |
| `scripts/remaster-debian-iso.sh` | ISO リマスター。L114 `set timeout=3` (UEFI grub.cfg) / L142 `timeout 30` (ISOLINUX) を本 phase で 300/3000 に一時延長 |
| `scripts/tx1320-raid10-orchestrate.sh` | build / deploy / monitor オーケストレーション |
| `config/training_tx1320.yml` | NFS host / export path / ISO name / serial_unit=0 |

## 主要参照 memory

- `training_tx1320_kernel_silent_post_grub` (Phase 5 までの履歴 + 仮説マトリクス)
- `training_tx1320_hdimage_blocked` (HDImage MaxDev=0 既知)
- `training_tx1320_nfs_solved` (NFS attach 経路確立)
- `training_tx1320_kvm_kbd_dead` (KVM キー入力で過去のハマりどころ、必要時参照)

## 想定リスク

| リスク | 対処 |
|---|---|
| GRUB shell に `c` が入らず menu のままで auto-select | timeout=300 設定で countdown が事実上止まる → `c` を複数回試行可能。`type:` で代替送信、KEY_MODE 切替も検討 |
| BIOS POST 時間が +150s から外れて wait:140 / wait:30 が外す | screenshot で実画面確認後、second-pass で wait 値調整 + 再試行 |
| `cat (cd0)/install.amd/vmlinuz` の binary 大量出力で SOL session 過負荷 / 切断 | 1-2 分で打ち切り (`type:Ctrl+C` 相当キー送信 or 強制 Power off) |
| iRMC FW 9.08F の SOL ring buffer リプレイで GRUB 出力が複数回流出 | Phase 5 と同様、最初の 1 回のみ実 boot と解釈。grep 時に時系列で先頭分のみ採用 |
| ISO build 中の disk full / NFS server 接続失敗 | local sha256 + remote sha256 が一致しない時点で halt、build/scp やり直し |
| Phase 6a HDImage PATCH 後に CDImage の attach state が損傷 | PATCH 後すぐ CDImage status 再確認。損傷時は CDImage 経路を再 mount から実施 |

## Phase 6 完了条件

1. Phase 6a: HDImage NFS PATCH 試行完了 + Members / status 観測 + memory に結果記録
2. Phase 6b: GRUB shell で `ls (cd0)/install.amd/vmlinuz` 出力取得 + local size と比較 + `cat` 完走可否判定 + memory に結果記録
3. レポート (`report/2026-05-22_*_tx1320_raid10_phase6_grub_shell.md`) 作成
4. cmdline patch 完全戻し (`git diff scripts/remaster-debian-iso.sh` が空)
5. PowerState=Off + CDImage attach 維持
