---
name: ib-switch
description: "Mellanox SX6036 InfiniBand スイッチのシリアルコンソール操作。ステータス確認、show コマンド、IB 設定、FW 管理を行う。"
argument-hint: "<subcommand> [args]"
---

# IB Switch スキル

Mellanox SX6036 InfiniBand スイッチを USB シリアルコンソールまたは SSH 経由で操作する。

## 概要

| 項目 | 値 |
|------|-----|
| モデル | MSX6036F-1SFS (36ポート FDR InfiniBand) |
| ホスト名 | switch-d2b2e2 |
| MLNX-OS | 3.6.8012 (最終版, 2019-02-22) |
| シリアル接続先 | 4号機 (10.10.10.204) `/dev/ttyUSB0` |
| シリアル設定 | 9600/8N1, フロー制御なし |
| 認証 | admin / admin |
| 管理 IP | 10.10.10.100/24 (mgmt0, ラボから到達可) |
| SSH | port 22, 要レガシー鍵交換 (下記参照) |
| 内蔵 SM | active (OpenSM4.8.1) |

接続構成: Claude Code → SSH → server 4 → USB serial → SX6036

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/switch-sx6036.yml"
SERIAL_HOST=$("$YQ" '.serial_host' "$CONFIG")
SERIAL_HOST_USER=$("$YQ" '.serial_host_user' "$CONFIG")
MGMT_IP=$("$YQ" '.mgmt_ip' "$CONFIG")
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

`show` サブコマンドは内部で `"show " + arg` を組み立てるため、引数に `show` を含めないこと:

```sh
# OK: 引数に show を含めない
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py show version'
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py show interfaces brief'
ssh root@$SERIAL_HOST 'python3 /tmp/sx6036-console.py show inventory'

# NG: 引数に show を含めると二重になる
# python3 /tmp/sx6036-console.py show "show interfaces ib status 1" → "show show interfaces ..."
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

## SSH アクセス

mgmt0 (10.10.10.100) 経由で SSH 接続可能。レガシー鍵交換アルゴリズムが必要。

```sh
sshpass -p admin ssh -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa admin@10.10.10.100 'show version'
```

- SSH サーバ: mpSSH_0.2.1
- リブート直後は認証が一時的に失敗することがある（システム初期化中）
- `sx6036-console.py` で扱えない長時間操作（FW fetch/install 等）はシリアルコンソール手動操作を推奨

## SM 管理

現在の状態: **内蔵 SM active** (server 4 の opensm は disabled)

### SM 診断コマンド (enable モード)

```
show ib smnode switch-d2b2e2 sm-running    # SM プロセス実行状態 (active/not active)
show ib smnode switch-d2b2e2 sm-state      # SM 設定状態 (enable/disable)
show ib smnode switch-d2b2e2 sm-licensed   # ライセンス状態
show ib sm version                         # SM バージョン (OpenSM4.8.1)
show ib sm routing-info                    # ルーティングエンジン (minhop)
```

### SM 有効化

```
configure terminal
  ib sm
  ib smnode switch-d2b2e2 enable
  exit
write memory
```

SM 設定には2層構造がある:
- `ib sm` — グローバルな SM 有効/無効スイッチ
- `ib smnode <hostname> enable/disable` — ノード単位の SM 有効/無効

### SM 無効化 (opensm に切替)

```
configure terminal
  no ib sm
  ib smnode switch-d2b2e2 disable
  exit
write memory
```

切替後に server 4 で opensm を起動: `systemctl enable --now opensm`

## FW 管理

### イメージ確認

```
show images
```

2パーティション構成。現在両方とも 3.6.8012。

### FW イメージの取得

server 4 で HTTP サーバを起動し、スイッチからフェッチする:

```sh
# server 4 側
ssh root@$SERIAL_HOST 'cd /tmp && python3 -m http.server 8080'
```

```
# スイッチ側 (シリアルコンソール)
image fetch http://10.10.10.204:8080/image-PPC_M460EX-3.6.8012.img
```

- 所要時間: ~5分 (358MB)
- FW イメージ URL: `https://content.mellanox.com/Software/image-PPC_M460EX-3.6.8012.img`
- MD5: `e2114b923351bf4d499c7200392afecb`

### FW インストール

```
image install <file>                    # 次のブートパーティションに自動インストール
image install <file> location <N>       # 指定パーティション (1 or 2) にインストール
```

- **`partition` キーワードは不可。必ず `location` を使う**
- 4ステージ: Verify → Uncompress → Create Filesystems → Extract
- 所要時間: ~15分

### ブートパーティション切替・リブート

```
image boot next
write memory
reload
```

- リブート所要時間: ~8分
- **設定保存は `write memory`** (`configuration write` は MLNX-OS 3.6 では不可)

## MLNX-OS CLI モード階層

```
operator (>)  →  enable (#)  →  configure terminal ((config) #)
               enable           configure terminal
               ←  disable      ←  exit
```

- **operator mode (`>`)**: show コマンドの一部のみ (version, fan, interfaces brief 等)
- **enable mode (`#`)**: show running-config, show ib, show interfaces mgmt0, SM 設定の表示
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
- **OS 再インストール後の再セットアップ**: pyserial の再インストールに加え、`sx6036-console.py` の再転送 (`scp ./scripts/sx6036-console.py root@$SERIAL_HOST:/tmp/`) が必要。初回実行時のエラーを `2>/dev/null` で抑制しないこと（ファイル不在の検出が遅れる）
- **低速通信**: 9600 baud (~960 bytes/sec)。36 ポート表示で 5-10 秒かかる。タイムアウトはデフォルト 30 秒
- **enable パスワード**: 不要（パスワードプロンプトなしで enable モードに入れる）
- **pve-lock**: 不要（IB スイッチは PVE クラスタとは独立）
- **DTR トグルでコンソール復帰**: リブート後や長時間放置後にシリアルコンソールが無応答になった場合、pyserial で `ser.dtr = False` → `ser.dtr = True` でリセットする。手動の場合は `screen` を一度切断 (Ctrl+A, K) して再接続
- **限定シェル `CLI > `**: リブート直後に `CLI >` プロンプトになることがある。`enable` も使えない。`exit` → 再ログインで正常なフルプロンプトに復帰
- **`?` ヘルプキーの副作用**: シリアル自動化で `?` を送ると改行も送信され、コマンドが実行されてしまう。手動操作では問題ない
- **進捗バーの `#` 記号**: `image fetch` / `image install` の進捗バーにプロンプト (`#`) と同じ文字が含まれる。自動化でプロンプト検出する場合はフルプロンプトパターン (`switch-d2b2e2 [standalone: master] #`) を使う
- **`show interfaces mgmt0` は enable モードが必要**: operator mode だとエラー
- **MLNX-OS の ping 構文**: `-c N` を使う (`count N` は不可)
- **設定保存**: `write memory` を使う (`configuration write` は MLNX-OS 3.6 では不可)
- **長時間操作と `sx6036-console.py`**: FW fetch (~5分), install (~15分), reload (~8分) はタイムアウトを超えるため、シリアルコンソール手動操作 (`screen /dev/ttyUSB0 9600`) を推奨
- **QSFP+ トランシーバ電力制限**: SX6036 (SwitchX-2) はポートあたり最大 2W。CWDM4/LR4 等の高消費電力光モジュール (2.5-3.5W) は非対応。DAC ケーブルまたは Mellanox FDR AOC (<2W) を使用すること。スイッチ側で `Warning: High power transceiver is not supported` が表示されリンクが確立できない
- **IB トランシーバ情報取得の制約**: MLNX-OS 3.6 の IB インターフェースでは `transceiver`, `module-info`, `pluggable`, `cables`, `running-config interface` サブコマンドが非対応。サーバ側の `ethtool -m` も IB インターフェースでは `Operation not supported`。トランシーバの詳細診断手段は限定的

## 参照

- [FW 更新レポート](../../../report/2026-02-26_011138_sx6036_firmware_update.md)
- [SM 調査レポート](../../../report/2026-02-25_224551_sx6036_sm_investigation.md)
- [シリアルコンソール接続レポート](../../../report/2026-02-25_193442_sx6036_serial_console.md)
- [IB ベンチマークレポート](../../../report/2026-02-25_203745_ib_switch_benchmark.md)
