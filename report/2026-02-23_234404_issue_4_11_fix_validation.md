# 課題 #4-#11 修正 + 3回通しテスト検証

- **実施日時**: 2026年2月23日 18:00〜23:44

## 前提・目的

通しテスト3回（テスト #5, #6, #7 相当）で発見された8件の課題を修正し、3回の通しテストで検証する。

- 背景: os-setup スキルの通しテスト3回で計8件の課題（#4-#11）が報告された
- 目的: 全課題を修正し、3回連続の通しテスト成功で安定動作を確認する
- 前提条件: 課題 #16-#21（前回ラウンド）の修正は完了済み
- 参照: [前回の検証テストレポート](2026-02-23_035225_os_setup_validation_tests.md)

## 環境情報

- サーバ: Supermicro SYS-6019U-TN4R4T (X11DPU)
- BMC IP: 10.10.10.24
- Static IP: 10.10.10.204 (eno2np1)
- OS: Debian 13.3 (Trixie)
- PVE: 9.1.5 (pve-manager)
- カーネル: 6.17.9-1-pve
- ISO: debian-13.3.0-amd64-netinst.iso (リマスター済み)
- SMB ホスト: 10.1.6.1

## 修正内容

### 実装順序: #6 → #4 → #10 → #5 → #7 → #8 → #9 → #11

| 課題 | ファイル | 種別 | 修正内容 |
|------|---------|------|---------|
| #6 | `pve-lock.sh` | 新規作成 | flock ベースの排他制御スクリプト（status/run/wait） |
| #4 | `scripts/remaster-debian-iso.sh` | スクリプト修正 | 引数3つの相対→絶対パス変換を追加 |
| #10 | `scripts/pve-setup-remote.sh` | スクリプト修正 | `/etc/default/locale` 設定追加（Perl locale 警告修正） |
| #5 | `CLAUDE.md` | ドキュメント修正 | `oplog.sh` → `./oplog.sh` パス統一（4箇所） |
| #7 | `.claude/skills/os-setup/SKILL.md` | ドキュメント修正 | Phase 7 完了マーク強調 + Phase 8 前提チェック追加 |
| #8 | `.claude/skills/os-setup/SKILL.md` | ドキュメント修正 | SOL バックグラウンド監視を非推奨に変更 |
| #9 | `.claude/skills/os-setup/SKILL.md` | ドキュメント修正 | SSH 再接続待ち時間の目安追加 |
| #11 | `.claude/skills/os-setup/SKILL.md` | ドキュメント修正 | インストール最大待機時間の目安追加 |

### pve-lock.sh (#6) の詳細

- API: `status` / `run <cmd...>` / `wait [--timeout N] <cmd...>`
- `flock` ベース（`state/.pve-lock` にロックファイル）
- 子プロセスへの fd 継承防止: `"$@" 9>&-`（ユニットテストで発見・修正）

### remaster-debian-iso.sh (#4) の詳細

```sh
case "$ORIG_ISO" in /*) ;; *) ORIG_ISO="$(cd "$(dirname "$ORIG_ISO")" && pwd)/$(basename "$ORIG_ISO")" ;; esac
```
POSIX sh 互換の相対→絶対パス変換（`realpath` 不使用）。3引数すべてに適用。

### pve-setup-remote.sh (#10) の詳細

```sh
printf 'LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\n' > /etc/default/locale
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
```
locale-gen 済みだが `/etc/default/locale` 未設定のため SSH セッションで warning が出ていた。

## ユニットテスト結果

| テスト | 結果 |
|--------|------|
| pve-lock.sh `status` → "unlocked" | PASS |
| pve-lock.sh `run echo test` → "test", exit 0 | PASS |
| pve-lock.sh ロック競合（`run sleep &` → 別の `run` がエラー） | PASS |
| pve-lock.sh `wait --timeout 2` タイムアウト | PASS |
| pve-lock.sh `wait --timeout 10` ロック解放後に成功 | PASS |
| remaster-debian-iso.sh 相対パス解決 | PASS |
| pve-setup-remote.sh diff 確認 | PASS |
| ドキュメント diff 確認 | PASS |

### pve-lock.sh fd 継承バグの発見と修正

ユニットテストでロック競合テスト中に、子プロセス (`sleep`) が親シェルの fd 9（ロックファイルディスクリプタ）を継承し、親を kill してもロックが解放されない問題を発見。`"$@" 9>&-` で子プロセスの fd 9 をクローズすることで修正。

## 通しテスト結果（3回）

### Run 1

| Phase | 結果 | 所要時間 | 備考 |
|-------|------|---------|------|
| 1 (iso-download) | OK | - | キャッシュ済み |
| 2 (preseed-generate) | OK | - | |
| 3 (iso-remaster) | OK | - | 相対パス `preseed/preseed-generated.cfg` で成功（#4 検証 OK） |
| 4 (bmc-mount-boot) | OK | - | |
| 5 (install-monitor) | OK | ~11分 | 目安 10-12分内（#11 検証 OK） |
| 6 (post-install-config) | OK | - | SOL ログイン、SSH 設定、locale 設定 |
| 7 (pve-install) | OK | - | SSH 再接続: 138s/165s、locale 警告なし（#9, #10 検証 OK） |
| 8 (cleanup) | OK | - | 前提チェック通過（#7 検証 OK） |

### Run 2

| Phase | 結果 | 所要時間 | 備考 |
|-------|------|---------|------|
| 1 (iso-download) | OK | - | キャッシュ済み |
| 2 (preseed-generate) | OK | - | |
| 3 (iso-remaster) | OK | - | 相対パスで成功 |
| 4 (bmc-mount-boot) | OK | - | |
| 5 (install-monitor) | OK | ~12分 | 目安内 |
| 6 (post-install-config) | OK | - | |
| 7 (pve-install) | OK | - | SSH 再接続: 105s/134s、locale 警告なし |
| 8 (cleanup) | OK | - | 前提チェック通過 |

### Run 3

| Phase | 結果 | 所要時間 | 備考 |
|-------|------|---------|------|
| 1 (iso-download) | OK | - | キャッシュ済み |
| 2 (preseed-generate) | OK | - | |
| 3 (iso-remaster) | OK | - | 相対パスで成功 |
| 4 (bmc-mount-boot) | OK | - | 停電から復帰、VirtualMedia 再設定で回復 |
| 5 (install-monitor) | OK | ~11分 | 目安内 |
| 6 (post-install-config) | OK | - | |
| 7 (pve-install) | OK | - | SSH 再接続: 104s/132s、locale 警告なし |
| 8 (cleanup) | OK | - | 前提チェック通過 |

### 課題別検証サマリー

| 課題 | 検証ポイント | Run 1 | Run 2 | Run 3 |
|------|------------|-------|-------|-------|
| #4 | 相対パスの ISO リマスター成功 | OK | OK | OK |
| #5 | `./oplog.sh` で command not found なし | OK | OK | OK |
| #6 | pve-lock.sh がエラーなく動作 | OK | OK | OK |
| #7 | Phase 8 前提チェック通過 | OK | OK | OK |
| #8 | SOL バックグラウンド起動なし | OK | OK | OK |
| #9 | SSH 再接続が目安時間内 | OK | OK | OK |
| #10 | locale 警告なし | OK | OK | OK |
| #11 | インストール時間が目安内 | OK | OK | OK |

### 特記事項

- **Run 3 停電復帰**: Phase 4 実行中に停電が発生。復帰後、VirtualMedia は自動アンマウントされていた (STATUS=255)。Boot ID が変化 (Boot001C → Boot000E) していたが、動的検索で対応。VirtualMedia 再設定・再マウント後、正常に再開。

## 再現方法

1. 課題 #4-#11 の修正を適用（上記修正内容参照）
2. os-setup スキルの Phase 1-8 を実行
3. 各フェーズの検証ポイントを確認

## 結論

8件すべての課題が修正され、3回の通しテストで安定動作が確認された。Run 3 では停電という外部要因があったが、復旧手順により問題なく完了した。全課題のステータスを done に更新した。
