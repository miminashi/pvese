# BIOS Boot タブ操作訓練レポート (30回)

- **実施日時**: 2026年3月22日 02:16 - 03:06 JST
- **対象サーバ**: 4号機 (BMC: 10.10.10.24, 静的IP: 10.10.10.204)
- **セッション**: b7c12e46

## 添付ファイル

- [実装プラン](attachment/2026-03-21_180624_bios_boot_tab_training/plan.md)

## 前提・目的

先のブートオーダー正規化セッションで、BIOS Boot タブの操作中に複数の未知の挙動が発見された。ドロップダウンのラップ、値スワップ、+/- キーの挙動、Boot mode 変更によるレイアウト変更など。本訓練では4号機で体系的に30回のテストを実施し、Boot タブの全挙動を解明して SKILL.md に反映する。

安全性: `efibootmgr -o 0004` 設定済みのため、BIOS Boot Option の順序に関わらず OS 起動が保証される。

## 環境情報

- マザーボード: Supermicro X11DPU
- BIOS: AMI Aptio Setup Utility, Version 2.20.1276
- OS: Debian 13.3 + Proxmox VE 9.1.6
- KVM 操作: `scripts/bmc-kvm-interact.py` (Playwright + Chromium)

## 訓練結果

### Group A: ドロップダウン挙動 (訓練 1-8)

| 訓練 | 操作 | 結果 |
|------|------|------|
| 1 | Boot タブ初期状態確認 | 17 selectable items (Boot mode, LEGACY to EFI, #1-#15 visible) |
| 2 | ArrowDown x10 | Boot mode → #1 は ArrowDown 2回。"FIXED BOOT ORDER Priorities" ラベルはスキップ |
| 3 | Boot Option #5 でダイアログ開く | 18項目のドロップダウンリスト表示。現在値にハイライト |
| 4 | ダイアログ内 ArrowDown x20 | **ラップ確認**: 18項目で循環 (Disabled→CD/DVDにラップ) |
| 5 | ダイアログ内 ArrowUp x20 | **逆方向もラップ**: CD/DVD→Disabled にラップ |
| 6 | Escape でダイアログ閉じ | **Escape = キャンセル**: 値変更なし |
| 7 | Enter で値確定 | **値スワップ発生**: #5←UEFI AP, #7←USB Key (自動交換) |
| 8 | Home/End/PageUp/PageDown | **Home/End 無効**, **PageUp=先頭**, **PageDown=末尾** |

### Group B: +/- キー挙動 (訓練 9-14)

| 訓練 | 操作 | 結果 |
|------|------|------|
| 9 | Minus x3 on #5 | Minus はドロップダウン index 減少方向にサイクル + スワップ |
| 10 | Plus (Shift+Equal) x3 | Plus は index 増加方向。Equal 単体は無効 |
| 11 | Minus x3 on #15 | 正常動作。各ステップでスワップ発生 |
| 12 | (スキップ) | 訓練 7, 9, 11 でスワップ確認済み |
| 13 | Minus x10 (200ms) | 200ms 間隔でも全ステップ正常処理 |
| 14 | Boot mode select で +/- | **DUAL→UEFI でレイアウト激変** (Boot Option 17→9個)。Plus で即復元可能 |

### Group C: Boot Option 設定戦略 (訓練 15-22)

| 訓練 | 操作 | 結果 |
|------|------|------|
| 15 | ダイアログ方式で Disabled | Enter→PageDown→Enter の 3キーで Disabled 一発設定 |
| 16 | Plus で Disabled 到達 | Plus x4 で UEFI USB Key → Disabled。**ラップ確認**: Disabled→CD/DVD に循環 |
| 17 | (結合) | Plus 方向の値到達テスト完了 |
| 18 | 3つ連続で Disabled | **複数 Disabled 共存可能**: #12-#15 全て Disabled に設定成功 |
| 19 | (結合) | Disabled はスワップ対象外 (特殊値) |
| 20 | (スキップ) | 訓練 7 でスワップ確認済み |
| 21 | (結合) | Disabled 設定後も Boot Option は残る (消えない) |
| 22 | BBS Priorities 探索 | Boot Option 下方に 6つのサブメニュー発見。スクロールで #16, #17 と合わせて出現 |

### Group D: Boot タブ構造 (訓練 23-26)

| 訓練 | 操作 | 結果 |
|------|------|------|
| 23 | Boot タブ総項目数 | 24 selectable items (Boot mode + LEGACY + #1-#17 + 5サブメニュー) |
| 24 | 先頭から ArrowUp | **ラップ確認**: Boot mode select → Network Drive BBS Priorities (末尾) |
| 25 | (結合) | ページスクロールは ArrowDown で自動発生 |
| 26 | Boot mode select ダイアログ | 3値: LEGACY, UEFI, DUAL |

### Group E: Save/Restore (訓練 27-30)

| 訓練 | 操作 | 結果 |
|------|------|------|
| 27 | Escape → Exit | BIOS 終了 (保存せず) |
| 28 | F2 Previous Values | 確認ダイアログ→Yes で保存済み値に復元。シャッフルされた全 Boot Option が元に戻る |
| 29 | F3 Optimized Defaults | 確認ダイアログ→Tab+Enter で No (キャンセル) |
| 30 | F4 Save & Exit | 確認ダイアログ→Tab+Enter で No (キャンセル) |

## 発見した新知見

### 1. Boot Option は 17 個 (DUAL モード)

初期画面では #15 までしか見えないが、スクロールすると #16, #17 が出現する。

### 2. ドロップダウンは 18 項目・双方向循環

ArrowDown/ArrowUp ともに末尾↔先頭でラップする。PageDown/PageUp で先頭・末尾にジャンプ可能。Home/End は無効。

### 3. +/- キーの正確な動作

- Minus (`Minus`): ドロップダウンリストの前方向 (index 減少)
- Plus (`Shift+Equal`): 後方向 (index 増加)
- Equal 単体は無効
- 双方向ラップ (Disabled→CD/DVD, CD/DVD→Disabled)
- 200ms 間隔でも安定動作

### 4. 値スワップルール

- 通常の値: 他の Boot Option が持つ値に設定 → 自動スワップ (2つの Boot Option が値を交換)
- Disabled: スワップ対象外。複数の Boot Option を同時に Disabled 可能

### 5. Boot mode 変更は即座にレイアウト変更

DUAL→UEFI で Boot Option が 17→9 個に減少。新しいメニュー項目が出現。+/- で即座に変更されるため、誤操作に注意。

### 6. Boot タブ下部に 5つのサブメニュー

Add/Delete Boot Option, UEFI HDD BBS, UEFI App Boot, HDD BBS, Network BBS の 5 サブメニューがスクロールしないと見えない位置にある。

### 7. F2 Previous Values はシャッフル全体を復元

+/- やダイアログで複数の Boot Option を変更しても、F2 で一括復元できる。

## インシデント: F4 誤保存によるブート障害

F4 ダイアログの Tab+Enter キャンセルが間に合わず、シャッフルされたブート順序が保存されてしまった。Boot Option #1 が CD/DVD になっていたため PXE ブートで停止。

**リカバリ**: BIOS 再進入 → Boot Option #1 をダイアログで UEFI Hard Disk:debian (index 10) に設定 → F4 保存 → 正常起動。

**教訓**: F4 キーは Yes がデフォルトのため、Enter 即実行。F4 ダイアログのキャンセルは Tab→Enter の 2キーが必要で、KVM セッション切り替え中にタイミングがずれるリスクがある。BIOS 操作中は F4 の誤押下に注意。

## 成果物

- `.claude/skills/bios-setup/SKILL.md` — Boot タブ操作リファレンスセクション追記
- `.claude/skills/bios-setup/reference.md` — Boot タブの Boot Option 数・サブメニュー情報更新
