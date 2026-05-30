# TX1320 M3 RAID10 自動化 — Form Cursor 検出 + RAID10 commit + dispatcher 統合 (続き)

## Context

前セッション (`partitioned-beaver`、 `report/2026-05-17_092256_tx1320_raid10_active_cursor.md`) で `tmp/iter/_util.py:145` に `detect_active_cursor_row()` + `nav_cursor_to_y(detector='caret'|'highlight', settle_ms)` を実装したが、 実機検証で重大な問題が判明し RAID10 commit (C2 以降) が未完遂のまま引き継ぎ:

1. **`[RAID0]` 値表示の bright cluster (y=121..132, max=110) が常に brightest** で `detect_active_cursor_row` が picking → Create VD form 内の cursor 位置検出が highlight 単独で不可能
2. **ArrowDown 1 from y=88 → y=147 に 2 行飛び** で Select RAID Level (y=128) が skip される
3. **`+/-` は `NumpadAdd`/`NumpadSubtract` 専用** (他の `+` 送出方法は届かず)
4. **iRMC KVM frame buffer ラグで Aptio 内部 cursor と表示画面がずれる** (`settle_ms=3000` でも解消せず)
5. form 内 ArrowUp/Down wrap-around は非一様 (from-TOP は 2 行飛び、 from-bottom は wrap to TOP)

ゴール (ユーザ確定: 全 5 タスク + 実機接続 + dry-run 先行 + 1 セッションで終わらなければ引き継ぎ):
1. cursor 位置の信頼性ある検出手段確立 (`identify_form_cursor_by_probe`)
2. Select RAID Level (y=128) 到達手段確定
3. drives popup の cursor 検出
4. RAID10 commit C1-C13 (C12 は dry-run → 確認後本番 commit)
5. dispatcher (`scripts/irmc-bios-raid-setup.sh`) シンプル統合

## Approach

### Task 1: `identify_form_cursor_by_probe()` — hybrid (internal model + image diff probe)

`tmp/iter/_util.py` に追加:

```python
PROBE_FORBIDDEN_Y = {88, 411}              # Save Config TOP / Emulation Type — action 行 or 不明
PROBE_SAFE_Y = {147, 259, 280, 299, 316, 337, 373}  # 値 cycling 安全行

def identify_form_cursor_by_probe(vp, sdir, label, expected_y=None):
    """NumpadAdd → 2s wait → image diff → cursor 行特定 → NumpadSubtract で値戻し.
    Returns (y, method) where method in {'probe','model','highlight'}.

    1. before.png + size_before + highlight_y_naive
    2. expected_y in PROBE_FORBIDDEN_Y → model 採用、 probe skip
    3. expected_y in PROBE_SAFE_Y → probe:
       a. press NumpadAdd, wait 2s, after.png, size_after
       b. press NumpadSubtract, wait 2s, restore.png, size_restore
       c. abs(size_after - size_before) > 200:
            PIL row-wise diff (|after - before|.sum() per y) → 最大 y が cursor
       d. assert abs(size_restore - size_before) < 100 (cleanup OK)
    4. unknown → highlight_y_naive + WARN log
    """
```

副作用最小化:
- `PROBE_FORBIDDEN_Y` は完全 skip (action 行で probe しない)
- 必ず NumpadSubtract で戻し、 戻し後 size diff < 100 を assert
- assert 失敗時は `emergency_esc_out` + form 再 open

### Task 2: Select RAID Level (y=128) 到達 — 採用案 A2 (ArrowUp from y=147)

検証スクリプト `tmp/iter/iter_09_explore_y128.py`:
1. form_open (cursor y=88 確定)
2. ArrowDown 1 → y=147 (Select Drives From、 既知)
3. ArrowUp 1 → screenshot → NumpadAdd probe で値変化 y を確認
4. 変化が y=128 周辺 → A2 確定
5. NumpadSubtract で値戻し → Esc

A2 否定時のフォールバック (順次試行):
- ArrowUp x2/x3
- ArrowUp from y=88 → y=411 wrap → ArrowDown x N で y=128 訪問可能性
- Tab / Shift+Tab

### Task 3: drives popup cursor 検出 — bounds 限定 detect

```python
def detect_popup_cursor_row(png_path, x_min=410, x_max=580,
                            y_min=340, y_max=560, **kw):
    return detect_active_cursor_row(png_path, x_min=x_min, x_max=x_max,
        y_min=y_min, y_max=y_max, bg_threshold=200, min_bright_cols=20,
        merge_gap=4)
```

検証スクリプト `tmp/iter/iter_10_drives_popup.py`:
- form を RAID0 default で開く → nav to Select Drives → Enter → popup open
- `detect_popup_cursor_row` で y 確認 + ArrowDown x4 で単調性確認
- bounds が想定とずれたら本検証で実測値に補正、 定数化

popup 内 cursor 検出が確立されれば `[RAID0]` cluster 問題は popup の外なので発生しない見込み (form bounds の外を見るため)。

### Task 4: RAID10 commit C1-C13 (dry-run 先行)

検証スクリプト `tmp/iter/iter_11_raid10_commit.py` を `--stop-at C<N>` 引数付きで段階実行可能に。 まず `--skip-confirm` mode で C1-C12 を通し、 C12 で Yes 押さず Esc で revert する経路を 1 周検証。 成功確認後に C12-C13 を本番 commit で実行。

| # | アクション | 期待 cursor | 検出 | 失敗時 |
|---|-----------|-----------|------|--------|
| C1 | nav AVAGO Main → Main Menu → Cfg Mgmt → Create VD | form open, y=88 | `detect_active_cursor_row` (TOP の Save Config TOP highlight は単独で誤検出なし: [RAID0] cluster は y=128) | retry |
| C2 | ArrowDown 1 → y=147 (Select Drives From) | model + size fingerprint 18474 | retry |
| C3 | ArrowUp 1 → y=128 (Select RAID Level) | `identify_form_cursor_by_probe` 特例: probe ではなく **Enter で submenu** | Task 2 フォールバック |
| C4 | RAID Level submenu: ArrowDown x5 → Enter (RAID10 select) | `detect_popup_cursor_row` + size fingerprint | size diff で確認、 不一致 Esc+retry |
| C5 | form 戻り → nav_to_y(166=Select Drives) → Enter → drives popup | `detect_popup_cursor_row` | retry |
| C6 | popup Span 0: Drive 0/1 Space toggle | screenshot diff (チェックマーク) | individual screenshot 確認 |
| C7 | nav to Apply Changes → Enter → OK dialog dismiss | size 増加 (Span 0 サマリ) | dialog dismiss x3 retry |
| C8 | form: nav_to_y(Add More Spans) → Enter | mini scout で y 確定 | RAID10 化後 form layout 変化のため C7 完了直後に mini scout を 1 回挟む |
| C9 | popup Span 1: Drive 2/3 toggle | screenshot diff | |
| C10 | Apply Changes → OK dismiss → form 戻り | size fingerprint (両 Span 確定) | |
| C11 | nav_to_y(88=Save Configuration TOP) → Enter → Confirm dialog | dialog y=216 | `detect_cursor_row` (caret detector — dialog は ► 単独) |
| C12 | Confirm dialog: NumpadAdd ([Disabled]→[Enabled]) → nav_to_y(235=Yes) → Enter | **dry-run mode**: Esc x2 で revert / **本番 mode**: Enter | OK dialog (size < 10000) |
| C13 | OK dismiss → Esc x3 → AVAGO Main 戻り | `avago_main_vds1` fingerprint | `emergency_esc_out` |

### Task 5: dispatcher 統合

`scripts/irmc-raid10-create.py` (新規):
```
args:
  --bmc-ip / --bmc-user / --bmc-pass (required)
  --session-dir <dir>    (screenshot 出力先)
  --mode {create,verify,scout,dry-run}
  --warmup-s 15
  --stop-at C<N>         (C1-C13 で停止、 debug 用)
  --skip-confirm         (C12 で commit せず Esc revert)
exit codes: 0=成功, 1=cursor 失敗, 2=size mismatch, 3=BMC login fail, 4=form open fail
```

実装: `sys.path.insert(0, "tmp/iter")` で `_util.py` 流用 (前 plan 踏襲、 本番昇格は別セッション)。

`scripts/irmc-bios-raid-setup.sh`:
- `step_S6` / `step_S7` / `step_S8` を `_legacy` リネーム + 呼出側コメントアウト
- 新 `step_S6_S8_python()` で `python3 scripts/irmc-raid10-create.py --mode create --session-dir $SESSION_DIR ...` 呼出
- S1-S5 (BMC reset, ForceOff, KVM warmup, Advanced→AVAGO 探索), S9-S10 (Save & Exit, VD verify) は bash 据置

## 実装順序

1. **Task 1 (静的)**: `_util.py` に `identify_form_cursor_by_probe()` + `detect_popup_cursor_row()` 追加 — リスク低、 静的検証で先行
2. **Task 2 (実機)**: `iter_09_explore_y128.py` 実行 (15-20 分) → A2 確定/否定
3. **Task 3 (実機)**: `iter_10_drives_popup.py` 実行 (15-20 分) → popup bounds 実測 + detect 確認
4. **Task 4 (実機 dry-run)**: `iter_11_raid10_commit.py --skip-confirm` で C1-C12 一周検証 (60 分目安)
5. **Task 4 (実機 本番)**: 同 `iter_11` を本番 commit で C1-C13 完遂 + VD0 verify
6. **Task 5**: `scripts/irmc-raid10-create.py` + `irmc-bios-raid-setup.sh` 修正 + dispatcher 検証
7. SKILL.md 「2026-05-17 #4」追記 + `raid create-r10` セル 「自動化対応」更新

## 中止判断基準 (引き継ぎレポート行き)

- iter_09 で A2 + 4 つのフォールバック全て失敗 → 中止
- iter_10 で popup detection が bounds 補正 1 回でも誤検出 → 中止
- iter_11 が C7 (Span 0 Apply) 以前で連続 3 trial 失敗 → 中止
- BMC login timeout が累計 5 回超 → 30 min cool-down 推奨、 即時中止
- 累計セッション 4 時間超 → 中止
- Add More Spans 行の位置が想定外 (mini scout で発見不可) → C7 まで完遂 + scout 結果のみレポート

引き継ぎテンプレ: `report/YYYY-MM-DD_HHMMSS_tx1320_raid10_form_cursor.md`
- `identify_form_cursor_by_probe` 採用パラメータ + 副作用観察記録
- iter_09 結論 (A2 結果 + 試したフォールバック)
- iter_10 結論 (popup bounds 実測値)
- C1-C13 達成位置
- 次セッション推奨手順

## リスク + 対策

| リスク | 影響 | 対策 |
|--------|------|------|
| C12 で誤って Yes commit (中途半端 VD) | RAID 構成破損 | dry-run mode (`--skip-confirm`) を先行で 1 周検証してから本番 commit。 復旧は `clear_configuration` (iter_05 確立済、 SKILL.md 既存) |
| BMC 過負荷 (KVM session churn) | 自動化中断 | `open_viewer` の `login_retries=3` + 30s wait 既存。 4 trial 連続失敗で即 cool-down |
| frame buffer ラグで cursor 位置ずれ | 誤キー入力 | `identify_form_cursor_by_probe` で expected_y との一致を毎 step 確認、 不一致なら 1 step ロールバック + 再 probe |
| popup bounds 実測値ずれ | popup cursor 誤検出 | iter_10 で実測してから本実装に反映、 定数化 |
| BMC ファクトリリセット禁止制約 | 復旧手段限定 | Clear Configuration (RAID NVRAM のみ reset) で済む範囲に限定。 BIOS Setup から出る前に Esc + Discard で抜ける選択肢を保持 |
| RAID10 化後の form layout 変化 (Add More Spans 位置) | C8 nav 失敗 | C7 完了直後に mini scout (ArrowDown x16 + highlight_y 記録) を 1 回挟む |
| Aptio 内部 cursor と display ずれで wrong submenu | 意図しないダイアログ | C3/C5/C8/C11 の各 Enter 前に `settle_ms=2000` + Enter 後 size fingerprint check、 想定外なら Esc x3 + retry |
| Strip Size / Read Policy 等で NumpadSubtract が異値に戻る | probe cleanup 失敗 | PROBE_SAFE_Y で対象を限定。 cleanup 失敗時は emergency_esc_out + form 再 open |

## 新規 / 修正 / 触らないファイル

### 新規
- `tmp/iter/iter_09_explore_y128.py` — Task 2 検証 (Select RAID Level 到達手段)
- `tmp/iter/iter_10_drives_popup.py` — Task 3 popup cursor bounds 検証
- `tmp/iter/iter_11_raid10_commit.py` — Task 4 C1-C13 段階実行 (`--stop-at`, `--skip-confirm`)
- `scripts/irmc-raid10-create.py` — Task 5 CLI wrapper

### 修正
- `tmp/iter/_util.py` — `identify_form_cursor_by_probe()` + `detect_popup_cursor_row()` + `PROBE_FORBIDDEN_Y` / `PROBE_SAFE_Y` 定数 + `CURSOR_Y_CREATE_VD_FORM` map 確定値
- `scripts/irmc-bios-raid-setup.sh` — `step_S6/S7/S8` を `_legacy` リネーム + `step_S6_S8_python()` 追加
- `.claude/skills/irmc-bios-raid/SKILL.md` — 「2026-05-17 #4」セクション + `raid create-r10` セル「自動化対応」更新

### 触らない
- `config/training_tx1320.yml` — `.raid_setup.*_arrowdown` 系は新コード安定後に別セッション DEPRECATED 化
- `scripts/irmc-kvm-interact.py` — pixel detection の本体統合は別セッション
- `tmp/iter/fingerprints.json` — 必要に応じて新規 fingerprint 追加のみ

## Verification

### 静的検証 (Task 1)
- `identify_form_cursor_by_probe` を既存 21 form PNG (`tmp/iter/iter07_scout_run/`) で probe path を模擬 → expected_y との一致率
- `detect_popup_cursor_row` を popup を含む PNG (`b_popup.png` 等) で誤検出 0% 確認

### 実機検証 (Task 2-5)

実機接続前に毎回:
```sh
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" BMC_PATCH_REQUIRES_ETAG=1 \
  ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 BiosSetup UEFI
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" \
  ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
sleep 5
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" POWER_ON_RESET_TYPE=On \
  ./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
sleep 75
```

Task 2: `.venv/bin/python tmp/iter/iter_09_explore_y128.py`
- 出力 `tmp/iter/iter09_run/` で y=128 到達手段の screenshot + size diff 確認

Task 3: `.venv/bin/python tmp/iter/iter_10_drives_popup.py`
- 出力 `tmp/iter/iter10_run/` で popup bounds + ArrowDown 単調性確認

Task 4 (dry-run): `.venv/bin/python tmp/iter/iter_11_raid10_commit.py --stop-at C12 --skip-confirm`
- C12 で Yes 押さず Esc revert → form 状態が clean か確認 (Clear Configuration 不要なら成功)

Task 4 (本番): `.venv/bin/python tmp/iter/iter_11_raid10_commit.py --mode create`
- F4 (Save & Exit BIOS) → 再起動 → 再度 BIOS Setup 入り → AVAGO Main → Virtual Drive Mgmt で VD0 = RAID10 / 4 drives / Span 2 を目視確認

Task 5 (dispatcher): `./scripts/irmc-bios-raid-setup.sh setup-raid10` で end-to-end (S1-S10) 動作確認 → `oplog.log` に成功 record

## 関連 Issue

- #69 (継続) — `verify` 状態のまま owner 引き継ぎ。 本セッション完遂時に close、 不完遂時は再び `verify` に戻して引き継ぎレポート参照を追記
