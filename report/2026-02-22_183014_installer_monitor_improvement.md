# インストーラ監視機能の改善

- **実施日時**: 2026年2月22日 18:30 (UTC)
- **参照**: [テスト #3 レポート](2026-02-22_171020_os_setup_skill_test3.md)

## 前提・目的

os-setup スキルのテスト実行 #1〜#3 で、インストーラの状態を確認できないことが最大の課題だった。本改善ではインストーラ実行中の可視性を確保するため、以下を実施する:

- POST code 取得機能の追加（IPMI OEM コマンド）
- BMC スクリーンショット機能の調査・実装
- ISO リマスター時の efi.img 内 GRUB シリアルコンソール設定追加
- Phase 5 (install-monitor) の監視方式を3層化
- BMC ファクトリーリセット禁止ルールの明文化

### 背景

- SOL はインストール済み OS では動作するが、Debian インストーラ起動時は無出力
- BMC の iKVM はライセンス（SFT-DCMS-SINGLE）が既にアクティベート済みだが、HTML5 (noVNC) のみでサーバ側スクリーンショット API なし
- POST code (`ipmitool raw 0x30 0x70 0x02`) は動作する

## 環境情報

- サーバ: Supermicro SYS-6019U-TN4R4T (X11DPU)
- BMC IP: 10.10.10.24 (User: claude)
- BMC ファームウェア: HTML5 iKVM (noVNC) ベース
- DCMS ライセンス: アクティベート済み
- サーバ状態: PowerState On

## 成果物

| # | ファイル | 操作 | 概要 |
|---|---------|------|------|
| 1 | `CLAUDE.md` | 更新 | BMC factory reset 禁止ルール追加 |
| 2 | `scripts/bmc-power.sh` | 更新 | `postcode` サブコマンド追加（28コードの説明付き） |
| 3 | `scripts/bmc-screenshot.sh` | 新規 | BMC スクリーンショット取得（404 検出 + 代替手段案内） |
| 4 | `scripts/remaster-debian-iso.sh` | 更新 | efi.img 内 GRUB にシリアル設定追加（Option A/B フォールバック） |
| 5 | `.claude/skills/os-setup/SKILL.md` | 更新 | Phase 5 を3層監視に書き換え |
| 6 | `.claude/skills/os-setup/reference.md` | 更新 | POST code テーブル（28エントリ）追加 |
| 7 | `.claude/settings.local.json` | 更新 | `bmc-screenshot.sh` の permission 追加 |

## テスト結果

### POST code 取得

```sh
/home/ubuntu/projects/pvese/scripts/bmc-power.sh postcode 10.10.10.24 claude Claude123
# => 0x01 SEC: Power on, reset detected
```

- **結果**: OK — POST code を正しく取得し、説明テキストを付与
- **備考**: OS 稼働中は POST code レジスタが SEC フェーズの値（0x01）を保持する。起動中の遷移監視が主目的

### BMC スクリーンショット

```sh
/home/ubuntu/projects/pvese/scripts/bmc-screenshot.sh 10.10.10.24 /tmp/bmc-cookie-test "$CSRF" /tmp/test.bmp
# => ERROR: CapturePreview.cgi not found (HTTP 404)
```

- **結果**: 非対応 — X11DPU の BMC には `CapturePreview.cgi` エンドポイントが存在しない
- **原因**: この BMC は HTML5 iKVM (noVNC over WebSocket) ベースで、サーバ側スクリーンショット API を持たない
- **対応**: スクリプトは 404 を検出し、代替手段（POST code、SOL、ブラウザ経由 iKVM）を案内

### DCMS ライセンス確認

```sh
curl -sk ... "https://10.10.10.24/cgi/url_redirect.cgi?url_name=misc_license"
# => PageInit() 内で license_activated() が呼ばれている
```

- **結果**: 既にアクティベート済み（いつ有効化されたかは不明）
- **備考**: Web UI の形式は 6x4文字の hex キー（OOB-LIC 形式）。ユーザ提供のキーは base64 形式（X11 DCMS 形式）で別フォーマット

### remaster-debian-iso.sh（構文チェックのみ）

```sh
sh -n scripts/remaster-debian-iso.sh
# => OK
```

- **結果**: 構文チェック OK
- **未検証**: efi.img パッチの実動作は次回の OS インストール（テスト #4）で統合テストとして検証予定

## 再現方法

### POST code 取得テスト

```sh
scripts/bmc-power.sh postcode 10.10.10.24 claude Claude123
```

### スクリーンショットテスト

```sh
scripts/bmc-session.sh login 10.10.10.24 claude Claude123 /tmp/bmc-cookie
CSRF=$(scripts/bmc-session.sh csrf 10.10.10.24 /tmp/bmc-cookie)
scripts/bmc-screenshot.sh 10.10.10.24 /tmp/bmc-cookie "$CSRF"
```

### ISO リマスター（efi.img シリアル設定付き）

```sh
scripts/remaster-debian-iso.sh /var/samba/public/debian-13.3.0-amd64-netinst.iso preseed/preseed-generated.cfg /var/samba/public/debian-preseed.iso
```

Docker コンテナ内で mtools を使い efi.img 内の grub.cfg にシリアル設定を注入する。空き容量不足の場合は grub-mkstandalone で efi.img を再構築（Option B フォールバック）。

## 発見事項

### BMC スクリーンショット API の不在

X11DPU の BMC は以下のスクリーンショット関連エンドポイントをすべて持たない:

- `CapturePreview.cgi` → 404
- Redfish `Actions` → `Manager.Reset` のみ、キャプチャ系なし
- `op.cgi` + `capture_preview` → 500

HTML5 iKVM の `screenshot.js` は html2canvas（クライアント側 HTML canvas キャプチャ）であり、サーバ側 API ではない。

### POST code の挙動

- OS 稼働中: `0x01` (SEC: Power on) を返す。POST 完了後は POST code レジスタが意味ある値を保持しない
- 起動中: 0x01 → 0x19 → 0x2B → ... → 0x92 → ... → 0xE0 と遷移する（想定）
- 電源 Off: 未テスト（現在サーバ稼働中のため）

## 残課題

1. **SOL テスト**: efi.img のシリアル設定が SOL 出力に効くかは、次回 ISO ブート時に検証
2. **POST code 起動遷移テスト**: サーバの次回起動時に POST code の遷移をポーリングで確認
3. **統合テスト**: 改善後のスクリプト群で OS インストールを再実行（テスト #4）
