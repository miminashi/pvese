---
name: idrac7
description: "iDRAC7 基本操作。SSH 経由で racadm コマンドを実行し、サーバ管理を行う。"
argument-hint: "<subcommand: getsysinfo|getconfig|config|jobqueue|fwupdate|racreset|ipmi-lan>"
---

# iDRAC7 スキル

SSH 経由で racadm コマンドを実行し、DELL PowerEdge R320 (7-9号機) を管理する。

## 概要

| 項目 | 7号機 | 8号機 | 9号機 |
|------|-------|-------|-------|
| シャーシ | PowerEdge R320 | PowerEdge R320 | PowerEdge R320 |
| iDRAC IP | `10.10.10.27` | `10.10.10.28` | `10.10.10.29` |
| SSH ホスト | `idrac7` | `idrac8` | `idrac9` |
| 静的 IP | `10.10.10.207` | `10.10.10.208` | `10.10.10.209` |
| 認証 | SSH 鍵 (`ssh/idrac_rsa`, RSA 2048) | 同左 | 同左 |
| Web/IPMI 認証 | `claude` / `Claude123` | 同左 | 同左 |

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/server7.yml"
BMC_IP=$("$YQ" '.bmc_ip' "$CONFIG")
BMC_USER=$("$YQ" '.bmc_user' "$CONFIG")
BMC_PASS=$("$YQ" '.bmc_pass' "$CONFIG")
```

## SSH 前提条件

プロジェクトローカルの `ssh/config` に全ホスト定義済み。全 SSH コマンドに `-F ssh/config` を付けること。

```sh
ssh -F ssh/config idrac7 racadm getsysinfo
```

- iDRAC7 は Ed25519 非対応。RSA 2048 鍵 (`ssh/idrac_rsa`) を使用
- レガシー鍵交換アルゴリズム (`diffie-hellman-group14-sha1` 等) が必要
- 鍵が無い場合は `./ssh/setup.sh` で生成

## サブコマンド

### getsysinfo — システム情報

```sh
ssh -F ssh/config idrac7 racadm getsysinfo
```

FW バージョン、モデル名、電源状態、Service Tag 等を表示。

### getconfig — 設定取得

```sh
ssh -F ssh/config idrac7 racadm getconfig -g <group>
```

主要グループ:
- `cfgIpmiLan` — IPMI LAN 設定
- `cfgLanNetworking` — ネットワーク設定
- `cfgUserAdmin -i 2` — ユーザ設定 (index 2 = claude)
- `cfgRacTuning` — RAC チューニング

### config — 設定変更

```sh
ssh -F ssh/config idrac7 racadm config -g <group> -o <object> <value>
```

状態変更のため oplog で記録:
```sh
./oplog.sh ssh -F ssh/config idrac7 racadm config -g cfgIpmiLan -o cfgIpmiLanEnable 1
```

### jobqueue — ジョブキュー

```sh
ssh -F ssh/config idrac7 racadm jobqueue view
```

実行中・保留中のジョブを確認。FW アップデート前に空であることを確認すること。

### fwupdate — FW アップデート

```sh
ssh -F ssh/config idrac7 racadm fwupdate -g -u -a <tftp-server-ip>
```

- `-g`: TFTP から取得
- `-u`: アップデート実行
- `-a`: TFTP サーバの IP アドレス
- `-d` オプションは**省略**する (ディレクトリパスを指定するオプションであり、ファイル名ではない)

詳細は [idrac7-fw-update スキル](../idrac7-fw-update/SKILL.md) を参照。

### racreset — iDRAC リセット

```sh
./oplog.sh ssh -F ssh/config idrac7 racadm racreset
```

- ソフトリセット。FW アップデートが進行中の場合は拒否される
- リセット後 60-120 秒で SSH 再接続可能
- SSH ホスト鍵が変わる場合がある → `ssh-keygen -R $BMC_IP -f ssh/known_hosts`

### ipmi-lan — IPMI LAN 操作

ipmitool で直接 BMC と通信:

```sh
ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 chassis status
ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 mc info
ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 mc reset cold
```

- IPMI LAN は FW アップグレード作業中に有効化済み (`cfgIpmiLanEnable=1`)
- `mc reset cold`: スタックした FW アップデートの回復に使用

## ブート制御

### 概要

R320 の BIOS ブート順序は iDRAC7 racadm 経由で制御可能:
- **iDRAC.ServerBoot** — 次回ブートデバイスの一時設定（BootOnce/FirstBootDevice）
- **BIOS.BiosBootSettings** — 永続的ブートシーケンス（BootSeq, BootMode）

### スクリプトサブコマンド

```sh
./scripts/idrac-virtualmedia.sh boot-status $BMC_IP   # 現在のブート設定表示
./scripts/idrac-virtualmedia.sh boot-once $BMC_IP VCD-DVD  # 一時ブートデバイス設定
./scripts/idrac-virtualmedia.sh boot-reset $BMC_IP    # boot-once 解除（通常ブート復帰）
```

### FirstBootDevice の有効な値

| 値 | 説明 |
|----|------|
| `Normal` | BIOS BootSeq に従う（デフォルト） |
| `PXE` | ネットワークブート |
| `BIOS` | BIOS セットアップに入る |
| `VCD-DVD` | VirtualMedia CD/DVD |
| `Floppy` | VirtualMedia フロッピー |
| `HDD` | ハードディスク |

### VirtualMedia ブート → HDD ブートの切り替え

OS インストール後、VirtualMedia ブート設定をクリアしないと「No boot device available」が発生する:

```sh
# インストール前: VirtualMedia からブート
./scripts/idrac-virtualmedia.sh boot-once $BMC_IP VCD-DVD

# インストール完了後: boot-once を解除して HDD からブート
./scripts/idrac-virtualmedia.sh umount $BMC_IP
./scripts/idrac-virtualmedia.sh boot-reset $BMC_IP
```

### 永続的ブート順序

BIOS BootSeq は racadm set + ジョブキューで変更可能（通常は変更不要）:

```sh
# 現在の BootSeq 確認
ssh -F ssh/config idrac7 racadm get BIOS.BiosBootSettings.BootSeq

# 変更する場合（ジョブキュー + リブートが必要）
ssh -F ssh/config idrac7 racadm set BIOS.BiosBootSettings.BootSeq HardDisk.List.1-1,NIC.Embedded.1-1-1,...
ssh -F ssh/config idrac7 racadm jobqueue create BIOS.Setup.1-1 -r pwrcycle -s TIME_NOW
```

デフォルト BootSeq: `HardDisk.List.1-1,NIC.Embedded.1-1-1,Optical.SATAEmbedded.E-1,Unknown.Slot.1-1`
HddSeq: `RAID.Integrated.1-1` (PERC H310 仮想ディスク)

### R320 固有の注意事項

- BootMode は `Bios`（レガシー）。UEFI ではない
- POST は遅い（Lifecycle Controller: Collecting System Inventory... で 2-3 分）
- ACPI Error (AE_NOT_EXIST for IPMI handler) が起動時に出るが動作に影響なし
- `cfgServerBootOnce`（旧構文）と `iDRAC.ServerBoot.BootOnce`（新構文）は同じ設定。新構文を推奨

## SOL (Serial Over LAN)

### 接続

```sh
ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 sol activate
```

切断: `~.` (チルダ + ドット) または `ipmitool ... sol deactivate`

### 前提条件

| 設定 | 必要値 | 確認コマンド |
|------|--------|-------------|
| IPMI SOL Enable | Enabled | `ssh -F ssh/config idrac7 racadm get iDRAC.IPMISOL` |
| SOL BaudRate | 115200 | (同上) |
| BIOS RedirAfterBoot | **Enabled** | `ssh -F ssh/config idrac7 racadm get BIOS.SerialCommSettings` |
| BIOS SerialComm | OnConRedirCom2 | (同上) |
| カーネル console | `console=ttyS0,115200n8` | `cat /proc/cmdline` |

### 重要: COM ポートのマッピング

R320 iDRAC7 では **BIOS の COM2 リダイレクトと SOL の COM ポートが異なる**:

- **BIOS コンソールリダイレクト**: COM2 (0x2F8 = ttyS1) — POST 出力はこちら経由
- **iDRAC7 SOL (Linux 用)**: **COM1 (0x3F8 = ttyS0)** — SPCR ACPI テーブルで指定

BIOS POST 出力は INT10h リダイレクト経由で SOL に表示されるため、COM2 設定で問題ない。
Linux カーネル以降の出力は直接 UART I/O を使うため、SPCR が指す COM1 (ttyS0) に出力する必要がある。

### SOL で表示される内容

| フェーズ | SOL 表示 | 仕組み |
|---------|---------|--------|
| BIOS POST | OK | BIOS INT10h → COM2 リダイレクト |
| GRUB メニュー | OK (BIOS リダイレクト経由) | INT10h テキストモード |
| Linux カーネル | OK (`console=ttyS0` 必須) | 直接 UART I/O |
| ログインプロンプト | OK (serial-getty@ttyS0) | 直接 UART I/O |

### RedirAfterBoot の重要性

`RedirAfterBoot=Disabled` (デフォルト) では BIOS POST 後に SOL が途切れる。
**必ず Enabled に設定**すること:

```sh
ssh -F ssh/config idrac7 racadm set BIOS.SerialCommSettings.RedirAfterBoot Enabled
ssh -F ssh/config idrac7 racadm jobqueue create BIOS.Setup.1-1
# パワーサイクルで適用
```

## KVM スクリーンショット

### 使用方法

```sh
python3 ./scripts/idrac-kvm-screenshot.py \
    --bmc-ip $BMC_IP --bmc-user claude --bmc-pass Claude123 \
    --output tmp/<session-id>/screenshot.png
```

### 動作方式

| 順序 | 方式 | 解像度 | 品質 | 条件 |
|------|------|--------|------|------|
| 1 (主) | VNC (port 5901) | 800x600 | フルカラー | 最大 3 回リトライ |
| 2 (副) | capconsole API | 400x300 | グレースケール | VNC 全失敗時のフォールバック |

### オプション引数

| 引数 | デフォルト | 説明 |
|------|-----------|------|
| `--vnc-pass` | `Claude1` | VNC パスワード |
| `--vnc-port` | `5901` | VNC ポート |
| `--timeout` | `30` | タイムアウト秒（VNC は半分の値を使用） |

### 前提条件

- `iDRAC.VNCServer.Enable` = `Enabled`（全 3 台設定済み）
- VNC パスワード設定済み (`Claude1`)
- `cryptography` + `Pillow` が必要（不足時は VNC スキップし capconsole へ）

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

### VNC スクリーンアイドル

iDRAC7 VNC はしばらく画面更新がないと "SYSTEM IDLE" を表示する。
スクリーンショットスクリプトは自動で Wake キーイベントを送信して復帰させる。
手動で送る場合: RFB KeyEvent `struct.pack(">BBxxI", 4, down_flag, keysym)`。

## 既知の失敗パターン

### D1: SSH 接続拒否 (Connection refused)

iDRAC リセット後やFWアップデート後に発生。60-120 秒待機して再試行。

### D2: ホスト鍵変更 (REMOTE HOST IDENTIFICATION HAS CHANGED)

FW アップデート後に SSH ホスト鍵が変わる。解決:
```sh
ssh-keygen -R $BMC_IP -f ssh/known_hosts
```

### D3: racadm racreset 拒否 (firmware update in progress)

FW アップデートジョブがスタック状態。ipmitool で強制リセット:
```sh
ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 mc reset cold
```

前提: IPMI LAN が有効であること。無効の場合は先に SSH 経由で有効化:
```sh
ssh -F ssh/config idrac7 racadm config -g cfgIpmiLan -o cfgIpmiLanEnable 1
```

### D4: Ed25519 鍵で認証失敗

iDRAC7 は Ed25519 非対応。RSA 2048 鍵 (`ssh/idrac_rsa`) を使用すること。

## oplog・pve-lock ルール

| 操作 | oplog | pve-lock |
|------|-------|----------|
| getsysinfo, getconfig, jobqueue view | 不要 | 不要 |
| config (設定変更) | 必要 | 不要 (iDRAC 単体操作) |
| fwupdate | 必要 | 不要 (iDRAC 単体操作) |
| racreset | 必要 | 不要 |
| ipmitool power on/off/reset | 必要 | **必要** (サーバ電源操作) |
| ipmitool mc reset | 必要 | 不要 (BMC のみ) |

## SSH 鍵ブートストラップ (新規 iDRAC)

SSH 鍵が未登録の iDRAC には paramiko パスワード認証で接続して鍵を登録する:

```python
import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('<BMC_IP>', username='claude', password='Claude123',
          look_for_keys=False, allow_agent=False, timeout=15)

# ユーザインデックスを確認 (claude が index 2 か 3 かはサーバによる)
c.exec_command('racadm getconfig -g cfgUserAdmin -i 2')
c.exec_command('racadm getconfig -g cfgUserAdmin -i 3')

# 正しいインデックスに鍵を登録
c.exec_command('racadm sshpkauth -i <INDEX> -k 1 -t "<PUB_KEY>"')

# IPMI LAN を有効化 (デフォルトで無効)
c.exec_command('racadm config -g cfgIpmiLan -o cfgIpmiLanEnable 1')
```

**注意**: 8/9号機では `claude` ユーザは index 3 (7号機は index 2)。`getconfig -g cfgUserAdmin -i N` で `cfgUserAdminUserName` を確認すること。

## PERC H710 Missing VDs プロンプト

R320 の PERC H710 は以前存在した VD が検出されない場合 "The following VDs are missing" プロンプトを表示し、キー入力を待つ。
SOL 経由で Enter キーを送信して通過させる必要がある。`tmp/<session-id>/sol-send-enter.py` スクリプトで POST 中に定期的に Enter を送信するパターンが有効。

## Lifecycle Controller 初回有効化

FW アップグレード後に LC が無効な場合:
```sh
ssh -F ssh/config idrac8 racadm set LifecycleController.LCAttributes.LifecycleControllerState 1
```
初回有効化後の "Collecting System Inventory" は 10-15 分かかる。SOL で Enter キーを送って PERC プロンプトを通過させないと LC がスタックする。

## 参照

- [iDRAC7 FW アップグレードレポート](../../../report/2026-03-02_143000_idrac7_firmware_upgrade.md)
- [iDRAC SSH セットアップレポート](../../../report/2026-03-02_052246_dell_r320_idrac_setup.md)
- [idrac7-fw-update スキル](../idrac7-fw-update/SKILL.md)
- [Region B 構築レポート](../../../report/2026-03-19_173724_linstor_thick_stripe_benchmark_region_b.md)
