# R320 VNC 修正知見のドキュメント反映 + preseed 完全自動インストールテスト

- **実施日時**: 2026年3月5日 18:30
- **前回レポート**: [R320 VNC ブランク画面修正](2026-03-05_174316_r320_vnc_blank_screen_fix.md)

## 前提・目的

前回セッション (17a03196) で発見した R320 iDRAC7 VNC の知見をドキュメントに反映し、
修正済み preseed (`apt-setup/cdrom/set-double boolean false` 追加) での完全自動インストールを検証する。

### 背景

1. `vga=788` (VESA 800x600) は iDRAC7 VNC ポート 5901 と非互換 → `vga=normal nomodeset` で解決
2. preseed の initrd 注入（cpio 連結）は iDRAC7 VNC で d-i TUI を壊す → `preseed/file=/cdrom/preseed.cfg` 方式に変更
3. `apt-setup/cdrom/set-double boolean false` が必要（`set-next` だけでは不十分）

### 目的

- 上記知見を os-setup スキル、idrac7 スキル、preseed テンプレートに反映
- 修正済み preseed で「Scan extra installation media?」ダイアログが表示されず完全自動インストールが完了することを確認

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | 7号機 (DELL PowerEdge R320) |
| iDRAC | FW 2.65.65.65, IP 10.10.10.120 |
| VNC | ポート 5901, パスワード Claude1 |
| ISO | Debian 13.3 amd64 netinst (リマスター済み) |
| preseed | preseed/preseed-server7.cfg |
| リマスターモード | --legacy-only (EFI パッチスキップ) |

## 変更内容

### 変更1: os-setup SKILL.md Phase 3 更新

Phase 3 (iso-remaster) に 7号機固有の注意事項を追記:
- `--legacy-only` フラグ使用
- `vga=normal nomodeset` 必須
- initrd 注入禁止、`preseed/file=/cdrom/preseed.cfg` のみ
- server7 用 preseed は手動管理

### 変更2: os-setup reference.md ISO リマスターセクション更新

ISO リマスター手順を現在のスクリプト実装に合わせて更新:
- initrd 注入 → preseed/file 方式に記述変更
- 7号機固有設定セクション追加

### 変更3: idrac7 SKILL.md VNC セクション追加

`## 既知の失敗パターン` の前に VNC セクションを新規追加:
- 接続情報（ポート、プロトコル、認証）
- VGA モード非互換の詳細と解決策
- VNC スクリーンアイドルの説明

### 変更4: preseed テンプレートコメント追加

`preseed/preseed.cfg.template` 末尾に server7 用 preseed との違いを示すコメントを追加。

## 再現方法（実地テスト）

### 1. ISO リマスター

```bash
./scripts/remaster-debian-iso.sh --legacy-only \
  /var/samba/public/debian-13.3.0-amd64-netinst.iso \
  preseed/preseed-server7.cfg \
  /var/samba/public/debian-preseed.iso
```

### 2. VirtualMedia マウント + ブート

```bash
ssh idrac7 racadm remoteimage -d
ssh idrac7 racadm remoteimage -c -u guest -p guest -l //10.1.6.1/public/debian-preseed.iso
ssh idrac7 racadm config -g cfgServerInfo -o cfgServerBootOnce 1
ssh idrac7 racadm config -g cfgServerInfo -o cfgServerFirstBootDevice VCD-DVD
./oplog.sh ssh idrac7 racadm serveraction powercycle
```

### 3. VNC モニタリング

`.venv/bin/python3 tmp/744c4cec/vnc-monitor.py` で 90s～780s の7チェックポイントでスクリーンショット取得。

## テスト結果

**結果: 成功** — 完全自動インストールが手動介入なしで完了。

### VNC スクリーンショット

| 時刻 | ファイル | 画面内容 | 判定 |
|------|---------|---------|------|
| 90s | vnc-test-01-090s.png | 黒画面（POST/BIOS フェーズ） | 正常 |
| 180s | vnc-test-02-180s.png | SYSTEM IDLE（インストーラ読み込み中） | 正常 |
| 300s | vnc-test-03-300s.png | **d-i TUI 表示**: "Detecting link on eno1..." 91% | `vga=normal nomodeset` 動作確認 |
| 420s | vnc-test-04-420s.png | SYSTEM IDLE（インストール進行中） | **"Scan extra" ダイアログなし** |
| 540s | vnc-test-05-540s.png | **SYSTEM POWER OFF** | インストール完了 |
| 660s | vnc-test-06-660s.png | SYSTEM POWER OFF | 継続 |
| 780s | vnc-test-07-780s.png | SYSTEM POWER OFF | 継続 |

### 電源状態遷移

| 時刻 | PowerState | 確認方法 |
|------|-----------|---------|
| 0s (powercycle) | ON | `racadm serveraction powercycle` |
| +5分 | ON | `racadm serveraction powerstatus` |
| +10分 | **OFF** | `racadm serveraction powerstatus` |

### 成功基準の達成状況

| 基準 | 達成 |
|------|------|
| VNC スクリーンショットで d-i TUI が表示される | 300s で確認 |
| 「Scan extra installation media?」ダイアログが表示されない | 確認（420s で SYSTEM IDLE、ダイアログなし） |
| 手動介入なしで SYSTEM POWER OFF に到達 | 540s で確認 |
| 全プロセスが完全自動で完了 | 約9分で完了 |

## 考察

### preseed/cdrom/set-double 修正の効果

前回セッションで追加した `apt-setup/cdrom/set-double boolean false` により、
「Scan extra installation media?」ダイアログが完全に抑制された。
`set-next boolean false` だけでは不十分で、`set-double` も必要だった。

### VNC スクリーンショットの SYSTEM IDLE について

iDRAC7 VNC は画面更新がない期間に "SYSTEM IDLE" を表示する。
420s のスクリーンショットが SYSTEM IDLE だったのは、インストーラがバックグラウンドで
パッケージインストール等を行っている間に VNC が idle 判定したため。
540s で SYSTEM POWER OFF に到達しているため、この間に正常にインストールが完了している。

### インストール所要時間

パワーサイクルから POWER OFF まで約9分。
前回の手動介入付きインストールと比較して、ダイアログ待ちがなくなった分スムーズに完了。

## 対象ファイル一覧

| ファイル | 変更種別 |
|---------|---------|
| `.claude/skills/os-setup/SKILL.md` | Phase 3 に 7号機注意事項追記 |
| `.claude/skills/os-setup/reference.md` | ISO リマスターセクション更新 |
| `.claude/skills/idrac7/SKILL.md` | VNC セクション新規追加 |
| `preseed/preseed.cfg.template` | server7 との違いコメント追加 |
