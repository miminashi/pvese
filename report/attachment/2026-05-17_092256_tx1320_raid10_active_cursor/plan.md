# TX1320 M3 RAID10 — active-cursor 検出 + 2-span commit + dispatcher シンプル統合

## Context

前セッション `report/2026-05-17_075519_tx1320_raid10_robustness.md` で `tmp/iter/_util.py` の cursor_y adaptive nav (`nav_cursor_to_y` + PIL ベース `detect_cursor_row`) を確立し、 BIOS Advanced tab → AVAGO Main Menu → Cfg Mgmt の navigation が安定動作するようになった。 しかし AVAGO Create VD form 内では **複数の ► が同時表示される** ため `detect_cursor_row` が active cursor (実際に選択された行) を識別できず、 RAID 10 の 2-span commit が未完遂のままセッション切れ。

本セッションのゴール:
1. 「行の白背景ハイライト」を検出する `detect_active_cursor_row()` を `_util.py` に実装
2. Create VD form 内の cursor_y を再 scout し `CURSOR_Y_CREATE_VD_FORM` を確定
3. RAID 10 2-span commit を実機で完遂 (training-tx1320, 10.254.254.9)
4. `scripts/irmc-bios-raid-setup.sh` の S6-S8 を新 python script に**シンプル統合**

ユーザ確認済み事項:
- 1 セッションで終わらない場合はレポートに引き継ぎ事項を書く
- 実機 (training-tx1320) への接続・操作を含む
- dispatcher 統合はシンプル方式 (`_util.py` は `tmp/iter/` のまま、 sh から python script 呼出、 旧 sh は `_legacy` リネームで温存)

## 静的 probe 結果 (Phase 2 で実測済み)

既存 21 form PNG (`tmp/iter/iter07_scout_run/form_00..form_13.png`) で probe 完了。 `x=30..400`, `brightness>=200` でカウントした「明るいピクセル列数」が:
- highlighted row: 37-92 cols
- 非 highlighted row: 0-15 cols

明確に分離。 採用パラメータ:
- `bg_threshold=200` (anti-aliasing 不要)
- `min_bright_cols=30` (form_06 の min=37 を救うため。 50 では取りこぼし)
- `x_min=30, x_max=400` (dialog 行までカバー)

silent drop (ArrowDown 落ち) は form_04→05, form_08→09 で観測 — `nav_cursor_to_y(allow_overshoot_correct=True)` で吸収可能。

## Approach

### Task A: `detect_active_cursor_row()` 実装 (静的検証済み)

`tmp/iter/_util.py` に追加 (新規関数):

```python
def detect_active_cursor_row(png_path, x_min=30, x_max=400,
                              bg_threshold=200, min_bright_cols=30,
                              y_min=60, y_max=720, merge_gap=4):
    """Detect highlighted (active-cursor) row.
    Returns center y of the first (top-most) cluster, or None.
    Multiple clusters: pick highest single-row max_count (most opaque)."""
```

`nav_cursor_to_y` に `detector='caret'|'highlight'` 引数を追加 (default `'caret'` で既存呼出互換)。 既存の Advanced tab / AVAGO Main / Cfg Mgmt 呼出は無変更。 form 内では `detector='highlight'` を渡す。

### Task B: Create VD form cursor_y scout (実機)

新規 `tmp/iter/iter_08_scout.py`:
1. `open_viewer` → `navigate_to_avago_main` → Main Menu (Enter) → Cfg Mgmt (Enter) → Create VD (Enter)
2. 初期 highlight y 記録 (= Save Config TOP)
3. ArrowDown × 16 (wrap 含む) で各ステップ screenshot + highlight_y 記録
4. RAID Level → RAID10 選択後にも同じ scout を別ラベル (`CURSOR_Y_CREATE_VD_FORM_RAID10`) で実施 (Span セクション出現で項目数増の可能性)

静的推定マッピング (form_*.png から):

```python
CURSOR_Y_CREATE_VD_FORM = {
    "save_configuration_top": 90,
    "select_raid_level":      128,
    "select_drives_from":     147,
    "select_drives":          204,
    "virtual_drive_name":     223,
    # ... 残りは scout で確定
}
```

### Task C: RAID10 2-span commit (実機)

新規 `tmp/iter/iter_08.py` で 13 ステップ実行:

| Step | アクション | 期待 highlight_y | フォールバック |
|------|-----------|-----------------|----------------|
| C1 | AVAGO Main → Main Menu → Cfg Mgmt → Create VD | 90 (Save Cfg TOP) | `emergency_esc_out`, retry |
| C2 | nav_to_y(Select RAID Level) → Enter (popup open) | popup highlight | Esc, retry |
| C3 | popup 内 RAID10 行へ → Enter | form 戻り、 RAID10 表示 | size fingerprint |
| C4 | (RAID10 後 form 再 scout 値) → nav_to_y(select_drives_from) → Enter → [Unconfigured Capacity] | — | — |
| C5 | nav_to_y(select_drives) → Enter (drives popup) | drives popup | — |
| C6 | drives popup: Drive 0/1 を Space toggle → Tab to Apply → Enter | (scout 値) | OK dialog Enter |
| C7 | OK dialog dismiss (Enter) → form 戻り | TOP highlight | — |
| C8 | nav_to_y(add_more_spans) → Enter | span 1 行 active | size check |
| C9 | span 1: nav_to_y(select_drives) → Enter → drives popup | — | — |
| C10 | Drive 2/3 Space toggle (Check All も試行) → Apply → OK | — | — |
| C11 | nav_to_y(save_configuration_top=90) → Enter → Confirm dialog | dialog y=216 (Confirm) | — |
| C12 | Confirm dialog: `+` で Enabled 化 → nav_to_y(yes=235) → Enter → commit | size 小 = OK dialog | Enter dismiss |
| C13 | form 終了 → AVAGO Main 戻り | `avago_main_vds1` fingerprint | size 確認 |

すべて `nav_cursor_to_y(detector='highlight', allow_overshoot_correct=True)`。 失敗時は `emergency_esc_out` + 再 enter form。

### Task D: dispatcher シンプル統合

`scripts/irmc-raid10-create.py` を新規作成 (Task C の iter_08 を CLI 化):
- options: `--bmc-ip --bmc-user --bmc-pass --session-dir --mode={create,verify}`
- import: `sys.path.insert(0, "tmp/iter")` + `from _util import ...`
- exit code: 0=成功, 1=cursor 失敗, 2=size unexpected, 3=BMC login failed

`scripts/irmc-bios-raid-setup.sh`:
- `step_S6 / S7 / S8` を `step_S6_legacy / S7_legacy / S8_legacy` リネーム + 呼出側コメントアウト
- 新 `step_S6_to_S8 ()` 関数で `python3 scripts/irmc-raid10-create.py --mode=create ...` を呼出
- S1-S3 (BMC reset, ForceOff, KVM warmup), S4-S5 (Main→Advanced→AVAGO 探索), S9 (Save & Exit), S10 (VD verify) は bash のまま

`_util.py` の場所は **`tmp/iter/` のまま** (実験 phase。 本番昇格 `scripts/lib/irmc_raid_nav.py` は今回見送り、 安定動作確認後の別セッションで検討)。 `config/training_tx1320.yml` の `.raid_setup.*_arrowdown` 系は **今回触らず** (新コードが動作確認できてから DEPRECATED 化)。

### Task E: skill 更新

`.claude/skills/irmc-bios-raid/SKILL.md` に「2026-05-17 #3: active-cursor highlight detection + RAID10 commit」セクション追加:
- `detect_active_cursor_row` 仕様 (highlight 検出 + 推奨パラメータ)
- `CURSOR_Y_CREATE_VD_FORM` 確定値
- RAID10 commit 13 ステップ (C1-C13 概略)
- 「span1 drives popup の挙動は状況依存 → Check All / 個別 toggle の両方試せ」
- dispatcher: `cmd_setup_raid10` → `scripts/irmc-raid10-create.py` を呼ぶ
- `raid create-r10` セル状態を「自動化対応」に更新

## 実装順序

1. Task A (`detect_active_cursor_row` 追加 + `nav_cursor_to_y` に `detector` 引数) — 静的検証済み、 リスク低
2. Task B (iter_08_scout 実機) — A 完了が前提
3. Task C (iter_08 RAID10 commit 実機) — B の y map 確定が前提
4. Task D (dispatcher シンプル統合) — C 成功確認後
5. Task E (skill 更新) — D と並行可

## 「1 セッションで終わらない」判断基準と引き継ぎ

- iter_08_scout で highlight 検出が安定しない → パラメータ再調整、 引き継ぎ
- RAID10 commit が C6 (Span0 drive toggle) で 3 trial 連続失敗 → drives popup 内 highlight が異なる可能性、 引き継ぎ
- BMC login timeout が 5 回超 → BMC 過負荷、 30 min cool-down 推奨、 引き継ぎ

引き継ぎテンプレ: `report/YYYY-MM-DD_HHMMSS_tx1320_raid10_active_cursor.md`
- Task A 採用パラメータ
- iter_08_scout 実測 `CURSOR_Y_CREATE_VD_FORM` map (RAID10 前後 2 版)
- C ステップ達成位置 (C1-C13 のどこまで)
- 次セッション推奨手順

## 修正/新規ファイル

### 新規

- `tmp/iter/iter_08_scout.py` — Create VD form scout (Task B)
- `tmp/iter/iter_08.py` — RAID10 commit 13 ステップ (Task C)
- `scripts/irmc-raid10-create.py` — dispatcher 呼出用 wrapper (Task D)

### 修正

- `tmp/iter/_util.py` — `detect_active_cursor_row()` 追加 (Task A)、 `nav_cursor_to_y` に `detector` 引数追加
- `scripts/irmc-bios-raid-setup.sh` — `step_S6/S7/S8` を `_legacy` リネーム + 新 `step_S6_to_S8` 追加 (Task D)
- `.claude/skills/irmc-bios-raid/SKILL.md` — 「2026-05-17 #3」セクション追記、 `raid create-r10` セル状態更新 (Task E)

### 触らない

- `config/training_tx1320.yml` — `.raid_setup.*_arrowdown` 系は新コード安定後に別セッションで DEPRECATED 化
- `scripts/irmc-kvm-interact.py` — pixel-detection op の本体統合は別セッション
- `tmp/iter/fingerprints.json` — 必要に応じて新規 fingerprint 追加のみ

## Verification

### 静的検証 (Phase 2 で完了)

既存 21 form PNG + 17 dialog PNG で `detect_active_cursor_row` が誤検出 0%、 非ハイライト max=15 vs ハイライト min=37 で 2 倍以上の差。

### 実機検証 (本セッション)

1. **iter_08_scout 段階実行** (RAID Level 変更前 + RAID10 後 2 段階)
   - 各ステップで screenshot + highlight_y 出力
   - 期待: 14-16 ArrowDown で 1 周、 cursor_y 単調増加 (silent drop は adaptive で吸収)
2. **iter_08 (RAID10 commit) 段階実行**
   - C1-C7 (Span0 まで) → 一旦停止して screenshot 確認
   - C8-C13 (Span1 + Save) → VD0 検証
3. **失敗時の手動リカバリ**:
   - 中途半端な VD pending: `clear_configuration` で reset (iter_05 で確立済み)
   - BIOS hang: `./scripts/bmc-power.sh forceoff` → boot-override BiosSetup → on
4. **dispatcher 検証**: `./scripts/irmc-bios-raid-setup.sh setup-raid10` で end-to-end 動作確認 (S1-S10)
5. **VD0 verify**: AVAGO Main → Virtual Drive Mgmt で VD0 = RAID10 / 4 drives / Span 2 を目視確認

## 関連 Issue

- #69 (継続) — 本セッションで M6/M7 (drive toggle + Save) 完遂を目標。 dispatcher 統合まで完了すれば close
