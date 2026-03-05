# R320 iDRAC7 VNC ブランク画面修正レポート

- **実施日時**: 2026年3月5日 06:00〜17:43
- **関連レポート**: [R320 VNC/preseed 試行](report/2026-03-05_035607_r320_vnc_and_preseed_attempt.md)

## 前提・目的

リマスター Debian 13.3 ISO で Dell R320 に preseed 自動インストールを行う際、iDRAC7 VNC (ポート 5901) でカーネルメッセージ表示後に d-i TUI が表示されず、カーソル点滅のみまたは "SYSTEM IDLE" になる問題を解決する。

- **背景**: 素の Debian 13.3 netinst ISO では ISOLINUX のグラフィカルメニュー (vesamenu.c32) は表示されるが、いずれのインストールオプションも `vga=788` を使用しており、iDRAC7 VNC ではインストーラ TUI が表示されない
- **目的**: VNC 経由で d-i TUI が正常に表示される ISO リマスター方法を確立する
- **前提条件**: iDRAC7 FW 2.65.65.65、VNC ポート 5901 (password: Claude1)

## 環境情報

- **サーバ**: Dell PowerEdge R320 (7号機)
- **iDRAC**: iDRAC7 Enterprise、FW 2.65.65.65
- **iDRAC VNC**: ポート 5901、RFB 3.008、VNC Auth
- **ISO**: Debian 13.3.0 amd64 netinst (debian-13.3.0-amd64-netinst.iso)
- **ストレージ**: PERC H310 Mini、8 物理ディスク、7 仮想ディスク
- **ブートモード**: Legacy BIOS

## 発見した根本原因

### 根本原因1: `vga=788` が iDRAC7 VNC と非互換

素の Debian 13.3 netinst ISO のすべてのブートエントリは `vga=788` (VESA 800x600x16bit フレームバッファ) を使用する。iDRAC7 VNC ポート 5901 はこの VESA モードを表示できず、"SYSTEM IDLE" を表示する。

**検証**:
- 仮説1 (vga=788 追加): リマスター ISO に `vga=788` を追加 → SYSTEM IDLE (NG)
- 仮説4 (vga=normal nomodeset): `vga=normal nomodeset` に変更 → **d-i TUI 表示成功**
- コントロールテスト: 素の ISO でもすべてのエントリが `vga=788` のため、VNC で TUI は表示されない

### 根本原因2: preseed の initrd 注入が d-i 表示を壊す

cpio アーカイブ連結方式で preseed.cfg を initrd.gz に注入すると、d-i の TUI 表示が破壊される。注入方式 (cpio -A、gzip 連結) や preseed の内容（最小限の locale 設定のみ）に関わらず発生する。

**検証**:
- vga=normal nomodeset + preseed 注入あり → ブランク画面 (NG)
- vga=normal nomodeset + preseed 注入なし → **d-i TUI 表示成功**
- vga=normal nomodeset + preseed/file=/cdrom/preseed.cfg (注入なし) → **d-i TUI 表示成功 + 自動インストール進行**

### 追加問題: `apt-setup/cdrom/set-double` テンプレートの未設定

「Scan extra installation media?」ダイアログが preseed で抑制されず手動介入が必要だった。
このダイアログの debconf テンプレート名は `apt-setup/cdrom/set-double` であり、
preseed に `apt-setup/cdrom/set-next` しか設定していなかったため抑制されなかった。

## 解決策

### 1. remaster-debian-iso.sh の変更

```diff
- initrd に preseed.cfg を cpio 連結で注入
+ preseed.cfg を ISO ルートに配置し、カーネルパラメータで読み込み

ブートパラメータ:
- vga=normal nomodeset auto=true priority=critical
- preseed/file=/cdrom/preseed.cfg
+ locale=en_US.UTF-8 keymap=us console=tty0
+ --- quiet
```

xorriso コマンドで ISO ルートに preseed.cfg をマッピング:
```
-map "$WORK/mod/preseed.cfg" /preseed.cfg
```

### 2. preseed-server7.cfg の変更

```diff
 d-i apt-setup/cdrom/set-first boolean true
 d-i apt-setup/cdrom/set-next boolean false
+d-i apt-setup/cdrom/set-double boolean false
 d-i apt-setup/cdrom/set-failed boolean false
```

## 再現方法

### ISO リマスター

```bash
./scripts/remaster-debian-iso.sh --legacy-only \
  /var/samba/public/debian-13.3.0-amd64-netinst.iso \
  preseed/preseed-server7.cfg \
  /var/samba/public/debian-preseed.iso
```

### VirtualMedia マウント + インストール実行

```bash
ssh idrac7 racadm remoteimage -d
ssh idrac7 racadm remoteimage -c -u "guest" -p "guest" \
  -l //10.1.6.1/public/debian-preseed.iso
ssh idrac7 racadm config -g cfgServerInfo -o cfgServerBootOnce 1
ssh idrac7 racadm config -g cfgServerInfo -o cfgServerFirstBootDevice VCD-DVD
ssh idrac7 racadm serveraction powercycle
```

### VNC スクリーンショットで進行確認

```bash
.venv/bin/python tmp/17a03196/vnc-screenshot.py \
  --host 10.10.10.120 --port 5901 --password Claude1 \
  --output tmp/17a03196/vnc-check.png --timeout 10
```

## 仮説テスト結果一覧

| # | 仮説 | ブートパラメータ | preseed 注入 | 結果 |
|---|------|----------------|-------------|------|
| 1 | vga=788 が必要 | vga=788 | initrd 注入 | NG: SYSTEM IDLE |
| 3 | preseed が原因 | vga=788, preseed なし | なし | NG: SYSTEM IDLE (vga=788 が原因) |
| C | コントロール (素 ISO) | vga=788 (素 ISO デフォルト) | なし | NG: SYSTEM IDLE |
| 4 | vga=normal nomodeset | vga=normal nomodeset | なし | **OK: d-i TUI 表示** |
| 5 | +auto mode+preseed注入 | vga=normal nomodeset auto=true | initrd 注入 | NG: SYSTEM IDLE |
| 6 | +preseed注入(auto なし) | vga=normal nomodeset | initrd 注入 | NG: ブランク画面 |
| 7 | cpio 連結方式変更 | vga=normal nomodeset | gzip 連結 | NG: SYSTEM IDLE |
| 8 | 最小 preseed | vga=normal nomodeset | initrd (最小) | NG: ブランク画面 |
| 9 | preseed/file from CD | vga=normal nomodeset auto=true | ISO ルート配置 | **OK: 自動インストール成功** |

## VNC スクリーンショットツール

セッション中に作成した `tmp/17a03196/vnc-screenshot.py` は RFB プロトコルで iDRAC7 VNC に直接接続しスクリーンショットを取得する。依存: pycryptodome (VNC Auth の DES 暗号)、Pillow (PNG 保存)。

また `tmp/17a03196/vnc-send-keys.py` は VNC にキーイベントを送信する。RFB KeyEvent のパケット形式は `struct.pack(">BBxxI", type, down_flag, keysym)` が正しい（`>BxBBI` はフィールド位置がずれる）。

## 残存課題

- **RAID ブート順序**: インストール後の OS ブートで "No boot device available" が発生。PERC H310 Mini の7つの仮想ディスクのうち、BIOS ブートデバイスと `/dev/sda` の対応関係の確認が必要
- **preseed/cdrom/set-double の検証**: 修正済みだが未テスト。次回の完全自動インストールテストで確認する
