# TX1320 M3 RAID10 自動構成 — Playwright 改修成功 + M1-M6 確定 + Save は手動完遂推奨

- **実施日時**: 2026年5月17日 00:42 〜 05:42 (JST、 約 5 時間)
- **担当**: golden-candle
- **Issue**: #69 (進行中 → verify、 残作業は次セッションでユーザ手動完遂または再自動化)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**: [2026-05-16_235440_tx1320_raid10_kvm_kbd_dead.md](2026-05-16_235440_tx1320_raid10_kvm_kbd_dead.md)

## 添付ファイル

- [実装プラン](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/plan.md) — Plan モード成果物
- [Advanced タブ AVAGO 行発見](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v5_03_advanced.png) — Advanced タブ 17 アイテム表示、 AVAGO MegaRAID 行確認
- [AVAGO HII Main 画面](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v6_04_avago_main.png) — Status [Optimal] Drives=4 VDs=0
- [Main Menu submenu (5 items)](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v6_05_main_menu.png) — Configuration Mgmt / Controller Mgmt / Virtual Drive Mgmt / Drive Mgmt / Hardware Components
- [Create VD form 初期表示](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v8_04_create_vd_form.png) — Select RAID Level cursor、 13 ナビ可能フィールド
- [RAID Level popup (6 オプション)](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v9_02_raid_popup.png) — RAID0/1/5/6/00/RAID10 順
- [RAID 10 選択直後 form](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v10_07_after_raid_select.png) — Select RAID Level [RAID10]、 SELECT SPAN(S): / Span 0: 出現
- [4 drives Check All 後](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v10_11_after_check_all.png) — Drive Port 0:01:00..03 全て [Enabled]
- [Apply 完了 OK dialog](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v10_13_after_apply.png) — "The operation has been performed successfully. OK"
- [Save 失敗エラー](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v13_04_save_confirm_dialog.png) — "more than one span and an equal number of Drives in each span is required"
- [v21 安全状態回復](attachment/2026-05-17_050000_tx1320_raid10_playwright_partial/v21_esc_10.png) — BIOS Setup Advanced タブ、 AVAGO 行 cursor

## 前提・目的

前セッション ([2026-05-16_235440_tx1320_raid10_kvm_kbd_dead.md](2026-05-16_235440_tx1320_raid10_kvm_kbd_dead.md)) で中断した RAID10 自動構成の続行。 ユーザ確定方針:

- **`scripts/irmc-kvm-interact.py` の Playwright 経路を改修** (新 path 追加・既存 path 温存)
- **他機種影響ゼロ**を担保 (`irmc-kvm-interact.py` は training-tx1320 専用、 他機種は別ファイル)
- **KVM 経路のみ** (Live ISO + storcli は今回スコープ外)

## 環境情報

- マシン: Fujitsu PRIMERGY TX1320 M3 (Serial MABK035229)
- BIOS: V5.0.0.11 R1.22.0 (Aptio Setup Utility)
- iRMC: S4 FW 9.08F、 KVM + MEDIA ライセンス
- RAID controller: PRAID EP400i (LSI MegaRAID SAS3008, AVAGO MegaRAID Configuration Utility 03.25.05.10)
- 物理ディスク: SAS HDD 900 GB × 4 (Seagate ST900MM0168, [Unconfigured Good])
- ネットワーク: 10.254.254.9 (iRMC), 別拠点

## 実施内容と結果

### Phase 0: `irmc-kvm-interact.py` 改修 ✅ 完了

新 path を追加・既存 path 温存:

| 項目 | 旧パス (温存) | 新パス (default) |
|------|--------------|-----------------|
| `capture()` | `canvas.toDataURL()` (WebGL 黒問題で動かない) | **`locator.screenshot()`** — composed frame で実画像取得 |
| `focus_kvm()` | `click(force=True)` | **`locator.click(force=False)`** — hit-test 経由 |
| キー送信 | `keyboard.press` | (default、 代替 `dispatch-event` も実装) |

新 CLI flag: `--capture-mode={locator,canvas}` / `--focus-mode={hittest,force}` / `--key-mode={playwright,dispatch-event}`。 全 default を新パス。 関数シグネチャ互換、 `force_refresh` / `capture_with_retry` 等の旧パスユーティリティはコード残置。

**他機種影響なし** (`bmc-kvm-*.py`, `idrac-kvm-*.py` には未触手)。

### Phase 0-B: smoke test ✅ 完了

最初の smoke で **locator.screenshot() が実画像 (8782 B) 取得成功** を確認。 dispatcher S1 の Manager.Reset で BMC session 全クリアした単一 viewer で keystroke が host に届くことを Phase α 以降で実証。

### Phase α: dispatcher S1-S5 ✅ 完了

`tmp/biosraid/run-a/` で実行。 S1 (BMC 復帰 231s) → S2 (ForceOff + boot-override + Power On + 90s 待機) → S5 (Advanced 内 ArrowDown x14 で AVAGO 行ハイライト確認)。

ただし dispatcher の S3+S4+S5 が **独立 viewer session を 3 つ開く** ため、 各 session が BMC 内で「master reconnecting」状態を生成 → 後続 session が partial-access (read-only) になる落とし穴あり。 解決策: **単一 viewer で end-to-end** に切替 (Phase β 以降は全て独立 Python スクリプト経由)。

### Phase β: AVAGO HII キーシーケンス確定 ✅ M1-M6 完了 / M7 一部達成

| Milestone | キー | 確定値 | 検証 screenshot |
|-----------|------|--------|----------------|
| M1 AVAGO HII 進入 | Advanced cursor on AVAGO → Enter | ArrowDown 14 + Enter | v6_04: AVAGO Main "Status [Optimal] Drives=4" |
| M2 Main Menu submenu | AVAGO Main cursor on Main Menu → Enter | Enter (cursor 起動位置) | v6_05: 5 items (Cfg Mgmt 1st item) |
| M3 Configuration Mgmt | Main Menu cursor on Configuration Mgmt → Enter | Enter (cursor 起動位置) | v7_03: Cfg Mgmt submenu, 3 items |
| M4 Create VD form | Cfg Mgmt cursor on Create Virtual Drive → Enter | Enter (cursor 起動位置) | v8_04: form 表示 (Select RAID Level cursor) |
| M5 RAID 10 選択 | Enter (popup open) + ArrowDown 5 + Enter | `ArrowDown 5` | v9_02 popup (RAID0/1/5/6/00/10) + v10_07 form RAID Level [RAID10] |
| M6 4 drives 選択 (Span 0 のみ) | Span 0 Select Drives + Enter + ArrowDown 8 + Enter (Check All) + ArrowDown 2 + Enter | drives popup → Check All → Apply | v10_11 [Enabled] x4 + v10_13 "Operation successful" |
| M7 Save Configuration | Enter on Save Config TOP | Enter (cursor 自動着地) | v13_04: ⚠️ **「more than one span...」エラー** |

確定パラメータ (`config/training_tx1320.yml` の `raid_setup` セクションに反映予定):

```yaml
raid_setup:
  avago_arrowdown: 14    # Advanced cursor 起動位置 → AVAGO
  cfgmgmt_arrowdown: 0   # Main Menu cursor 起動位置 = Configuration Mgmt
  createvd_arrowdown: 0  # Cfg Mgmt cursor 起動位置 = Create Virtual Drive
  raid10_arrowdown: 5    # RAID Level popup → RAID 10 (5 ArrowDown)
  drives_check_all_down: 8   # drives popup → Check All
  drives_apply_down: 2       # drives popup → Apply Changes (bottom)
  vdlist_arrowdown: 2    # Main Menu → Virtual Drive Management
```

ただし M5-M7 一発通しは未達 → 下記 (C) 参照。

### Phase γ: RAID 10 VD0 Save ⚠️ **未完遂**

#### (A) Save 失敗の根本原因 (**重要新発見**)

**LSI MegaRAID の RAID 10 は最低 2 span 必要、 各 span 同数ドライブ**。 Check All で 4 drives 全てを Span 0 に入れる構成は AVAGO HII のバリデーションで弾かれる:

> "To create Virtual Drives for the selected RAID level, more than one span and an equal number of Drives in each span is required. Click OK to go back and make changes."

正解は **Span 0 = 2 drives + Span 1 = 2 drives** (4-drive RAID 10 = 2-span × 2-drive mirror striped)。

#### (B) 2-span 構成自動化の試行

以下を試行 (v14 ~ v20):

- **Span 0 の drives popup で 4 drives 中 2 drives を個別 uncheck** → 個別 drive toggle の navigation 信頼性問題 (ArrowDown が 1-2 個 silently drop、 想定外フィールドに着地)
- **Esc out + Clear Configuration で pending state クリア + 再構築** → Esc が想定外深さで戻り、 Drive Management 個別ドライブ画面に偶然着地。 危険操作 ([Make Unconfigured Bad]) が pending したが **Go 未押下で未 commit**
- **Create Profile Based Virtual Drive 試行** → AVAGO HII pending state が NVRAM 持続のため、 form 再進入で過去状態が復活

#### (C) AVAGO HII の重大な落とし穴 (**新発見・要記録**)

1. **Create VD form の Pending state は AVAGO controller NVRAM に永続** — Host reboot しても消えない。 S1+S2 で boot-override 再進入しても form は前回の状態 (Span 0 + 1 + 2 + 4 drives etc) が復元される。 リセット手段は Configuration Management → **Clear Configuration** のみ
2. **個別 drive toggle (ArrowDown N + Enter) の navigation 不安定** — AVAGO HII Aptio 系では ArrowDown 1 個ごとに 700-1500ms 待機しても 30-50% が silently dropped。 ArrowDown 4 が実際 2 にしか効かないケース多発。 適切に検証するなら **screenshot で位置 verify ⇒ 必要なら追加 ArrowDown** のアダプティブ navigation が必要
3. **Enter on drive 行は popup open** (`[Disabled]` / `[Enabled]` の選択肢)。 single press toggle ではない。 toggle は + キー (Change Opt.) で行うべき
4. **Tab キーは drives popup / VD form 内で動作せず** — Aptio HII の Tab はタブバー移動のみ。 form 内 field 間移動は ArrowDown/Up のみ

### Phase δ: 検証 ❌ 未実施 (VD 未作成のため)

## 完了事項

- [x] `scripts/irmc-kvm-interact.py` 改修: `--capture-mode=locator` (default) + `--focus-mode=hittest` (default) + `--key-mode=playwright` (default、 `dispatch-event` 代替も実装) — 他機種影響なし
- [x] smoke test で locator.screenshot() 実画像取得確認
- [x] dispatcher S1+S2 (Manager.Reset + boot-override + cycle) が改修後 Playwright で動作
- [x] **AVAGO HII 進入手順 M1-M4 完全確定** (avago_arrowdown=14, cfgmgmt=0, createvd=0)
- [x] **RAID 10 選択手順 M5 確定** (raid10_arrowdown=5)
- [x] **drives popup の Check All / Apply 経路 M6 確定** (drives_check_all_down=8, drives_apply_down=2)
- [x] **Save Configuration TOP cursor 自動着地パターン発見** (Apply OK → Enter dismiss → 自動的に Save Config TOP に cursor)
- [x] **重大新発見**: RAID 10 は LSI MegaRAID で **最低 2 span 必須**、 4-drive 単一 span 不可
- [x] **重大新発見**: AVAGO controller NVRAM 持続の form pending state、 Clear Configuration が唯一の reset 手段
- [x] **重大新発見**: 個別 drive toggle の ArrowDown 信頼性問題 (WAIT_MS=1500 でも 30-50% loss)
- [x] host 安全状態回復 (v21 で BIOS Advanced タブ、 destructive action 未実行)

## 未完了

### 1. RAID 10 VD0 実 commit

**Span 0 = 2 drives + Span 1 = 2 drives** 構成での Save Configuration。 自動化は ArrowDown 信頼性問題で完遂できず。 推奨次手:

- **ユーザ手動完遂** (Web UI 経由、 5-10 分):
  1. iRMC Web UI (`https://10.254.254.9`) ブラウザでログイン
  2. Console Redirection → HTML5 KVM 起動
  3. BIOS Setup → Advanced → AVAGO MegaRAID Configuration Utility → Main Menu → Configuration Management
  4. (前 pending state を消すため) Clear Configuration → Confirm Enabled → Yes → 確認
  5. Create Virtual Drive → Select RAID Level → RAID 10
  6. Select Drives (Span 0) → drives popup → drive 0, drive 1 を個別 toggle → Apply Changes
  7. Add More Spans → Span 1 Select Drives → drive 2, drive 3 toggle → Apply Changes
  8. Save Configuration → Confirm Enabled → Yes
  9. Esc out + Save & Exit BIOS

- **自動化リトライ次セッション**: アダプティブ navigation (screenshot で position verify、 ArrowDown 1 ずつ、 想定外位置ならリトライ) を実装。 OR Live ISO + storcli 経路へ切替

### 2. config/training_tx1320.yml の raid_setup 反映

確定パラメータ (avago_arrowdown=14, raid10_arrowdown=5 等) を yml に書き戻す作業は本セッション内で実施せず (RAID 10 完遂後にまとめて反映する想定だった)。 次セッションで反映予定。

### 3. dispatcher の修正

`scripts/irmc-bios-raid-setup.sh setup-raid10` の S6-S9 は **単一 viewer で end-to-end** に書き換える必要あり (現状は各 step ごとに独立 viewer = partial-access 問題)。 次セッション。

## 再現方法

### Phase 0 改修内容の検証 (ArrowDown 1 個で cursor 動くか確認)

```sh
# 0. host を BIOS Setup Main 状態にする (S1+S2)
./scripts/irmc-bios-raid-setup.sh setup-raid10 config/training_tx1320.yml \
    --continue-from=S1 --stop-at=S2 --session=verify-1

# 1. smoke test
sh tmp/<sid>/smoke_kvm.sh   # tmp/golden/smoke_kvm.sh と同等
# → tmp/<sid>/smoke_before.png と smoke_after.png で cursor 移動確認
```

### AVAGO HII Main Menu submenu 確認 (M1-M2)

```sh
# (S1+S2 後) tmp/golden/e2e_v6.py 同等の単一 viewer スクリプト実行
.venv/bin/python tmp/<sid>/e2e_v6.py
# → v6_04_avago_main.png = AVAGO Main + v6_05_main_menu.png = 5-item Main Menu
```

### Create VD form 確認 (M4)

```sh
.venv/bin/python tmp/<sid>/e2e_v8.py   # M1-M4 + form 表示
# → v8_04_create_vd_form.png
```

### RAID 10 選択 + 4 drives Apply (M5-M6) — Save 直前まで

```sh
.venv/bin/python tmp/<sid>/e2e_v10_final.py
# → v10_07 RAID Level [RAID10] + v10_11 4 drives [Enabled] + v10_13 Apply OK
```

### Save Configuration エラー再現 (RAID 10 single-span 不可)

```sh
.venv/bin/python tmp/<sid>/e2e_v13.py
# → v13_04 "more than one span" エラーダイアログ
```

## 関連ファイル

### 修正

- `scripts/irmc-kvm-interact.py` — `--capture-mode={locator,canvas}` / `--focus-mode={hittest,force}` / `--key-mode={playwright,dispatch-event}` フラグ追加、 default は新パス。 旧パス温存

### 未修正 (次セッションで修正予定)

- `config/training_tx1320.yml` — `raid_setup.*` 反映待ち
- `scripts/irmc-bios-raid-setup.sh` — S6-S9 を単一 viewer 化、 RAID 10 の 2-span 対応必要

### ドキュメント

- `.claude/skills/irmc-bios-raid/SKILL.md` — Phase 0 改修内容と AVAGO HII 落とし穴 #28-30 (RAID 10 2-span、 Pending state 持続、 ArrowDown 信頼性) を追記予定
- `.claude/skills/irmc-bios-raid/reference.md` — 同上

### 参考スクリプト (tmp/golden/、 本セッションで使い捨て)

- `e2e_avago.py` (v1 最初の試行)
- `e2e_v4.py` ~ `e2e_v8.py` — ナビゲーション探索
- `e2e_v10_final.py` — RAID 10 + Apply 直前まで通せた最良スクリプト
- `e2e_v13.py` — Save 失敗エラー再現
- `e2e_v21_safe.py` — Esc out で安全回復

## 関連 Issue

- #67/#68 (前々セッション、 完了)
- #69 (前セッション + 本セッション、 **進行中 → verify**)
  - 前々セッション: BIOS UEFI 化完了
  - 前セッション: AVAGO HII Main 画面進入確定 + Playwright 自動化バグの原因究明
  - **本セッション**: Playwright 改修完了 + AVAGO HII の M1-M6 完全自動化確定 + RAID 10 の 2-span 必須仕様発見。 残作業: 2-span 構成での Save (ユーザ手動 OR 次セッションで自動化リトライ)
