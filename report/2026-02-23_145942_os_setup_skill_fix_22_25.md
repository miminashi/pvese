# OS Setup スキル修正 (問題 22〜25) — 検証レポート

- 日時: 2026-02-23
- 作業者: Claude Code
- 種別: バグ修正 + 検証

## 概要

ステージ2 通しテストで発見された問題 22〜25 を SKILL.md と bmc-power.sh に修正し、3回の通しテストで検証した。

## 修正内容

| # | 問題 | 修正ファイル | 修正概要 |
|---|------|-------------|---------|
| 22 | SMB パスのダブルバックスラッシュ | SKILL.md | yq 展開後の `$SMB_SHARE` + シングルクォート `'\debian-preseed.iso'` で正しいパス構築 |
| 23 | SSH 公開鍵のハードコード | SKILL.md | `<SSH_PUBKEY>` プレースホルダー + Read ツールで毎回読み取る旨の注記追加 |
| 24 | find-boot-entry タイミング問題 | bmc-power.sh, SKILL.md | 最大3回・30秒間隔のリトライループ追加 |
| 25 | known_hosts の衝突 | SKILL.md | Phase 6 に `ssh-keygen -R` ステップを挿入 |

## 検証結果

### ステージ1: ユニットテスト

| テスト | 結果 |
|--------|------|
| `find-boot-entry "debian"` (正常系) | Pass — Boot0017 を即座に返却 |
| `find-boot-entry "NONEXISTENT"` (異常系) | Pass — 3回リトライ後 exit 1 |

### ステージ2: OS インストール通しテスト (3回)

| 回 | DHCP IP | Boot ID | リトライ | OS | PVE | Web UI |
|----|---------|---------|---------|-----|-----|--------|
| 1 | 192.168.39.203 | Boot0019 | 1回 | Debian 13.3 | 9.1.5 | HTTP 200 |
| 2 | 192.168.39.201 | Boot001C | 1回 | Debian 13.3 | 9.1.5 | HTTP 200 |
| 3 | 192.168.39.202 | Boot001C | 1回 | Debian 13.3 | 9.1.5 | HTTP 200 |

### 修正別の検証

- **問題 22**: 3/3 で VirtualMedia マウント成功（`VMCOMCODE=001`）
- **問題 23**: 3/3 で SSH 公開鍵を Read ツールから読み取り、SOL 経由で設定
- **問題 24**: 3/3 で `find-boot-entry` のリトライが発動。初回は BootOptions 未列挙、30秒後の2回目で検出
- **問題 25**: 3/3 で `ssh-keygen -R` により古いホスト鍵を削除、SSH 接続エラーなし

## 特記事項

- `find-boot-entry` のリトライは全3回で必要だった（初回は常に失敗）。この修正がなければ 3/3 で手動介入が必要だった
- DHCP IP は毎回変動（.201, .202, .203）。SOL 経由の IP 確認が必須
- Boot ID も OS 再インストール後に変動（Boot0019 → Boot001C）。動的検索の重要性を再確認

## 変更ファイル

- `.claude/skills/os-setup/SKILL.md` — 問題 22, 23, 24, 25 の修正
- `scripts/bmc-power.sh` — 問題 24 (find-boot-entry リトライ)
