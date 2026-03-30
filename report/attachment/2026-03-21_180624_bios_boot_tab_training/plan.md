# bios-setup スキル改善: Boot タブ操作訓練 (30回)

## Context

先のブートオーダー正規化セッションで、BIOS Boot タブの Boot Option 操作が複数の未知の挙動により失敗した。ドロップダウンのラップ、値スワップ、ダイアログのタイミング問題等、SKILL.md に未記載の挙動が多数発見された。4号機で30回の体系的訓練を行い、Boot タブの全挙動を解明して SKILL.md に反映する。

### 前回セッションで発覚した問題

1. **ドロップダウンがラップする** — 18項目リストで ArrowDown/Up が先頭↔末尾で循環
2. **値スワップ** — 他の Boot Option と同じ値を設定すると自動スワップ
3. **Minus キーで値サイクル** — ダイアログ不要で値変更可能だが方向・ラップが未文書化
4. **ダイアログの突然の閉鎖** — ArrowDown 10回程度でダイアログが消える現象
5. **Boot mode 誤変更** — バッチ操作で UEFI→DUAL に変わりレイアウトが激変
6. **End キー無効** — ダイアログ内でリスト末尾にジャンプ不可
7. **F2/F3 の挙動** — F2 復元不可、F3 で Boot mode が DUAL に変更

### 安全性

`efibootmgr -o 0004` 設定済みのため、BIOS Boot Option の順序に関わらず OS は起動する。訓練中に Boot Option を自由に変更しても起動に影響なし。

## 対象・前提

- **サーバ**: 4号機 (BMC: 10.10.10.24, 静的IP: 10.10.10.204)
- **pve-lock 必須** (BIOS 進入の電源操作)
- **保存しない**: 訓練中は F4 Save を押さず、最後に Escape → Exit Without Saving で終了
- スクリーンショットは `tmp/<session-id>/` に保存

## 手順

### Step 0: BIOS Setup 進入 + Boot タブ移動

```sh
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.24 -U claude -P Claude123 power off
sleep 15
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H 10.10.10.24 -U claude -P Claude123 power on
# → 80回 Delete 送信スクリプト実行 (enter_bios_4.sh)
# → ArrowRight x5 で Boot タブへ
```

### Group A: ドロップダウン挙動 (訓練 1-8)

各訓練は 1 KVM セッション、`--screenshot-each` + `--pre-screenshot` で全キー記録。

| # | 操作 | 目的 | キー |
|---|------|------|------|
| 1 | Boot タブ初期状態 | レイアウト確認、選択可能項目マップ | (Boot タブ到着後) screenshot |
| 2 | ArrowDown x10 | カーソル移動マップ、Boot Option #1 までの距離 | ArrowDown x10 (`--screenshot-each`) |
| 3 | Boot Option #5 でダイアログ開く | ダイアログ外観、可視項目数 | Enter (`--screenshot`) |
| 4 | ダイアログ内 ArrowDown x20 | ラップ挙動、何キーで一周するか | ArrowDown x20 (`--screenshot-each`) |
| 5 | ダイアログ内 ArrowUp x20 | 逆方向ラップ、0→17 のラップ確認 | ArrowUp x20 (`--screenshot-each`) |
| 6 | Escape でダイアログ閉じ | 値が変更されないことを確認 | ArrowDown x3 → Escape (`--screenshot-each`) |
| 7 | Enter で値確定 | 値変更の確認、スワップの有無 | Enter → ArrowDown x2 → Enter (`--screenshot-each`) |
| 8 | Home/End/PageUp/PageDown | ショートカットキーの動作確認 | Enter → Home → End → PageUp → PageDown (`--screenshot-each`) |

**確認ポイント**: ダイアログの可視項目数、ラップ挙動 (wrap or stop)、Escape=キャンセル確認

### Group B: +/- キー挙動 (訓練 9-14)

| # | 操作 | 目的 | キー |
|---|------|------|------|
| 9 | Boot Option #5 で Minus x3 | Minus の方向 (逆順サイクル?) | Minus x3 (`--screenshot-each`) |
| 10 | Boot Option #5 で Plus x3 | Plus の方向 (順方向?) | Plus x3 (`--screenshot-each`) ※ Playwright キー名は `Equal` + Shift? 要テスト |
| 11 | Disabled の項目 (#3) で Minus x3 | 境界でのラップ (17→16 or 17→0?) | Minus x3 (`--screenshot-each`) |
| 12 | スワップ検出テスト | 値変更が他の Boot Option に波及するか | Minus x1 → ArrowUp 数回で他のオプション値確認 |
| 13 | Minus x10 高速 (wait=200ms) | BIOS の処理速度限界 | Minus x10 (`--wait 200`) |
| 14 | Boot mode select で +/- | enum 項目での +/- 動作 (UEFI/DUAL/Legacy) | Minus x1 → screenshot → Plus x1 (即座に戻す) |

**注意**: 訓練14は Boot mode 変更リスクあり。Minus 後すぐ Plus で戻す。

### Group C: Boot Option 設定戦略 (訓練 15-22)

Group A/B の結果に基づき、確実な設定方法を確立する。

| # | 操作 | 目的 |
|---|------|------|
| 15 | ダイアログ方式で Disabled 設定 | Group A で判明した正確なキー数で Disabled 到達 |
| 16 | Minus 方式で Disabled 設定 | Group B で判明した Minus 回数で Disabled 到達 |
| 17 | Plus で特定値に設定 | UEFI USB CD/DVD 等の特定値への到達 |
| 18 | 3つ連続で Disabled 設定 | カスケード挙動の確認 |
| 19 | 複数 Disabled 共存確認 | スクリーンショットで Disabled が複数存在するか |
| 20 | スワップ明示テスト | #2 を #1 と同じ値に設定してスワップ観察 |
| 21 | Disabled 後のリスト変化 | リストが短縮されるかスクリーンショット確認 |
| 22 | BBS Priorities サブページ探索 | Boot Option 下方のサブメニュー構造調査 |

### Group D: Boot タブ構造 (訓練 23-26)

| # | 操作 | 目的 |
|---|------|------|
| 23 | ArrowDown x25 でラップポイント | 選択可能項目の総数 |
| 24 | 先頭項目から ArrowUp x3 | 上端ラップ動作 |
| 25 | 全項目スクロール観察 | ページスクロールの有無・タイミング |
| 26 | Boot mode select ダイアログ | 利用可能な値一覧 (Escape でキャンセル) |

### Group E: Save/Restore (訓練 27-30)

| # | 操作 | 目的 |
|---|------|------|
| 27 | Escape → Exit Without Saving | ダイアログ確認、Tab+Enter で No |
| 28 | F2 Previous Values | 変更した Boot Option が復元されるか |
| 29 | F3 Optimized Defaults (確認のみ) | ダイアログ表示→Escape でキャンセル |
| 30 | F4 Save & Exit (確認のみ) | ダイアログ表示→Tab+Enter でキャンセル |

### Step 終了: BIOS Exit + OS 起動確認

```sh
# Escape → Enter (Exit Without Saving → Yes) で変更を破棄
# SSH で起動確認
ssh -F ssh/config -o ConnectTimeout=10 pve4 date -u
# efibootmgr 確認
ssh -F ssh/config pve4 efibootmgr
```

## 成果物

### SKILL.md に追記する内容

1. **Boot Option ドロップダウン挙動表**: ラップ方向、可視項目数、キーバインド
2. **+/- キーリファレンス**: 方向、ラップ、速度、スワップ
3. **Boot Option 設定の推奨手順**: ダイアログ方式 vs +/- 方式の比較と推奨
4. **値スワップルール**: いつ発生するか、予測・回避方法
5. **Boot mode select 安全警告**: 変更時の影響とリカバリ
6. **F2/F3/F4 の Boot タブ挙動**

### 変更対象ファイル

- `.claude/skills/bios-setup/SKILL.md` — Boot タブセクション追記
- `.claude/skills/bios-setup/reference.md` — Boot タブ詳細の更新 (必要に応じて)
- `report/` — 訓練レポート作成

## リスク

- **リスクレベル: Low** — efibootmgr で OS 起動保証済み、保存せず終了
- 訓練14 (Boot mode +/-): 即座に戻すため影響限定的
- POST 92 スタック (4号機): ForceOff → 20秒 → Power On で回復
