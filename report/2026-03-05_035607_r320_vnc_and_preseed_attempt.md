# 7号機 (DELL R320) preseed インストール試行と VNC 接続ガイド

- **実施日時**: 2026年3月5日 03:56

## 前提・目的

7号機 (DELL PowerEdge R320) に Debian 13 + Proxmox VE 9 を preseed 自動インストールする試みの続き。
前回セッション（試行 #9〜#11）で改良した preseed 設定（静的IP・ミラーなし・NTP なし・LVM パーティション）を使い、
3回連続で hw-detect ハングが再現したため、手動インストールに切り替えるための VNC 接続環境を整備した。

- **背景**: 前回レポートで 8 回の試行（UEFI ブート失敗、DHCP ハング、SOL 無応答、LVM/partman デッドロック）を経て、今回の 3 回で合計 11 回試行。全て失敗
- **目的**: (1) hw-detect ハングの原因切り分け、(2) 手動インストール用の VNC 接続手段の確立
- **前提条件**: iDRAC7 FW 2.65.65.65、Enterprise ライセンス、PERC H710 (7VD + バッテリー失効)

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | DELL PowerEdge R320 (7号機) |
| iDRAC IP | 10.10.10.120 |
| 静的 IP (予定) | 10.10.10.207 |
| iDRAC FW | 2.65.65.65 |
| ライセンス | Enterprise (PERPETUAL) |
| RAID | PERC H710 — 7 Virtual Disks、バッテリー失効 |
| インストール ISO | Debian 13 (Trixie) netinst + preseed 注入済み (755MB) |
| ISO マウント | iDRAC VirtualMedia — `//10.1.6.1/public/debian-preseed.iso` |
| ブートモード | Legacy BIOS |
| 監視ツール | capconsole API (KVM スクリーンショット)、Python UDP syslog リスナー |

## 自動インストール試行結果 (試行 #9〜#11)

### 試行 #9: オリジナル preseed (2026-03-04 22:27〜)

- **設定**: preseed-server7.cfg そのまま（静的IP, ミラーなし, NTP なし, `hw-detect/load_firmware=true`）
- **ブートパラメータ**: `auto=true priority=critical locale=en_US.UTF-8 keymap=us console=tty0 console=ttyS0,115200n8 console=ttyS1,115200n8 ---`
- **結果**: CD ブート成功 → 「Scanning for devices. Please wait, this may take several minutes...」で **67 分以上停止**
- **syslog**: 0 バイト（`early_command` に到達せず）
- **Ping 10.10.10.207**: 100% パケットロス

### 試行 #10: 再起動のみ (2026-03-05 00:20〜)

- **変更点**: なし（同一 ISO で再試行）
- **結果**: BIOS POST に 23 分（Lifecycle Controller: Collecting System Inventory...）→ CD ブート後、同一の hw-detect ハング
- **screen6.png**: BIOS POST 画面をキャプチャ（唯一 hw-detect 以外の画面）

### 試行 #11: modules=dep + load_firmware 削除 (2026-03-05 01:52〜)

- **preseed 変更**: `d-i hw-detect/load_firmware boolean true` を削除
- **ブートパラメータ変更**: `modules=dep` を追加（依存モジュールのみロード）
- **remaster-debian-iso.sh 変更**: Docker コンテナに `--dns 8.8.8.8` を追加（DNS 解決問題修正）
- **結果**: **同一の hw-detect ハング** — 48 分以上停止、syslog 0 バイト、Ping 失敗

### うまくいったこと

| コンポーネント | 結果 |
|--------------|------|
| `remaster-debian-iso.sh --legacy-only` | ISO リマスター正常動作 (755MB, El-Torito 構造保持) |
| Docker `--dns 8.8.8.8` | コンテナ内 DNS 解決問題の修正 |
| VirtualMedia mount/verify | SMB 経由の ISO マウント・検証成功 |
| Boot Override (Cd + Legacy) | Redfish API で Legacy CD ブート成功 |
| CD ブート | Debian インストーラカーネルは起動した |
| KVM スクリーンショット | capconsole API で 9 枚の画面キャプチャに成功 |
| Python syslog リスナー | socat 代替として UDP:5514 リスン正常動作 |
| IPMI 電源管理 | ForceOff/PowerOn/Status すべて正常 |

### うまくいかなかったこと

| 問題 | 詳細 |
|------|------|
| hw-detect ハング | 「Scanning for devices」で 3 回とも停止。`modules=dep` 追加・`load_firmware` 削除ともに効果なし |
| syslog 未受信 | `early_command` に到達前のハングのため、リモート syslog 転送が機能しない（診断不可） |
| ネットワーク未到達 | hw-detect フェーズではネットワーク未設定のため Ping/SSH 不可 |
| 原因特定不可 | PERC H710 (7VD + バッテリー失効) の SCSI デバイススキャン or Debian hw-detect の切り分けができない |

### Docker DNS 問題の詳細

試行 #11 の ISO リマスター時、Docker コンテナ内で DNS 解決に失敗:

```
W: Failed to fetch http://deb.debian.org/debian/dists/trixie/InRelease  Could not resolve 'deb.debian.org'
```

原因: コンテナの `/etc/resolv.conf` がホストの `192.168.39.1` を参照するが、Docker ブリッジネットワークから到達不可。
修正: `docker run` に `--dns 8.8.8.8` を追加。

## iDRAC7 VNC 接続ガイド（手動インストール用）

### 前提条件

- iDRAC7 **Enterprise ライセンス**が必要（Standard では VNC 不可）
- 現在のライセンス: Enterprise (PERPETUAL) — 確認済み

### VNC 有効化手順

```sh
# 1. VNC サーバを有効化
ssh idrac7 racadm set iDRAC.VNCServer.Enable 1

# 2. VNC パスワードを設定（最大 8 文字）
ssh idrac7 racadm set iDRAC.VNCServer.Password "Claude1"

# 3. VirtualConsole のアクセス権を Full Access に変更
ssh idrac7 racadm set iDRAC.VirtualConsole.AccessPrivilege 2
```

### VNC 設定値一覧

| 設定 | 変更前 | 変更後 |
|------|--------|--------|
| `iDRAC.VNCServer.Enable` | Disabled | **Enabled** |
| `iDRAC.VNCServer.Password` | (未設定) | **Claude1** |
| `iDRAC.VNCServer.Port` | 5901 | 5901 (変更なし) |
| `iDRAC.VNCServer.SSLEncryptionBitLength` | Disabled | Disabled (変更なし) |
| `iDRAC.VNCServer.Timeout` | 300 | 300 (変更なし) |
| `iDRAC.VirtualConsole.AccessPrivilege` | Deny Access (0) | **Full Access (2)** |
| `iDRAC.VirtualConsole.Enable` | Enabled | Enabled (変更なし) |

### VNC クライアント接続方法

```sh
# TigerVNC のインストール（未インストールの場合）
sudo apt install -y tigervnc-viewer

# 接続
vncviewer 10.10.10.120:5901
# パスワード: Claude1
```

他の VNC クライアント (Remmina, RealVNC 等) でも接続可能。接続先は `10.10.10.120:5901`。

### 接続検証結果

Python スクリプトによる TCP 接続テストで VNC サーバの正常動作を確認:

```
Connected to 10.10.10.120:5901
Server response: RFB 003.008
VNC server is responding with RFB protocol handshake - SUCCESS
```

- **プロトコル**: RFB 003.008 (VNC 標準)
- **認証方式**: VNC Authentication (type 2) — パスワード認証
- **SSL 暗号化**: Disabled（ラボ内ネットワークのため無効のまま）

### 注意事項

1. **パスワード制限**: VNC パスワードは最大 8 文字。9 文字以上は切り捨てられる
2. **タイムアウト**: 300 秒（5 分）無操作で VNC セッション切断。`Timeout` 値は racadm で変更可能
3. **同時接続**: VNC と iDRAC Web コンソール (Java/HTML5) は排他。片方が接続中は他方が使えない場合がある
4. **SSL**: `SSLEncryptionBitLength=Disabled` のため暗号化なし。外部ネットワークからの接続時は要検討
5. **AccessPrivilege**: `0=Deny`, `1=Read Only`, `2=Full Access`。手動インストールには Full Access (2) が必要

### VNC 設定の無効化手順（作業完了後）

```sh
ssh idrac7 racadm set iDRAC.VNCServer.Enable 0
ssh idrac7 racadm set iDRAC.VirtualConsole.AccessPrivilege 0
```

## VirtualMedia の現在の状態

```
Remote File Share is Enabled
ShareName //10.1.6.1/public/debian-preseed.iso
```

preseed 注入済み ISO がマウント済み。手動インストールでも preseed 付き ISO のまま使用可能（preseed は自動適用されず、手動操作で進められる）。

## 手動インストール手順（推奨）

1. VNC クライアントで `10.10.10.120:5901` に接続
2. iDRAC から Boot Override を Cd + Legacy に設定し電源サイクル:
   ```sh
   ./scripts/bmc-power.sh boot-override 10.10.10.120 Cd Legacy
   ./scripts/bmc-power.sh forceoff 10.10.10.120
   # 20 秒待機
   ./scripts/bmc-power.sh on 10.10.10.120
   ```
3. BIOS POST 完了を待つ（R320 は POST に 20〜25 分かかる場合がある）
4. Debian インストーラの起動メニューで **Expert install** を選択
5. hw-detect でハングした場合:
   - ハング画面で **Alt+F2** でシェルに切り替え
   - `/var/log/syslog` を確認してハング原因を特定
   - 必要に応じてモジュールの手動ロード/除外
6. NIC 名とディスクデバイス名を確認し、preseed 設定に反映

## 教訓と推奨事項

1. **PERC H710 (7VD + バッテリー失効) は preseed 自動インストールと相性が悪い**: 11 回の試行で、hw-detect フェーズのハングが最も頑固な障害。手動インストールで Expert モードを使い、hw-detect の内部状態を確認すべき
2. **手動インストールで確認すべき項目**:
   - PERC H710 のデバイス名 (`/dev/sd*` or `/dev/cciss/*`)
   - NIC デバイス名（preseed では `eno1` を想定しているが未検証）
   - hw-detect がハングする具体的なモジュール名
3. **VNC 接続で手動操作が可能になった**: iDRAC Web コンソール (Java/HTML5) が使えない環境でも、VNC で直接操作できる
4. **Docker DNS 設定**: `remaster-debian-iso.sh` に `--dns 8.8.8.8` を追加済み。Docker ホストの DNS 設定に依存しなくなった
5. **capconsole API の限界**: 低解像度 (400x300, 5色) のため文字が判別しづらい場面がある。VNC は高解像度でリアルタイム操作が可能

## 全試行サマリー (11回)

| # | 日付 | ブートモード | 到達フェーズ | 失敗原因 |
|---|------|-------------|-------------|----------|
| 1-4 | 03-02 | UEFI/Legacy | ブートローダ | UEFI非対応、SOL無応答 |
| 5-6 | 03-03 | Legacy | ネットワーク設定 | DHCP タイムアウト (eno1→eno2 問題) |
| 7 | 03-03 | Legacy | partman | LVM 既存 VG でデッドロック |
| 8 | 03-04 | Legacy | partman | partman_early_command 修正後も LVM 問題 |
| 9 | 03-04 | Legacy | hw-detect | 「Scanning for devices」ハング (67分+) |
| 10 | 03-05 | Legacy | hw-detect | 同上 (再現) |
| 11 | 03-05 | Legacy | hw-detect | `modules=dep` + `load_firmware` 削除でも同上 |

## 参考資料

- [前回レポート: R320 OS インストール失敗分析](2026-03-04_035512_r320_os_install_failure_analysis.md) — 試行 #1〜#8 の詳細
- [R320 iDRAC セットアップレポート](2026-03-02_052246_dell_r320_idrac_setup.md) — iDRAC 初期設定
- `config/server7.yml` — 7号機設定ファイル
- `preseed/preseed-server7.cfg` — preseed 設定
- `scripts/remaster-debian-iso.sh` — ISO リマスタースクリプト
- `log/oplog.log` — 操作ログ
