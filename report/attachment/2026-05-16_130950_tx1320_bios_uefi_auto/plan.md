# TX1320 M3 BIOS/RAID 設定完全自動化

## Context

`report/2026-05-16_111810_tx1320_m3_followup.md` の引き継ぎ事項のうち、**RAID10 構成** と **BIOS 設定** を完全自動化する。前セッション (#68) で以下までは完成済み:

- Redfish OEM `irmc-virtualmedia.sh` (Virtual Media SMB マウント)
- Playwright + HTML5 KVM 自動操作 (`irmc-kvm-screenshot.py`, `irmc-kvm-interact.py`)
- `bmc-power.sh` の iRMC 対応 (ETag quotes なし PATCH, BootOverride 無 Disabled, ResetType=On)
- BIOS Setup へ Redfish 経由で進入できることを実証 (添付 `kvm-after-enter.png`)

未完了タスクの中心:
1. **RAID10 (HW RAID10, SAS HDD 900GB × 4 → 1.8 TB)** — eLCM ライセンス無しのため Redfish 経由不可、BIOS Setup の Advanced タブ内の MegaRAID Configuration Utility (UEFI HII) を HTML5 KVM 経由で叩く
2. **BIOS 設定** (Boot Mode UEFI / Serial Console / Boot Order) — preseed 自動 install の前提

OS インストール (Phase F) は本セッションでは扱わず、次セッションへ持ち越し。

### 既知の構成 (ユーザ確認済み)

- **RAID コントローラ: PRAID EP400i** (LSI MegaRAID 12Gbps SAS3008 系、`storcli` 対応)
- **RAID 設定経路: BIOS Setup → Advanced タブ → MegaRAID Configuration Utility (UEFI HII)** — Ctrl+R による独立 BIOS Utility ではなく、Aptio Setup の Advanced タブ配下から HII 経由で操作
- `config/training_tx1320.yml` の `raid_controller` は `PRAID EP400i` で確定して書き込む

## 戦略

### 二層構成

| 層 | 対象 | 経路 | 信頼性 |
|----|------|------|--------|
| Layer 1 | BIOS 設定 (Boot Mode, Serial Console, Boot Order) | OEM `BSPBRBackup` → XML 編集 (xmlstarlet) → `BSPBRRestore` → cycle | 高 (構造化操作) |
| Layer 2 | RAID10 構成 | HTML5 KVM (Playwright + OCR で画面状態判定 + キーシーケンス) | 中 (実機探索後に確定) |

Layer 1 が大部分の BIOS 設定をカバーし、Layer 2 は RAID 専用とする。Layer 1 で BIOS 設定変更が反映されない項目があれば Layer 2 (KVM) にフォールバック。

### OCR フィードバックループ (Layer 2)

`pytesseract` を `.venv` にインストールし、`irmc-kvm-interact.py` を拡張して以下を提供:

- `--expect-text "PATTERN"` — screenshot 後に OCR で text 抽出、正規表現マッチで画面到達を確認
- `--frame-refresh` — Control キー単独送信 + 短い待機で frame full を誘発
- 状態マシンベースの操作 (現在画面を OCR で判定 → 次の遷移キー送信 → 期待画面到達確認)

## Phase 1: 実機探索 (4-6 時間)

### 1a. 現状把握 (read-only)

```sh
# Power state + System info
./scripts/bmc-power.sh status 10.254.254.9 claude Claude123
# Redfish System
curl -k --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    https://10.254.254.9/redfish/v1/Systems/0
```

確認項目: PowerState, BiosVersion, MemorySummary, ProcessorSummary, Boot.*

### 1b. WinSCU XML ダウンロード

OEM `BSPBRBackup` を実行 → XML を `report/attachment/<session>/bios-backup-initial.xml` に保存。

XML 構造を確認し、以下の項目を grep で抽出:
- `BootMode` / `BootDevicePriority` / `LegacyOpRom` (UEFI モード関連)
- `SerialPortConsoleRedirection` / `BAUDRate` / `COMPort` (Serial Console 関連)
- `BootOption` / `BootOrder` (起動順)
- `RAID` 関連項目 (含まれるか確認)

```sh
# 実装後の擬似コマンド
./scripts/irmc-bios-xml.sh backup config/training_tx1320.yml \
    report/attachment/<session>/bios-backup-initial.xml

# 中身解析
grep -i 'boot\|serial\|raid\|console' report/attachment/<session>/bios-backup-initial.xml
```

### 1c. BIOS Setup へ進入

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' BMC_PATCH_REQUIRES_ETAG=1 \
    ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 BiosSetup UEFI
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
    ./oplog.sh ./scripts/bmc-power.sh cycle 10.254.254.9 claude Claude123 20
sleep 120  # POST 通過 + BIOS Setup 表示まで待機
```

### 1d. BIOS Setup メニューマップ作成

`irmc-kvm-interact.py shell` で 1 viewer session 内に全画面を巡回:

```sh
.venv/bin/python scripts/irmc-kvm-interact.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    shell "\
        combo:Control; wait:1; screenshot:report/attachment/<session>/bios-main.png; \
        sendkeys:ArrowRight; combo:Control; wait:1; screenshot:bios-advanced.png; \
        sendkeys:ArrowRight; combo:Control; wait:1; screenshot:bios-security.png; \
        sendkeys:ArrowRight; combo:Control; wait:1; screenshot:bios-boot.png; \
        sendkeys:ArrowRight; combo:Control; wait:1; screenshot:bios-save-exit.png"
```

各画面で目視 + OCR 試験 (pytesseract で text 抽出 → 期待単語マッチ率を計測)。

### 1e. MegaRAID Configuration Utility (UEFI HII) 到達 + 全画面 screenshot

Advanced タブ → "AVAGO MegaRAID Configuration Utility" or "LSI MegaRAID Configuration Utility" (UEFI HII の entry 名) → Enter → サブ画面群 (Main Menu, Configuration Management, Controller Management, Virtual Drive Management, Drive Management) を順次 screenshot。

MegaRAID UEFI HII の典型メニュー階層 (要実機確認):
- Main Menu
  - Configuration Management
    - Create Virtual Drive
    - Create Profile Based Virtual Drive
    - Manage Foreign Configuration
    - Clear Configuration
  - Controller Management
  - Virtual Drive Management
  - Drive Management
  - Hardware Components

### 1f. 既存 VD / Physical Drives 把握

VD 一覧画面と PD 一覧画面を screenshot。既存 VD があれば Phase 3 で `Clear Configuration` で全削除してから新規 R10 を作成する。`raid_controller: PRAID EP400i` は確定値として `config/training_tx1320.yml` に反映済み (Phase 4b 時)。

## Phase 2: BIOS 設定自動化 (Layer 1, XML 経由) (4-6 時間)

### 2a. `scripts/irmc-bios-xml.sh` 新規 (sh)

ラッパースクリプト。サブコマンド:
- `backup <config> <out.xml>` — BSPBRBackup → ダウンロード → XML 保存
- `restore <config> <in.xml>` — BSPBRRestore で適用
- `diff <a.xml> <b.xml>` — 設定差分表示 (xmlstarlet sel)

実装は既存 `scripts/irmc-virtualmedia.sh` の Redfish PATCH パターンを流用 (ETag quotes なし対応含む)。

### 2b. `scripts/irmc-bios-edit.sh` 新規 (sh + xmlstarlet)

XML を編集するユーティリティ。サブコマンド:
- `set-boot-mode <xml> <UEFI|Legacy>` — Boot Mode 切替
- `set-serial-console <xml> <enable|disable> <unit:0|1> <baud:115200>` — Serial Port Console Redirection
- `set-boot-order-cd-first <xml>` — Boot Order の先頭を CD/DVD に
- `set-boot-order-hdd-first <xml>` — Boot Order の先頭を HDD に (install 完了後用)

各操作は `xmlstarlet ed -L --inplace ...` で xpath ベースに値を書き換える。Phase 1b で確定した xpath を使用。

`bin/xmlstarlet` は `sudo apt install -y xmlstarlet` でローカルインストール (`Bash(sudo apt:*)` 許可済)。

### 2c. 適用ループ

```sh
./scripts/irmc-bios-xml.sh backup config/training_tx1320.yml tmp/<sid>/bios-before.xml
cp tmp/<sid>/bios-before.xml tmp/<sid>/bios-edit.xml
./scripts/irmc-bios-edit.sh set-boot-mode tmp/<sid>/bios-edit.xml UEFI
./scripts/irmc-bios-edit.sh set-serial-console tmp/<sid>/bios-edit.xml enable 0 115200
./scripts/irmc-bios-edit.sh set-boot-order-cd-first tmp/<sid>/bios-edit.xml
./scripts/irmc-bios-xml.sh restore config/training_tx1320.yml tmp/<sid>/bios-edit.xml
# Restore は次回起動時に適用 → cycle
./oplog.sh ./scripts/bmc-power.sh cycle 10.254.254.9 claude Claude123 20
sleep 180  # POST + BIOS update 反映
./scripts/irmc-bios-xml.sh backup config/training_tx1320.yml tmp/<sid>/bios-after.xml
./scripts/irmc-bios-xml.sh diff tmp/<sid>/bios-before.xml tmp/<sid>/bios-after.xml
```

差分が期待通りに反映されていることを確認。

### 2d. Idempotency

再度 `set-*` を当てて `restore` しても No-op になることを確認 (同一 XML を Apply しても問題ないこと)。

## Phase 3: RAID10 構成自動化 (Layer 2, KVM 経由) (8-12 時間)

### 3a. `irmc-kvm-interact.py` 拡張

新オプション/サブコマンド:

```python
# Step 構文を拡張:
#   expect:PATTERN          OCR で正規表現マッチを待つ (max 30s)
#   refresh                 Control 送信 + 待機 + 再 screenshot
#   ocr:save.txt            screenshot を OCR して text を保存

# CLI 追加:
.venv/bin/python scripts/irmc-kvm-interact.py \
    --bmc-ip ... shell "
        refresh;
        expect:Main.*Advanced;     # BIOS Setup Main 画面確認
        sendkeys:ArrowRight;
        refresh;
        expect:Advanced;           # Advanced タブ到達確認
        ...
    "
```

OCR は `pytesseract` (or `easyocr` フォールバック) を `.venv` に追加。BIOS Setup は単純な英文 + 数字なので tesseract で十分。

### 3b. `scripts/irmc-raid-create-r10.py` 新規 (Python)

RAID10 作成専用の状態マシン。Phase 1 で記録した MegaRAID UEFI HII の構造に基づいて以下を実装 (PRAID EP400i 想定):

```
状態:                                       期待 OCR pattern              遷移キー
1. ENTER_BIOS_SETUP                        Main.*Aptio                    ArrowRight (Advanced)
2. ADVANCED_TAB                            Advanced                       ArrowDown × N + Enter (AVAGO MegaRAID)
3. MEGARAID_MAIN_MENU                      Main Menu                      Enter (Configuration Management)
4. CONFIG_MGMT                             Configuration Management       Enter (Create Virtual Drive)
5. SELECT_RAID_LEVEL                       Select RAID Level              ArrowDown → RAID10 → Enter
6. SELECT_DRIVES                           Select Drives                  各 PD で Tab + Space (4 本) → Apply Changes
7. CREATE_VD_PARAMS                        Virtual Drive Name             (default 名のまま) Strip Size: 64KB / Read/Write Cache: default
8. APPLY_CHANGES                           Save Configuration             Enter (Confirm warning)
9. CONFIRM_WRITE                           Confirm                        Y (Yes) or Enter
10. VD_CREATED                             Operation Successful           Enter (OK) → Esc × N (Back to BIOS Main)
11. SAVE_AND_EXIT                          Save & Exit                    F10 → Y (Save changes and reset)
```

各状態間で `refresh` (frame refresh, Control 送信) を挟む。OCR 失敗時は再度 refresh → 最大 3 回リトライ → 失敗なら abort + screenshot 保存。

MegaRAID UEFI HII では選択キーが `Enter` (open submenu) / `Space` (toggle checkbox) / `+/-` (numeric increase) / `F1` (help) などになる。Phase 1e の screenshot を基に確定。

### 3c. `scripts/irmc-raid-delete-all.py` 新規 (Python)

既存 VD を全削除する。同じ状態マシンパターンで実装。

### 3d. 実機テスト + 試行錯誤

1. 既存 VD があれば delete-all を実行
2. create-r10 を実行
3. 完了後に Save & Exit (`F10` or Exit メニュー)
4. cycle で再起動
5. Redfish/SOL/再度 BIOS Setup 進入で VD0 (1.8 TB) Optimal を確認
6. Idempotent 確認 (既に VD0 がある状態で create-r10 を実行 → 検出して skip)

試行錯誤の余地が大きい。1 試行に 10-15 分かかるため、各 step を screenshot 比較しながら徐々に詰めていく。

## Phase 4: 統合ラッパー (2-3 時間)

### 4a. `scripts/irmc-bios-raid-setup.sh` 新規 (sh)

最終的なエントリポイント:

```sh
./scripts/irmc-bios-raid-setup.sh discover config/training_tx1320.yml
# → 現状取得 (RAID controller, BIOS version, current VDs, Boot Mode 等)

./scripts/irmc-bios-raid-setup.sh setup-bios config/training_tx1320.yml
# → Phase 2 (XML 経由 BIOS 設定)

./scripts/irmc-bios-raid-setup.sh setup-raid10 config/training_tx1320.yml
# → Phase 3 (RAID10 作成)

./scripts/irmc-bios-raid-setup.sh full-setup config/training_tx1320.yml
# → discover → bios → raid10 → verify
```

### 4b. config 拡張

`config/training_tx1320.yml` に以下を追加 (`raid_controller` は確定値 EP400i):

```yaml
raid_controller: "PRAID EP400i"   # LSI MegaRAID SAS3008, UEFI HII via Advanced tab
disk: /dev/sda                     # Phase 3d 完了後 (variants 次第)

bios_settings:
  boot_mode: UEFI
  serial_console:
    enabled: true
    com_port: 1
    baud_rate: 115200
    terminal_type: VT100+
  boot_order_first: CD              # install 時。完了後 HDD に切替
```

## Phase 5: ドキュメント・skill 更新 (2 時間)

- `.claude/skills/irmc-bios-raid/SKILL.md`:
  - `raid create-r10` / `raid delete` / `bios set-boot-mode` / `bios set-serial-console` / `bios set-boot-order` を **完全自動** にステータス変更
  - 各サブコマンドの引数・例を更新
- `.claude/skills/irmc-bios-raid/reference.md`:
  - WinSCU XML schema 抜粋 (xpath 一覧)
  - RAID Configuration Utility メニューマップ (Phase 1d/1e の screenshot リンク + キーシーケンス)
- `memory/training_tx1320.md`:
  - RAID controller model 確定値
  - BIOS menu map
  - WinSCU XML schema 抜粋
- `report/2026-05-17_<session>_tx1320_bios_raid_auto.md` 新規 (本セッションのレポート)

## 重要ファイル

### 新規

- `scripts/irmc-bios-xml.sh` — WinSCU XML backup/restore (BSPBRBackup/Restore のラッパー)
- `scripts/irmc-bios-edit.sh` — XML 編集ユーティリティ (xmlstarlet 経由)
- `scripts/irmc-raid-create-r10.py` — RAID10 作成 (Python + Playwright + pytesseract)
- `scripts/irmc-raid-delete-all.py` — 既存 VD 全削除
- `scripts/irmc-bios-raid-setup.sh` — 統合ラッパー (Phase 2 + Phase 3 + verify)

### 改修

- `scripts/irmc-kvm-interact.py` — `expect` / `refresh` / `ocr` step を `shell` 構文に追加、OCR ヘルパー (`pytesseract` 使用)
- `config/training_tx1320.yml` — `raid_controller`, `bios_settings` セクション追加
- `.claude/skills/irmc-bios-raid/SKILL.md` — 完全自動化ステータス
- `.claude/skills/irmc-bios-raid/reference.md` — XML schema, RAID menu map
- `memory/training_tx1320.md` — RAID controller, BIOS map

### 既存資産で活用

- `scripts/bmc-power.sh` — boot-override BiosSetup, cycle
- `scripts/irmc-virtualmedia.sh` — Redfish OEM PATCH パターン (ETag quotes なし) を参考に
- `scripts/irmc-kvm-screenshot.py` — screenshot 取得 (capture 関数を import 可能性)
- `bin/yq` — config 読み取り

## リスク・代替案

| リスク | 影響 | 対策 |
|--------|------|------|
| WinSCU XML に Serial Console 等の項目が無い | Layer 1 で全 BIOS 設定をカバー不可 | Layer 2 (KVM) で BIOS Setup → Advanced → Serial Console 設定を実装 |
| MegaRAID UEFI HII のメニュー文言が想定と違う | Phase 3b の状態マシン設計やり直し | Phase 1e の screenshot 探索でメニュー文言を確定。expect pattern を実機文言ベースで定義 |
| OCR の認識率が低い | 状態判定の信頼性低下 | `--lang eng --psm 6` 等の tesseract オプション調整。BIOS Setup は英文+大文字なので比較的 OCR しやすい想定。ダメなら DOM-canvas pixel 差分 (特定領域のハッシュ比較) に切替 |
| BIOS Setup の Save & Exit でエラー | 設定反映されない | 再 backup XML で確認、失敗時は再試行。事前に backup を保持して revert 可能 |
| RAID 既存 VD 削除でデータ消失 | training-tx1320 は OS 未 install なので影響軽微 | 念のため初回起動時に screenshot を保存しておく |
| 1 試行 10-15 分 × 多数 → 24h 上限超過 | Phase 3 完了不可 | Phase 3a の OCR ヘルパーを先に完成させて 1 試行あたりの分析時間を短縮。Phase 3b は実機ログを残しながら漸進的に詰める |

## 検証手順

### 各 Phase の verify

Phase 1: 全 BIOS / RAID 画面の screenshot が `report/attachment/<session>/` に揃っている

Phase 2:
```sh
./scripts/irmc-bios-xml.sh backup config/training_tx1320.yml tmp/<sid>/verify.xml
xmlstarlet sel -t -v "//Setting[@Name='BootMode']" tmp/<sid>/verify.xml
# → UEFI
xmlstarlet sel -t -v "//Setting[@Name='SerialPortConsoleRedirection']" tmp/<sid>/verify.xml
# → Enabled
```

Phase 3: BIOS Setup 再進入 → RAID Configuration Utility → VD 一覧画面で VD0 (RAID10, 1.8 TB, Optimal) 表示

Phase 4 (end-to-end):
```sh
./scripts/irmc-bios-raid-setup.sh discover config/training_tx1320.yml
# 期待: BootMode=UEFI, SerialConsole=Enabled, VD0=RAID10 Optimal 1.8TB, controller=<model>

# Idempotent 確認
./scripts/irmc-bios-raid-setup.sh full-setup config/training_tx1320.yml
# → 既に揃っているため変更なし (No-op)
```

### 最終確認 (OS install への準備完了)

- `config/training_tx1320.yml` の `raid_controller`, `disk`, `bios_settings` が確定値
- BIOS Setup 進入時のスクリーンショットで Boot Order 先頭が CD/DVD、Serial Console Enabled
- RAID10 VD0 が Optimal で 1.8 TB
- 次セッションで `os-setup` skill を使って Phase F (OS install) に着手可能な状態

## タイムライン目安 (合計 20-29 時間)

| Phase | 時間 |
|-------|------|
| Phase 1 (探索) | 4-6h |
| Phase 2 (BIOS XML) | 4-6h |
| Phase 3 (RAID KVM) | 8-12h |
| Phase 4 (統合) | 2-3h |
| Phase 5 (docs) | 2h |

24 時間目安に収まる想定。Phase 3 の試行錯誤が膨らむ場合は Phase 4 の `full-setup` を省略して個別サブコマンドのみで完了させる。
