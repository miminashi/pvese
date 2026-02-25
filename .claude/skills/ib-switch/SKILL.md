---
name: ib-switch
description: "Mellanox SX6036 InfiniBand スイッチのシリアルコンソール操作。ステータス確認、show コマンド、IB 設定を行う。"
disable-model-invocation: true
argument-hint: "<subcommand> [args]"
---

# IB Switch スキル

Mellanox SX6036 InfiniBand スイッチを USB シリアルコンソール経由で操作する。

## 概要

| 項目 | 値 |
|------|-----|
| モデル | MSX6036F-1SFS (36ポート FDR InfiniBand) |
| ホスト名 | switch-d2b2e2 |
| MLNX-OS | 3.6.8008 |
| シリアル接続先 | 4号機 (10.10.10.204) `/dev/ttyUSB0` |
| シリアル設定 | 9600/8N1, フロー制御なし |
| 認証 | admin / admin |
| 管理 IP | 10.125.13.104/24 (mgmt0) |

接続構成: Claude Code → SSH → server 4 → USB serial → SX6036

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/switch-sx6036.yml"
SERIAL_HOST=$("$YQ" '.serial_host' "$CONFIG")
SERIAL_HOST_USER=$("$YQ" '.serial_host_user' "$CONFIG")
```

## スクリプトの転送

セッション開始時に 1 回、スクリプトを server 4 に転送する:

```sh
scp ./scripts/sx6036-console.py root@$SERIAL_HOST:/tmp/
```

pyserial が未インストールの場合:
```sh
ssh root@$SERIAL_HOST 'pip3 install pyserial'
```

## サブコマンド

### status — 基本ステータス表示

version, fan, temperature, power, protocols をまとめて表示。

```sh
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py status'
```

### show — 任意の show コマンド

```sh
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py show version'
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py show interfaces brief'
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py show inventory'
```

### ports — IB ポート状態サマリ

36 ポート (IB1/1 〜 IB1/36) の状態を表示。

```sh
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py ports'
```

### enable-cmd — enable モードでコマンド実行

operator mode では使えない `show running-config`, `show ib` 等を実行。

```sh
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py enable-cmd show running-config'
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py enable-cmd show ib sm'
```

### configure — 設定変更

ファイルからコマンドを読み込み、enable → configure terminal で実行。

```sh
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py configure /tmp/ib-config.txt'
```

設定変更時は oplog で記録する:
```sh
./oplog.sh ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py configure /tmp/ib-config.txt'
```

## MLNX-OS CLI モード階層

```
operator (>)  →  enable (#)  →  configure terminal ((config) #)
               enable           configure terminal
               ←  disable      ←  exit
```

- **operator mode (`>`)**: show コマンドの一部のみ (version, fan, interfaces brief 等)
- **enable mode (`#`)**: show running-config, show ib, SM 設定の表示
- **configure mode (`(config) #`)**: 設定変更 (SM 有効化, IP 変更等)

## oplog

- **show コマンド**: oplog 不要（読み取りのみ）
- **設定変更 (enable-cmd, configure)**: oplog で記録する

```sh
./oplog.sh ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py enable-cmd <cmd>'
./oplog.sh ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py configure /tmp/config.txt'
```

## 注意事項

- **シリアルポート排他**: 同時に 1 セッションのみ接続可能。別のプロセスがシリアルポートを使用中だとエラーになる
- **pyserial 必須**: server 4 に `pyserial` パッケージが必要。OS 再インストールで消失するため、接続失敗時は `pip3 install pyserial` を再実行
- **低速通信**: 9600 baud (~960 bytes/sec)。36 ポート表示で 5-10 秒かかる。タイムアウトはデフォルト 30 秒
- **enable パスワード**: 不要（パスワードプロンプトなしで enable モードに入れる）
- **pve-lock**: 不要（IB スイッチは PVE クラスタとは独立）
