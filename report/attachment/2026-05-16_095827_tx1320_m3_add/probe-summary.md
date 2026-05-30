# Phase 2 実機調査サマリ — TX1320 M3 (10.254.254.9, iRMC S4)

実施日時: 2026-05-16 (JST)
対象: Fujitsu PRIMERGY TX1320 M3 (Serial MABK035229) / iRMC S4 FW 9.08F

## ハードウェア確定

| 項目 | 値 |
|------|----|
| Manufacturer | FUJITSU |
| Model | PRIMERGY TX1320 M3 |
| Serial | MABK035229 |
| MainBoard | D3373 (PartNumber S26361-D3373-B12, Version WGS03 GS03) |
| BIOS | V5.0.0.11 R1.22.0 for D3373-B1x |
| CPU | 1 socket |
| Memory | 24 GiB |
| BMC | iRMC S4 (FW 9.08F, SDR 3.16) |
| BMC Manager UUID | fa9cede6-adcb-4294-9e57-529cc6e62353 |
| HostName (現在) | DAYNETGROUP |
| PowerState (調査時) | On |
| Drive Slots (HDD0-3) | 全 OK (SignalStatus) |
| PCIe Slots 1-4 | 全 EmptyOrNotInstalled (RAID コントローラは onboard / mezzanine) |

## ネットワーク・接続プロトコル

| 経路 | 結果 | 備考 |
|------|------|------|
| HTTP (anonymous) `/redfish/v1/` | 200 OK | ServiceRoot だけ取れる、認証付きは 404 |
| HTTPS default ciphers | 失敗 (curl exit 35) | 古い DH 鍵で SSL handshake fail |
| HTTPS `--tls-max 1.2` | 失敗 (curl exit 35) | 同上 |
| **HTTPS `--ciphers DEFAULT@SECLEVEL=0`** | **成功** ★ | 認証付き全エンドポイント到達 |
| IPMI LAN+ default cipher 3 | OK | |
| IPMI LAN+ cipher 1/2/17 | OK | 全 cipher 通過 |
| **SOL (payload disabled の状態)** | 失敗 | "Info: SOL payload disabled" |
| **SOL (`sol payload enable 2 4` 後)** | **成功** ★ | `[SOL Session operational.]` |

→ **bmc-power.sh は `BMC_SCHEME=https` (デフォルト) + `BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"` で動作**

## アカウント

| index | UserName | RoleId | LAN/Serial | KVM/Storage | IPMI チャネル権限 |
|-------|----------|--------|-----------|-------------|------------------|
| 2 | admin | Administrator | - | - | OEM |
| 3 | root | Administrator | - | - | ADMINISTRATOR |
| **4** | **claude** | **Administrator** | **Administrator** | UseVideoRedirection: true / UseRemoteStorage: true | **ADMINISTRATOR** |

→ **claude のアカウント index は 4** (X11DPU 4-6号機 = 2、iDRAC7 7-9号機 = 3、X10DRT-P 10-13号機 = 4、R430 14-15号機 = 3 と並列で TX1320 M3 = 4)

## SOL (Serial Over LAN)

- **利用可能 ✓** (本セッションで確定 — ユーザ要求事項)
- **事前手順必須**: `ipmitool ... sol payload enable 2 4` で claude (user 4) のチャンネル 2 で SOL payload を有効化
- SOL info: Privilege Level USER, Bit rate 38.4kbps, Payload channel 1 (デフォルト), Payload port 623
- `ipmitool ... sol activate` で接続できることを確認 (`[SOL Session operational.]`)
- 次セッションの OS install 監視に `sol-monitor.py` を流用可能

## Redfish エンドポイント所見

### 標準操作

| 項目 | 結果 | 備考 |
|------|------|------|
| ServiceRoot | Redfish v1.0.5 + Fujitsu OEM (`ts_fujitsu`) | |
| Systems Members | `/redfish/v1/Systems/0` (1 台) | `get_system_path()` のパースで OK (要 `tr -d '\\'` 正規化) |
| Managers Members | `/redfish/v1/Managers/iRMC` (1 台) | |
| Chassis Members | `/redfish/v1/Chassis/0` | |
| **`#ComputerSystem.Reset` AllowableValues** | **`ForceOff` / `ForceRestart` / `Nmi` / `PushPowerButton`** ★ | **`On` 不在** — 電源 On は `PushPowerButton` を使う |
| BootSourceOverrideTarget AllowableValues | `None` / `Pxe` / `Floppy` / `Cd` / `Hdd` / `BiosSetup` | |
| Bios.Attributes | **空 `{}`** | Redfish 経由 BIOS 設定取得不可 (OEM の WinSCU XML 経由) |
| Storage Members | **空 `[]`** | Redfish 経由 RAID コントローラ列挙不可 |
| SimpleStorage Members | **空 `[]`** | 同上 |

### Fujitsu OEM 拡張 (主要)

| エンドポイント | 用途 | 動作確認 |
|---------------|------|----|
| `Systems/0/Actions/Oem/FTSComputerSystem.Reset` | OEM 電源操作 (`PressPowerButton` 等) | エンドポイント存在 |
| `Systems/0/Actions/Oem/FTSComputerSystem.Screenshot` | OEM スクリーンショット | POST 204 で受理 (ダウンロード経路は要 Web UI) |
| `Systems/0/Oem/ts_fujitsu/VirtualMedia` | Virtual Media 設定 (CDImage 2 スロット, SMB) | RemoteMountEnabled=true ★ |
| `Systems/0/Bios/Actions/Oem/FTSBios.BSPBRBackup/Restore` | BIOS 設定 XML 経由 | 利用可能 (実 PATCH は次セッションで検証) |
| `Managers/iRMC/Oem/.../iRMCConfiguration/Raid` | OEM Raid (中身は `OOBRaidEventsEnabled` のみ) | 情報なし |
| `Managers/iRMC/Oem/.../iRMCConfiguration/eLCM` | eLCM 経由の RAID 操作 | **HTTP 403 — ライセンスなし** |
| `Managers/iRMC/Oem/.../iRMCConfiguration/Licenses` | KVM ✓ / MEDIA ✓ (Permanent) / **eLCM なし** | |
| `Managers/iRMC/Oem/.../iRMCConfiguration/VideoRedirection` | `Html5Enabled: true` ★ / MouseMode: Absolute | |

## KVM 方式

- **HTML5 KVM が利用可能** ★ (`Html5Enabled: true`)
- Java Web Start (jviewer.jnlp) は 404 (HTML5 専用設定 or Basic Auth 不可)
- Web UI は HTML 4 + IE8 互換 (古い設計、Console Redirection サブメニュー経由で起動)
- ライセンス: KVM (Permanent) ✓ → AVR 利用可能
- **Basic Auth では Web UI form セッションが取れず**、HTML5 KVM 自動操作の実装は本セッションでは見送り (form login 解析 + Cookie 認証 + KVM canvas 操作の実装が大規模)

## RAID 操作の現実

- 標準 Redfish Storage: **空** → コントローラ・物理ディスク・VD は Redfish では見えない
- OEM Raid: 情報なし
- OEM eLCM: **ライセンスなし (403)** → eLCM 経由の RAID 操作は不可
- **本セッションでは RAID10 構成は手動操作 (iRMC Web UI / BIOS RAID Configuration Utility) として skill にガイド記載のみ**
- 物理ディスクのセクタサイズ (520B/528B) は Redfish では取れない

## 結論 — 設計判断への反映

1. `bmc-power.sh` の対応:
   - `BMC_SCHEME` (default `https`) + `BMC_CURL_OPTS` 環境変数化 ✓
   - **`POWER_ON_RESET_TYPE` 環境変数 (default `On`) で上書き可能化** ✓
   - JSON `\/` エスケープに対応するため `get_system_path()` で `tr -d '\\'` 正規化 ✓
2. `irmc-bios-raid` skill:
   - `power` (Redfish 自動) ✓
   - `bios enter/screenshot/backup/restore` (Redfish 自動) ✓
   - `raid status/create-r10/delete` (手動ガイド、KVM 自動化は将来課題) ✓
3. SOL は使える ✓ (要 payload enable)
4. HTML5 KVM 自動化は将来余地ありだが本セッションスコープ外
