# OS Setup 技術リファレンス

## BMC CGI API

### 認証フロー

1. **ログイン**: `POST https://<bmc_ip>/cgi/login.cgi` (name=<user>&pwd=<pass>)
   - cookie を保存（`-c cookie_file`）
2. **CSRF トークン取得**: `GET https://<bmc_ip>/cgi/url_redirect.cgi?url_name=topmenu`
   - レスポンスから `CSRF_TOKEN", "<value>"` を正規表現で抽出
3. 以降のリクエストに `-H "CSRF_TOKEN: <value>"` を付与

**重要**: ヘッダ名は `CSRF_TOKEN`。`X-CSRFTOKEN` は動作しない（"Token Value is not matched" エラー）。

### VirtualMedia CGI エンドポイント

エンドポイント: `POST https://<bmc_ip>/cgi/op.cgi`

| 操作 | POST データ |
|------|-----------|
| ISO 設定 | `op=config_iso&host=<smb_host>&path=<smb_path>&user=&pwd=` |
| マウント | `op=mount_iso` |
| アンマウント | `op=umount_iso` |
| ステータス | `op=vm_status` |

SMB パスの例: `\public\debian-preseed.iso`（バックスラッシュ）

### VirtualMedia ステータス応答

- マウント成功時: `iso_total_size` を含む JSON 応答
- 未マウント時: サイズが 0 の応答

## Redfish API

### 認証

Basic 認証: `-u <user>:<pass>`

### 電源制御

```
POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset
```

| ResetType | 動作 |
|-----------|------|
| `On` | 電源オン |
| `ForceOff` | 強制電源オフ |
| `GracefulShutdown` | OS シャットダウン |
| `ForceRestart` | 強制リスタート |

### Boot Override

```
PATCH /redfish/v1/Systems/1
```

**CD から UEFI ブート（1回限り）** — 注意: VirtualMedia CD では動作しないことがある:
```json
{
  "Boot": {
    "BootSourceOverrideEnabled": "Once",
    "BootSourceOverrideTarget": "Cd",
    "BootSourceOverrideMode": "UEFI"
  }
}
```

**UefiBootNext（推奨）** — VirtualMedia CD の BootOption ID を直接指定:
```json
{
  "Boot": {
    "BootSourceOverrideEnabled": "Once",
    "BootSourceOverrideTarget": "UefiBootNext",
    "BootSourceOverrideMode": "UEFI",
    "BootNext": "Boot0011"
  }
}
```
- **`BootSourceOverrideMode: "UEFI"` は必須**。デフォルト "Legacy" では UefiBootNext が無視される
- Boot ID は固定ではなく OS インストール後に変動する（例: Boot0011 → Boot0013）
- `bmc-power.sh find-boot-entry` で DisplayName パターンから Boot ID を動的検索可能
- BootOptions 一覧: `GET /redfish/v1/Systems/1/BootOptions`
- 各エントリ詳細: `GET /redfish/v1/Systems/1/BootOptions/<id>` の `DisplayName` で確認
- **重要**: VirtualMedia の BootOption は UEFI POST で VirtualMedia を検出した後にのみ出現する。
  サーバが Off の状態では存在しないため boot-next が失敗する。
  手順: VirtualMedia マウント → サーバ On → POST 完了待ち(約2分) → boot-next 設定 → cycle

**オーバーライド解除**:
```json
{
  "Boot": {
    "BootSourceOverrideEnabled": "Disabled"
  }
}
```

### PowerState 取得

```
GET /redfish/v1/Systems/1
```

レスポンスの `PowerState` フィールド: `"On"` または `"Off"`

## SOL (Serial Over LAN)

### 接続

```
ipmitool -I lanplus -H <bmc_ip> -U <user> -P <pass> sol activate
```

### 切断

- ipmitool エスケープ: `~.`
- deactivate コマンド: `ipmitool ... sol deactivate`

### SOL ブートステージ検出

| ステージ | 所要時間 | SOL パターン |
|----------|---------|-------------|
| POST/BIOS | 60-120秒 | バイナリデータ |
| GRUB メニュー | 5秒 (timeout) | `GNU GRUB`, メニューエントリ |
| カーネルブート | 10-30秒 | `Loading Linux`, `[  0.000000]` |
| systemd 起動 | 20-60秒 | `systemd[1]:`, `Started` |
| ログインプロンプト | 持続 | `<hostname> login:` |

**重要**: GRUB メニュー表示中はキー入力禁止（メニュー選択やコマンドモードに入る危険）

`scripts/sol-login.py` はこれらのステージを自動検出する状態機械を実装している。
GRUB_MENU / KERNEL_BOOT 状態ではキー入力を一切送信しない。

### SOL 監視パターン

バックグラウンドで SOL を起動し、出力をログファイルに記録:

```sh
ipmitool -I lanplus -H <bmc_ip> -U <user> -P <pass> sol activate
```

Bash の `run_in_background=true` で起動。出力で進行状況キーワードを検出:

| キーワード | 意味 |
|-----------|------|
| `Loading additional components` | インストーラ起動中 |
| `Detecting network hardware` | NIC 検出中 |
| `Retrieving preseed file` | preseed 読み込み中 |
| `Installing the base system` | ベースシステムインストール中 |
| `Configuring apt` | APT 設定中 |
| `Select and install software` | パッケージインストール中 |
| `Installing GRUB` | ブートローダ設定中 |
| `Installation complete` | インストール完了 |
| `login:` | OS 起動完了 |
| `Power down` | シャットダウン中 |

### sol-monitor.py 使用方法

パッシブ SOL 監視（インストーラ進行追跡）:

```sh
./scripts/sol-monitor.py \
    --bmc-ip <bmc_ip> --bmc-user <user> --bmc-pass <pass> \
    --log-file tmp/<session-id>/sol-install.log
```

終了コード: 0=完了, 1=タイムアウト, 2=接続エラー, 3=異常終了
キー入力は一切送信しない。PowerState は60秒間隔でポーリング。

## カーネルコンソール設定

```
console=tty0 console=ttyS1,115200n8
```

最後に指定したコンソールがプライマリ。SOL で見るには `ttyS1` を最後にする。

## GRUB シリアル設定

`/etc/default/grub`:
```
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS1,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=1 --speed=115200 --word=8 --parity=no --stop=1"
```

## POST code (Supermicro X11 / AMI Aptio V)

### 取得方法

```sh
scripts/bmc-power.sh postcode <bmc_ip> <user> <pass>
```

IPMI raw コマンド: `ipmitool raw 0x30 0x70 0x02`

### 主要 POST code テーブル

| コード | フェーズ | 説明 |
|--------|---------|------|
| 0x00 | — | POST 完了 or 電源 Off |
| 0x01 | SEC | 電源投入、リセット検出 |
| 0x02 | SEC | AP 初期化 |
| 0x19 | PEI | SB プレメモリ初期化 |
| 0x2B | PEI | メモリ初期化 |
| 0x34 | PEI | CPU ポストメモリ初期化 |
| 0x4F | DXE | DXE IPL 開始 |
| 0x60 | DXE | DXE コア開始 |
| 0x61 | DXE | NVRAM 初期化 |
| 0x68 | DXE | PCI ホストブリッジ初期化 |
| 0x69 | DXE | CPU DXE 初期化 |
| 0x6A | DXE | IOH DXE 初期化 |
| 0x70 | DXE | PCH DXE 初期化 |
| 0x90 | BDS | ブートデバイス選択開始 |
| 0x91 | BDS | ドライバ接続 |
| 0x92 | BDS | PCI バス初期化 |
| 0x93 | BDS | PCI バスホットプラグ |
| 0x94 | BDS | PCI バスリソース割当 |
| 0x95 | BDS | コンソール出力接続 |
| 0x96 | BDS | コンソール入力接続 |
| 0x97 | BDS | Super I/O 初期化 |
| 0x98 | BDS | USB 初期化開始 |
| 0x9A | BDS | USB 初期化 |
| 0x9B | BDS | USB 検出 |
| 0x9C | BDS | USB 有効化 |
| 0x9D | BDS | SCSI 初期化 |
| 0xA0 | BDS | IDE 初期化 |
| 0xA1 | BDS | IDE リセット |
| 0xA2 | BDS | IDE 検出 |
| 0xA3 | BDS | IDE 有効化 |
| 0xB2 | BDS | Legacy Option ROM 初期化 |
| 0xB4 | BDS | USB Option ROM 初期化 |
| 0xE0 | Boot | OS ブート開始 |
| 0xE1 | Boot | OS ローダ検出 |
| 0xE4 | Boot | OS へブート |

### POST code 監視の判断基準

| 状態 | 判断 |
|------|------|
| コードが30秒ごとに変化 | POST 正常進行中 |
| 0x92 で10分以上停滞 | POST スタック（回復手順参照） |
| コード安定（変化なし5分以上） | カーネルに制御移行済み |
| 0x00 | POST 完了 or 電源 Off |
| 0xE0〜0xE4 | OS ブートフェーズ |

### POST code の stale 値問題

BMC ファームウェアの制限により、POST code レジスタが特定のスタック状態で更新されないことがある。実際に POST 0x92 (PCI Bus Enumeration) でスタックしているにもかかわらず、IPMI raw (`0x30 0x70 0x02`) が `0x00` (POST complete) を返すケースが確認されている (Issue #17 テスト時)。

**POST code だけでスタック判定してはならない。** 以下の組み合わせで判定すること:

| PowerState | POST code | SSH/ping | 判定 |
|------------|-----------|----------|------|
| On | 0x00 | 到達可能 | 正常起動完了 |
| On | 0x00 | 不達 (5分以上) | **スタック疑い** — KVM スクリーンショットで視覚確認 |
| On | 0x01 | 不達 (3分以上) | **stale 疑い** — KVM スクリーンショットで視覚確認 |
| On | 0x01 | 到達可能 | stale 確定 — POST code API は信頼不可 |
| On | 0x92 | 不達 | POST スタック確定 — パワーサイクルで回復 |
| Off | 0x00 | 不達 | 電源 Off（正常） |

**フォールバック確認手段**: `bmc-kvm.sh screenshot` で KVM スクリーンショットを取得し、実際の POST 画面を視覚的に確認する。POST code API の値が信頼できない場合の最終確認手段として使用する。

## エラーパターンと回復

### CSRF token 不一致

**検出**: レスポンスに "Token Value is not matched" を含む
**原因**: セッション切れ、または誤ったヘッダ名
**回復**:
1. `bmc-session.sh login` で再ログイン
2. `bmc-session.sh csrf` で新しいトークン取得

### POST code 92 スタック

**検出**: PowerState On かつ Health Critical が5分以上、SSH/ping 到達不能
**原因**:
1. ForceOff → On の間隔が短すぎる
2. 不正な UEFI NVRAM ブートエントリ（efibootmgr で作成した無効なデバイスパス等）
3. BIOS 設定リセット後のブートデバイス列挙エラー
**回復**:
1. `bmc-power.sh forceoff` で確実にオフ
2. **15秒以上**待機（`bmc-power.sh cycle` はデフォルト15秒）
3. `bmc-power.sh on` で起動
4. 解消しない場合: ForceOff → 2分以上待機 → On
5. それでも解消しない場合: 物理コンソールまたは BMC KVM で BIOS Setup に入りブートオーダーを確認

### IPMI raw コマンドによる BMC リセット (危険)

**警告**: `ipmitool raw 0x3c 0x40` は BMC をファクトリーリセットする。
**影響**:
- BMC ユーザアカウントがすべて削除される（ADMIN/ADMIN に戻る）
- BMC ネットワーク設定がリセットされる可能性がある
- POST code 92 の解消には効果がない場合がある
**回復**: `ipmitool -U ADMIN -P ADMIN user set name 3 claude` 等でユーザを再作成

### late_command 失敗

**検出**: SSH 接続後 `sudo -n true` が失敗
**原因**: in-target コマンドが preseed の late_command で正しく実行されなかった
**回復（SSH 経由）**:
```sh
ssh root@<ip> 'echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian && chmod 0440 /etc/sudoers.d/debian'
ssh root@<ip> 'sed -i "s/^#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config && systemctl restart sshd'
```

### poweroff 未動作

**検出**: インストール完了メッセージ後、PowerState が45分以上 On のまま
**原因**: Debian 13 で `d-i debian-installer/exit/poweroff` が効かないケースがある
**回復**:
1. `bmc-power.sh forceoff` で強制オフ
2. VirtualMedia をアンマウント
3. Boot override を解除
4. `bmc-power.sh on` でディスクから起動

### NIC 名変更（カーネル変更時）

**検出**: PVE カーネルリブート後に SSH 接続不可
**原因**: Debian カーネルと PVE カーネルで NIC 命名が異なる場合がある
**回復**:
1. SOL で接続: `ipmitool ... sol activate`
2. root でログイン
3. `ip link` で現在の NIC 名を確認
4. `/etc/network/interfaces` を修正
5. `systemctl restart networking`

**Debian 13 + PVE 9 での確認済み NIC 名**: `eno1np0`, `eno2np1`, `eno3np2`, `eno4np3`
（Debian カーネル 6.12 と PVE カーネル 6.17 で同一）

## preseed テンプレートプレースホルダ

| プレースホルダ | 説明 | 例 |
|--------------|------|-----|
| `%%HOSTNAME%%` | ホスト名 | ayase-web-service-4 |
| `%%DOMAIN%%` | ドメイン | local |
| `%%DISK%%` | ターゲットディスク | /dev/nvme0n1 |
| `%%ROOT_PASSWORD%%` | root パスワード | password |
| `%%USER_NAME%%` | 一般ユーザ名 | debian |
| `%%USER_PASSWORD%%` | 一般ユーザパスワード | password |
| `%%CONSOLE_ORDER%%` | カーネルコンソール引数 | console=tty0 console=ttyS1,115200n8 |

## ISO リマスター

`scripts/remaster-debian-iso.sh` が Docker 内で以下を実行:
1. GRUB/isolinux 設定をシリアルコンソール + 自動インストール用に書き換え
2. preseed.cfg を ISO ルートに配置（`-map preseed.cfg /preseed.cfg`）
3. カーネルパラメータに `preseed/file=/cdrom/preseed.cfg auto=true priority=critical` を設定
4. `xorriso -boot_image any replay` で UEFI ブート構造を保持した ISO を再構築

> **注意**: 以前は preseed を initrd に cpio 連結で注入していたが、
> iDRAC7 VNC で d-i TUI が表示されない問題が発生したため廃止。
> preseed/file= カーネルパラメータ方式に統一した。

引数: `<元ISO> <preseed.cfg> <出力ISO>`
デフォルト出力: `/var/samba/public/debian-preseed.iso`

### 7号機 (Legacy BIOS / iDRAC7 VNC) 固有の設定

- `--legacy-only` フラグで EFI パッチをスキップ
- カーネルパラメータ: `vga=normal nomodeset`（`vga=788` は iDRAC7 VNC 非互換）
- preseed: `preseed/preseed-server7.cfg`（ミラーなし、静的 IP、CD のみ）

### efi.img パッチ注意点

ISO リマスター時に efi.img 内の GRUB を再構築してシリアルコンソール対応にする。
`grub-mkstandalone` (Option B) のみが有効。以下の注意点がある:

1. **`search` ターゲット**: `search --file /boot/grub/grub.cfg` は memdisk 内の grub.cfg を
   再帰的に検出して無限ループを引き起こす。`search --file /install.amd/vmlinuz` のように
   ISO 上にのみ存在するファイルを指定する
2. **`set prefix` を変更しない**: prefix を書き換えると GRUB モジュールパスが壊れ、
   モジュールの動的ロードが失敗する。menuentry は embed.cfg に直接記述して
   外部 grub.cfg への依存を回避する
3. **`--modules` で全必要モジュールを明示指定**: embed.cfg から使用する全モジュールを
   `grub-mkstandalone --modules="..."` で静的リンクする。動的ロードに頼ると
   prefix 問題でモジュールが見つからない場合がある
4. **必要なモジュール例**: `part_gpt part_msdos fat iso9660 search serial
   linux normal echo test gzio`
