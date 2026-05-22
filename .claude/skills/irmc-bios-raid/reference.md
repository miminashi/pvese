# iRMC S4 リファレンス

## Redfish エンドポイント早見表 (training-tx1320 確認済み)

ベース URL: `https://10.254.254.9` (HTTPS + `--ciphers DEFAULT@SECLEVEL=0` 必須)

| パス | 用途 | 認証 | アクセス |
|------|------|-----|---------|
| `/redfish/v1/` | ServiceRoot (1.0.5 + Fujitsu OEM) | anon可 (HTTPS) / anon可 (HTTP) | GET |
| `/redfish/v1/Systems/` | Systems Collection (Members: `Systems/0`) | 要 | GET |
| `/redfish/v1/Systems/0` | System オブジェクト (Manufacturer/Model/BIOS 等) | 要 | GET |
| `/redfish/v1/Systems/0/Actions/ComputerSystem.Reset` | 標準 Reset | 要 | POST |
| `/redfish/v1/Systems/0/Bios` | BIOS リソース (**Attributes 空**) | 要 | GET |
| `/redfish/v1/Systems/0/Bios/Settings` | 設定の PATCH 対象 | 要 | PATCH |
| `/redfish/v1/Systems/0/Storage` | Storage Collection (**Members 空**) | 要 | GET |
| `/redfish/v1/Systems/0/SimpleStorage` | SimpleStorage (**Members 空**) | 要 | GET |
| `/redfish/v1/Systems/0/Processors` | CPU リソース | 要 | GET |
| `/redfish/v1/Systems/0/Memory` | メモリリソース | 要 | GET |
| `/redfish/v1/Systems/0/EthernetInterfaces` | NIC リソース | 要 | GET |
| `/redfish/v1/Managers/` | Managers Collection (Members: `Managers/iRMC`) | 要 | GET |
| `/redfish/v1/Managers/iRMC` | Manager オブジェクト (FW、SerialConsole 等) | 要 | GET |
| `/redfish/v1/Managers/iRMC/VirtualMedia` | 標準 Virtual Media (**Members 空**、OEM 経由) | 要 | GET |
| `/redfish/v1/Chassis/0` | Chassis (温度・ファン等) | 要 | GET |
| `/redfish/v1/AccountService/Accounts/<n>` | アカウント (claude=4) | 要 | GET/PATCH |

### Fujitsu OEM (`ts_fujitsu`)

| パス | 用途 |
|------|------|
| `/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.Reset` | OEM Reset (`PowerOff`/`PowerCycle`/`ImmediateReset`/`PulseNmi`/`PressPowerButton`) |
| `/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.Screenshot` | スクリーンショット撮影 |
| `/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia` | Virtual Media (CDImage 2 スロット, SMB) |
| `/redfish/v1/Systems/0/Oem/ts_fujitsu/PowerOnOff` | 週次の電源スケジュール (Reset とは別物) |
| `/redfish/v1/Systems/0/Oem/ts_fujitsu/BootConfig` | Fujitsu OEM ブート設定 |
| `/redfish/v1/Systems/0/Oem/ts_fujitsu/System` | OEM System プロパティ |
| `/redfish/v1/Systems/0/Oem/ts_fujitsu/FirmwareInventory` | FW インベントリ |
| `/redfish/v1/Systems/0/Bios/Actions/Oem/FTSBios.BSPBRBackup` | BIOS 設定 XML エクスポート |
| `/redfish/v1/Systems/0/Bios/Actions/Oem/FTSBios.BSPBRRestore` | BIOS 設定 XML インポート |
| `/redfish/v1/Systems/0/Bios/Actions/Oem/FTSBios.BSPBRSaveBackupToFile` | BIOS バックアップをファイル保存 |
| `/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration` | iRMC 設定ルート |
| `/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/Raid` | OEM Raid (中身は `OOBRaidEventsEnabled` のみ) |
| `/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/eLCM` | eLCM (ライセンス必須、training-tx1320 は **403**) |
| `/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/Licenses` | KVM/MEDIA/eLCM ライセンス |
| `/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/VideoRedirection` | KVM 設定 (Html5Enabled 等) |
| `/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/WebUI` | Web UI 設定 |
| `/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/BiosConsole` | BIOS Console Redirection 設定 |
| `/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/Components` | iRMC コンポーネント |
| `/redfish/v1/Managers/iRMC/Actions/Oem/FTSManager.FWUpdate` | iRMC FW 更新 |
| `/redfish/v1/Managers/iRMC/Actions/Oem/FTSManager.AddLicense` | ライセンス追加 (eLCM 取得時に使う) |

## Reset アクション AllowableValues 比較

iRMC S4 標準の AllowableValues は **PowerState に応じて動的に変わる** (2026-05-16 実機検証):

| PowerState | iRMC S4 標準 AllowableValues |
|------------|------------------------------|
| `Off` | `["On"]` のみ |
| `On` | `["ForceOff", "ForceRestart", "Nmi", "PushPowerButton"]` |

つまり「電源 On は `On` を使う (Off 状態のとき)、`PushPowerButton` は On 状態で物理ボタンを pulse する用途」と理解する。OEM `FTSComputerSystem.Reset` は固定 list で別系統。

| | iRMC S4 標準 (Off時) | iRMC S4 標準 (On時) | iRMC S4 OEM (FTSComputerSystem.Reset) | Supermicro X11DPU | DELL iDRAC7/8 |
|--|---|---|-----------|-----------|-----------|
| 電源 On 相当 | **`On`** | (送れない、状態 mismatch) | `PressPowerButton` | `On` | `On` |
| Pulse Power Button | (送れない) | `PushPowerButton` | `PressPowerButton` | - | - |
| 強制 Off | (送れない) | `ForceOff` | `PowerOff` (Graceful 含意) | `ForceOff` | `ForceOff` |
| 強制 Restart | (送れない) | `ForceRestart` | `ImmediateReset` | `ForceRestart` | `ForceRestart` |
| Power Cycle | n/a | (組合せ: ForceOff → wait → On) | `PowerCycle` | `PowerCycle` | `PowerCycle` |
| NMI | (送れない) | `Nmi` | `PulseNmi` | `Nmi` | `Nmi` |
| Graceful Off | (送れない) | (なし) | `PowerOff` | `GracefulShutdown` | `GracefulShutdown` |

→ **iRMC S4 でも `POWER_ON_RESET_TYPE=On` (default) で OK**。前セッション (#67) で `PushPowerButton` を推奨と書いていたが、実機検証で電源 Off 状態では拒否されることが判明し 2026-05-16 修正。

## BootSourceOverride

| | iRMC S4 (training-tx1320) |
|--|----|
| Target AllowableValues | `None`, `Pxe`, `Floppy`, `Cd`, `Hdd`, `BiosSetup` |
| Enabled AllowableValues | `Once`, `Continuous` |
| Mode AllowableValues | (Bios リソースに依存、UEFI/Legacy 両対応想定) |

`Disabled` は `BootSourceOverrideEnabled` の値ではなく、別フィールドで設定。

## Web UI 経由の操作

iRMC S4 Web UI は HTML 4 + IE8 互換の form ベース。Basic Auth では `/22?ms=N` のサブメニュー (Console Redirection / Storage / BIOS) に到達しても "Login required to continue" となる。Cookie ベースの form login が必要。

KVM 起動方法 (HTML5):
1. Web UI ログイン (form post)
2. 左メニュー → Console Redirection (ms11)
3. "Video Redirection (HTML5)" リンクをクリック
4. 別ウィンドウで HTML5 KVM が開く

Storage タブ:
1. Web UI ログイン
2. 左メニュー → System Information (ms1) → Storage
3. RAID コントローラ・物理ディスク・VD 表示

## ライセンス

`/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/Licenses` で確認:

| ライセンス | 用途 | training-tx1320 |
|-----------|------|----|
| KVM | Advanced Video Redirection (HTML5/Java KVM) | **あり (Permanent)** |
| MEDIA | Virtual Media (Remote Storage) | **あり (Permanent)** |
| eLCM | Embedded Lifecycle Management — Redfish 経由 RAID/BIOS 自動操作の中核 | **なし** (eLCM エンドポイント 403) |

eLCM ライセンスがあれば `iRMCConfiguration/eLCM/.../Profiles/...` 配下で RAID/BIOS の宣言的設定 (Profile XML) ができる。training-tx1320 はライセンスが無いので、RAID は KVM 経由・BIOS は WinSCU XML 経由で操作する。

## SOL (Serial Over LAN)

iRMC S4 の SOL は payload を user ごとに enable する必要がある:

```sh
# 状態確認
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload status 2 4
# → User 4 on channel 2 is enabled / disabled

# 有効化 (一度だけ)
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload enable 2 4

# Activate
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol activate
# → [SOL Session operational.  Use ~? for help]
```

`sol info` (channel 引数なし) で Enabled: true でも、payload 個別に enable しないと activate で `Info: SOL payload disabled` になる。

## bmc-power.sh のラッパー例

config を読んで環境変数を組み立てて `bmc-power.sh` を呼ぶ簡易ラッパー (使い捨て):

```sh
#!/bin/sh
# tmp/<sid>/tx1320-power.sh
set -eu
CFG=config/training_tx1320.yml
BMC_IP=$(./bin/yq '.bmc_ip' "$CFG")
USR=$(./bin/yq '.bmc_user' "$CFG")
PSW=$(./bin/yq '.bmc_pass' "$CFG")
export BMC_SCHEME=$(./bin/yq '.bmc_scheme' "$CFG")
export BMC_CURL_OPTS=$(./bin/yq '.bmc_curl_opts' "$CFG")
export POWER_ON_RESET_TYPE=$(./bin/yq '.power_on_reset_type' "$CFG")
exec ./scripts/bmc-power.sh "$@" "$BMC_IP" "$USR" "$PSW"
```

将来 `scripts/irmc-power.sh` のような恒久版を作る場合の雛形。

## 想定 RAID コントローラ (確定)

- **PRAID EP400i** (LSI MegaRAID 12 Gbps SAS3008、 PCIe Slot 4 に装着、 LaunchSlot4Oprom=Enabled で OpROM 有効) — `storcli` 対応
- BIOS Setup HII から RAID 操作する場合は Advanced → "AVAGO MegaRAID Configuration Utility - 03.25.05.10" (UEFI HII) に進入
- `storcli` (Linux) は OS 起動後に broadcom 公式から download してインストール

## BMC Manager Reset (`/redfish/v1/Managers/iRMC/Actions/Manager.Reset`)

iRMC の Actions セクションには `#Manager.Reset` が `target` だけで AllowableValues 未掲載 (2026-05-16 確認)。実機検証 (2026-05-16 #69) で **`{"ResetType":"GracefulRestart"}` が HTTP 204 で受理**、 BMC ソフトリブートが走り ~187s で Redfish が 200 で復帰する。 ユーザ・設定は保持される (ファクトリリセットではない)。

```sh
curl -sS -k --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"GracefulRestart"}' \
    "https://10.254.254.9/redfish/v1/Managers/iRMC/Actions/Manager.Reset"
# → HTTP/1.1 204 No Content
# Wait ~187s for Redfish to return 200 again.
```

注意: VGA frame buffer 問題は Reset で改善**しない** (落とし穴 #19 参照)。 KVM session lock の release や iRMC 内部 task のクリアには有効。

## WinSCU XML schema (training-tx1320 / BIOS V5.0.0.11 R1.22.0)

セクション構造:

```xml
<config>
  <schemeVersion>0.04</schemeVersion>
  <genId>BIOS</genId>
  <genRev>V5.0.0.11 R1.22.0 for D3373-B1x</genRev>
  <sysId>TX1320M3F2</sysId>
  <BootOrderApply>false</BootOrderApply>
  <BootOrder></BootOrder>
  <BootOrderChangeStatus>0</BootOrderChangeStatus>
  <settingDefinitions comment="setting definition part only, does not restore anything">
    <setting>
      <id>SerialPort1</id>
      <name>Serial Port</name>
      <token api="BSPBR"><setupItemID>0x0001</setupItemID>
        <possibleValues default="Enabled" current="Enabled">
          <possibleValue val="Disabled">1</possibleValue>
          <possibleValue val="Enabled">2</possibleValue>
        </possibleValues></token>
    </setting>
    ...  (91 entries)
  </settingDefinitions>
  <configuration>
    <supportedSetting>
      <id>SerialPort1</id>
      <name>Serial Port</name>
      <setupItemID>0x0001</setupItemID>
      <value>Enabled</value>
    </supportedSetting>
    ...  (book restore 対象)
  </configuration>
</config>
```

### UEFI 化に必要な主な supported settings (Legacy → UEFI)

| id | name | 変更先 |
|-----|------|--------|
| `BootOptionFilter` | Boot option filter | `Legacy only` → **`UEFI only`** |
| `LaunchStorageOpRomPolicy` | Launch Storage OpROM policy | `Legacy only` → **`UEFI only`** |
| `LaunchPxeOpRomPolicy` | Launch PXE OpROM Policy | `Legacy only` → **`UEFI only`** |
| `LaunchVideoOpRomPolicy` | Launch Video OpROM policy | `Legacy only` → **`UEFI only`** |
| `Csm` | Launch CSM | `Disabled` (デフォルト維持で OK) |
| `SerialPort1` | Serial Port | `Enabled` (デフォルト維持で OK) |

`config/training_tx1320.yml` の `bios_settings.supported` で宣言的に管理する (2026-05-16 実機検証で動作確認済み)。

## 既知の落とし穴

1. **HTTPS 古い DH 鍵**: `--ciphers DEFAULT@SECLEVEL=0` 必須
2. **ResetType AllowableValues 動的**: PowerState=Off では `["On"]`、PowerState=On では `["ForceOff","ForceRestart","Nmi","PushPowerButton"]`。Off→On は `On` を使う
3. **JSON `/` が `\/` でエスケープ**: sed で `tr -d '\\'` 正規化
4. **OEM Redfish PATCH に If-Match 必須、ETag は quotes なし**: 標準は `If-Match: "1778128217"` だが iRMC は `If-Match: 1778128217` でないと 412。`scripts/irmc-virtualmedia.sh` で対応済み
5. **Bios.Attributes 空**: WinSCU XML 経由で設定変更
6. **Storage Members 空 + eLCM ライセンスなし**: RAID 操作は KVM か OS 起動後の storcli
7. **SOL payload disabled**: `sol payload enable 2 4` 事前必須
8. **HTTP は anonymous root のみ**: 認証付きエンドポイントは HTTPS で
9. **Web UI は Basic Auth + form Login の併用**: Basic Auth でログインページに到達できるが、Console Redirection (Server Management ページ) に行くには `P99` submit して URL に `?sid=<SID>` を取得する必要あり (iRMC は Cookie ではなく URL パラメータで SID 保持)
10. **HTML5 KVM canvas は描画差分のみ**: viewer を新規 session で開くと、サーバが画面差分しか送らないため static screen (BIOS Setup 中など) では canvas が真っ白/真っ黒。**Control 単独キーで frame full refresh を誘発できる** ことがあるが、 BIOS Setup の HII 画面では効かない場合が多い (2026-05-16 検証)
11. **HTML5 KVM の WebSocket**: `wss://<bmc>/kvm`、proprietary protocol (viewer.min.js 経由)、`<canvas id="kvm">` に描画
12. **iRMC Web UI の `processing_maindiv` overlay が canvas をブロック**: Playwright で canvas.click() を呼ぶと "subtree intercepts pointer events" エラー。`focus_kvm()` で `document.getElementById('processing_maindiv').style.display='none'` してから click する (`scripts/irmc-kvm-interact.py` で対応済み、 2026-05-16)
13. **BSPBRBackup task は BIOS Boot Phase で実行される**: POST すると Task /N が Pending (`StatusOEM: BSPBRBootPhasePending`)。サーバを cycle/forceoff/on で再起動すると boot phase で実行 → Completed `BSPBRSuccess`。`/Systems/0/Bios` の `IsBspbrFileAvailable: true` を確認してから POST `FTSBios.BSPBRSaveBackupToFile` で download (`Content-Type: application/json`, body `{}`, response は `application/octet-stream` で WinSCU XML が返る)
14. **BSPBR backup ファイル末尾に NUL bytes**: 取得した XML には `\x00\x00` が末尾に付く。Python ElementTree の `fromstring` が `not well-formed` で失敗する。`text.rstrip(b"\x00\r\n\t ")` で除去してから parse (`scripts/irmc-bios.py` で対応済み、 2026-05-16)
15. **BSPBRRestore は multipart/form-data, field name `data` 必須**: `Content-Type: application/octet-stream` / `application/xml` / `text/xml` 等は HTTP 406 (`Fujitsu.1.0.ContentTypeNotSupported`)。`curl -F "data=@bios.xml"` で送る。 field 名が違うと `Fujitsu.1.0.DeclaredDataNotPresent`。HTTP 202 + Task URL を返す
16. **BSPBR restore で backup file が消費される**: restore 適用後の SaveBackupToFile は HTTP 404。再度新規 backup task を投入する必要
17. **WinSCU XML には 2 セクション**: `<settingDefinitions>` (read-only、 comment: "setting definition part only, does not restore anything") と `<configuration>` 内 `<supportedSetting>` (restore で適用される値)。書き換えは `<supportedSetting><value>` の方
18. **BIOS Setup 中の OEM Screenshot Make / KVM canvas frame が不安定**: `FTSScreenshotType` AllowableValues に `Preview` が遷移しない / canvas に frame が来ない (alive=True でも frame buffer 空)。**実態は 3 回に 1 回程度で成功**するため、 Make→Preview→Download を **wall-clock 経過時間で polling + Make を再 POST する retry** に変えると現実的な成功率が得られる (`scripts/irmc-oem-screenshot.sh` 2026-05-16 改修)。`irmc-kvm-interact.py oem-shot` 側にも 3 回 retry を実装、 subprocess に `poll=5 max_attempts=3` を渡す。
19. **BMC Manager.Reset は VGA frame buffer 問題を改善しない** (2026-05-16 #69 実機検証): `POST /redfish/v1/Managers/iRMC/Actions/Manager.Reset` body `{"ResetType":"GracefulRestart"}` で HTTP 204、 BMC は ~187s で復帰 (Redfish 200 が返るまで)。 ただし Reset 後の BIOS Setup HII でも canvas は黒のまま、 OEM Screenshot 経路でしか画面取得できない。 Aptio HII の GOP / EFI_GRAPHICS_OUTPUT_PROTOCOL が frame を再送しないと推定。
20. **OEM Screenshot 大量呼出で BMC が overload する**: 連続して Make POST を投げると BMC 全体 (Web UI/Redfish) が 60-90s 程度無応答になる。 確認: `curl https://<bmc>/redfish/v1/` が timeout (HTTP 000) する。 自動回復はする (人手介入不要)。 対策: OEM Screenshot は撮影回数を限定し、 各 oem-shot 失敗時は早期 fail (poll_timeout=5s 以下) で次へ進む。
21. **新規 viewer session の最初の sendkeys が swallowed されることがある** (2026-05-16 観測): 1 viewer session 内で連続 sendkeys したものは確実に効く (explore-advanced.sh で 13 ArrowDown 連続成功)。ただし新規 session を開いて単発 sendkeys + oem-shot を行うと、 カーソル位置が変わっていないケース観測。 対策: 各 viewer session の冒頭に `wait:5; oem-shot:initial.jpg;` を入れて canvas focus を確立してから sendkeys を送る。 もしくは「dummy Shift キー」を先に 1 個送る。
22. **Advanced タブのキーシーケンス確定** (2026-05-16): Main → `ArrowRight x1` → Advanced タブ。 Advanced の cursor は `Onboard Devices Configuration` から起動し、 `ArrowDown x14` で **AVAGO MegaRAID <PRAID EP400i> Configuration Utility - 03.25.05.10** に到達 (空行は cursor が skip)。経路: Onboard Devices → PCI Status → PCI Subsystem Settings → CPU Configuration → Memory Status → SATA Configuration → CSM Configuration → Trusted Computing → USB Configuration → Super IO Configuration → Network Stack Configuration → Option ROM Configuration → VIOM → iSCSI Configuration → AVAGO MegaRAID。 BIOS Setup タブは `Main, Advanced, Security, Power, Server Mgmt, Boot, Save & Exit` の 7 タブ。
23. **AVAGO MegaRAID HII 内のキーシーケンスは未確定** (2026-05-16 時点): 標準的な LSI MegaRAID SAS3008 操作からの推定では Main Menu → Configuration Management → Create Virtual Drive → RAID 10 → 4 drives → Save Configuration → Confirm。 ただし M1 (AVAGO 進入) のみ確定 (落とし穴 #24 参照)。
24. **AVAGO MegaRAID HII への進入は Enter 1 回で成功** (2026-05-16 #69 続報で確定): BIOS Setup → Advanced タブ → ArrowDown x14 で AVAGO 行ハイライト状態から `Enter` 1 回で AVAGO MegaRAID Configuration Utility Main 画面に入る。Main 画面の cursor 起動位置は `▶ Main Menu` (一番上)、 右ペイン description は "Shows menu options such as Configuration Management, Controller Management, Virtual Drive Management, Drive Management and Hardware Components."。 Main 画面に Properties (Status [Optimal] / Backplane 1 / BBU [No] / Enclosure 0 / Drives 4 / Drive Groups 0 / Virtual Drives 0 / View Server Profile) + Actions (Configure / Set Factory Defaults / Update Firmware / Silence Alarm) + Background Operations + MegaRAID Advanced Software Options (RAID6/RAID5/FastPath [Enabled]) が同居。
25. **BMC OEM Screenshot pipeline は連続 Make POST で 200s+ 完全停止する** (2026-05-16 #69 続報): 前セッションは「60-90s で自動回復」と書いていたが、 連続して数回 Make POST を投げると 5+ 分待っても回復しないケースを観測。 確認: `/redfish/v1/Systems/0` の `FTSScreenshotType@Redfish.AllowableValues` が `["Make"]` のみで `Preview` が永続的に出現しない。 **回復は Manager.Reset (BMC ソフトリブート) のみ** — 200s 待機後の最初の Make/Preview は必ず成功。 ただし続く数回の Make で再度詰まる。 対策: OEM Screenshot は milestone ごとに 1 回限定し、 Make POST 後 5-15s 待ってから Preview 取得。`scripts/irmc-oem-screenshot.sh` の curl `--max-time` は **15s 必須** (BMC 高負荷時 `Systems/0` GET に 7-8s 要する、 4s では永久に失敗)。
26. ~~**Manager.Reset を 2 回以上実行すると KVM HTML5 viewer のキーボード入力が死亡する**~~ — **2026-05-17 訂正: 誤判定**。 2026-05-16 #69 セッション後、 ユーザが手動 Web UI から HTML5 KVM を試したところ **BIOS 画面のキー操作は問題なく可能、 ブラウザ DevTools の `#kvm` ノード screenshot も正常取得**を確認。 BMC 側 USB HID emulation・frame buffer 配信ともに健全。 当時「KVM 死亡」と見なした症状の実態は Playwright 自動化スクリプト (`scripts/irmc-kvm-interact.py`) 側の問題で、 (a) `canvas#kvm.toDataURL()` が常に黒画像を返す (viewer.min.js が WebGL `preserveDrawingBuffer: false` で canvas を作っていると推定 — frame 合成後にバックバッファ消失) (b) Playwright の `keyboard.press()` が viewer.min.js のキーイベント listener に届かない (focus 確立 or 信頼イベント or target 要素の問題と推定) の 2 点に分解できる。 対策案 (次セッション検証要): canvas screenshot は `locator('canvas#kvm').screenshot()` / `page.screenshot(clip=...)` でディスプレイ側の合成済みフレームを取得 (WebGL の影響を受けない経路)、 キー送信は `force=True` を外した実 hit-test 経由 click で focus を確立してから press。 詳細→ [report/2026-05-16_235440_tx1320_raid10_kvm_kbd_dead.md](../../../report/2026-05-16_235440_tx1320_raid10_kvm_kbd_dead.md) 「(B) Playwright 経由のキー送信 + canvas screenshot が共に失敗」。
27. **iRMC S4 Manager.Reset は POST 後即座ではなく数秒-数十秒遅れで実行開始する** (2026-05-16 #69 続報): `POST /redfish/v1/Managers/iRMC/Actions/Manager.Reset` の HTTP 204 受理直後に Redfish endpoint をポーリングしても **数秒間は HTTP 200** を返し続け、 reset 開始後に 000 → 503 → 200 と遷移する。 `setup-raid10` dispatcher の S1 は当初 `sleep 3` 後にポーリング開始しており、 reset 前の HTTP 200 を「復帰完了」と誤検出していた (本セッションで発覚 → 修正済: `sleep 30` の事前待機追加、 ポーリング間隔も 3s → 5s)。 reset 後の BMC 復帰には実測 90-170s 要する。
28. **iRMC AVAGO HII 進入時のキー送信は SOL では届かない** (2026-05-16 #69 続報): training-tx1320 の BIOS Setup HII はグラフィックモードで描画され、 Console Redirection (Serial Port) は無効。 SOL を activate してもキー送信は host BIOS に届かず、 SOL は使えない。 唯一の input チャネルは HTML5 KVM USB HID emulation。 これが死亡すると操作不能。

## 関連ドキュメント

- [config/training_tx1320.yml](../../../config/training_tx1320.yml) — config
- [memory/training_tx1320.md](memory) — マシン固有メモリ
- [scripts/bmc-power.sh](../../../scripts/bmc-power.sh) — `BMC_SCHEME`/`BMC_CURL_OPTS`/`POWER_ON_RESET_TYPE` 対応済
