# TX1320 M3 NFS install Phase 4 — KVM locator screenshot で VGA 実画面を確認する

## Context

Phase 3 (s-rustling-melody, 2026-05-22 00:14-00:40) で `quiet` 除去 + `earlyprintk` 追加でも SOL に kernel printk 0 行、 NFS pcap READ 0 packet、 KVM screenshot 全黒 (`tmp/fbd799f5/kvm-*.png` 3 ファイル全て **11857 byte 同一サイズ**) で「kernel が startup できていない」と結論された。

しかし以下の 2 つの事実が Phase 3 結論への重大な反証となる:

1. **ユーザ目視で「GRUB の後に Automated Install と表示されていた」** — Web UI 経由で実画面に GRUB メニュー表示が出ていた (= KVM 自体は alive、 VGA に何か描画されている)
2. **Phase 3 の KVM screenshot 3 ファイルが全部 11857 byte で完全一致** — これは `irmc-kvm-interact.py` の **legacy `--capture-mode=canvas`** で起きる WebGL `preserveDrawingBuffer:false` 由来の典型的な黒画 artifact (`/home/ubuntu/projects/pvese/scripts/irmc-kvm-interact.py:205-219` ドキュメンテーション参照)。 同スクリプトは `--capture-mode=locator` (default) で `viewer_page.locator("canvas#kvm").screenshot()` を使えば composed frame を取得でき WebGL 黒問題を回避可能 (line 196-202、 `/home/ubuntu/projects/pvese/report/2026-05-17_054151_tx1320_raid10_playwright_partial.md` Phase 0 で確立済)

**Phase 4 の目的**: locator mode で KVM screenshot を時系列取得し、 kernel が実際は boot しているのか (= Phase 3 結論の誤りで真因は console redirect 系) / 本当に死んでいるのか (Phase 3 結論補強) を切り分ける。 ユーザ指示で **iter3 (Step 0-5) までを本セッションで実施 → 結果で分岐方針を相談**。

## 期待される判定

| KVM locator screenshot 内容 | SOL kernel printk | 結論 |
|---|---|---|
| GRUB 後の kernel boot 画面 / installer 画面 が見える | 0 行 | **D-1**: kernel は動作中、 console redirect 経路問題 (cmdline `console=tty0` 単独 / BIOS Redirection After BIOS POST) |
| kernel boot 画面が見える | ≥1 行 | 既に動作中、 deploy 側の SOL 観測タイミング問題 |
| 真黒 (canvas mode と比較しても同じ) | 0 行 | **D-2**: Phase 3 結論補強、 kernel 早期 hang (仮説 7/8) |

D-1 / D-2 の対処 (cmdline 変更 / BIOS apply-config / USB stick 物理 boot 等) は本セッションでは実施せず、 次セッション課題として整理する。

## 実装手順

### Step 0: セッション準備 (3 分)

```sh
SID=<UUID 先頭 8 文字。 Glob "*.jsonl" path "/home/ubuntu/.claude/transcripts" で取得>
mkdir -p tmp/$SID
./issue.sh start 71 --owner <セッション名>
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./scripts/irmc-virtualmedia.sh --share-type=NFS status \
  10.254.254.9 claude Claude123 \
  | tee tmp/$SID/vm-status-pre.txt
```

期待: 前 session から `Server=10.1.6.6, ImageName=debian-training-tx1320-raid10.iso, AllowableValues=["DisconnectCD"]` が維持。 外れていたら `connect-cd` + `mount` で再 attach。

### Step 1: regression diff 確認 (並行、 5 分)

```sh
git -C /home/ubuntu/projects/pvese show --stat f96d47b > tmp/$SID/f96d47b-stat.txt
git -C /home/ubuntu/projects/pvese diff f96d47b~1..f96d47b -- scripts/remaster-debian-iso.sh \
  > tmp/$SID/remaster-diff-5-18.patch
git -C /home/ubuntu/projects/pvese log --oneline --since=2026-05-15 -- \
  scripts/tx1320-raid10-orchestrate.sh scripts/irmc-virtualmedia.sh \
  config/training_tx1320.yml preseed/preseed.cfg.template \
  > tmp/$SID/related-history.txt
```

5/18 報告 (`report/2026-05-18_025914_*.md`) と現在の `scripts/remaster-debian-iso.sh:193` の cmdline を `tmp/$SID/cmdline-diff.txt` に整理。 特に `cdrom-detect/try-usb=true`, `cdrom-detect/scan=true`, `hw-detect/load_media=false` の混入時期を確認。

### Step 2: BIOS XML backup (4 分)

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  .venv/bin/python /home/ubuntu/projects/pvese/scripts/irmc-bios.py \
  --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
  backup tmp/$SID/bios-phase4.xml

.venv/bin/python /home/ubuntu/projects/pvese/scripts/irmc-bios.py \
  show tmp/$SID/bios-phase4.xml 'redirect|console|serial|secure.*boot|boot.*mode' \
  > tmp/$SID/bios-phase4-grep.txt
```

D-1 分岐用に値を保持。 既存 XML が無いため SMB session #6 (5/18) との diff は本セッションでは取れない (今回取った XML が将来の基準になる)。

### Step 3: SOL bg capture + 電源再起動 (3 分)

```sh
# SOL bg
.venv/bin/python /home/ubuntu/projects/pvese/scripts/sol-monitor.py \
  --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
  --log-file tmp/$SID/sol-iter3.log --timeout 720 --powerstate-interval 30 \
  > tmp/$SID/sol-iter3.stdout 2>&1 &
SOL_PID=$!
sleep 2

# Force off → On
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
sleep 8
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' POWER_ON_RESET_TYPE=On \
  ./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
echo $(date +%s) > tmp/$SID/boot-t0.txt
```

run_in_background=true で SOL を投げ、 同時に KVM screenshot Step を進める。

### Step 4: 🎯 KVM locator screenshot 時系列取得 (12-15 分、 Phase 4 の核)

`scripts/irmc-kvm-interact.py shell` op で **単一 viewer session**にまとめ、 iRMC 同時 session 数 (~4) を消費しない:

```sh
.venv/bin/python /home/ubuntu/projects/pvese/scripts/irmc-kvm-interact.py \
  --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
  --capture-mode=locator --focus-mode=hittest --timeout 60 \
  shell "wait:30; screenshot:tmp/$SID/kvm-t030.png; \
         wait:30; screenshot:tmp/$SID/kvm-t060.png; \
         wait:30; screenshot:tmp/$SID/kvm-t090.png; \
         wait:30; screenshot:tmp/$SID/kvm-t120.png; \
         wait:60; screenshot:tmp/$SID/kvm-t180.png; \
         wait:120; screenshot:tmp/$SID/kvm-t300.png" \
  2>&1 | tee tmp/$SID/kvm-iter3.log

sha256sum tmp/$SID/kvm-t*.png > tmp/$SID/kvm-iter3-meta.txt
stat -c '%n %s' tmp/$SID/kvm-t*.png >> tmp/$SID/kvm-iter3-meta.txt
```

判定:

| 観測 | Phase 3 artifact | 真の VGA 沈黙 | 実画面あり |
|---|---|---|---|
| ファイルサイズ全て 11857 B | ❌ canvas mode 残存 (再実行要) | — | — |
| 全 size が一致 (但し 11857 でない) | — | ✅ 真黒 | — |
| 各 size 異なる | — | — | ✅ 動画相当の画面更新あり |

11857 B が再現したら、 直後に `--capture-mode=canvas` で 1 枚撮って比較し artifact かハードかを 1 分で確認:

```sh
.venv/bin/python /home/ubuntu/projects/pvese/scripts/irmc-kvm-interact.py \
  --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
  --capture-mode=canvas \
  screenshot tmp/$SID/kvm-canvas-compare.png
ls -la tmp/$SID/kvm-canvas-compare.png tmp/$SID/kvm-t300.png
```

(canvas で 11857 B + locator で別サイズ = locator で実画面取れた、 両方 11857 B = 本当に黒)

### Step 5: SOL bg 停止 + 結果整理 (3 分)

```sh
wait $SOL_PID || kill $SOL_PID 2>/dev/null
grep -cE '^\[\s*[0-9]+\.[0-9]+\]' tmp/$SID/sol-iter3.log > tmp/$SID/sol-printk-count.txt
grep -c "Booting \`Automated Install" tmp/$SID/sol-iter3.log >> tmp/$SID/sol-printk-count.txt
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
  ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
```

各 KVM screenshot を Read ツールで読み (画像表示で目視確認)、 以下のいずれかを判定:

- **D-1 候補**: 1 枚以上で kernel boot text / installer text / 何らかの実画面が見える
- **D-2 候補**: 全 screenshot が真黒 (canvas/locator 両 mode で同サイズ)
- **artifact only**: locator で実画面が見えて Phase 3 は単に screenshot 取得方法が悪かっただけ

### Step 6: レポート作成 + ユーザ相談

`report/<ts>_tx1320_raid10_phase4_kvm_locator.md` を Phase 3 と同形式で起こす。 attachment に kvm-t*.png 全 6 枚 / sol-iter3.log / bios-phase4.xml / cmdline-diff.txt をコピー。

レポート末尾の「次セッション課題」セクションでユーザに分岐方針を相談:

| Phase 4 判定 | 次セッション提案 |
|---|---|
| D-1 (locator で kernel boot 画面確認) | iter4a (cmdline `console=tty0` 除去 → ttyS のみ) or iter4b (BIOS Redirection After BIOS POST=Always Enabled) |
| D-2 (真黒継続) | iter5 (nousb), iter6 (acpi=off noapic), iter7 (pci=noacpi) を順次。 最終手段は USB stick 物理 boot (ユーザ手配依頼) |
| artifact only | Phase 3 結論を訂正する postmortem + `orchestrate.sh` の deploy に locator screenshot を組み込む PR の検討 |

## Critical Files

### 読み取りのみ (本セッションでは修正なし)

- `/home/ubuntu/projects/pvese/scripts/irmc-kvm-interact.py:196-226` — `_capture_locator()` + `capture_with_retry()` (再利用)
- `/home/ubuntu/projects/pvese/scripts/irmc-virtualmedia.sh` — `--share-type=NFS status` (Phase 2 完成済)
- `/home/ubuntu/projects/pvese/scripts/bmc-power.sh` — forceoff/on (`--ciphers DEFAULT@SECLEVEL=0` 必須)
- `/home/ubuntu/projects/pvese/scripts/sol-monitor.py` — SOL log capture
- `/home/ubuntu/projects/pvese/scripts/irmc-bios.py:412` — backup / show subcommands
- `/home/ubuntu/projects/pvese/scripts/remaster-debian-iso.sh:193,266` — 現在 cmdline (`earlyprintk` + `console=tty0 console=ttyS${SERIAL_UNIT}` で構成)
- `/home/ubuntu/projects/pvese/report/2026-05-22_004000_tx1320_raid10_kernel_silent_persist.md` — Phase 3 結果
- `/home/ubuntu/projects/pvese/report/2026-05-17_054151_tx1320_raid10_playwright_partial.md` — Phase 0 改修 (locator mode default)

### 修正 (本セッションでは無し)

D-1 / D-2 分岐に進む場合は次セッションで `scripts/remaster-debian-iso.sh:193,266` の cmdline 変更を想定。 本セッションでは触らない。

## 既存スクリプト再利用パターン

| 用途 | スクリプト | 呼び方 |
|---|---|---|
| NFS attach 確認 | `scripts/irmc-virtualmedia.sh` | `--share-type=NFS status 10.254.254.9 claude Claude123` |
| 電源 forceoff/on | `scripts/bmc-power.sh` | `BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' ...` |
| SOL bg | `scripts/sol-monitor.py` | `--timeout 720 --powerstate-interval 30` + `&` でバックグラウンド |
| **KVM locator screenshot** | `scripts/irmc-kvm-interact.py` | **`shell "wait:N; screenshot:..."` で 1 viewer session に集約**、 default `--capture-mode=locator` |
| BIOS XML backup | `scripts/irmc-bios.py` | `backup tmp/$SID/bios-phase4.xml` |
| BIOS XML show | `scripts/irmc-bios.py` | `show tmp/$SID/bios-phase4.xml <regex>` |

## 判定基準

| Metric | コマンド | D-1 (kernel 動作) | D-2 (kernel 沈黙) |
|---|---|---|---|
| SOL kernel printk | `grep -cE '^\[\s*[0-9]+\.[0-9]+\]' tmp/$SID/sol-iter3.log` | ≥1 | 0 |
| Booting Automated Install 到達 | `grep -c "Booting \`Automated Install" tmp/$SID/sol-iter3.log` | ≥1 (両 D で同じ) | ≥1 (両 D で同じ) |
| locator screenshot 内容 (目視) | Read ツールで画像表示 | 何らかの画面 | 真黒 |
| canvas vs locator size 差 | `stat -c %s` 比較 | locator > canvas | 同じ (両方真黒) |

## 失敗時のフォールバック

| 失敗症状 | 対処 |
|---|---|
| NFS attach 外れ (`AllowableValues=["ConnectCD"]`) | `scripts/irmc-virtualmedia.sh --share-type=NFS config + connect-cd + mount` で再 attach |
| `bios-power.sh on` で `POWER_ON_RESET_TYPE` エラー | 既存 quirk: `On` 固定 (memory note 参照) |
| `irmc-kvm-interact.py shell` で viewer timeout | `--timeout 90` に伸ばす + 個別 screenshot 呼び出しに分割 |
| `irmc-bios.py backup` の task が timeout | 既存 quirk: `--deadline 1200` で延長、 polling 間隔は内部 |
| KVM screenshot 全て 11857 B (canvas mode) | スクリプトが default locator を尊重しているか `--capture-mode=locator` を明示再指定 |

## 検証方法 (end-to-end)

1. **NFS attach 維持**: Step 0 で `AllowableValues=["DisconnectCD"]`
2. **regression diff 取得**: `tmp/$SID/remaster-diff-5-18.patch` が空でない or 「commit f96d47b の前後で cmdline 差分なし」が明示
3. **BIOS XML 取得成功**: `tmp/$SID/bios-phase4.xml` が valid XML、 grep で `Redirection`/`Console`/`Serial` が 1 件以上ヒット
4. **電源再起動成功**: `bmc-power.sh on` の終了コード 0
5. **SOL log 取得**: `tmp/$SID/sol-iter3.log` に最低 GRUB countdown + Booting Automated Install ヒット
6. **🎯 KVM locator screenshot 6 枚取得**: `tmp/$SID/kvm-t030.png` ... `kvm-t300.png` が全て存在、 size が 0 でない
7. **判定確定**: D-1 / D-2 / artifact の 3 通りのうちいずれかが Step 5 のメタデータで決まる
8. **レポート完成**: `report/<ts>_tx1320_raid10_phase4_kvm_locator.md` + attachment 揃い、 ユーザに次セッション方針相談を提示

## セッション規約

- スクリプトは `./scripts/...` 相対パス
- 一時ファイルは `tmp/$SID/`
- BMC 操作は `BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0'`
- 状態変更は `./oplog.sh` でラップ (forceoff / on / build / deploy)
- 本機はクラスタ非参加なので `pve-lock.sh` 不要
- 複雑コマンドは Write でスクリプト化 → `sh tmp/$SID/...sh` で実行
- パイプ複合は `tmp/$SID/...sh` に書く
- 全ての Bash 実行で `2>&1` / `2>/dev/null` は付けない

## 次セッションへの引き継ぎフォーマット (レポート末尾)

```
## Phase 4 判定 (1 行)
[D-1 console_redirect / D-2 kernel_hang / D-X artifact_only] —
kernel printk N 行 / KVM 画像種類 N (size: a, b, c, ...)

## 残課題 (Phase 5 候補)
- (D-1) cmdline iter4a (console=tty0 除去) / iter4b (BIOS Redirection apply-config)
- (D-2) iter5 (nousb) / iter6 (acpi=off noapic) / iter7 (pci=noacpi) / USB stick 物理 boot
- (artifact) Phase 3 postmortem + orchestrate.sh deploy への locator screenshot 組み込み PR

## 必須引き継ぎ artifact パス
- tmp/$SID/kvm-t*.png (6 枚)
- tmp/$SID/sol-iter3.log
- tmp/$SID/bios-phase4.xml
- tmp/$SID/remaster-diff-5-18.patch
- tmp/$SID/cmdline-diff.txt
- report/attachment/<ts>_*/
```
