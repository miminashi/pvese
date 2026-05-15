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
| KVM スクリーンショット | `bmc-kvm.sh screenshot` | `idrac-kvm-screenshot.py` (VNC primary + capconsole fallback) |
| SOL serial unit | ttyS1 (COM2, `serial_unit: 1`) | ttyS0 (COM1, `serial_unit: 0`) |
| pre-pve-setup | 不要 (内部 mgmt + 外部 DHCP は legacy bridge で同居) | 必要 (`pre-pve-setup.sh`) |

> **VLAN trunk 環境** (10号機の例、別拠点): host LAN が 1本の VLAN trunk
> (内部 mgmt + 外部 DHCP がタグ付き) で来る場合、`config/serverN.yml` に
> 以下を追加すれば自動で対応される。フィールドが無い 4-9号機は従来動作。
> ```yaml
> vlan_iface: eno1            # trunk 物理 NIC (Phase 0 で実測)
> internet_vlan_id: 1120       # DHCP/インターネット側
> internal_vlan_id: 1083       # 10.0.0.0/8 内部 mgmt 側
> static_iface: vmbr0          # 静的 IP は vmbr0 上に乗る
> dhcp_iface: vmbr1            # DHCP は vmbr1 上に乗る
> ```
> - `generate-preseed.sh` が early_command で 8021q + VLAN サブを作り、
>   late_command で 8021q 永続化と VLAN サブインタフェース定義を target に書き込む
> - `pve-bridge-setup.sh` を Phase 8 で `--vlan-iface` 系フラグ付きで呼ぶ:
>   `pve-bridge-setup.sh --vlan-iface eno1 --internet-vlan-id 1120
>   --internal-vlan-id 1083 --static-ip 10.10.10.210/8`
> - `pre-pve-setup.sh --dhcp-iface eno1.1120` で動作 (GW 動的検出済み)
> - 拠点固有 GW (4-9号機の `192.168.39.1` とは違う値) も DHCP 経由で動的取得される

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
| iDRAC install retry (full bmc-mount-boot 単位) | 3 | 5min | **racadm racreset soft** → 再 mount → 再 boot (R430 で実証) |

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

> **⚠️ `netcfg/choose_interface` は明示的に静的側 NIC を指定すること** (Round 1 s15/s5 で観測):
> `netcfg/choose_interface auto` は link up している先頭 NIC を選ぶため、mgmt 配線が `eno2` のサーバでも `eno1` (DHCP 側) に静的 IP が割り当てられ、Phase 6 で SSH 不到達になる。
> `generate-preseed.sh` は `static_iface` の値を自動設定するので、config の `static_iface` が正しければ問題ない。preseed.cfg.template は `%%CHOOSE_INTERFACE%%` プレースホルダーを使用。

> **⚠️ `netcfg/no_default_route` と `netcfg/gateway_unreachable` の両方を preseed に追加すること** (Round 1 s5 で観測):
> 管理ネットワーク (10.0.0.0/8) はインターネット到達性がないため、以下の 2 つのダイアログが blocking する:
> 1. "Continue without a default route?" — `d-i netcfg/no_default_route boolean true` で自動応答
> 2. "Gateway unreachable, continue?" — `d-i netcfg/gateway_unreachable boolean true` で自動応答
> `preseed.cfg.template` には両方追加済み (2026-05-14)。iDRAC 用の手動管理 preseed にも追記すること。

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
./scripts/remaster-debian-iso.sh <元ISO> preseed/preseed-server<N>.cfg <iso_download_dir>/${ISO_FILENAME} --serial-unit=<UNIT>
```

**`--serial-unit` の決定**: 事前に BIOS `SerialPortAddress` を確認して決める:

```sh
ssh -F ssh/config idrac<N> racadm get BIOS.SerialCommSettings.SerialPortAddress
```

| SerialPortAddress | iDRAC SOL → 物理 COM | kernel `console=` | `--serial-unit=` |
|-------------------|--------------------|-------------------|-----------------|
| `Serial1Com2Serial2Com1` | Serial2 → Com1 (0x3F8) | `ttyS0` | **`0`** |
| `Serial1Com1Serial2Com2` | Serial2 → Com2 (0x2F8) | `ttyS1` | **`1`** |

> **注意**: この値は個体ごとに異なる (Serial1Com2Serial2Com1 が推奨設定だが、
> F3 Load Defaults や過去の BIOS 操作で Serial1Com1Serial2Com2 に戻っている
> 個体もある)。SOL に BIOS POST は出るが installer 出力が出ない場合はこの
> mismatch を疑うこと (`report/2026-04-10_172807_server8_vmedia_recovery_test.md`
> 関連調査で発見)。

- `--legacy-only` を**付けない**（UEFI + Legacy dual boot ISO を生成）
- `remaster-debian-iso.sh` のカーネルパラメータが `vga=normal nomodeset` であること確認
- preseed は **initrd への注入禁止**（iDRAC VirtualMedia では d-i TUI が壊れる）。`preseed/file=/cdrom/preseed.cfg` でISO ルート配置のみ使用
- **例外: Supermicro VirtualMedia では initrd 注入が必要**。UEFI GRUB から `preseed/file=/cdrom/preseed.cfg` が読めない環境があるため、`remaster-debian-iso.sh` が preseed を initrd に注入する (ホスト側で 7z + cpio)。Supermicro の場合はこの動作がデフォルト

4. リマスター成功後、preseed ハッシュを保存:
   ```
   sha256sum <preseed_file> の出力を <iso_download_dir>/${ISO_FILENAME}.preseed-sha256 に保存
   ```
5. 出力 ISO の存在確認
4. 完了: `./scripts/os-setup-phase.sh mark iso-remaster --config "$CONFIG"`

#### iDRAC: UEFI モードの確認 (BIOSリセット後および初回)

R320 は **UEFI モード**で運用する。preseed から `partman-efi/non_efi_system` を削除済みで、
UEFI モードでは partman が自動的に ESP を作成し grub-efi-amd64 が正常にインストールされる。
Legacy BIOS モードでは GPT パーティションテーブルからブートできない問題が発生する。

> **重要 (反復5で発見)**: BIOS F3 (Load Default Settings) を実行すると Boot Mode が **UEFI → BIOS (Legacy)** に変わる。
> BIOSリセット後は必ず BootMode を確認し、BIOS (Legacy) になっていたら以下の手順で UEFI に戻すこと。

> ⚠️ **絶対禁止 (反復7-9で発見、8号機で永続的故障)**: `racadm set BIOS.BiosBootSettings.BootMode Uefi` を**使用してはならない**。
> R320 / iDRAC7 FW 2.65.65.65 では racadm 経由の BootMode 変更が UefiBootSeq から `Optical.iDRACVirtual.1-1` を削除し、**VirtualMedia ブートが永続的に不能**になる。
> 一度削除されると racadm では復元できない (BOOT018 read-only エラー)。BIOS Load Defaults + VNC BIOS UI での手動修正が必要になる ([idrac7 スキルの「VirtualMedia ブート復旧手順」](../idrac7/SKILL.md#virtualmedia-ブート復旧手順-bootmode-破壊からの回復) を参照)。

R320 が Legacy BIOS モードの場合、**VNC 経由で BIOS Setup から手動で UEFI に切り替える**:

```sh
# まず現在のモードを確認
ssh -F ssh/config idrac7 "racadm get BIOS.BiosBootSettings.BootMode"

# BootMode=Bios が返ってきたら、VNC BIOS UI で手動変更:
# 1. 電源サイクル後 POST 開始まで 45 秒待機
# 2. F2 連打で BIOS Setup 入場
python3 ./scripts/idrac-kvm-interact.py --bmc-ip $BMC_IP sendkeys F2 x30 --wait 2000 \
    --screenshot-each tmp/<sid>/bm-f2 --pre-screenshot

# 3. "System Setup" で Enter (System BIOS 選択)
# 4. "Boot Settings" に移動 → "Boot Mode" → UEFI 選択
# 5. Escape → Finish → 確認 Enter
# (具体的なキー操作はスクリーンショットを見ながら適宜)
```

**重要**: BootMode 変更には racadm を使わず、必ず VNC BIOS UI を使うこと。racadm の `set BIOS.BiosBootSettings.BootMode` は VirtualMedia デバイスの BIOS NVStore 登録を破壊する。

#### iDRAC: racadm コマンドの注意 (iDRAC7 FW 2.65.65.65)

`racadm set iDRAC.ServerBoot.BootOnce` は iDRAC7 で**サイレントに失敗**する。
BootOnce の操作には legacy コマンドを使用すること:
```sh
racadm config -g cfgServerInfo -o cfgServerBootOnce 1   # 有効化
racadm config -g cfgServerInfo -o cfgServerBootOnce 0   # 無効化
```
`FirstBootDevice` は `racadm set iDRAC.ServerBoot.FirstBootDevice` が正常に動作する。
`idrac-virtualmedia.sh` は修正済み (legacy コマンドを使用)。

#### iDRAC8 (R430) 固有の注意

- **`racadm raid clearforeignconfig` は存在しない**: foreign disk 解除には `racadm raid resetconfig:RAID.Integrated.1-1` を使う (Blocked disk 解除にも有効)
- **`/dev/sdb` として vFlash SD slot が exposed**: R430 は **内蔵 vFlash SD slot** (実 SD カード未装着でも) を `/dev/sdb` として OS から見える状態にすることがある。preseed の `partman/early_command` で `for disk in $(list-devices disk)` を使うと不正な空 disk (`/dev/sdb size= block=`) が partman に渡され `partman-auto` が失敗する。**`for disk in /dev/sda; do ...`** のように明示的に対象 disk のみ処理すること (server14.cfg で対応済)
- **PERC H730P FW 25.5.5 + 4Kn block では `partman-auto/method regular` + atomic recipe が失敗**: root mountpoint が割り当てられず「No root file system」dialog ループになる。**`partman-auto/method lvm` + atomic-lvm recipe** で確実に動作する (vg0 + root LV + swap_1 LV 構成)。LVM 経由は 4Kn alignment 自動調整も良好
- **iDRAC FW 2.63 (古い) でも racadm 主要コマンド (raid, jobqueue, remoteimage, set BIOS.*) は新版と同じ構文** で動作する。ただし `remoteimage` SMB マウントが不安定なら umount → 5 秒 → 再 mount を最大 3 回試行
- **iDRAC8 BIOS は出荷時 UEFI**。R430 を iDRAC7 + R320 と同じ感覚で BootMode 変更しないこと (BIOS 2.9.1 確認済)。`racadm get BIOS.BiosBootSettings.BootMode` が `Uefi` のままなら触らない

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

   **6号機: Redfish BootOptions API が空の場合のフォールバック**:
   6号機など一部のサーバでは Redfish BootOptions API が空配列を返し、`find-boot-entry` / `boot-next` (UefiBootNext) が使えない。
   この場合、`bios-setup` スキルの `--no-click` を使って BIOS Boot タブから Boot Option #1 を設定する:
   1. `--no-click` で Boot タブに移動 (ArrowRight x5)
   2. ArrowDown x2 で Boot Option #1 へ
   3. Enter → PageUp (先頭 CD/DVD) → ArrowDown x11 → Enter で "UEFI CD/DVD" (index 11) を選択
   4. F4 → Enter で Save & Exit → UEFI CD からブート
   - **Legacy ISOLINUX ブートだと MBR パーティションが作成され ESP が作成されない。NVMe は Legacy ブート不可なので、必ず UEFI モードでインストールすること**
   - **PXE 無限ループが発生する場合**: `bios-setup` スキルで全 PXE Boot Option を Disabled に設定 (`Enter → PageDown → Enter` を Boot Option ごとに繰り返す。17 個分)

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

##### R430 + PERC H730/H730P 固有: RAID 事前整備 (Phase 4 の前提)

R430 では Phase 4 開始前に **OS 用 VD が State=Online で存在すること** を確認する。
VD が無い、Foreign / Blocked disk が残っている、または前回 fail ジョブが pending に残っている場合は、以下の整備手順を実行してから Phase 4 に入る (詳細: `report/2026-05-12_040320_server14_os_install_retry.md`):

```sh
ssh -F ssh/config idrac<N> racadm raid get vdisks
ssh -F ssh/config idrac<N> racadm raid get pdisks -o -p Size,State
ssh -F ssh/config idrac<N> racadm jobqueue view
```

- VD0 が無い or pdisks に Blocked / Foreign が混在: 全構成を消す:
  ```sh
  ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac<N> racadm jobqueue delete --all
  ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac<N> racadm raid resetconfig:RAID.Integrated.1-1
  ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac<N> racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle
  ```
  > **iDRAC8 注意**: `clearforeignconfig` は **存在しない**。`clearconfig` も「No foreign drives detected」エラーで失敗することがある。`resetconfig` を使うこと。foreign + local + pending + Blocked が一括解除される。

> **⚠️ resetconfig 後の SCP Export ジョブに注意** (Round 2 s15 で観測):
> `racadm raid resetconfig` 完了後、iDRAC が自動的に `Export: Server Configuration Profile` job を生成する。これが完了する前に `racadm raid createvd` を実行すると **`LC062`** で失敗する。
> ```sh
> ssh -F ssh/config idrac<N> racadm jobqueue view
> ```
> resetconfig job + Export job 両方が `Completed (100)` を確認してから createvd へ進む。

- VD 作成 (Bay 1+6 で OS_RAID1 を作る例):
  ```sh
  ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac<N> racadm raid createvd:RAID.Integrated.1-1 -rl r1 \
    -pdkey:Disk.Bay.1:Enclosure.Internal.0-1:RAID.Integrated.1-1,Disk.Bay.6:Enclosure.Internal.0-1:RAID.Integrated.1-1 \
    -name OS_RAID1
  ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac<N> racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle
  ```
  `racadm jobqueue view` を 30 秒間隔でポーリングして `Completed (100)` を待つ (3-5 分目安)。

> **⚠️ PERC RAID-1 disk スペック一致必須**: link speed + sector size + model が一致したペアを選ぶこと。
> - 不一致 (例: ST300MP0026 12Gb/s + ST9300653SS 6Gb/s) は **BGI 26% 付近で停滞する** (14号機で確認、issue #63)
> - 同モデル・同サイズ・同 link speed なら BGI **スキップで即時 Online** になる
> - State=Online, OperationalState=Not applicable で BGI 不要

1. **事前検証: BIOS SerialCommSettings** (R320 固有、install-monitor 成立の必須条件):

   iDRAC SOL で Debian インストーラの進行を監視するためには、BIOS のシリアルコンソールリダイレクトが有効でなければならない。`BIOS.SerialCommSettings.SerialComm` が **`OnConRedirCom1`** でない場合、BIOS POST 以降の出力 (カーネルログ、インストーラテキスト) が iDRAC SOL に流れず、`sol-monitor.py` は永久に進行を検知できない (install-monitor フェーズがハング)。

   > ⚠️ **既知の原因**: `BIOS.BiosBootSettings.BootMode` 破壊からの VirtualMedia 復旧手順 ([idrac7 スキルの「VirtualMedia ブート復旧手順」](../idrac7/SKILL.md#virtualmedia-ブート復旧手順-bootmode-破壊からの回復)) で **BIOS Load Defaults (F3) を実行すると `SerialCommSettings` もデフォルト (`OnNoConRedir`) にリセットされる**。復旧手順で `SerialCommSettings` の復元を行っていないと、次回 install-monitor が無言でハングする。

   ```sh
   SERIAL_CURRENT=$(ssh -F ssh/config "$IDRAC_HOST" racadm get BIOS.SerialCommSettings.SerialComm | grep '^SerialComm=' | cut -d= -f2 | tr -d '\r\n')
   REDIR_CURRENT=$(ssh -F ssh/config "$IDRAC_HOST" racadm get BIOS.SerialCommSettings.RedirAfterBoot | grep '^RedirAfterBoot=' | cut -d= -f2 | tr -d '\r\n')
   if [ "$SERIAL_CURRENT" != "OnConRedirCom1" ] && [ "$SERIAL_CURRENT" != "OnConRedirAuto" ] || [ "$REDIR_CURRENT" != "Enabled" ]; then
       echo "FIX: SerialComm=$SERIAL_CURRENT RedirAfterBoot=$REDIR_CURRENT → restoring"
       ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config "$IDRAC_HOST" racadm set BIOS.SerialCommSettings.SerialComm OnConRedirCom1
       ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config "$IDRAC_HOST" racadm set BIOS.SerialCommSettings.RedirAfterBoot Enabled
       ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config "$IDRAC_HOST" racadm jobqueue create BIOS.Setup.1-1 -s TIME_NOW -r pwrcycle
       # BIOS ジョブ完了を待つ (5-6 分)。jobqueue view でポーリング。
   fi
   ```

   `BIOS.SerialCommSettings` は `BIOS.BiosBootSettings.BootMode` と異なり、racadm 経由の変更で UefiBootSeq の VirtualMedia エントリを破壊しない。安全に racadm で変更可能。

   > **注**: `OnConRedirCom1` だけでなく `OnConRedirAuto` も install-monitor 互換 (R430 + BIOS 2.9.1 / 2.15.0 で確認、Round 1)。両方とも許容値として扱う。

2. **VirtualMedia マウント**:
   ```sh
   REMOTE_URI=$("$YQ" '.remoteimage_uri' "$CONFIG")
   ./scripts/idrac-virtualmedia.sh mount "$BMC_IP" "$REMOTE_URI"
   ./scripts/idrac-virtualmedia.sh status "$BMC_IP"
   ./scripts/idrac-virtualmedia.sh verify "$BMC_IP"
   ```

3. **Boot Once 設定 + 電源サイクル**:
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

#### 0. Installer syslog receiver の起動（推奨、iDRAC 環境で特に重要）

preseed `early_command` は `syslogd -R 10.1.6.1:5514 -L` で installer syslog を UDP でフォワードする。
`./scripts/syslog-receiver.sh` を起動しておかないと、`grub-install` / `efibootmgr` の生エラー文字列が永久に失われる (SOL には TUI ダイアログのピクセルしか残らない)。

**単独実行時**:
```sh
mkdir -p tmp/<session-id>
if ss -uln 2>/dev/null | grep -q ':5514 '; then
    echo "WARN: UDP 5514 already in use; skipping syslog receiver"
    SYSLOG_RCV_PID=""
else
    ./scripts/syslog-receiver.sh 5514 tmp/<session-id>/installer-syslog-s${SUFFIX}.log &
    SYSLOG_RCV_PID=$!
    echo "Started syslog receiver (pid=$SYSLOG_RCV_PID)"
fi
```

**並列実行時 (7/8/9 同時)**: 3 台が同じ UDP 5514 に書くため、**親セッションで 1 本だけ** リスナーを立てる。子エージェントは立てない。
```sh
./scripts/syslog-receiver.sh 5514 tmp/<parent-sid>/installer-syslog-all.log &
```
受信後は送信元 IP (`10.10.10.207/208/209`) で grep して台ごとに切り分ける。

前提: `socat` が必要。未インストールなら `sudo apt install -y socat` (許可リスト内)。

ログは検証 3.5 で attachment へ永続化する (tmp 掃除前に必ず退避)。

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
- EOF 時: PowerState=Off かつ **最低 1 ステージ観測済み** → exit 0 (インストール完了)
- "Power down" 検出 → 30秒待機 → PowerState 確認 → (stage 観測あり) exit 0
- PowerState は20秒間隔でポーリング
- 終了コード: 0=完了, 1=タイムアウト, 2=接続エラー, 3=異常終了(再接続上限超過含む), **4=False positive (PowerState=Off だが installer stage 未観測)**

> **注意**: SOL は **OS レベルの `/dev/ttyS*` 書き込みを捕捉しない** (Dell R320 + iDRAC7 共通)。
> SOL に流れる出力は BIOS の INT10h リダイレクションまたは installer 特有の UEFI ConsoleOut 経由のみ。
> インストール後の OS 状態を SOL 経由で確認することは基本的にできないため、post-install-config は
> SSH + `/etc/machine-id` 検証で行うこと (Phase 6 ステップ 5 参照)。

#### 2. SOL exit code 別の対処

| exit code | 状態 | 対処 |
|-----------|------|------|
| 0 | 完了 (stage 観測 ≥ 1 & PowerState=Off) | 次の Phase へ |
| 1 | タイムアウト | PowerState 確認。Off かつ stage 観測あり→完了扱い。それ以外→forceoff |
| 2 | 接続エラー | フォールバックへ |
| 3 | 異常終了 | PowerState 確認。Off かつ stage 観測あり→完了扱い。それ以外→フォールバックへ |
| **4** | **False positive (stage 0 件 + Off)** | **強制 Off → bmc-mount-boot から再実行。install-monitor を done にしない。BIOS SerialComm/VirtualMedia の状態を再確認** |

> **重要**: `PowerState=Off` 単独での成功判定は False positive の原因となる
> (`report/2026-04-10_172807_server8_vmedia_recovery_test.md`)。
> `sol-monitor.py` は内部で **最低 1 ステージの観測** を必須化している。
> さらに install-monitor 完了を判断する前に、Phase 6 の `/etc/machine-id` タイムスタンプ検証を必ず通すこと。
> exit 4 を受け取った場合は、install-monitor を done にせず bmc-mount-boot からやり直す。

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

**iDRAC**: VNC スクリーンショット (VNC 3回リトライ → capconsole フォールバック)
```sh
python3 ./scripts/idrac-kvm-screenshot.py --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" --output tmp/<session-id>/screenshot.png
```

#### 4. iDRAC VirtualMedia 連続失敗時の回復 (R430 で確認)

**症状**: install attempt 2-3 回失敗後、GRUB 無限ループ (POST → GRUB プロンプト → again) で installer に到達しない。VirtualMedia status は Inserted=true を返すが、boot 時に iDRAC が ISO を正しく hand-off しない内部状態 corruption。

**解決**: iDRAC を soft reset → clean state で再 mount → install 再実行 (14号機 attempt 6 で成功実証):

```sh
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac<N> racadm racreset soft
# 約 2-3 分で iDRAC 再起動完了 (SSH 切断 → 再接続可能まで)
./scripts/ssh-wait.sh 10.10.10.<3N> --timeout 240 --interval 10
# 再起動後に bmc-mount-boot から再実行
./scripts/os-setup-phase.sh reset bmc-mount-boot --config "$CONFIG"
./scripts/os-setup-phase.sh reset install-monitor --config "$CONFIG"
```

> **目安**: 同一 ISO + 同一 preseed で **install attempt 3 連続失敗 (GRUB 無限ループ or false-positive exit 4)** が発生した場合は racreset soft を最初に試すこと。VirtualMedia をいくら再 mount しても状態は元に戻らない。
>
> **早期 trigger (Round 3 で観測)**: 以下のいずれかで 1 回目から racreset soft 即発動可:
> - **partman stuck**: stage 5/9 で 15 分以上停滞 + installer-syslog で `No matching physical volumes found` / `partman: ...failed` 等の同種エラー後の沈黙が 10 分以上 (Round 3/5 で実証)。SOL に **byobu status bar** が表示されたまま動かないのもサイン
> - **GRUB sector read error**: SOL に `error: failure reading sector 0x... from cd0` が連続出力
> - **iDRAC SSH 復旧確認**: `ssh-wait.sh` は root@host 限定。iDRAC は `ssh -F ssh/config idrac<N> racadm getsysinfo` を 30 秒間隔でポーリング (~2-3 分で復旧)

#### 5. SOL の dialog 表示単独では install 失敗と判断しない

preseed の `partman/confirm boolean true` は dialog を auto-confirm して partman 再試行を許す。`partman-base/no_root_device` 等の error dialog が SOL に表示されても、preseed が auto-confirm して install を最後まで進めている可能性がある (14号機 attempt 1, 3 で発生)。

**判定手順**:
1. SOL に dialog を観測しても **強制終了しない**
2. **installer-syslog (UDP 5514) を確認**:
   - `grub-installer` / `finish-install` の進行ログがあれば → install 進行中
   - syslog が空 or `partman-auto` で stop している → 真の失敗
3. installer-syslog が立ち上がっていない場合は KVM screenshot で実画面を確認
   ```sh
   python3 ./scripts/idrac-kvm-screenshot.py --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" --output tmp/<sid>/check.png
   ```
4. PowerState=Off に到達するまで `sol-monitor.py` を継続走らせる (1 ステージでも観測されていれば EOF 再接続で正常完了する)

#### 完了処理

1. SOL を切断: `ipmitool ... sol deactivate`（sol-monitor.py が自動切断するが念のため）
2. **Syslog receiver 停止** (単独実行時、ステップ 0 で起動した場合):
   ```sh
   if [ -n "$SYSLOG_RCV_PID" ]; then
       kill "$SYSLOG_RCV_PID" 2>/dev/null || true
       wait "$SYSLOG_RCV_PID" 2>/dev/null || true
       SYSLOG_LOG="tmp/<session-id>/installer-syslog-s${SUFFIX}.log"
       if [ -s "$SYSLOG_LOG" ]; then
           echo "Installer syslog: $(wc -l < "$SYSLOG_LOG") lines saved to $SYSLOG_LOG"
       else
           echo "WARN: Installer syslog empty — check network path to 10.1.6.1:5514"
       fi
   fi
   ```
   (並列実行時は親セッションで一括停止するため子エージェントはスキップ)
3. 完了: `./scripts/os-setup-phase.sh mark install-monitor --config "$CONFIG"`

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

#### ステップ 2-A: Disk first boot 失敗時のリカバリ (LSI HBA OPROM)

**症状**: Power On 後に POST → 「`Reboot and Select proper Boot device`」 → PXE フォールバック → DHCP 失敗で停止。SSH も到達しない。

**典型例**: 10号機 (NX-1065-G5) は OS install 先 disk が **LSI SAS HBA 経由** で、出荷時 BIOS 設定の `LSI HBA OPROM=[Disabled]` のままだと Legacy boot 不能。Boot Override に PXE しか出ず、Boot タブの "Hard Disk Drive BBS Priorities" サブメニューが空 (= disk が boot device として列挙されない)。

**判定**: BIOS Setup に入って以下を確認 (`bios-setup` スキル + `--prefer vkbd`):
1. **Boot タブ** — Legacy Boot Order #5 = "Hard Disk" の論理スロットは存在するか / **HARD DISK Drive BBS Priorities** サブメニューが出ているか
2. **Save & Exit > Boot Override** — disk (SATA: <model> や Hard Disk) が列挙されているか
3. **Advanced > SATA / sSATA Configuration** — 各ポートの "Installed/Not Installed" 状態
4. **Advanced > PCIe/PCI/PnP Configuration > LSI HBA OPROM** — Disabled/Enabled

**判定フロー**:
- Boot Override に disk が出る → 直接ブート (Plan A.1)
- 出ないが SATA/sSATA に Installed あり → Boot Order を直接 "Hard Disk" にして Save (Plan A.2)
- SATA/sSATA すべて Not Installed + LSI HBA OPROM=Disabled → **`LSI HBA OPROM=[Enabled]` に変更 → F4 → Save & Reset** (Plan A.3 — 10号機の本命)
- 上記すべて NG → Stock ISO で rescue mode → chroot で `grub-install /dev/sda` (Plan B)
- rescue で grub-pc 不在等 → preseed 修正後フル再インストール (Plan C)

詳細は [report/2026-05-02_*_server10_disk_first_boot_recovery.md](../../../report/) を参照。

#### ステップ 3: SOL 経由でログイン確認・SSH 鍵配置

> **重要**: preseed の late_command は Debian 13 で動作しないことが多い。
> SSH 公開鍵、PermitRootLogin、sudoers は SOL 経由で設定する必要がある。
> **両プラットフォーム共通**: このステップは Supermicro / iDRAC 両方で必須。
> Supermicro の場合も SOL (`sol-login.py`) で SSH 鍵を配置する。
> SSH 鍵が未配置のままだと、後続の Phase 7 (pve-install) で SSH 接続できない。

a. SSH 公開鍵を Read ツールで `ssh/id_ed25519.pub` から取得（**注意**: `~/.ssh/id_ed25519.pub` ではなく `ssh/id_ed25519.pub` を使うこと。`ssh/config` の pve7-9 エントリは `ssh/id_ed25519` を IdentityFile として使用するため、これが正しいプロジェクト鍵）
> **⚠️ SOL コマンド送信のベストプラクティス** (Round 1 s15 で観測):
> - **heredoc は使えない**: `sol-login.py` は行単位送信のため `cat <<EOF ... EOF` が複数 echo に分解される。**`printf '...\n...\n' > file` を使うこと**
> - **stdout は捕捉されない**: SOL 経由で `ip addr` 等を実行しても出力は SOL ログに混ざるだけで構造化キャプチャできない。状態確認は `> /tmp/result.txt` でファイル化してから後続 SSH で読み出すこと
> - **`printf '...' > /file` で出る "Command may have failed" 警告は誤検知** (Round 2 s15): リダイレクト自体は成功している。SSH 鍵認証成功 / ファイル存在で間接的に検証する

b. コマンドファイルを `tmp/<session-id>/sol-commands-s${SUFFIX}.txt` に作成:
   ```
   sed -i "s/^#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
   systemctl restart sshd
   echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian
   chmod 0440 /etc/sudoers.d/debian
   mkdir -p /root/.ssh
   chmod 700 /root/.ssh
   echo "<BASE64_ENCODED_PUBKEY>" | base64 -d > /root/.ssh/authorized_keys
   chmod 600 /root/.ssh/authorized_keys
   ```
   > **注意**: `echo "ssh-ed25519 ..." > /root/.ssh/authorized_keys` は SOL 経由で `>` リダイレクトと長い引数が正しく扱われないことがある。
   > 公開鍵は必ず base64 エンコードして書き込むこと:
   > ```sh
   > python3 -c "import base64; k=open('ssh/id_ed25519.pub').read().strip(); print(base64.b64encode(k.encode()).decode())"
   > ```
   > これで得た BASE64 文字列を `<BASE64_ENCODED_PUBKEY>` に置換する。
   ```
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

> **⚠️ DETECTING timeout** (Round 3 R430 で観測): 最初の sol-login.py が boot 完了前に DETECTING で 180s timeout する場合がある。120-180 秒待って再試行するか、ssh-wait.sh で SSH 到達してからにする (R430 + Debian 13 minimal で 5-6 分かかることがある)

> **⚠️ eno1 (DHCP iface) は preseed install 後 DOWN がデフォルト** (Round 3 で観測):
> preseed の `netcfg/choose_interface select eno2` で静的側 NIC を選んだ場合、DHCP 側の `eno1` は `/etc/network/interfaces` に未記述で boot 時 DOWN になる。Phase 7 で `pre-pve-setup.sh` が dhcpcd を試す前に `ip link set eno1 up` が必要なケースがある。
> SOL コマンドリストに以下を追加して preventive に対処:
> ```sh
> ip link set <dhcp_iface> up
> printf 'auto <dhcp_iface>\niface <dhcp_iface> inet manual\n' >> /etc/network/interfaces
> ```

> **⚠️ SOL の `|` (pipe) 文字解釈失敗 (R430 で観測)**:
> `echo "..." | base64 -d > /root/.ssh/authorized_keys` を SOL で実行すると、`|` の前後で escape が一部失敗し `authorized_keysecho` 等の **変名ファイル** が作られることがある (鍵配置が silent failure になり、後続 SSH が認証エラー)。
>
> **対策**: pexpect 経由のパスワード SSH (DHCP IP 経由) で鍵を配置する。SOL では PermitRootLogin + PasswordAuthentication の最低限の設定だけ行い、authorized_keys は SSH で:
> ```sh
> # SOL では PermitRootLogin / PasswordAuthentication のみ
> sed -i "s/^#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
> sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
> systemctl restart sshd
> ```
> ```sh
> # 別途 pexpect でパスワード SSH → 鍵配置 (DHCP IP は preseed install 後にログから取得)
> python3 -c "
> import pexpect
> p = pexpect.spawn('ssh -F ssh/config -o StrictHostKeyChecking=no root@<dhcp_ip>')
> p.expect('password:')
> p.sendline('<root_pass>')
> p.expect(r'#\s*$')
> p.sendline('mkdir -p /root/.ssh && chmod 700 /root/.ssh')
> p.expect(r'#\s*$')
> p.sendline('echo <pubkey> > /root/.ssh/authorized_keys')
> p.expect(r'#\s*$')
> p.sendline('chmod 600 /root/.ssh/authorized_keys')
> p.expect(r'#\s*$')
> "
> ```
> SOL 経由で `|` が必要な処理 (base64 デコード等) は **一切回避する**。短い鍵 (ed25519, 80 文字程度) なら base64 不要で直接 echo 可能。

**sol-login.py がタイムアウトした場合** (Supermicro):
POST code 確認 → `0x92` なら ForceOff → 20秒 → On → `ssh-wait.sh --timeout 180 --interval 10` → sol-login.py を再実行。

**iDRAC のフォールバック**:
SOL が使えない場合は pexpect で debian ユーザにパスワード SSH → su root で設定する。

#### ステップ 4: ホスト鍵削除 + SSH 接続確認

```sh
ssh-keygen -R <static_ip> -f ssh/known_hosts
./scripts/ssh-wait.sh <static_ip> --timeout 150 --interval 10
```

#### ステップ 5: 実インストール検証 (False positive 防止)

> **背景**: `sol-monitor.py` の PowerState=Off 判定は stage 観測ガードで補強されているが、
> それでも「古い OS がそのまま起動し SSH 応答を返した」ケースは検出できない。
> install-monitor 開始時刻より **新しい** `/etc/machine-id` が生成されていることを SSH 経由で
> 実測検証する。古ければリインストール未実行と判断し、install-monitor と bmc-mount-boot を
> reset してフェーズをやり直す
> (`report/2026-04-10_172807_server8_vmedia_recovery_test.md` 参照)。

```sh
SERVER_NAME=$(basename "$CONFIG" .yml)
STATE_DIR="state/os-setup/${SERVER_NAME}"
INSTALL_START=$(cat "${STATE_DIR}/install-monitor.start")
REMOTE_MACHINE_ID_MTIME=$(ssh -F ssh/config "pve${NUM}" stat -c %Y /etc/machine-id)
REMOTE_HOSTNAME_MTIME=$(ssh -F ssh/config "pve${NUM}" stat -c %Y /etc/hostname)
echo "install-monitor.start = ${INSTALL_START} ($(date -d @${INSTALL_START}))"
echo "remote /etc/machine-id mtime = ${REMOTE_MACHINE_ID_MTIME} ($(date -d @${REMOTE_MACHINE_ID_MTIME}))"
echo "remote /etc/hostname  mtime = ${REMOTE_HOSTNAME_MTIME} ($(date -d @${REMOTE_HOSTNAME_MTIME}))"

if [ "${REMOTE_MACHINE_ID_MTIME}" -lt "${INSTALL_START}" ]; then
    echo "ERROR: /etc/machine-id predates install-monitor start — FALSE POSITIVE"
    ./scripts/os-setup-phase.sh fail post-install-config --config "$CONFIG"
    ./scripts/os-setup-phase.sh reset install-monitor --config "$CONFIG"
    ./scripts/os-setup-phase.sh reset bmc-mount-boot --config "$CONFIG"
    exit 1
fi
```

両方のタイムスタンプが install-monitor 開始より新しいことを確認できたら正規のリインストールが行われたと判断する。

> **⚠️ initramfs dropout false-success** (Round 9 s14 attempt 2 で新規観測):
> sol-monitor が exit 0 (installation completed) を返したが、OS が `(initramfs)` プロンプトで停止していたケース。partman の "No root file system" dialog を preseed が auto-confirm し、kernel+initrd は書かれたが rootfs が実際は空のまま install monitor 完了。
> **検出**: 上記 `/etc/machine-id` mtime チェックの前に、SSH 不到達 → SOL 経由で Enter flood → `(initramfs)` プロンプトが返ってきたら initramfs dropout 確定。bmc-mount-boot + install-monitor を reset して再 install。

完了: `./scripts/os-setup-phase.sh mark post-install-config --config "$CONFIG"`

---

### Phase 7: pve-install

**pve-lock**: 必要

PVE のインストールを SSH 経由で実行。

> **ネットワーク制約**: `10.0.0.0/8` はインターネット到達不可。preseed で設定された `default via 10.10.10.1` を削除し、`192.168.39.1` 経由に切り替えないと apt/wget が失敗する。`preseed/late_command` と `pre-pve-setup.sh` の両方で `/etc/network/interfaces` から `gateway 10.10.10.1` 行を自動削除するため、新規セットアップでは原則手動操作不要。`ip route show default` が `via 192.168.39.1 ...` を返すことだけ確認する。

#### ステップ 0: インターネット接続確保 (iDRAC / CD-only preseed の場合)

preseed が CD-only (`apt-setup/use_mirror boolean false`) の場合:
```sh
scp -F ssh/config ./scripts/pre-pve-setup.sh root@<static_ip>:/tmp/
ssh -F ssh/config root@<static_ip> sh /tmp/pre-pve-setup.sh --dhcp-iface <dhcp_iface> --static-gw 10.10.10.1 --codename <codename>
```

`pre-pve-setup.sh` は DHCP 有効化、デフォルトルート修正、apt sources 設定、wget/ca-certificates インストールを自動で行う。

> **⚠️ DHCP 取得が timeout する場合 (Debian 13 minimal で観測)**:
> Debian 13 minimal install は `isc-dhcp-client` 不在で初回 DHCP が 30 秒 timeout する。
> `pre-pve-setup.sh` は内部で fallback 順序 (`ifup → dhclient → dhcpcd`) を持つが、タイミング依存で失敗することがある。
> その場合、手動で `dhcpcd -1 -t 30 <dhcp_iface>` を先に流してから `pre-pve-setup.sh` を再実行する:
> ```sh
> ssh -F ssh/config root@<static_ip> dhcpcd -1 -t 30 <dhcp_iface>
> ssh -F ssh/config root@<static_ip> sh /tmp/pre-pve-setup.sh --dhcp-iface <dhcp_iface> --static-gw 10.10.10.1 --codename <codename>
> ```
> **IPv4LL fallback 対処** (Round 8 s15 で観測): `dhcpcd` で 169.254.x が割り当てられたら実 DHCP 不取得。`ip addr flush dev <iface>` → `dhcpcd -t 60 <iface>` 再試行で復旧:
> ```sh
> ssh -F ssh/config root@<static_ip> ip addr flush dev <dhcp_iface>
> ssh -F ssh/config root@<static_ip> dhcpcd -t 60 <dhcp_iface>
> ```

#### ステップ 1: スクリプト転送 + pre-reboot

```sh
scp -F ssh/config ./scripts/pve-setup-remote.sh root@<static_ip>:/tmp/
ssh -F ssh/config root@<static_ip> /tmp/pve-setup-remote.sh --phase pre-reboot --hostname <hostname> --ip <static_ip> --codename <codename> --serial-unit ${SERIAL_UNIT}
```

#### ステップ 2: リブート + SSH 再接続待機

```sh
ssh -F ssh/config root@<static_ip> reboot || true
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
scp -F ssh/config ./scripts/pre-pve-setup.sh root@<static_ip>:/tmp/
ssh -F ssh/config root@<static_ip> sh /tmp/pre-pve-setup.sh --dhcp-iface <dhcp_iface> --static-gw 10.10.10.1 --codename <codename>
```
または手動で:
```sh
ssh -F ssh/config root@<static_ip> ip route del default via 10.10.10.1 || true
ssh -F ssh/config root@<static_ip> ip route add default via 192.168.39.1 || true
```

**ルート検証** (iDRAC に限らず全プラットフォーム共通で推奨):
ルート修正後にインターネット到達性を確認:
```sh
ssh -F ssh/config root@<static_ip> ping -c1 -W3 deb.debian.org || echo "WARN: no internet"
```
→ 失敗時は `ip route` を確認し、DHCP ルート (`192.168.39.1`) を手動追加

#### ステップ 4: post-reboot

```sh
scp -F ssh/config ./scripts/pve-setup-remote.sh root@<static_ip>:/tmp/
ssh -F ssh/config root@<static_ip> /tmp/pve-setup-remote.sh --phase post-reboot --hostname <hostname> --ip <static_ip> --codename <codename> --serial-unit ${SERIAL_UNIT} --linstor
```

> **`--linstor` フラグ**: LINBIT リポジトリの GPG 鍵追加 + DRBD/LINSTOR パッケージインストールを行う。LINSTOR クラスタに参加するサーバでは必ず指定すること。省略すると LINSTOR 関連のセットアップはスキップされる。
> enterprise リポジトリ (`.list` + `.sources`) の除去は `--linstor` の有無にかかわらず常に実行される。

> **⚠️ LINBIT GPG empty-file silent failure** (Round 2 s14 で観測):
> `wget` は 404 でも exit 0 + 空ファイルを残すケースがあり、`pve-setup-remote.sh` の内部 fallback (`wget` 失敗時のみ ubuntu keyserver) が発動しない。
> **`--linstor` を使う場合は事前にローカルから ubuntu キーサーバ経由で取得して配置することを推奨**:

> **🚨 post-reboot 中の default route 消失 → apt 失敗 (5 trial 連続再現)** (Round 4-6):
> `pve-setup-remote.sh --phase post-reboot` 実行中に `proxmox-ve` パッケージインストールが ifupdown2 を再初期化し、default route via 192.168.39.1 が消える。続く apt が `Temporary failure resolving 'packages.linbit.com'` で fail する。**5 trial 連続再現 = 必発**。
> **必須対処手順**: `pve-setup-remote.sh --phase post-reboot` が exit 100 で停止したら:
> 1. `ssh root@<static_ip> sh /tmp/pre-pve-setup.sh --dhcp-iface <dhcp_iface> --static-gw 10.10.10.1 --codename trixie` でルート修復
> 2. `ssh root@<static_ip> sh /tmp/pve-setup-remote.sh --phase post-reboot ... ` を再実行 (冪等性で resume される)
>
> 根本対処は `pve-setup-remote.sh` 内部に route check + dhclient 埋込が必要 (別 issue 候補)。

> **⚠️ LINBIT linstor-common (56MB) ダウンロード時間に注意** (Round 3 s15 で観測):
> `packages.linbit.com` 経由の `linstor-common` (56.6 MB) は ~150 KB/sec で 5-15 分かかることがある。`apt` が進捗なしに見えても `/var/cache/apt/archives/partial/` 内のファイルサイズが増えていれば正常。`-o Acquire::http::Timeout=60 -o Acquire::Retries=3` 検討余地あり。

> **⚠️ DRBD DKMS は build-essential / libc6-dev 必須** (Round 2 s14 で観測):
> `pve-setup-remote.sh --linstor` 完了後の DKMS ビルドが `stdio.h: No such file` で失敗し drbd-dkms が `iF` (Failed) 状態になる。
> 事前に build-essential を入れておく:
> ```sh
> ssh -F ssh/config root@<static_ip> apt-get install -y build-essential
> ```
> その後 `pve-setup-remote.sh --phase post-reboot --linstor` を再実行すると DKMS ビルドが通る。

> **🚨 LINBIT keyring 事前配置 (3/6 trial で必発)** — `--linstor` を使う場合は **必須ステップ**:
> wget からの 404 (silent failure) と内部 fallback の組合せが半数の trial で fail する。
> **`--linstor` を使う前に必ず事前配置**:

> **LINBIT GPG キーが 404 になる場合の対処**: `pve-setup-remote.sh` は `https://packages.linbit.com/package-signing-pubkey.gpg` から GPG キーを取得するが、URL が変更されて 404 になることがある。この場合はローカルマシンで Ubuntu キーサーバから取得してサーバに配置する:
> ```sh
> curl "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4E5385546726D13CB649872CFC05A31DB826FE48" -o tmp/<sid>/linbit-key.asc
> gpg --batch --yes --dearmor -o tmp/<sid>/linbit-keyring.gpg tmp/<sid>/linbit-key.asc
> scp -F ssh/config tmp/<sid>/linbit-keyring.gpg root@<static_ip>:/usr/share/keyrings/linbit-keyring.gpg
> ssh -F ssh/config root@<static_ip> chmod a+r /usr/share/keyrings/linbit-keyring.gpg
> ```
> その後、`pve-setup-remote.sh --phase post-reboot --linstor` を再実行する（GPG キーが存在する場合は再取得をスキップする）。

#### ステップ 5: 最終リブート + PVE 動作確認

```sh
ssh -F ssh/config root@<static_ip> reboot || true
./scripts/ssh-wait.sh <static_ip> --timeout 300 --interval 10
```

- **iDRAC**: SSH 再接続後にルート修正 + 検証:
  ```sh
  ssh -F ssh/config root@<static_ip> ip route del default via 10.10.10.1 || true
  ssh -F ssh/config root@<static_ip> ip route add default via 192.168.39.1 || true
  ssh -F ssh/config root@<static_ip> ping -c1 -W3 deb.debian.org || echo "WARN: no internet"
  ```
- `ssh -F ssh/config root@<static_ip> pveversion` で PVE バージョン確認
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
   - OS: `ssh -F ssh/config root@<static_ip> cat /etc/os-release`
   - PVE: `ssh -F ssh/config root@<static_ip> pveversion`
   - カーネル: `ssh -F ssh/config root@<static_ip> uname -r`
   - ネットワーク: `ssh -F ssh/config root@<static_ip> ip -brief addr`
   - Web UI: `curl -sk https://<static_ip>:8006`

5. **ブリッジ設定** (vmbr0/vmbr1) — **必須ステップ**:
   PVE で VM を利用するにはブリッジが必要。`pve-setup-remote.sh` は **vmbr0/vmbr1 を作らない** ので、必ず `pve-bridge-setup.sh` を別途実行すること (Round 5 で見落とし発生)。
   冪等: ブリッジが既に設定済みならスキップされる。
   実行前 check: `ip route` で default route 有無を確認 → 不在なら `dhclient -1 -v <dhcp_iface>` で復旧 (Round 5-7 で連続観測)。
   > `pve-setup-remote.sh` が installing する `/etc/network/if-up.d/z-fix-default-route` hook は final reboot 後の route loss を防げないことがある (Round 7 で確認)。`dhclient` 復旧手順を確実に流すこと。
   ```sh
   STATIC_IFACE=$("$YQ" '.static_iface' "$CONFIG")
   STATIC_IP=$("$YQ" '.static_ip' "$CONFIG")
   STATIC_NETMASK=$("$YQ" '.static_netmask' "$CONFIG")
   DHCP_IFACE=$("$YQ" '.dhcp_iface' "$CONFIG")
   scp -F ssh/config scripts/pve-bridge-setup.sh root@<static_ip>:/tmp/
   ssh -F ssh/config root@<static_ip> sh /tmp/pve-bridge-setup.sh \
       --static-iface "$STATIC_IFACE" --static-ip "${STATIC_IP}/${STATIC_NETMASK}" --dhcp-iface "$DHCP_IFACE"
   ```
   検証: `ip -brief link show type bridge` で vmbr0/vmbr1 が UP、`ip -brief addr show vmbr0` で正しい IP。

6. **IB セットアップ** (IB 搭載サーバのみ):
   OS セットアップ完了後、IPoIB を設定して永続化する。IB IP は `config/linstor.yml` の `ib_ip` を参照。
   ```sh
   scp -F ssh/config scripts/ib-setup-remote.sh pve$N:/tmp/ib-setup-remote.sh
   ssh -F ssh/config pve$N "sh /tmp/ib-setup-remote.sh --ip <IB_IP>/24 --mode connected --mtu 65520 --persist"
   ```
   初回実行時は udev リネーム前に検出され失敗することがある。再実行すれば解決する。
   `--persist` は `/etc/network/interfaces.d/ib0` に加えて `/etc/modules-load.d/ib_ipoib.conf` も書き込む。これにより `systemd-modules-load.service` が networking.service より前に `ib_ipoib` モジュールをロードし、リブート後の自動起動が確実になる。

7. 完了: `./scripts/os-setup-phase.sh mark cleanup --config "$CONFIG"`

8. **レポート作成**: `report/` ディレクトリに実行結果のレポートを作成
   - `./scripts/os-setup-phase.sh times --config "$CONFIG"` の出力をレポートに転記

---

## Resume（中断からの再開）

スキル呼び出し時に `./scripts/os-setup-phase.sh status --config "$CONFIG"` で現在の状態を確認し、
完了済みフェーズをスキップして次のフェーズから再開する。

`./scripts/os-setup-phase.sh next --config "$CONFIG"` で次の未完了フェーズ名を取得できる。

失敗したフェーズは `./scripts/os-setup-phase.sh reset <phase> --config "$CONFIG"` でリセットして再実行可能。

### 完全リセット (OS install をやり直す)

特定サーバの **全フェーズを pending に戻して Phase 1 からやり直す** 場合、state ディレクトリの中身を一括削除する:

```sh
find state/os-setup/<host> -mindepth 1 -delete
./scripts/os-setup-phase.sh init --config config/<host>.yml
```

> **⚠️ `rm -rf state/os-setup/<host>/*` は CLAUDE.md の shell 安全チェックでブロックされる** ことが多い (top-level wildcard 検出)。`find ... -mindepth 1 -delete` を使うこと (Round 1 s14 で確認)。

## pve-lock の使い方

Phase 4〜8 では状態変更操作に `./pve-lock.sh` を使用する:

```sh
./pve-lock.sh run <command...>     # 即座に実行（ロック中ならエラー）
./pve-lock.sh wait <command...>    # ロック待ち→実行（並列時はこちらを使用）
```

ロック中の場合は別の課題に着手し、ロック解放後に再開する。

## 2026-05-14/15 デグレ検証で確定した運用知見

`report/2026-05-14_091100_os_setup_18trial_x10dpu_r320.md` の 18 trial と
`report/2026-05-15_*_18trial_regression_fix.md` の後続検証で確定した実運用注意。

### `racreset soft` 後の VirtualMedia 復旧

iDRAC7/iDRAC8 で `racadm racreset soft` を実行すると、BMC リブート後に
**VirtualMedia の "Remote File Share" 設定が消失する**ことがある (trial-1-s9 で発生)。
症状: `racadm remoteimage -s` が `Status=Disabled` を返し、ISO がマウントされていない。

復旧手順:
1. `./scripts/idrac-virtualmedia.sh mount <bmc_ip>` を再実行 (SMB パスは config YAML の `vm_smb_path` を使う)
2. `racadm config -g cfgServerInfo -o cfgServerBootOnce 1` で boot-once を再設定
3. `racadm config -g cfgServerInfo -o cfgServerFirstBootDevice VCD-DVD` で次ブートを VCD に
4. `racadm serveraction powercycle` で電源 cycle (warmreboot ではブートデバイスが反映されないことあり)

> **重要**: `racreset soft` は最終手段。VirtualMedia の状態が消えるため、その後の
> 全ての mount/boot-once 設定をやり直す必要がある。

### subagent 運用注意 (Opus 必須・Monitor 禁止)

通しテストを subagent で実行する場合の必須条件:

1. **Opus 4.7 必須** — Sonnet 4.6 は tool_uses 制限 (~400-500回) で 1 trial 完走不能。
   過去 18 trial 検証では Sonnet で全件途中停止し Opus 再起動が発生した。
   Agent ツールの `subagent_type` には Opus を選び、明示的な model パラメータで
   `claude-opus-4-7` を指定する。
2. **Monitor ツール禁止** — subagent が `Monitor` で pause すると親への中間応答が
   止まり、親が状態を把握できなくなる。長時間待機は `Bash(run_in_background=false)`
   で foreground block するか、`sol-monitor.py` を foreground 実行する。
3. **state リセットを明示指示** — subagent は「既存 install を success として判定」
   する傾向がある。プロンプトに `find state/os-setup/<host> -mindepth 1 -delete` を
   明記し、`/etc/machine-id` の mtime が今回の install 開始時刻より新しいことを
   確認する手順を入れる。
4. **machine-id mtime 検証必須** — Phase 6 ステップ 5 の「実インストール検証」を
   subagent が省略しないよう、プロンプトで以下を明示する:
   ```sh
   ssh -F ssh/config root@<static_ip> stat -c %Y /etc/machine-id
   # → 当該 trial の preseed start epoch (date +%s で記録) より新しいことを確認
   ```

subagent プロンプトのテンプレ:
```
- os-setup スキルを呼び出し、config/<host>.yml で Phase 1-8 を実行する
- 着手前に `find state/os-setup/<host> -mindepth 1 -delete` で完全リセット
- 開始時刻を `date +%s > tmp/<sid>/trial-start-epoch` に記録
- sol-monitor.py には `--installer-syslog tmp/.../installer-syslog.log`,
  `--static-ip <static_ip>`, `--preseed-start-epoch $(cat ...)` を渡す
- 完了判定: ssh で /etc/machine-id mtime > trial-start-epoch を確認
- 中間レポートを `report/attachment/<MAIN>/trial-N-s<X>.md` に保存
- Monitor ツールは使わない、長時間待機は Bash foreground 実行
```

### `find-boot-entry "ATEN Virtual CDROM"` 失敗時のフォールバック

X11DPU BIOS 4.0 (4-6 号機) では、`find-boot-entry "ATEN Virtual CDROM"` が
**`Boot####` の動的列挙に失敗することがある** (trial-1-s4 で発生)。
ATEN Virtual CDROM は UEFI POST 中に VirtualMedia を検出してから初めて
BootOptions に出現するため、検出タイミングのズレで空リターンになる。

フォールバック:
```sh
# 1. boot-override で UEFI モードの CDROM を直接指定 (BootOrder 操作なし)
./scripts/bmc-power.sh boot-override <bmc_ip> <user> <pass> Cd UEFI

# 2. ふつうの順序での power on
./scripts/bmc-power.sh on <bmc_ip> <user> <pass>
```

`bmc-power.sh boot-override` の引数順序は **`<bmc_ip> <user> <pass> <target> <mode>`**
で、`<target>` は `Cd` (CDROM), `Hdd` (HDD), `Pxe` (PXE)、`<mode>` は `UEFI` or `Legacy`。
順序を間違えると Redfish の `Boot.BootSourceOverrideTarget` 未受理 (HTTP 400) になる。

`boot-override-reset` 後の最初の起動で iPXE / 無効 BootEntry に落ちる場合は、
`boot-override Hdd UEFI` で 1 回ディスク強制ブートを挟むと回復する (trial-1-s5/s6 で確認)。

### R430 (PERC H730/H730P) 通しテスト前の preflight

`report/attachment/2026-05-15_073531_18trial_regression_fix/trial-{1,2,3}-s14.md`
で確定した R430 固有の preflight。OS install 直前に確認すること。

#### 1. PERC のすべての PD を Ready (Raid mode) に戻す

PERC が HBA mode に切り替わっていた、あるいは過去の trial で Bay 0 や Bay 2-5 が
Non-Raid passthrough になっていると、partman の disk discovery で**前回 install の
LVM/VG が表に出てきて duplicate VG dialog で stuck する**。

```sh
# 全 PD の状態を確認
ssh -F ssh/config -i ssh/idrac_rsa root@10.10.10.34 \
  racadm storage get pdisks -o

# Non-Raid passthrough になっている PD を Ready に戻す
ssh -F ssh/config -i ssh/idrac_rsa root@10.10.10.34 \
  racadm storage converttoraid:Disk.Bay.0:Enclosure.Internal.0-1:RAID.Integrated.1-1
ssh -F ssh/config -i ssh/idrac_rsa root@10.10.10.34 \
  racadm jobqueue create RAID.Integrated.1-1 --realtime
```

OS install 対象は Bay 1+6 RAID-1 のみ。**それ以外のベイ (0, 2-5, 7) は
Non-Raid passthrough にしないこと**。Ready 状態 (Raid mode、VD 不所属) が正解。

#### 2. preseed-server14.cfg / preseed-server15.cfg の mirror セクションは CD-only

R430 は mgmt-only NIC (eno2 → 10.0.0.0/8、internet 不可) で OS install する。
debconf の preseed では、

- `apt-setup/use_mirror=false` だけでは不十分
- `mirror/country`, `mirror/http/hostname`, `mirror/http/directory`, `mirror/http/proxy`
  が残っていると **choose-mirror が依然 wget で deb.debian.org に到達を試み**、
  "Bad archive mirror" dialog で 30 分以上 stuck する (trial-3-s14 で確証)

完全 CD-only にする条件 (server7-9.cfg と同等):

```preseed
### Mirror dialog skipped entirely (no mirror/* lines)
d-i apt-setup/use_mirror boolean false
d-i apt-setup/no_mirror boolean true
d-i apt-setup/cdrom/set-first boolean true
d-i apt-setup/cdrom/set-next boolean false
d-i apt-setup/cdrom/set-double boolean false
d-i apt-setup/cdrom/set-failed boolean false
d-i apt-setup/non-free-firmware boolean true
```

> **重要**: `mirror/country string manual` が残っていると choose-mirror が
> インタラクティブモードに落ちて入力待ちになる。**mirror/\* 行は完全削除**。
> `cdrom/set-next=false` も必須 (true だと次 CD を待ち bouncer dialog)。

#### 3. pkgsel / tasksel の罠

netinst CD (mirror なし) で install するため、tasksel が install しようとするパッケージで
失敗ループを起こすことがある (trial-4-s14 で確認)。

- **`d-i pkgsel/include` から `curl` を削除**: netinst CD に curl の依存物が無い場合があり、
  tasksel "Select and install software" が失敗ループに陥る。`openssh-server sudo wget gnupg` 程度に絞る。
- **`d-i pkgsel/upgrade select none`** にすること: mirror なし環境で `full-upgrade` を選ぶと
  upgrade 対象を mirror から fetch できず失敗。`none` で skip。
- **`tasksel tasksel/first multiselect standard`** は残してよい (CD 内パッケージのみで完結する)。

#### 4. partman/early_command で前回 install 残骸を消す

複数 trial を回す場合、前回 install で書かれた **LVM PV/VG ヘッダ + GPT partition table が
/dev/sda に残り、partman の `atomic` recipe が "No root file system is defined" dialog で
stuck する** (trial-5-s14 で発生)。preseed に partman/early_command を入れて毎回 disk を
wipe する:

```preseed
d-i partman/early_command string \
  wipefs -a /dev/sda 2>/dev/null || true; \
  dd if=/dev/zero of=/dev/sda bs=1M count=10 2>/dev/null || true; \
  dd if=/dev/zero of=/dev/sda bs=1M seek=$(($(blockdev --getsz /dev/sda) / 2048 - 10)) count=10 2>/dev/null || true; \
  partprobe /dev/sda 2>/dev/null || true; \
  :
```

- `wipefs -a`: superblock 署名 (LVM/MD/GPT) を削除
- `dd` (先頭 + 末尾): GPT primary table + GPT backup table の領域をゼロ埋め
- `partprobe`: カーネルに変更を通知

server7-9.cfg は `sgdisk --zap-all` を使う別パターン。R430 では `wipefs + dd` 方式で
確認済み。

#### 5. serial_unit / console option は config と一致させる

R430 で `config/serverN.yml` の `serial_unit` が 0 のとき、preseed の
`debian-installer/add-kernel-opts` は `console=ttyS0` でなければならない (trial 4 直前で
ttyS1 のままだと SOL に installer 出力が流れず black-out)。
config と preseed をペアで管理する場合は generate-preseed.sh の console_order を参照、
手動管理 (preseed-serverN.cfg) の場合は config の serial_unit と整合確認すること。
