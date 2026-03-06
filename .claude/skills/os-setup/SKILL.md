---
name: os-setup
description: "Debian + Proxmox VE OS自動セットアップ。BMC VirtualMedia経由でpreseedインストール、PVEインストールまでを実行する。"
argument-hint: "<config_file>"
---

# OS Setup スキル

Debian + Proxmox VE のインストールを BMC VirtualMedia 経由で自動実行する。

## 事前準備

1. 設定ファイルを引数で指定する（例: `config/server4.yml`, `config/server5.yml`）
   - 新規サーバの場合は `config/os-setup.example.yml` をコピーして `config/server<N>.yml` として編集
2. 技術詳細は `reference.md` を参照

## スクリプト一覧

| スクリプト | 用途 |
|-----------|------|
| `./scripts/bmc-session.sh` | BMC 認証・CSRF トークン (Supermicro) |
| `./scripts/bmc-virtualmedia.sh` | VirtualMedia 操作 (Supermicro) |
| `./scripts/bmc-power.sh` | Redfish 電源制御 + POST code 取得 (Supermicro) |
| `./scripts/bmc-kvm.sh` | BMC KVM スクリーンショット (Supermicro) |
| `./scripts/idrac-virtualmedia.sh` | VirtualMedia + Boot 操作 (iDRAC) |
| `./scripts/os-setup-phase.sh` | フェーズ状態管理 |
| `./scripts/generate-preseed.sh` | preseed 生成 |
| `./scripts/remaster-debian-iso.sh` | ISO リマスター |
| `./scripts/pve-setup-remote.sh` | PVE インストール（リモート実行） |
| `./scripts/pre-pve-setup.sh` | DHCP + apt セットアップ（リモート実行、R320 等） |
| `./scripts/ssh-wait.sh` | SSH 再接続ポーリング |
| `./scripts/sol-monitor.py` | SOL 経由インストール監視 (自動再接続対応) |
| `./scripts/sol-login.py` | SOL 経由ログイン・コマンド実行 |
| `./scripts/bmc-kvm-screenshot.py` | BMC KVM スクリーンショット (Supermicro) |

## Platform Dispatch (プラットフォーム分岐)

config の `bmc_type` フィールドでプラットフォームを判別する。

| 操作 | Supermicro (`bmc_type: supermicro`) | iDRAC (`bmc_type: idrac`) |
|------|-------------------------------------|---------------------------|
| VirtualMedia マウント | `bmc-session.sh` + `bmc-virtualmedia.sh` | `idrac-virtualmedia.sh mount` |
| VirtualMedia アンマウント | `bmc-virtualmedia.sh umount` | `idrac-virtualmedia.sh umount` |
| Boot 設定 | `bmc-power.sh boot-next` (UefiBootNext) | `idrac-virtualmedia.sh boot-once` (racadm legacy) |
| Boot リセット | `bmc-power.sh boot-override-reset` | `idrac-virtualmedia.sh boot-reset` |
| POST code 監視 | `bmc-power.sh postcode` | N/A (SOL / VNC で代替) |
| KVM スクリーンショット | `bmc-kvm.sh screenshot` | VNC (`vnc-wake-screenshot.py`, port 5901) |
| SOL serial unit | ttyS1 (COM2, `serial_unit: 1`) | ttyS0 (COM1, `serial_unit: 0`) |
| pre-pve-setup | 不要 | 必要 (`pre-pve-setup.sh`) |

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/server4.yml"  # 引数で指定されたパス
BMC_TYPE=$("$YQ" '.bmc_type' "$CONFIG")
BMC_IP=$("$YQ" '.bmc_ip' "$CONFIG")
SERIAL_UNIT=$("$YQ" '.serial_unit' "$CONFIG")
ISO_FILENAME=$("$YQ" '.iso_filename' "$CONFIG")
SMB_HOST=$("$YQ" '.smb_host' "$CONFIG")
SMB_SHARE=$("$YQ" '.smb_share_path' "$CONFIG")  # YAML "\\public" → \public
# 以下同様に各値を読み取る
```

## 並列実行セットアップ

複数サーバを同時にセットアップする場合の規約:

```
SERVER_SUFFIX = hostname の末尾数字 (例: ayase-web-service-4 → "4")
```

| リソース | 命名規則 |
|---------|---------|
| preseed | `preseed/preseed-generated-s${SUFFIX}.cfg` |
| ISO | config の `iso_filename` (サーバ別に分離済み) |
| cookie | `tmp/<session-id>/bmc-cookie-s${SUFFIX}` |
| SOL ログ | `tmp/<session-id>/sol-install-s${SUFFIX}.log` |
| pve-lock | 並列時は常に `./pve-lock.sh wait` を使用 |
| 試行ログ | `tmp/<session-id>/trial-N-s${SUFFIX}.log` |

## リトライポリシー

| 操作 | 最大リトライ | 間隔 | フォールバック |
|------|------------|------|-------------|
| BMC session login | 3 | 10s | エラー停止 |
| VirtualMedia mount + verify | 3 | 15s | 再ログイン + 再mount |
| SOL connect (sol-monitor.py) | 3 | 5s | POST code ポーリング (Supermicro) / VNC (iDRAC) |
| SSH connect (ssh-wait.sh) | 30 | 10s | SOL 確認 |
| DHCP IPv4 (pre-pve-setup.sh) | 6 | 5s | dhclient |

## フェーズ実行

### 初期化

```sh
./scripts/os-setup-phase.sh init --config "$CONFIG"
./scripts/os-setup-phase.sh status --config "$CONFIG"
```

`--config` を指定すると、設定ファイル名からサーバ別の状態ディレクトリが自動導出される（例: `config/server6.yml` → `state/os-setup/server6/`）。これにより、異なるサーバの状態が互いに干渉しない。

既に初期化済みの場合は `status` で進行状況を確認し、完了済みフェーズはスキップする。
`./scripts/os-setup-phase.sh next --config "$CONFIG"` で次の未完了フェーズを取得する。

### 所要時間の記録

各フェーズ開始時に `./scripts/os-setup-phase.sh start <phase> --config "$CONFIG"` を実行する。
`mark` 時に終了タイムスタンプが自動記録される。

---

### Phase 1: iso-download

**pve-lock**: 不要

1. 設定ファイルから `debian_iso_url`, `debian_iso_sha256`, `iso_download_dir` を読み取る
2. ISO がダウンロード済みか確認（ファイル存在 + sha256 照合）
3. 未ダウンロードなら `curl -L -o <path> <url>` でダウンロード
4. sha256 検証: `sha256sum <file>` の出力と設定値を比較
5. 完了: `./scripts/os-setup-phase.sh mark iso-download --config "$CONFIG"`

**エラー時**: sha256 不一致 → ファイル削除して再ダウンロード

---

### Phase 2: preseed-generate

**pve-lock**: 不要

**Supermicro の場合**:
1. `./scripts/generate-preseed.sh <config.yml> preseed/preseed-generated-s${SUFFIX}.cfg`
2. 生成結果を確認（diff でテンプレートとの差分表示）

**iDRAC の場合**:
1. preseed は `preseed/preseed-server7.cfg` を手動管理。`generate-preseed.sh` は使用しない
2. preseed ファイルの内容を確認するだけでよい

完了: `./scripts/os-setup-phase.sh mark preseed-generate --config "$CONFIG"`

---

### Phase 3: iso-remaster

**pve-lock**: 不要

1. ISO パスと preseed のパスを確認
2. **ISO 再利用チェック**: 出力 ISO が既に存在し、preseed が前回と同一なら リマスターをスキップ:
   ```
   sha256sum <preseed_file> で現在のハッシュを取得
   前回のハッシュファイル (<iso_download_dir>/${ISO_FILENAME}.preseed-sha256) と比較
   → 一致 && 出力 ISO が存在 → リマスターをスキップ (Phase 3 即完了)
   → 不一致 or ISO なし → リマスター実行 (ステップ 3 へ)
   ```
3. ISO リマスター実行:

**Supermicro の場合**:
```sh
./scripts/remaster-debian-iso.sh <元ISO> preseed/preseed-generated-s${SUFFIX}.cfg <iso_download_dir>/${ISO_FILENAME}
```

**iDRAC の場合**:
```sh
./scripts/remaster-debian-iso.sh <元ISO> preseed/preseed-server7.cfg <iso_download_dir>/${ISO_FILENAME} --serial-unit=0
```
- `--legacy-only` を**付けない**（UEFI + Legacy dual boot ISO を生成）
- `--serial-unit=0` を指定（R320 の SOL は COM1/ttyS0）
- `remaster-debian-iso.sh` のカーネルパラメータが `vga=normal nomodeset` であること確認
- preseed は **initrd への注入禁止**（d-i TUI が壊れる）。`preseed/file=/cdrom/preseed.cfg` でISO ルート配置のみ使用

4. リマスター成功後、preseed ハッシュを保存:
   ```
   sha256sum <preseed_file> の出力を <iso_download_dir>/${ISO_FILENAME}.preseed-sha256 に保存
   ```
5. 出力 ISO の存在確認
4. 完了: `./scripts/os-setup-phase.sh mark iso-remaster --config "$CONFIG"`

#### iDRAC: UEFI モードの確認 (初回のみ)

R320 は **UEFI モード**で運用する。preseed から `partman-efi/non_efi_system` を削除済みで、
UEFI モードでは partman が自動的に ESP を作成し grub-efi-amd64 が正常にインストールされる。
Legacy BIOS モードでは GPT パーティションテーブルからブートできない問題が発生する。

R320 が Legacy BIOS モードの場合、以下で UEFI に切り替える:
```sh
ssh -i ~/.ssh/idrac_rsa claude@10.10.10.120 racadm set BIOS.BiosBootSettings.BootMode Uefi
ssh -i ~/.ssh/idrac_rsa claude@10.10.10.120 racadm jobqueue create BIOS.Setup.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA
# Power On して JOB 完了を待つ (約6分)
ssh -i ~/.ssh/idrac_rsa claude@10.10.10.120 racadm jobqueue view
# Status=Completed を確認
```

#### iDRAC: racadm コマンドの注意 (iDRAC7 FW 2.65.65.65)

`racadm set iDRAC.ServerBoot.BootOnce` は iDRAC7 で**サイレントに失敗**する。
BootOnce の操作には legacy コマンドを使用すること:
```sh
racadm config -g cfgServerInfo -o cfgServerBootOnce 1   # 有効化
racadm config -g cfgServerInfo -o cfgServerBootOnce 0   # 無効化
```
`FirstBootDevice` は `racadm set iDRAC.ServerBoot.FirstBootDevice` が正常に動作する。
`idrac-virtualmedia.sh` は修正済み (legacy コマンドを使用)。

---

### Phase 4: bmc-mount-boot

**pve-lock**: 必要（`./pve-lock.sh wait` で実行）

このフェーズは以下をまとめて実行する:

#### ステップ 0: サーバ状態の正規化

Phase 4 開始前にサーバを確実に Off にする:
```sh
PowerState=$(./scripts/bmc-power.sh status "$BMC_IP" "$BMC_USER" "$BMC_PASS")
# On なら ForceOff → 10 秒待機
```
これにより BootOptions 列挙が 1 回のパワーサイクルで成功する確率が上がる。

#### Supermicro の場合

1. **BMC ログイン**:
   ```sh
   COOKIE_FILE="tmp/<session-id>/bmc-cookie-s${SUFFIX}"
   ./scripts/bmc-session.sh login "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$COOKIE_FILE"
   CSRF=$(./scripts/bmc-session.sh csrf "$BMC_IP" "$COOKIE_FILE")
   ```

2. **VirtualMedia 設定・マウント**:

   > **警告: SMB パスのバックスラッシュ**
   > SMB パスは必ず yq で config から読み取った値を使うこと。シェルリテラルで
   > バックスラッシュをハードコードすると二重バックスラッシュ (`\\\\public`) が
   > CGI API に送信され、CGI は成功を返すが実際にはマウントされない silent failure が発生する。

   ```sh
   SMB_PATH="${SMB_SHARE}\\${ISO_FILENAME}"
   ./scripts/bmc-virtualmedia.sh config "$BMC_IP" "$COOKIE_FILE" "$CSRF" "$SMB_HOST" "$SMB_PATH"
   ./scripts/bmc-virtualmedia.sh mount "$BMC_IP" "$COOKIE_FILE" "$CSRF"
   ./scripts/bmc-virtualmedia.sh status "$BMC_IP" "$COOKIE_FILE" "$CSRF"
   ```

3. **Redfish でマウント検証**:
   ```sh
   ./scripts/bmc-virtualmedia.sh verify "$BMC_IP" "$BMC_USER" "$BMC_PASS"
   ```
   - `Inserted: true` → 次のステップへ
   - `Inserted: false` → BMC 再ログイン + CSRF 再取得 + 再マウント + 再検証 (最大3回)

4. **サーバをパワーサイクルして BootOptions を列挙させる**:
   > **重要**: `ATEN Virtual CDROM` は UEFI POST で VirtualMedia を検出した後にのみ BootOptions に出現する。
   ```sh
   ./pve-lock.sh wait ./scripts/bmc-power.sh cycle "$BMC_IP" "$BMC_USER" "$BMC_PASS" 20
   ```
   POST 完了をアクティブポーリングで待機 (固定 sleep 180 の代わり):
   - `bmc-power.sh postcode` を **15 秒間隔**でポーリング
   - POST code `0x00` (POST complete) 到達 → 即座に次のステップへ
   - POST code が stale (`0x00` or `0x01`) のまま **45 秒**変化なし → POST API 不信頼と判断し次のステップへ進む
   - 最大 **180 秒**でタイムアウト (従来と同じ上限)
   - POST code `0x92` で 120 秒以上停滞 → POST スタック、ForceOff → 20s → On で再試行

5. **BootOptions から VirtualMedia CD の Boot ID を動的検索**:
   ```sh
   BOOT_ID=$(./scripts/bmc-power.sh find-boot-entry "$BMC_IP" "$BMC_USER" "$BMC_PASS" "ATEN Virtual CDROM")
   ```
   - Boot ID は OS インストール後に変動する（例: Boot0011 → Boot0013）
   - `find-boot-entry` は最大3回リトライ（15秒間隔）
   - **絶対に efibootmgr -c でブートエントリを手動作成しないこと**

6. **Boot Override 設定** + **電源サイクル**:
   ```sh
   ./pve-lock.sh wait ./scripts/bmc-power.sh boot-next "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$BOOT_ID"
   ./pve-lock.sh wait ./scripts/bmc-power.sh cycle "$BMC_IP" "$BMC_USER" "$BMC_PASS" 20
   ```

   **POST 92 スタック (4号機固有)**:
   4号機は ForceOff 後のパワーサイクルで POST 92 (PCI Bus Enumeration) にスタックする傾向がある。
   `efibootmgr -n` + warm reboot でも回避不可 (検証済み)。
   ForceOff → 20s → On のリカバリで対処し、POST 92 発生時は追加 5-10 分を見込むこと。

#### iDRAC の場合

1. **VirtualMedia マウント**:
   ```sh
   REMOTE_URI=$("$YQ" '.remoteimage_uri' "$CONFIG")
   ./scripts/idrac-virtualmedia.sh mount "$BMC_IP" "$REMOTE_URI"
   ./scripts/idrac-virtualmedia.sh status "$BMC_IP"
   ./scripts/idrac-virtualmedia.sh verify "$BMC_IP"
   ```

2. **Boot Once 設定 + 電源サイクル**:
   ```sh
   ./scripts/idrac-virtualmedia.sh boot-once "$BMC_IP" VCD-DVD
   ./pve-lock.sh wait ./scripts/bmc-power.sh cycle "$BMC_IP" "$BMC_USER" "$BMC_PASS" 20
   ```

#### 共通

完了: `./scripts/os-setup-phase.sh mark bmc-mount-boot --config "$CONFIG"`

**エラー時**:
- CSRF エラー (Supermicro) → `bmc-session.sh login` + `csrf` を再実行
- VirtualMedia マウント失敗 → status 確認、再マウント (最大3回)

---

### Phase 5: install-monitor

**pve-lock**: 必要（Phase 4 から継続保持）

> **所要時間目安**: Debian インストールは通常 10-12 分。全フェーズ (Phase 1-8) 合計は 35-50 分。

Debian インストーラの進行を監視する。SOL 監視を主要手段とし、フォールバックはプラットフォーム別。

#### 1. SOL 監視（主要、共通）

`./scripts/sol-monitor.py` でインストーラの進行をパッシブ監視する:

```sh
./scripts/sol-monitor.py \
    --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
    --log-file tmp/<session-id>/sol-install-s${SUFFIX}.log \
    --max-reconnects 3
```

- キー入力は一切送信しない（パッシブ監視のみ）
- インストーラのステージ進行を stderr に表示
- EOF 時: PowerState 確認 → On なら自動で SOL deactivate + 5秒待機 + 再接続 (最大3回)
- EOF 時: PowerState=Off → exit 0 (インストール完了)
- "Power down" 検出 → 30秒待機 → PowerState 確認 → exit 0
- PowerState は20秒間隔でポーリング
- 終了コード: 0=完了, 1=タイムアウト, 2=接続エラー, 3=異常終了(再接続上限超過含む)

#### 2. SOL exit code 別の対処

| exit code | 状態 | 対処 |
|-----------|------|------|
| 0 | 完了 | 次の Phase へ |
| 1 | タイムアウト | PowerState 確認。Off→完了扱い。On→forceoff |
| 2 | 接続エラー | フォールバックへ |
| 3 | 異常終了 | PowerState 確認。Off→完了扱い。On→フォールバックへ |

#### 3. フォールバック

**Supermicro**: POST code ポーリング
```sh
./scripts/bmc-power.sh postcode "$BMC_IP" "$BMC_USER" "$BMC_PASS"
./scripts/bmc-power.sh status "$BMC_IP" "$BMC_USER" "$BMC_PASS"
```
- POST code を30秒間隔でポーリング
- PowerState を5分間隔でポーリング
- `Off` → インストール完了
- POST code `0x92` で10分以上停滞 → POST スタック（`reference.md` 参照）

**iDRAC**: VNC スクリーンショット
```sh
.venv/bin/python3 tmp/<session-id>/vnc-wake-screenshot.py
```

#### 完了処理

1. SOL を切断: `ipmitool ... sol deactivate`（sol-monitor.py が自動切断するが念のため）
2. 完了: `./scripts/os-setup-phase.sh mark install-monitor --config "$CONFIG"`

---

### Phase 6: post-install-config

**pve-lock**: 必要

Debian インストール後の初期設定。

#### ステップ 1: VirtualMedia アンマウント + Boot Override 解除

**Supermicro の場合**:
```sh
./scripts/bmc-session.sh login "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$COOKIE_FILE"
CSRF=$(./scripts/bmc-session.sh csrf "$BMC_IP" "$COOKIE_FILE")
./scripts/bmc-virtualmedia.sh umount "$BMC_IP" "$COOKIE_FILE" "$CSRF"
./pve-lock.sh wait ./scripts/bmc-power.sh boot-override-reset "$BMC_IP" "$BMC_USER" "$BMC_PASS"
```

**iDRAC の場合**:
```sh
./scripts/idrac-virtualmedia.sh umount "$BMC_IP"
./scripts/idrac-virtualmedia.sh boot-reset "$BMC_IP"
```
> boot-reset は BootOnce=Disabled + FirstBootDevice=Normal に設定する。

#### ステップ 2: ディスクからブート

```sh
./pve-lock.sh wait ./scripts/bmc-power.sh on "$BMC_IP" "$BMC_USER" "$BMC_PASS"
```

**Supermicro の場合** — POST code 監視:
- Power On 後 **30 秒待機**し POST code を確認
- POST code `0x92` で停滞 → 自動リカバリ (ForceOff → 20秒 → On)
- POST code `0x01`/`0x00` が 3-5 分変化なし → stale の疑い → KVM スクリーンショットで確認
- リカバリ後 `./scripts/ssh-wait.sh <static_ip> --timeout 180 --interval 10` でアクティブポーリング

**iDRAC の場合** — SSH リトライ:
- R320 の POST は 2-3 分 (Lifecycle Controller 初期化)
- `./scripts/ssh-wait.sh <static_ip> --timeout 210 --interval 10` で SSH 到達を待つ
- POST code 監視/KVM は使えない。SOL または VNC で代替

#### ステップ 3: SOL 経由でログイン確認・設定

> **重要**: preseed の late_command は Debian 13 で動作しないことが多い。
> SSH 公開鍵、PermitRootLogin、sudoers は SOL 経由で設定する必要がある。

a. SSH 公開鍵を Read ツールで `~/.ssh/id_ed25519.pub` から取得
b. コマンドファイルを `tmp/<session-id>/sol-commands-s${SUFFIX}.txt` に作成:
   ```
   sed -i "s/^#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
   systemctl restart sshd
   echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian
   chmod 0440 /etc/sudoers.d/debian
   mkdir -p /root/.ssh && chmod 700 /root/.ssh
   echo "<SSH_PUBKEY>" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
   printf "\nauto <static_iface>\niface <static_iface> inet static\n    address <static_ip>/8\n" >> /etc/network/interfaces
   ifup <static_iface>
   ip -brief addr
   ```
   > **重要**: 静的 IP 設定を SOL 経由で行うことで、DHCP IP への SSH 接続を不要にする。

c. `./scripts/sol-login.py` で実行:
   ```sh
   ./scripts/sol-login.py --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
       --root-pass "$ROOT_PASS" --commands-file tmp/<session-id>/sol-commands-s${SUFFIX}.txt
   ```

**sol-login.py がタイムアウトした場合** (Supermicro):
POST code 確認 → `0x92` なら ForceOff → 20秒 → On → `ssh-wait.sh --timeout 180 --interval 10` → sol-login.py を再実行。

**iDRAC のフォールバック**:
SOL が使えない場合は pexpect で debian ユーザにパスワード SSH → su root で設定する。

#### ステップ 4: ホスト鍵削除 + SSH 接続確認

```sh
ssh-keygen -R <static_ip>
./scripts/ssh-wait.sh <static_ip> --timeout 150 --interval 10
```

完了: `./scripts/os-setup-phase.sh mark post-install-config --config "$CONFIG"`

---

### Phase 7: pve-install

**pve-lock**: 必要

PVE のインストールを SSH 経由で実行。

#### ステップ 0: インターネット接続確保 (iDRAC / CD-only preseed の場合)

preseed が CD-only (`apt-setup/use_mirror boolean false`) の場合:
```sh
scp ./scripts/pre-pve-setup.sh root@<static_ip>:/tmp/
ssh root@<static_ip> sh /tmp/pre-pve-setup.sh --dhcp-iface <dhcp_iface> --static-gw 10.10.10.1 --codename <codename>
```

`pre-pve-setup.sh` は DHCP 有効化、デフォルトルート修正、apt sources 設定、wget/ca-certificates インストールを自動で行う。

#### ステップ 1: スクリプト転送 + pre-reboot

```sh
scp ./scripts/pve-setup-remote.sh root@<static_ip>:/tmp/
ssh root@<static_ip> /tmp/pve-setup-remote.sh --phase pre-reboot --hostname <hostname> --ip <static_ip> --codename <codename> --serial-unit ${SERIAL_UNIT}
```

#### ステップ 2: リブート + SSH 再接続待機

```sh
ssh root@<static_ip> reboot || true
./scripts/ssh-wait.sh <static_ip> --timeout 300 --interval 10
```

**ssh-wait.sh がタイムアウトした場合のリカバリ**:

**Supermicro の場合**:
1. POST code 確認: `./scripts/bmc-power.sh postcode "$BMC_IP" "$BMC_USER" "$BMC_PASS"`
   - `0x92` → POST スタック
   - `0x00`/`0x01` が長時間 → stale の疑い → `./scripts/bmc-kvm.sh screenshot "$BMC_IP" tmp/<session-id>/post-check.png`
2. パワーサイクル: ForceOff → 20秒 → On → `./scripts/ssh-wait.sh <static_ip> --timeout 180 --interval 10`

**iDRAC の場合**:
- R320 の POST は 2-3 分 (Lifecycle Controller)
- SOL 監視 / VNC スクリーンショットで確認
- 必要ならパワーサイクル: ForceOff → 20秒 → On → `./scripts/ssh-wait.sh <static_ip> --timeout 180 --interval 10`

#### ステップ 3: ルート修正 (iDRAC の場合)

SSH 再接続後、post-reboot 前にデフォルトルートを修正する。`pre-pve-setup.sh` を再実行するのが最も確実:
```sh
scp ./scripts/pre-pve-setup.sh root@<static_ip>:/tmp/
ssh root@<static_ip> sh /tmp/pre-pve-setup.sh --dhcp-iface <dhcp_iface> --static-gw 10.10.10.1 --codename <codename>
```
または手動で:
```sh
ssh root@<static_ip> ip route del default via 10.10.10.1 || true
ssh root@<static_ip> ip route add default via 192.168.39.1 || true
```

**ルート検証** (iDRAC に限らず全プラットフォーム共通で推奨):
ルート修正後にインターネット到達性を確認:
```sh
ssh root@<static_ip> ping -c1 -W3 deb.debian.org || echo "WARN: no internet"
```
→ 失敗時は `ip route` を確認し、DHCP ルート (`192.168.39.1`) を手動追加

#### ステップ 4: post-reboot

```sh
scp ./scripts/pve-setup-remote.sh root@<static_ip>:/tmp/
ssh root@<static_ip> /tmp/pve-setup-remote.sh --phase post-reboot --hostname <hostname> --ip <static_ip> --codename <codename> --serial-unit ${SERIAL_UNIT}
```

#### ステップ 5: 最終リブート + PVE 動作確認

```sh
ssh root@<static_ip> reboot || true
./scripts/ssh-wait.sh <static_ip> --timeout 300 --interval 10
```

- **iDRAC**: SSH 再接続後にルート修正 + 検証:
  ```sh
  ssh root@<static_ip> ip route del default via 10.10.10.1 || true
  ssh root@<static_ip> ip route add default via 192.168.39.1 || true
  ssh root@<static_ip> ping -c1 -W3 deb.debian.org || echo "WARN: no internet"
  ```
- `ssh root@<static_ip> pveversion` で PVE バージョン確認
- `curl -sk https://<static_ip>:8006` で Web UI アクセス確認

完了マーク（**必須**）: `./scripts/os-setup-phase.sh mark pve-install --config "$CONFIG"`
> **WARNING**: このマークを忘れると Phase 8 が開始できない。

---

### Phase 8: cleanup

**前提チェック**: `./scripts/os-setup-phase.sh check pve-install --config "$CONFIG"`

**pve-lock**: 必要

#### Supermicro の場合

1. VirtualMedia クリーンアップ:
   ```sh
   ./scripts/bmc-session.sh login "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$COOKIE_FILE"
   CSRF=$(./scripts/bmc-session.sh csrf "$BMC_IP" "$COOKIE_FILE")
   ./scripts/bmc-virtualmedia.sh umount "$BMC_IP" "$COOKIE_FILE" "$CSRF"
   ```
2. Boot Override 解除:
   ```sh
   ./pve-lock.sh wait ./scripts/bmc-power.sh boot-override-reset "$BMC_IP" "$BMC_USER" "$BMC_PASS"
   ```

#### iDRAC の場合

1. VirtualMedia クリーンアップ:
   ```sh
   ./scripts/idrac-virtualmedia.sh umount "$BMC_IP"
   ```
2. Boot リセット確認:
   ```sh
   ./scripts/idrac-virtualmedia.sh boot-status "$BMC_IP"
   ```

#### 共通

3. cookie ファイル削除: `rm -f "$COOKIE_FILE"`

4. **最終検証サマリ**:
   - OS: `ssh root@<static_ip> cat /etc/os-release`
   - PVE: `ssh root@<static_ip> pveversion`
   - カーネル: `ssh root@<static_ip> uname -r`
   - ネットワーク: `ssh root@<static_ip> ip -brief addr`
   - Web UI: `curl -sk https://<static_ip>:8006`

5. 完了: `./scripts/os-setup-phase.sh mark cleanup --config "$CONFIG"`

6. **レポート作成**: `report/` ディレクトリに実行結果のレポートを作成
   - `./scripts/os-setup-phase.sh times --config "$CONFIG"` の出力をレポートに転記

---

## Resume（中断からの再開）

スキル呼び出し時に `./scripts/os-setup-phase.sh status --config "$CONFIG"` で現在の状態を確認し、
完了済みフェーズをスキップして次のフェーズから再開する。

`./scripts/os-setup-phase.sh next --config "$CONFIG"` で次の未完了フェーズ名を取得できる。

失敗したフェーズは `./scripts/os-setup-phase.sh reset <phase> --config "$CONFIG"` でリセットして再実行可能。

## pve-lock の使い方

Phase 4〜8 では状態変更操作に `./pve-lock.sh` を使用する:

```sh
./pve-lock.sh run <command...>     # 即座に実行（ロック中ならエラー）
./pve-lock.sh wait <command...>    # ロック待ち→実行（並列時はこちらを使用）
```

ロック中の場合は別の課題に着手し、ロック解放後に再開する。
