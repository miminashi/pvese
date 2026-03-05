---
name: idrac7
description: "iDRAC7 基本操作。SSH 経由で racadm コマンドを実行し、サーバ管理を行う。"
argument-hint: "<subcommand: getsysinfo|getconfig|config|jobqueue|fwupdate|racreset|ipmi-lan>"
---

# iDRAC7 スキル

SSH 経由で racadm コマンドを実行し、DELL PowerEdge R320 (7号機) を管理する。

## 概要

| 項目 | 値 |
|------|-----|
| サーバ | 7号機 (DELL PowerEdge R320) |
| iDRAC IP | `10.10.10.120` |
| SSH ホスト | `idrac7` (`~/.ssh/config` で定義) |
| 認証 | SSH 鍵 (`~/.ssh/idrac_rsa`, RSA 2048) |
| Web/IPMI 認証 | `claude` / `Claude123` |
| FW バージョン | 2.65.65.65 (Build 15) |
| IPMI LAN | 有効 (`cfgIpmiLanEnable=1`) |

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/server7.yml"
BMC_IP=$("$YQ" '.bmc_ip' "$CONFIG")
BMC_USER=$("$YQ" '.bmc_user' "$CONFIG")
BMC_PASS=$("$YQ" '.bmc_pass' "$CONFIG")
```

## SSH 前提条件

`~/.ssh/config` に以下が設定済み:

```
Host idrac7
  HostName 10.10.10.120
  User claude
  IdentityFile ~/.ssh/idrac_rsa
  IdentitiesOnly yes
  KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
  HostKeyAlgorithms +ssh-rsa,ssh-dss
  PubkeyAcceptedAlgorithms +ssh-rsa
```

- iDRAC7 は Ed25519 非対応。RSA 2048 鍵を使用
- レガシー鍵交換アルゴリズム (`diffie-hellman-group14-sha1` 等) が必要

## サブコマンド

### getsysinfo — システム情報

```sh
ssh idrac7 racadm getsysinfo
```

FW バージョン、モデル名、電源状態、Service Tag 等を表示。

### getconfig — 設定取得

```sh
ssh idrac7 racadm getconfig -g <group>
```

主要グループ:
- `cfgIpmiLan` — IPMI LAN 設定
- `cfgLanNetworking` — ネットワーク設定
- `cfgUserAdmin -i 2` — ユーザ設定 (index 2 = claude)
- `cfgRacTuning` — RAC チューニング

### config — 設定変更

```sh
ssh idrac7 racadm config -g <group> -o <object> <value>
```

状態変更のため oplog で記録:
```sh
./oplog.sh ssh idrac7 racadm config -g cfgIpmiLan -o cfgIpmiLanEnable 1
```

### jobqueue — ジョブキュー

```sh
ssh idrac7 racadm jobqueue view
```

実行中・保留中のジョブを確認。FW アップデート前に空であることを確認すること。

### fwupdate — FW アップデート

```sh
ssh idrac7 racadm fwupdate -g -u -a <tftp-server-ip>
```

- `-g`: TFTP から取得
- `-u`: アップデート実行
- `-a`: TFTP サーバの IP アドレス
- `-d` オプションは**省略**する (ディレクトリパスを指定するオプションであり、ファイル名ではない)

詳細は [idrac7-fw-update スキル](../idrac7-fw-update/SKILL.md) を参照。

### racreset — iDRAC リセット

```sh
./oplog.sh ssh idrac7 racadm racreset
```

- ソフトリセット。FW アップデートが進行中の場合は拒否される
- リセット後 60-120 秒で SSH 再接続可能
- SSH ホスト鍵が変わる場合がある → `ssh-keygen -R 10.10.10.120`

### ipmi-lan — IPMI LAN 操作

ipmitool で直接 BMC と通信:

```sh
ipmitool -I lanplus -H 10.10.10.120 -U claude -P Claude123 chassis status
ipmitool -I lanplus -H 10.10.10.120 -U claude -P Claude123 mc info
ipmitool -I lanplus -H 10.10.10.120 -U claude -P Claude123 mc reset cold
```

- IPMI LAN は FW アップグレード作業中に有効化済み (`cfgIpmiLanEnable=1`)
- `mc reset cold`: スタックした FW アップデートの回復に使用

## VNC

### 接続情報

| 項目 | 値 |
|------|-----|
| ポート | 5901 |
| プロトコル | RFB 3.008 |
| 認証 | VNC Auth (パスワード: `Claude1`) |
| 同時接続 | 1本のみ |

### iDRAC7 VNC と VGA モードの非互換

iDRAC7 VNC ポート 5901 は `vga=788` (VESA 800x600x16bit フレームバッファ) に**非対応**。
VESA モードで起動すると "SYSTEM IDLE" 表示で画面内容が見えない。

- **解決**: カーネルパラメータに `vga=normal nomodeset` を指定（テキストモード）
- 素の Debian 13.3 netinst ISO も全エントリが `vga=788` のため、リマスターが必須
- VNC スクリーンショットツール: `tmp/<session-id>/vnc-screenshot.py`（pycryptodome + Pillow 必要、`.venv/` で実行）

### VNC スクリーンアイドル

iDRAC7 VNC はしばらく画面更新がないと "SYSTEM IDLE" を表示する。
VNC キーイベント送信で復帰可能（RFB KeyEvent: `struct.pack(">BBxxI", 4, down_flag, keysym)`）。

## 既知の失敗パターン

### D1: SSH 接続拒否 (Connection refused)

iDRAC リセット後やFWアップデート後に発生。60-120 秒待機して再試行。

### D2: ホスト鍵変更 (REMOTE HOST IDENTIFICATION HAS CHANGED)

FW アップデート後に SSH ホスト鍵が変わる。解決:
```sh
ssh-keygen -R 10.10.10.120
```

### D3: racadm racreset 拒否 (firmware update in progress)

FW アップデートジョブがスタック状態。ipmitool で強制リセット:
```sh
ipmitool -I lanplus -H 10.10.10.120 -U claude -P Claude123 mc reset cold
```

前提: IPMI LAN が有効であること。無効の場合は先に SSH 経由で有効化:
```sh
ssh idrac7 racadm config -g cfgIpmiLan -o cfgIpmiLanEnable 1
```

### D4: Ed25519 鍵で認証失敗

iDRAC7 は Ed25519 非対応。RSA 2048 鍵 (`~/.ssh/idrac_rsa`) を使用すること。

## oplog・pve-lock ルール

| 操作 | oplog | pve-lock |
|------|-------|----------|
| getsysinfo, getconfig, jobqueue view | 不要 | 不要 |
| config (設定変更) | 必要 | 不要 (iDRAC 単体操作) |
| fwupdate | 必要 | 不要 (iDRAC 単体操作) |
| racreset | 必要 | 不要 |
| ipmitool power on/off/reset | 必要 | **必要** (サーバ電源操作) |
| ipmitool mc reset | 必要 | 不要 (BMC のみ) |

## 参照

- [iDRAC7 FW アップグレードレポート](../../../report/2026-03-02_143000_idrac7_firmware_upgrade.md)
- [iDRAC SSH セットアップレポート](../../../report/2026-03-02_052246_dell_r320_idrac_setup.md)
- [idrac7-fw-update スキル](../idrac7-fw-update/SKILL.md)
