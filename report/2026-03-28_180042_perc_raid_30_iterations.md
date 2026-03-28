# PERC H710 RAID 操作 30 回反復レポート

- **実施日時**: 2026年3月29日 03:00 (JST)

## 前提・目的

perc-raid スキルの信頼性を検証するため、PERC H710 BIOS の VD 作成・削除を 30 回繰り返し実行。
段階的に複雑化し、操作手順の安定性・再現性を確立する。

- **対象**: 8号機 (Dell PowerEdge R320, iDRAC7, PERC H710 Mini)
- **方式**: VNC (RFB 3.008) 経由のキーストローク操作 (単一セッション Python スクリプト)

## 環境情報

- iDRAC FW: 2.65.65.65
- PERC H710 Mini FW: 4.04-0001
- VNC: port 5901, password Claude1
- PD: 7本 (Bay 0-6), うち Bay 3 は Blocked

## 結果サマリ

| Phase | Rounds | 操作 | 結果 |
|-------|--------|------|------|
| 1 | 1-5 | RAID-0/1/5 基本 Create/Delete | ✅ 全成功 |
| 2a | 6-10 | VD Name, RAID-6, 設定オプション | ✅ 全成功 |
| 2b | 11-15 | Multi-VD, Clear Config, Rebuild | ✅ 全成功 |
| 3 | 16-25 | 高速サイクル (全 RAID レベル) | ✅ 全成功 (再接続 2 回) |
| 4 | 26-30 | 文書検証 + 最終構成 | ✅ 全成功 |

**30/30 成功。VNC 自動再接続は合計 5 回発生し、全て自動復旧。**

## 発見・修正した問題

### 1. Tab x5 → Tab x4 修正
**問題**: Create VD フォームの OK ボタンは Tab x5 ではなく Tab x4 で到達。
**原因**: Tab 順序は VD Size(1) → VD Name(2) → Advanced Settings(3) → **OK(4)** → CANCEL(5)。
**修正**: スキルの操作手順を Tab x4 に更新。

### 2. VNC stale framebuffer
**問題**: VNC 再接続後のスクリーンショットが古いフレームを返す。
**原因**: iDRAC7 BMC のビデオキャプチャが VNC 切断後に停止。
**対策**: (1) 単一セッション Python スクリプトで全操作を完結、(2) racreset で VNC リセット。

### 3. F2 メニュー初期カーソル位置の不安定性
**問題**: VD 行の F2 メニューの初期カーソルが Consistency Check ではないことがある。
**対策**: ArrowUp x5 (メニュー先頭) → ArrowDown x2 で Delete VD に確実到達。

### 4. ツリーの循環ラッピング
**問題**: ArrowUp x N がツリーアイテム数と一致すると元の位置に戻る。
**対策**: ArrowUp x20 (大きな数) でルートで停止する方式に変更。

### 5. VNC 接続の ~80 秒制限
**問題**: 約 80 秒後に VNC 接続が切断される。
**対策**: safe_key() メソッドで自動再接続。再接続後もキー入力は正常動作。

## 検証済み操作一覧

| 操作 | 検証回 |
|------|--------|
| RAID-0 (1PD) Create/Delete | 1, 19, 26 |
| RAID-0 (2PD) Create/Delete | 2, 20 |
| RAID-0 (3PD) Create/Delete | 25 |
| RAID-1 (2PD) Create/Delete | 3, 18, 23, 28 |
| RAID-5 (3PD) Create/Delete | 4, 6, 7, 8, 9, 13, 16, 21, 27 |
| RAID-5 (4PD) Create/Delete | 5, 17, 24 |
| RAID-6 (4PD) Create/Delete | 10, 22, 29 |
| VD Name 設定 | 6 |
| Multi-VD (RAID-0 x2) | 11 |
| Multi-VD 削除 (VD2→VD1) | 12 |
| Clear Config (全 VD 削除) | 14 |
| VD0 再構築 (Clear Config 後) | 15 |
| 最終構成構築 (RAID-5 4PD) | 30 |
