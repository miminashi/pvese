# SKILL.md へのFW更新知見反映レポート

- **実施日時**: 2026年2月26日 03:03

## 前提・目的

### 背景

FW 更新作業 (Issue #22) で多くの実践的知見が得られた。SKILL.md はシリアルコンソール経由の基本操作のみカバーしており、FW 管理・SSH アクセス・SM 管理・トラブルシューティングの知見が欠落していた。

### 目的

SKILL.md に FW 更新作業で得られた知見を反映し、今後の操作時に参照できるようにする。

## 対象ファイル

- `.claude/skills/ib-switch/SKILL.md`

## 実施内容

### 1. 概要テーブルの補足

- SSH 接続情報 (`port 22, 要レガシー鍵交換`) を追加
- 内蔵 SM 状態 (`active (OpenSM4.8.1)`) を追加
- MLNX-OS バージョンにビルド日付 (`2019-02-22`) を追加

### 2. 設定値の読み取りセクション

- `MGMT_IP` の読み取りを追加

### 3. 新セクション「SSH アクセス」

- mgmt0 経由の SSH 接続コマンド（レガシー鍵交換オプション付き）
- SSH サーバ情報 (mpSSH_0.2.1)
- リブート直後の認証失敗に関する注意
- 長時間操作はシリアルコンソール手動操作を推奨

### 4. 新セクション「SM 管理」

- 現在の SM 状態
- SM 診断コマンド 5 つ
- SM 有効化/無効化手順
- SM 設定の2層構造の説明
- opensm との切替手順

### 5. 新セクション「FW 管理」

- `show images` でパーティション確認
- `image fetch` でイメージ取得（HTTP サーバ経由）
- `image install` の構文（`location` を使う、`partition` は不可）
- `image boot next` でブートパーティション切替
- `write memory` で設定保存（`configuration write` は不可）
- 所要時間の目安（fetch ~5分、install ~15分、reboot ~8分）
- FW イメージ URL と MD5

### 6. 注意事項セクションへの追加 (7項目)

| 項目 | 内容 |
|------|------|
| DTR トグル | リブート後のコンソール無応答を `ser.dtr = False → True` で復帰 |
| 限定シェル `CLI >` | リブート直後に発生。`exit` → 再ログインで復帰 |
| `?` ヘルプキー | シリアル自動化で改行送信されコマンド実行される |
| 進捗バーの `#` | プロンプト検出と衝突。フルプロンプトパターンを使う |
| `show interfaces mgmt0` | enable モードが必要 |
| ping 構文 | `-c N` を使う（`count N` は不可） |
| 長時間操作 | `sx6036-console.py` のタイムアウトを超えるため手動操作推奨 |

### 7. 既存項目の修正

- 設定保存コマンドを `write memory` に統一（`configuration write` は MLNX-OS 3.6 では不可と明記）
- enable mode の説明に `show interfaces mgmt0` を追加

### 8. 参照セクション追加

FW 更新レポート、SM 調査レポート等へのリンクを追加。

## 検証結果

`config/switch-sx6036.yml` の全11フィールドおよび `memory/sx6036.md` の全項目と SKILL.md の記載が一致していることを確認。FW 更新レポートの所要時間・手順・注意事項もすべて正確に反映されている。

## 参照

- [FW 更新レポート](2026-02-26_011138_sx6036_firmware_update.md)
- [SM 調査レポート](2026-02-25_224551_sx6036_sm_investigation.md)
