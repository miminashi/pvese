# OS セットアップスキル テスト実行 #2

- **実施日時**: 2026年2月22日 13:11〜14:48 (UTC)
- **参照**: [テスト #1 レポート](2026-02-22_131114_os_setup_skill_test1.md)

## 前提・目的

テスト #1 で発見された7件の問題を修正した後、`/os-setup` スキルの2回目のフルテスト実行。修正が正しく動作するか検証し、新たな問題を発見する。

## 環境情報

- サーバ: Supermicro SYS-6019U-TN4R4T (X11DPU)
- BMC IP: 10.10.10.24
- サーバ IP: 10.10.10.204 (static), 192.168.39.200 (DHCP, 前回から変更)
- NIC: eno1np0 (DHCP), eno2np1 (static 10.10.10.204/8)
- ターゲットディスク: /dev/nvme0n1
- OS: Debian 13.3 (Trixie) → PVE 9.1.5
- カーネル: 6.17.9-1-pve

## 結果

**成功**: Debian 13 + PVE 9 のインストール完了。SSH 接続可能、Web UI (https://10.10.10.204:8006) 200 OK。

## テスト #1 修正の検証

### 修正済み問題の再テスト結果

| # | テスト #1 問題 | テスト #2 結果 |
|---|---------------|---------------|
| 1 | VirtualMedia CGI 404 | **OK** — `cgi/op.cgi` で正常動作 |
| 2 | Boot Override Cd 不一致 | **OK** — boot-next Boot0011 で CD ブート成功 |
| 3 | SOL シリアル出力なし | **未解決** — 引き続き SOL に出力なし（PowerState ポーリングで監視） |
| 4 | late_command 失敗 | **修正確認** — `true` に変更したことで finish-install が成功 |
| 5 | poweroff 未動作 | **修正確認** — 約7分で PowerState Off（finish-install 成功による副次効果） |
| 6 | cdrom リポジトリエラー | **OK** — `sed` で cdrom 行削除が動作 |
| 7 | /etc/hosts 重複 | **OK** — `grep -q` チェックが動作 |

## 新たに発見した問題と修正

### 問題 8: boot-next がサーバ Off 時に失敗

- **症状**: VirtualMedia マウント後、サーバ Off の状態で `boot-next Boot0011` を設定してから cycle しても、Boot0011 が BootOptions に存在しないためインストーラが起動しない
- **原因**: UEFI BootOption `Boot0011` (ATEN Virtual CDROM) は POST で VirtualMedia デバイスを列挙した後にのみ出現する。サーバが Off の状態では BootOptions に含まれない
- **修正**: Phase 4 の手順を変更 — VirtualMedia マウント → サーバ On → POST 完了待ち(約2分) → boot-next 設定 → cycle
- **修正ファイル**: `SKILL.md` Phase 4、`reference.md` UefiBootNext セクション

### 問題 9: preseed late_command の \n が finish-install を壊す (テスト #2 初回試行で発見)

- **症状**: インストーラが finish-install フェーズでエラーコード 2 を返し、メインメニューに戻る
- **原因**: preseed.cfg.template の late_command に `printf "...\n..."` が含まれており、preseed パーサーが `\n` を改行として展開した結果、sh の構文エラー（"unterminated quoted string"）が発生
- **修正**: late_command を `d-i preseed/late_command string true` に変更（複雑なコマンドは Phase 6 で SOL 経由実行）
- **修正ファイル**: `preseed/preseed.cfg.template`
- **備考**: この修正により問題 5 (poweroff 未動作) も同時に解決した。finish-install が正常完了することで poweroff が正しく実行されるようになった

### 問題 10: 最終リブート後にネットワーク到達不能が長時間続く

- **症状**: Phase 7 post-reboot 完了後の `reboot` コマンド実行後、5分以上 static IP/DHCP IP 両方に ping が通らない
- **原因**: VirtualMedia が STATUS=255 の異常状態で、ブートシーケンスが遅延した可能性
- **回避策**: VirtualMedia umount + BMC 経由 power cycle で回復
- **修正**: SKILL.md Phase 7 に「5分超過時は BMC で power cycle を試す」注記を追加

## 修正ファイル一覧

| ファイル | 修正内容 |
|---------|---------|
| `preseed/preseed.cfg.template` | late_command を `true` に変更 |
| `.claude/skills/os-setup/SKILL.md` | Phase 4: boot-next シーケンス修正、Phase 7: リブート回復手順追記 |
| `.claude/skills/os-setup/reference.md` | UefiBootNext の BootOptions 列挙要件を追記 |

## フェーズ所要時間（概算）

| Phase | 時間 | 備考 |
|-------|------|------|
| 1 iso-download | 0分 | ダウンロード済み |
| 2 preseed-generate | 1分 | |
| 3 iso-remaster | 2分 | |
| 4 bmc-mount-boot | 5分 | boot-next シーケンス変更 |
| 5 install-monitor | 7分 | poweroff 正常動作 |
| 6 post-install-config | 10分 | SOL 経由設定 |
| 7 pve-install | 25分 | post-reboot 含む |
| 8 cleanup | 5分 | VirtualMedia 異常状態の回復含む |
| **合計** | **約55分** | テスト #1 (93分) から大幅短縮 |

## テスト #1 との比較

| 項目 | テスト #1 | テスト #2 |
|------|----------|----------|
| 所要時間 | 約93分 | 約55分 |
| 新発見問題数 | 7件 | 3件 |
| 手動介入回数 | 多数 | 3回（boot-next 再試行、preseed 修正後再実行、power cycle） |
| poweroff 動作 | 失敗（45分待ち→ForceOff） | 成功（7分で Off） |
| finish-install | 初回失敗 → late_command 修正後成功 | 成功 |
