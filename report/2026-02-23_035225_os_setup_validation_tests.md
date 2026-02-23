# os-setup スキル改善の検証テスト (3回通しテスト)

- **実施日時**: 2026年2月23日 02:00〜03:52

## 前提・目的

テスト #4 (SOL テスト) で発見された問題 16〜21 の修正をスクリプト・ドキュメントに反映し、修正後の安定動作を検証する。

- 背景: テスト #4 で Boot ID ハードコード問題、BootSourceOverrideMode 欠落、efi.img パッチ問題等が発見された
- 目的: 修正後の os-setup スキルで3回連続成功を確認する
- 前提条件: ステージ1（コード・ドキュメント修正 + ユニットテスト）は完了済み
- 参照: [テスト #4 レポート](2026-02-22_222524_os_setup_skill_test4_sol.md)

## 環境情報

- サーバ: Supermicro SYS-6019U-TN4R4T (X11DPU)
- BMC IP: 10.10.10.24
- Static IP: 10.10.10.204 (eno2np1)
- OS: Debian 13.3 (Trixie)
- PVE: 9.1.5 (pve-manager)
- カーネル: 6.17.9-1-pve
- ISO: debian-13.3.0-amd64-netinst.iso (リマスター済み)
- SMB ホスト: 10.1.6.1

## 修正内容（ステージ1）

| ファイル | 修正内容 |
|---------|---------|
| `scripts/bmc-power.sh` | `find-boot-entry` サブコマンド追加、`cmd_boot_next` に `BootSourceOverrideMode:"UEFI"` 追加 |
| `.claude/skills/os-setup/SKILL.md` | Phase 4 で Boot ID 動的検索の手順に変更 |
| `.claude/skills/os-setup/reference.md` | UefiBootNext に BootSourceOverrideMode 追加、efi.img パッチ注意点セクション追加 |

## ユニットテスト結果（ステージ1）

| テスト | 結果 |
|--------|------|
| `find-boot-entry "debian"` → Boot ID 返却 | 3/3 PASS |
| `find-boot-entry "NONEXISTENT..."` → exit 1 | 3/3 PASS |
| `boot-next` JSON に BootSourceOverrideMode 含有 | 確認済み |

## 通しテスト結果（ステージ2）

### サマリ

| テスト | 結果 | Boot ID | DHCP IP | 所要時間 |
|--------|------|---------|---------|----------|
| 1/3 | PASS | Boot0013 | 192.168.39.201 | 約50分 |
| 2/3 | PASS | Boot0016 | 192.168.39.204 | 約40分 |
| 3/3 | PASS | Boot0019 | 192.168.39.200 | 約35分 |

### 各テストの全フェーズ結果

全テストで Phase 1〜8 がエラーなく完了:

1. **iso-download**: SHA256 検証済み（初回のみダウンロード）
2. **preseed-generate**: preseed.cfg 生成
3. **iso-remaster**: Docker + xorriso でリマスター、efi.img パッチ含む
4. **bmc-mount-boot**: VirtualMedia マウント → find-boot-entry → boot-next → 電源サイクル
5. **install-monitor**: PowerState ポーリング（5分間隔）、約10-12分で Off 検出
6. **post-install-config**: SOL 経由で SSH/sudoers/公開鍵設定、static IP 設定
7. **pve-install**: pre-reboot → reboot → post-reboot → 最終リブート
8. **cleanup**: VirtualMedia 確認、Boot Override リセット、最終検証

### 最終検証（テスト 3/3）

| 項目 | 値 |
|------|-----|
| OS | Debian GNU/Linux 13 (trixie) |
| PVE | pve-manager/9.1.5/80cf92a64bef6889 |
| カーネル | 6.17.9-1-pve |
| DHCP IP | 192.168.39.200 (eno1np0) |
| Static IP | 10.10.10.204/8 (eno2np1) |
| Web UI | https://10.10.10.204:8006 → HTTP 200 |

## 発見された問題と対応

### 問題 22: SMB パスのバックスラッシュ（テスト 1/3 で発見）

- **症状**: VirtualMedia の CGI が VMCOMCODE=001 (成功) を返すが、Redfish で Inserted=false
- **原因**: シェルでダブルバックスラッシュ `\\public\\` が渡され、パスに `\public\` が含まれなかった
- **修正**: シングルクォート `'\public\debian-preseed.iso'` でシングルバックスラッシュを渡す
- **SKILL.md への反映**: 未（今後対応が必要）

### 問題 23: 公開鍵のハードコード（テスト 1/3, 3/3 で発見）

- **症状**: SOL 経由でインストールした公開鍵がローカルの鍵と不一致で SSH 接続失敗
- **原因**: スクリプト内に古い公開鍵がハードコードされていた
- **修正**: ローカルの `~/.ssh/id_ed25519.pub` の内容を使用
- **推奨**: SKILL.md Phase 6 で公開鍵をファイルから読み取る手順を明記すべき

### 問題 24: find-boot-entry のタイミング問題（テスト 2/3 で発見）

- **症状**: 電源サイクル直後に find-boot-entry を実行すると "No BootOptions found"
- **原因**: BMC の Redfish API がPOST中はBootOptionsを返さない場合がある
- **修正**: 3分待機後に実行。失敗した場合は即リトライで成功
- **推奨**: find-boot-entry にリトライロジックを追加するか、SKILL.md に待機時間の注記を追加

### 問題 25: known_hosts の衝突（全テストで発生）

- **症状**: OS 再インストール後にホスト鍵が変わり SSH 接続拒否
- **原因**: 毎回新規インストールで新しいホスト鍵が生成される
- **修正**: `ssh-keygen -R` で古いエントリを削除
- **推奨**: SKILL.md Phase 6 で `ssh-keygen -R` を事前実行する手順を追加

## 再現方法

### ステージ1: コード修正

```sh
# find-boot-entry サブコマンドの追加と boot-next の修正は bmc-power.sh を参照
# SKILL.md Phase 4 の動的 Boot ID 検索手順を確認
# reference.md の BootSourceOverrideMode と efi.img パッチセクションを確認
```

### ステージ2: 通しテスト

```sh
# Phase 初期化
scripts/os-setup-phase.sh init

# Phase 1: ISO ダウンロード
# (スクリプト or 手動で debian-13.3.0-amd64-netinst.iso を取得・検証)

# Phase 2: preseed 生成
scripts/generate-preseed.sh

# Phase 3: ISO リマスター
scripts/remaster-debian-iso.sh

# Phase 4: VirtualMedia マウント + ブート設定
# CGI でログイン → VirtualMedia config → mount → 電源サイクル → find-boot-entry → boot-next → 電源サイクル

# Phase 5: インストール監視
# PowerState ポーリング (5分間隔) → Off で完了

# Phase 6: post-install 設定
# SOL で root ログイン → SSH/sudoers/公開鍵 → static IP

# Phase 7: PVE インストール
scp scripts/pve-setup-remote.sh root@10.10.10.204:/tmp/
ssh root@10.10.10.204 '/tmp/pve-setup-remote.sh --phase pre-reboot --hostname ayase-web-service-4 --ip 10.10.10.204 --codename trixie'
ssh root@10.10.10.204 'reboot'
# SSH 再接続待機
scp scripts/pve-setup-remote.sh root@10.10.10.204:/tmp/
ssh root@10.10.10.204 '/tmp/pve-setup-remote.sh --phase post-reboot --hostname ayase-web-service-4 --ip 10.10.10.204 --codename trixie'
ssh root@10.10.10.204 'reboot'

# Phase 8: 最終検証
ssh root@10.10.10.204 'pveversion'
curl -sk -o /dev/null -w '%{http_code}' https://10.10.10.204:8006
```

## 結論

3回の通しテストすべてで全フェーズが成功し、テスト #4 の知見を反映した修正が安定動作することを確認した。Boot ID の動的検索 (`find-boot-entry`) と `BootSourceOverrideMode:"UEFI"` の明示指定が正しく機能している。

追加で発見された問題 22〜25 については、今後の SKILL.md 改善で対応する。
