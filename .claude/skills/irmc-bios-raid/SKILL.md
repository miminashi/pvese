---
name: irmc-bios-raid
description: "Fujitsu iRMC S4 (TX1320 M3 等) の電源・BIOS・RAID 操作。Redfish (HTTPS + SECLEVEL=0) 経由の電源/ブート操作 + iRMC Web UI 経由の手動 BIOS/RAID 操作手順。training-tx1320 対応。"
argument-hint: "<subcommand: power|bios|raid|info> [args...]"
---

# iRMC S4 BIOS / RAID 操作スキル

Fujitsu PRIMERGY サーバの iRMC S4 BMC を Redfish (HTTPS + 古い DH 鍵対策) 経由で操作する。
本セッション (2026-05-16) 時点で対応している唯一のマシンは **training-tx1320** (10.254.254.9, 一時設置・クラスタ非参加)。

| サブコマンド | 用途 | 自動化レベル |
|-------------|------|-------------|
| `info <config>` | 接続情報・PowerState・BIOS バージョン・ライセンス確認 | 完全自動 |
| `power status <config>` | 電源状態取得 | 完全自動 |
| `power on <config>` | 電源 On (ResetType=On) | 完全自動 |
| `power forceoff <config>` | 強制 Off | 完全自動 |
| `power cycle <config> [wait=15]` | ForceOff → wait → On | 完全自動 |
| `bios enter <config>` | 再起動して BIOS Setup へ (BootSourceOverrideTarget=BiosSetup) | 完全自動 (POST 中の F2 不要) |
| `bios screenshot <config> <out.jpg>` | OEM `FTSComputerSystem.Screenshot` (Make→Preview) | 半自動 (BIOS Setup 中など static screen で AllowableValues に Preview が出ない場合あり) |
| `bios backup <config> <out.xml>` | WinSCU XML をダウンロード (boot phase で実行) | **完全自動** (`scripts/irmc-bios.py backup`) |
| `bios restore <config> <in.xml>` | WinSCU XML をインポート (boot phase で適用) | **完全自動** (`scripts/irmc-bios.py restore`、 multipart/form-data `data=@xml`) |
| `bios show <xml> [regex]` | XML 内の `<supportedSetting>` を一覧 | 完全自動 |
| `bios set <xml> <id> <value>` | XML 内の特定 id の `<value>` を書換 | 完全自動 |
| `bios diff <a.xml> <b.xml>` | 2 つの XML 間の値差分表示 | 完全自動 |
| `bios apply-config <config>` | config['bios_settings.supported'] の値を XML に書き込み → restore | **完全自動** |
| `bios verify <config>` | 現在の BIOS 設定が config と一致するか確認 | **完全自動** |
| `raid status <config>` | RAID コントローラ・VD・PD 表示 | **手動 (iRMC Web UI で確認、手順ガイドのみ)** |
| `raid create-r10 <config>` | 4 本選んで RAID10 VD 作成 | **⚠️ 部分動作 (2026-05-18 #7 s-peaceful-hinton)**。 #6 (p-effervescent-kahn) で SMB silent failure 真因確定 + 修正 → CD boot + kernel boot まで成功。 installer の `cdrom-detect` で iRMC Virtual CD が見つからない問題に対し、 #7 で kernel cmdline (GRUB legacy / ISOLINUX / EFI 全 3 経路) + preseed.cfg.template に `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` を仕込んで再試行 → **効かず**。 iRMC OEM CDImage は GRUB レベル (BIOS USB CD-ROM emulation) では読めるが、 Linux 起動後の installer cdrom-detect の udev/sysfs ルールにマッチしない。 preseed.cfg 自体も `/cdrom/preseed.cfg` から load される設計上 cdrom-detect 失敗の時点で適用されない (chicken-and-egg)。 次セッション候補 (優先順): (1) initrd preseed 注入 + `preseed/early_command` で自前 `mount /dev/sr0 /cdrom`、 (2) iRMC HDImage (USB Mass Storage) 経由配信、 (3) PXE / hd-media 経路。 詳細は本 SKILL.md 末尾の「RAID10 storcli + preseed 経路」セクション + report `2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed.md` を参照 |
| `raid delete <config> <vd>` | VD 削除 | **手動 (同上)** |

詳細プロトコル・落とし穴・スクリーンショットは [reference.md](reference.md) を参照。

## 前提条件

- 対象: **training-tx1320** (10.254.254.9, iRMC S4 FW 9.08F, claude index 4)
- config: `config/training_tx1320.yml`
- 認証: claude / Claude123 (BMC ユーザ)
- ライセンス: KVM + MEDIA (Permanent)、**eLCM なし** → Redfish 経由 RAID 操作不可
- ipmitool は SOL 用 (本 skill では電源・BIOS は Redfish のみ使用)

## Redfish 接続規約

iRMC S4 は古い DH 鍵で TLS handshake するため、curl のオプションが必要:

```sh
curl -k --ciphers 'DEFAULT@SECLEVEL=0' -u claude:Claude123 https://10.254.254.9/redfish/v1/...
```

`scripts/bmc-power.sh` は環境変数で対応済み:

```sh
BMC_SCHEME=https \
BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
POWER_ON_RESET_TYPE=On \
    ./scripts/bmc-power.sh <command> 10.254.254.9 claude Claude123
```

> **iRMC ResetType メモ**: AllowableValues は PowerState で変わる。Off→On 遷移は `"On"` を使う (default で OK)。`PushPowerButton` は電源 On 状態で物理ボタンを pulse する用途のみ。

config から自動で読み込んで export するヘルパーパターン (skill 内で利用):

```sh
BMC_IP=$(./bin/yq '.bmc_ip' config/training_tx1320.yml)
BMC_USER=$(./bin/yq '.bmc_user' config/training_tx1320.yml)
BMC_PASS=$(./bin/yq '.bmc_pass' config/training_tx1320.yml)
export BMC_SCHEME=$(./bin/yq '.bmc_scheme' config/training_tx1320.yml)
export BMC_CURL_OPTS=$(./bin/yq '.bmc_curl_opts' config/training_tx1320.yml)
export POWER_ON_RESET_TYPE=$(./bin/yq '.power_on_reset_type' config/training_tx1320.yml)
./scripts/bmc-power.sh status "$BMC_IP" "$BMC_USER" "$BMC_PASS"
```

## サブコマンド: `info`

接続性と基本情報を一括取得。

```sh
# 例
BMC_IP=10.254.254.9
USR=claude; PSW=Claude123
CURL='curl -sS -k --ciphers DEFAULT@SECLEVEL=0 --max-time 30 -u'
$CURL "$USR:$PSW" "https://$BMC_IP/redfish/v1/Systems/0" | grep -E '"Manufacturer"|"Model"|"BiosVersion"|"PowerState"|"SerialNumber"|"TotalSystemMemoryGiB"'
$CURL "$USR:$PSW" "https://$BMC_IP/redfish/v1/Managers/iRMC" | grep -E '"Model"|"FirmwareVersion"'
$CURL "$USR:$PSW" "https://$BMC_IP/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/Licenses"
```

期待出力 (training-tx1320):
- Manufacturer: FUJITSU / Model: PRIMERGY TX1320 M3 / BIOS V5.0.0.11 R1.22.0 / Memory 24 GiB
- iRMC S4 FW 9.08F
- Licenses: KVM, MEDIA (Permanent)

## サブコマンド: `power`

`scripts/bmc-power.sh` を呼ぶ。電源 On は `ResetType=On` (デフォルト) で OK。

```sh
# Status
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
    ./scripts/bmc-power.sh status 10.254.254.9 claude Claude123
# → On / Off

# Power on (Off 状態から On へ)
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
    ./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

# Force off
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
    ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123

# Cycle (forceoff → wait 20s → on)
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
    ./oplog.sh ./scripts/bmc-power.sh cycle 10.254.254.9 claude Claude123 20
```

## サブコマンド: `bios enter`

Redfish PATCH で BootSourceOverrideTarget を BiosSetup に設定 → 再起動 → BIOS Setup に入る。
F2 キー送信不要 (POST 自動で BIOS Setup に分岐する)。

```sh
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
    ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 BiosSetup UEFI
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
    ./oplog.sh ./scripts/bmc-power.sh cycle 10.254.254.9 claude Claude123 20
```

> 注意: `BootSourceOverrideEnabled` は iRMC の AllowableValues が `Once` / `Continuous` のみ (Disabled は別フィールド)。`Once` で 1 回限定。

## サブコマンド: `bios screenshot`

OEM `FTSComputerSystem.Screenshot` で現在の画面を取得 (POST 中・BIOS Setup 中・OS 起動後の画面が見える)。

```sh
BMC_IP=10.254.254.9
USR=claude; PSW=Claude123
# 1. Trigger screenshot
curl -sS -k --ciphers 'DEFAULT@SECLEVEL=0' -u "$USR:$PSW" \
    -X POST "https://$BMC_IP/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.Screenshot" \
    -H 'Content-Type: application/json' \
    -d '{"FTSScreenshotType":"Make"}'
# 2. Download image (path documented in reference.md)
```

## サブコマンド: `bios backup` / `bios restore` / `bios apply-config`

OEM `FTSBios.BSPBRBackup` / `FTSBios.BSPBRRestore` で WinSCU XML を読み書き。`Bios.Attributes={}` なため、設定変更はこの XML 経由で行う。`scripts/irmc-bios.py` でラップ済み。

### Backup フロー (新規 backup を取得して download する場合)

1. POST `FTSBios.BSPBRBackup` → 任意 Task /N (TaskState=Pending)
2. **Task は BIOS Boot Phase で実行される** — `MessagesOEM` に `"BSPBR boot phase pending, you may need to reboot host"` → サーバを cycle/forceoff/on で再起動
3. Boot Phase が始まると Task は Running `BSPBRBootInProgress` → 完了で Completed `BSPBRSuccess`
4. `/Systems/0/Bios` の `IsBspbrFileAvailable: true` を確認
5. POST `FTSBios.BSPBRSaveBackupToFile` (`Content-Type: application/json`, body `{}`) → HTTP 200 で `application/octet-stream` の WinSCU XML が返る
6. **末尾に NUL bytes が付いてくる** → Python は `text.rstrip(b"\x00\r\n\t ")` で除去してから parse する

### Restore フロー

1. WinSCU XML を編集 (`<supportedSetting>` の `<value>` を書換)
2. POST `FTSBios.BSPBRRestore` → **`Content-Type: multipart/form-data`、 field 名 `data` 必須** (`-F "data=@bios.xml"`)
   - 他の Content-Type は `406 Not Acceptable` (`Fujitsu.1.0.ContentTypeNotSupported`)
   - field 名が違うと `400` (`Fujitsu.1.0.DeclaredDataNotPresent`)
3. HTTP 202 + Task /N (Pending)
4. cycle で boot phase → 適用 → Completed `BSPBRSuccess`
5. **2 度目以降の SaveBackupToFile は 404** — restore で backup file が「消費」される。再度新規 backup task を投入する。

### apply-config フロー (推奨)

```sh
# config 例:
# bios_settings:
#   supported:
#     BootOptionFilter: "UEFI only"
#     LaunchStorageOpRomPolicy: "UEFI only"
#     LaunchPxeOpRomPolicy: "UEFI only"
#     LaunchVideoOpRomPolicy: "UEFI only"

./scripts/irmc-bios-raid-setup.sh setup-bios config/training_tx1320.yml --cycle
./scripts/irmc-bios-raid-setup.sh verify-bios config/training_tx1320.yml
```

実機検証済み: training-tx1320 で `BootOptionFilter` 等の Legacy→UEFI 切替が確実に動作する (2026-05-16)。

### XML スキーマ

WinSCU XML には 2 つのセクションが含まれる:

- `<settingDefinitions>` — 各 setting の **定義** (id, name, possibleValues, default, current)。 `comment="setting definition part only, does not restore anything"` の通り、 restore 対象外。
- `<configuration>` 内の `<supportedSetting>` — **restore で適用される現在値** (id, name, setupItemID, value)。 `<value>` を書き換えて restore する。

詳細は [reference.md](reference.md) の "WinSCU XML schema" を参照。

## サブコマンド: `raid` (BIOS UEFI HII 手動操作のガイド)

iRMC S4 の Redfish Storage Members は空、OEM Raid は OOBRaidEventsEnabled しか持たず、eLCM ライセンスもない (training-tx1320)。BIOS Setup → Advanced → AVAGO MegaRAID Configuration Utility (UEFI HII) を HTML5 KVM で操作するのが唯一の経路。

### ⚠️ VGA frame buffer 問題 (2026-05-16 #69 続報)

**確定: BMC Manager Reset では改善しない**。 2026-05-16 #69 で `Manager.Reset GracefulRestart` (HTTP 204) → BMC 復帰 187s → BIOS Setup 再進入を試したが、 canvas は引き続き黒で frame buffer が更新されない。

**ただし OEM Screenshot (`FTSComputerSystem.Screenshot`) は 3 回に 1 回程度成功する**ことが判明。 これを retry で穴埋めすれば実用的な画面取得が可能 (`scripts/irmc-oem-screenshot.sh` 2026-05-16 改修済、 wall-clock 化 + 4 attempts retry, `--max-time 15`)。

### ✅ Playwright KVM 自動化 解決 (2026-05-17 golden-candle セッションで実証)

`scripts/irmc-kvm-interact.py` 改修済み。 default で動作する新パス + 旧パス温存:

| 旧パス (温存) | 新パス (default) |
|--------------|-----------------|
| `canvas.toDataURL()` — WebGL `preserveDrawingBuffer:false` で黒 | **`locator.screenshot()`** — composed frame を取得 |
| `click(force=True)` | **`locator.click(force=False)`** — hit-test 経由 |
| (なし) | キー送信に **`dispatch-event`** フォールバック (`document.dispatchEvent(KeyboardEvent)`) も実装済み |

新 CLI flag: `--capture-mode={locator,canvas}` / `--focus-mode={hittest,force}` / `--key-mode={playwright,dispatch-event}`。 旧経路は `--capture-mode=canvas` 等で利用可能。

> 🎯 **KVM screenshot は必ず `--capture-mode=locator` (default) を使うこと**。 legacy `scripts/irmc-kvm-screenshot.py` は canvas mode 固定で WebGL 黒画 artifact を出す (Phase 3 s-rustling-melody 2026-05-22 で 11857 B × 3 同一 PNG を「VGA 全黒」と誤判定、 Phase 4 s-vast-hare 2026-05-22 で訂正)。 **canvas mode artifact のサイン: 撮った PNG が全部完全同 size (sha256 一致) で 11857 B 前後**。 これが出たら即 locator mode に切り替える。 ただし host が実際に kernel hang していて VGA が更新されない場合も同 size 連続になるため (Phase 4 で BIOS POST 12833 B × 4、 凍結 4489 B × 2)、 単に同 size 連続 = artifact とは限らない。 識別ポイント: canvas mode artifact は **全 5 枚で完全同 sha256**、 実 host hang は **POST 段階と hang 段階で sha256 が分かれる**。

### ✅ 2026-05-17 #2: cursor_y adaptive navigation (golden-dongarra セッション)

`scripts/irmc-kvm-interact.py` の Playwright 路線を更に強化し、 **PIL でカーソル位置を pixel-level 検出**する `nav_cursor_to_y(target_y, max_press, tol)` を `tmp/iter/_util.py` に実装。 size fingerprint だけでは隣接 menu items を区別できない (16 items in BIOS Advanced tab で size 差 7-30 bytes 程度) ことが判明、 pixel-level cursor detection が解決策。

**確定知見** (詳細→ [report/2026-05-17_…_robustness.md]):

| 検証項目 | 結果 |
|---------|------|
| Partial-access dialog dismiss | `_dismiss_partial_access_dialog(vp)` — HTML overlay の Ok ボタンを JS click。 旧 KVM session が master の場合に発生 |
| Exit-Without-Saving dialog | キー `n` は Aptio で無効。 **ArrowRight (No) + Enter** で dismiss |
| BIOS top-level tab detection | 17 fingerprints (各 tab の各カーソル位置) を size + cursor_y で識別 |
| `safe_navigate_to_advanced_tab()` | Esc + dialog dismiss → ArrowLeft/Right で adaptive にタブ移動 |
| AVAGO row 到達 | nav_cursor_to_y(target=393) で 100% 成功 (iter 3b PASS) |
| AVAGO Main → Cfg Mgmt navigation | cursor_y mapping (Main Menu y=70 base, +19 per item) で stable |
| 個別 drive toggle 信頼性問題 | 解消: nav_cursor_to_y で silent drops を自動補正 (ArrowDown が dropped → 再 press) |
| Clear Configuration scaffolding | `clear_configuration(vp, sdir)` 実装。 ただし Confirm field の dialog cursor 検出に課題あり (要更なる pixel detection 改善) |
| **RAID 10 VD0 commit** | 未完遂。 form 内の **複数 ► マーカー問題** (`form` には「navigable 標識」として ► が複数表示され、 active cursor 検出が混乱) |

**カーソル検出関数** (`tmp/iter/_util.py:detect_cursor_row`):

```python
def detect_cursor_row(png_path, x_min=4, x_max=30, y_min=60, y_max=720,
                       cursor_pixel_value=255, min_cursor_run=4):
    """カーソル ► の bright (255) pixel 連続を検出。
    Menu items: cursor at x=8-14; Dialog form fields: cursor at x=24-26
    """
```

`nav_cursor_to_y(vp, sdir, target_y, max_press=25, tol=10, ...)` は target_y に着地するまで ArrowDown を adaptive に押し、 overshoot 時は ArrowUp に切替え。 silent drops に自動対応。

**まだ未解決** (次セッション継続必要):
1. **Create VD form の active cursor 検出** — form には複数の ► マーカーが表示され、 detect_cursor_row が active cursor を正しく識別できない。 → 解決案: ► glyph 検出ではなく「行の白背景ハイライト」(background color) を検出。 `bright_pixels` count を per-row で計算、 highlighted row を特定する関数に置換
2. **Clear Config dialog の field navigation** — Confirm field の cursor detection が不安定
3. **2-span 構成自動化** — RAID 10 選択後の form layout (Span 0 / Add More Spans / Span 1) の cursor_y マッピング未取得

### ✅ 2026-05-17 #3: active-cursor highlight detection + NumpadAdd + ArrowDown skip 発見 (partitioned-beaver セッション)

`tmp/iter/_util.py` に以下を追加実装:

- `detect_active_cursor_row(png_path, x_min=30, x_max=400, bg_threshold=200, min_bright_cols=30, y_min=60, y_max=720, merge_gap=4)` — 行の白背景ハイライト (highlight band) を検出。 各 y で bright pixel cluster 数を計測し、 最も bright count が大きい cluster の center y を返す
- `nav_cursor_to_y(..., detector='caret'|'highlight', settle_ms=0)` — caret/highlight を選択 + reach 後 settle 待機 + drift 補正

**実機検証 (training-tx1320) で判明した重大事実**:

| 観測 | 結論 |
|------|------|
| `detect_active_cursor_row` が **form 内で常に y=128 (Select RAID Level の [RAID0] 値表示) を picking** | cursor が他行にいても **`[RAID0]` の cluster (y=121..132, max bright cols=110)** が brightest として誤検出される。 form 内では highlight detection 単独で cursor 位置確定は不可能 |
| `form_open` 直後 `ArrowDown 1500ms wait` → **size=18474 → 実機 cursor は y=147 (Select Drives From)** | **Aptio が Select RAID Level (y=128) をスキップ**。 form_open (cursor on Save Config TOP y=88) → ArrowDown 1 で 2 行飛びで Select Drives From に着く |
| `ArrowUp 1` from y=88 → cursor at y=411 (Emulation Type) | wrap-around to form の bottom |
| `vp.keyboard.press("+")` / chord `Shift+Equal` / `type("+")` | **どれも Aptio に届かず** size 不変 |
| `vp.keyboard.press("NumpadAdd")` | **届く**。 Select Drives From で押すと `[Unconfigured Capacity]` ↔ `[Free Capacity]` トグル (size 18474↔18436 振動) |
| ArrowDown でカーソル位置が画面表示と Aptio 内部状態でずれる | iRMC KVM frame buffer の lazy refresh + Aptio key event queue の race condition。 `settle_ms=1500-3000` でも完全解消せず |
| **cursor 位置の確実な検出手段** | `NumpadAdd` を 1 回押して何の値が変わったかを screenshot size + 画像比較で同定するのが最も信頼性高い (highlight detection は誤検出多発) |

**確定した CURSOR_Y_CREATE_VD_FORM (RAID0 default, scout iter08_scout_run/p2_raid0_*.png から)**:

| 行 | y | 項目 | navigable? |
|----|---|------|-----------|
| step 0 | 88  | Save Configuration (TOP) | yes |
| step 1 | 128 | Select RAID Level [RAID0] | **No (Aptio skip)** |
| step 2 | 147 | Select Drives From [Unconfigured Capacity] | yes |
| step 3 | 166 | Select Drives | yes (submenu) |
| step 4 | 204 | Virtual Drive Name | yes |
| step 5 | 223 | Virtual Drive Size | yes |
| step 6 | 259 | Strip Size [256 KB] | yes |
| step 7 | 280 | Read Policy [Read Ahead] | yes |
| step 8 | 299 | Write Policy [Write Back] | yes |
| step 9 | 316 | I/O Policy [Direct] | yes |
| step 10 | 337 | Access Policy [Read/Write] | yes |
| step 11 | 373 | Disable Background Initialization [No] | yes |
| step 12 | 411 | Emulation Type [Default] | yes |
| step 13 | (wrap) | → 88 | wrap |

ArrowDown を 14 回押すと wrap-around。 silent drop (同じ y 連続) は step 9-10, 11-12 で観測。

**Select RAID Level (y=128) は ArrowDown skip 対象**のため、 値変更には:
1. ArrowDown でいずれかの navigable 行に着く
2. `Tab` または `Shift+Tab` で項目間 cycle (未検証)
3. もしくは **popup 経由** (`Enter` で Select RAID Level に入る—これが本来の Aptio の意図と思われる)

**次セッション継続課題** (Task C/D):

1. **cursor on Select RAID Level の到達方法を確定** — Tab/Shift+Tab? それとも form 初期 cursor が default で Select RAID Level (y=128) にあり、 そこで NumpadAdd?
2. **size fingerprint ベースの cursor identifier** — NumpadAdd 1 回で size diff から cursor 行を確定する関数 (`identify_form_cursor_by_probe`)
3. **drives popup の cursor 検出** — popup overlay 範囲 (x=410-600, y=350-420 など) に限定した detect 関数
4. **RAID10 commit シーケンス C1-C13** — 上記 1-3 完了が前提
5. **dispatcher 統合** — RAID10 commit 動作確認後

詳細→ [report/2026-05-17_092256_tx1320_raid10_active_cursor.md](../../../report/2026-05-17_092256_tx1320_raid10_active_cursor.md)

### 🛑 2026-05-17 #4: RAID10 自動化 dead end 確定 (a-goofy-graham セッション)

`tmp/iter/_util.py` に `identify_form_cursor_by_probe(vp, sdir, label, expected_y)` + `detect_popup_cursor_row(...)` + `PROBE_FORBIDDEN_Y` / `PROBE_SAFE_Y` / `CURSOR_Y_CREATE_VD_FORM` を追加。 静的検証 (既存 PNG) で `_rowwise_diff_y` が cursor 行を確実に特定可能なことを実証 (size delta -38 でも `_rowwise_diff_y` は y=148 を pin pointer 検出、 期待 y=147 と一致)。

**実機検証 (training-tx1320, iter_09 + iter_09b + iter_09c) で判明した dead end**:

| 試行 | 結果 |
|------|------|
| **iter_09 Phase 3** A2: ArrowUp x1 from y=147 → cursor y=88 (Save Config TOP に戻る、 expect y=128) | ❌ A2 失敗 |
| ArrowUp x2 from y=147 → y=411 (Emulation Type, wrap to BOTTOM) | ❌ A2 fallback 失敗 |
| ArrowUp x3 from y=147 → y=392 (不明位置) | ❌ |
| **iter_09b T1** form_open + Enter on Save Config TOP → Save Configuration dialog (size +1215) | ❌ y=128 到達せず (cursor は内部的にも y=88 確定) |
| **iter_09b T2/T3** Tab / Shift+Tab → size +0 (完全無反応) | ❌ Aptio HII は Tab を解さない |
| **iter_09b T_home** Home key → size +0 (無反応) | ❌ |
| **iter_09b T_end / T_pagedown** → cursor y=411 (form BOTTOM) | ❌ y=128 訪問なし |
| **iter_09b T_pageup** → cursor y=88 (form TOP) | ❌ y=128 スキップ |
| **iter_09b T_click x50/x200/x300, y=128** Mouse click via Playwright canvas → size +0 | ❌ Aptio HII は canvas click を解さない |
| **iter_09c** Profile-Based VD: 4 profile cycle (RAID 0/1/5/6) — **RAID 10 profile なし** | 🛑 **Profile 経路も dead end** |

**結論**: AVAGO HII for TX1320 M3 (LSI SAS3008, FW iRMC 9.08F) では:
- Create VD form の Select RAID Level (y=128) には **ArrowDown/Up/Tab/Shift+Tab/Home/End/PageUp/PageDown/Mouse Click のいずれでも到達不可能**
- Profile-Based VD は **RAID 0/1/5/6 のみ提供、 RAID 10 profile なし**
- → **RAID 10 自動化は AVAGO HII KVM 経路では不可能**

**残された候補** (次セッション以降):
1. **LSI Software RAID Utility (Advanced tab y=406)** を試す — AVAGO とは別 controller の HII の可能性
2. **キーボードイベント raw injection** (Playwright bypass、 iRMC KVM Java/HTML5 protocol level) — Tab/Click が届かない原因の分析
3. **2 段階 RAID 1 + RAID 0 ストライプ** — Profile-based で RAID 1 を 2 つ作り、 後で manual RAID 0 化 (AVAGO がこの構成をサポートするか未確認)
4. **iRMC OEM Redfish 探索** — TX1320 は eLCM なしだが、 OEM Redfish で RAID 設定変更ができる panel が隠れている可能性
5. **MEGACLI CLI を OS 側から実行** — OS install 後に MEGACLI で RAID 10 を作成 (ただし OS install には先に RAID 必要なので circular)

**Drives popup の frame buffer 描画問題** (iter_09 Phase 4 で判明):
- popup を Enter で開いた直後 4 frame canvas 全て真っ黒 (cnt=0)
- 5 frame 目以降 highlight が部分的に見える (cnt=39-79)
- `detect_popup_cursor_row(x=410-580, y=340-560)` でも検出失敗
- 仮説: iRMC KVM frame buffer の lazy refresh + popup overlay の partial draw
- → 次セッションで Ctrl 単独 key で frame refresh を強制 + 待機時間長期化を試行 (ただし dead end のため優先度低)

**確定した CURSOR_Y_CREATE_VD_FORM (本セッションで追加)**:

```python
CURSOR_Y_CREATE_VD_FORM = {
    "save_configuration_top": 88,
    "select_raid_level":      128,   # ❌ UNREACHABLE
    "select_drives_from":     147,
    "select_drives":          166,
    "virtual_drive_name":     204,
    "strip_size":             259,
    "read_policy":            280,
    "write_policy":           299,
    "io_policy":              316,
    "access_policy":          337,
    "disk_cache_policy":      373,
    "emulation_type":         411,
}
```

**追加実装関数** (`tmp/iter/_util.py`):
- `identify_form_cursor_by_probe(vp, sdir, label, expected_y)` — hybrid (model + image diff probe). `PROBE_FORBIDDEN_Y={88,411}` で action 行 skip、 `PROBE_SAFE_Y={147,259,280,299,316,337,373}` で NumpadAdd→NumpadSubtract で値を確実に戻す + image diff で cursor 行特定
- `detect_popup_cursor_row(...)` — popup overlay 範囲限定 detect (popup frame buffer 描画問題で本セッションでは動作未確認)
- `_rowwise_diff_y(before, after, ...)` — 2 PNG 間の row-wise pixel diff sum を計算 → 最大 y を返す (probe の内部実装)

**詳細**: 次セッション引き継ぎレポート `report/2026-05-17_HHMMSS_tx1320_raid10_dead_end.md` 参照

### 🎯 2026-05-31 (cosmic-aho): FW 9.69F KVM ログイン修正 + HII モーダルダイアログ入力不能の確定

FW **9.69F** で KVM 自動化を再開しようとして判明した 2 点 (実機 training-tx1320)。

#### (1) FW 9.69F の KVM ログインは cookie ベース — 旧 `open_viewer` は必ず失敗する

- 旧 `scripts/irmc-kvm-interact.py` / `tmp/iter/_util.py` の `open_viewer` は login 成功を `re.search(r'sid=', page.url)` で判定していたが、**FW 9.69F は SID を URL に入れず cookie (`sid`) に格納**する。`P99` (Login submit) クリック後の URL は `/systeminfo?ms=1&lang=0#login` のまま (ログインは成功している) → 旧コードは `Failed to login after 3 attempts` で必ず死ぬ。
- **修正 3 点** (検証済み):
  1. login 成功判定を `ctx.cookies()` に `sid` cookie 出現で行う
  2. viewer は `viewer.html?ms=0&lang=0` を **sid パラメータなし**で開く (cookie セッションで認証)。Web UI の "Video Redirection (HTML5)" link href も `viewer.html?ms=1&lang=0` で sid なし
  3. `canvas#kvm` の click は `#cursor_canvas` overlay が pointer を intercept するため **`click(force=True)` 必須** (旧コードの hit-test click は timeout)
- KVM canvas locator screenshot (1024x768) は鮮明に判読可能。BIOS Setup メニュー画面の cursor_y マップ (`CURSOR_Y_ADVANCED_TAB` 等) は 9.69F でも有効。
- 参考実装: `tmp/503d9361/kvmlib.py` の `open_viewer` (本セッションの作業コピー)。次回これを `scripts/irmc-kvm-interact.py` に移植すべき。

#### (2) 🛑 Aptio HII モーダルダイアログ/ポップアップは KVM 入力 (キー・マウス) を一切受け付けない

VD 削除を BIOS メニュー (Configuration Management → Clear Configuration) で試行したところ、**Clear Configuration 確認ダイアログがキーボード・マウスの両方を完全に無視**する。OEM Screenshot (真の VGA) で裏取り済み:

- **Clear Config 確認ダイアログ** (`Confirm [Disabled]` / `Yes` / `► No`、初期カーソル No):
  - ArrowUp/ArrowDown を **20 回連打しても ► は No から 1px も動かない** (OEM screenshot で確定、frame buffer 凍結ではない)
  - Enter (No 上) も効かない (ダイアログが閉じない)
  - Escape も効かない (General Help popup を F1 で開いた後 Escape で閉じられない)
  - canvas マウスクリック (Confirm/Yes/No 行の座標) も無効 (Aptio HII はマウスを解さない、 2026-05-17 #4 既出を再確認)
  - 一方 **F1 (General Help) は効く** — F1 は下層フォームが処理するグローバルホットキーのため。だが開いた Help popup 自体は Esc/Ok で閉じられない
- **メニュー (Setup ページ) の矢印ナビゲーションは効く** — Main tab → Advanced tab → AVAGO row (ArrowDown 14)、Main Menu → Configuration Management → Clear Configuration への移動は成功。Enter でのサブメニュー/ダイアログ展開も成功。
- **境界**: 「Setup ページ (左寄せメニュー項目リスト)」の ↑↓ は効くが、「モーダル確認ダイアログ/ポップアップ」の ↑↓/Enter/Esc/マウスは効かない。これは 2026-05-17 #3/#4 の「Create VD form の Select RAID Level 到達不可」「drives popup frame buffer 描画問題」と同根 (HII popup/form の入力レイヤが KVM では機能しない)。

> ⚠️ **上記 (2) の「入力不能 / dead-end」結論は 2026-06-01 に覆った (下記参照)**。当初は「Confirm/Yes/No モーダルに synthesized input が一切届かない」と判断したが、真相は **「フォーカスカーソル ► が常に No に固定表示され実フォーカスを反映しないため、キーが効いていないように見えていた」** だけ。実際にはキーは届いており、正しいキーシーケンス + 1キーごとの screenshot 確認で **完全自動操作が可能**。

### 🎉🎯 2026-06-01 (cosmic-aho 続き): 確認ダイアログ自動操作レシピ確立 — RAID 削除→再作成を完全自動化

上記 (2) の訂正。`Confirm/Yes/No` モーダル (Clear Configuration 削除確認 / Save Configuration 作成確認 / drives popup ではない方) は **operable**。鍵は「► は静的でフォーカスを示さない」ことを理解し、**1キーごとに screenshot で状態遷移を確認しながら**進めること (盲目の連続送信は不可)。

**確認ダイアログ commit レシピ (実証済み、削除・作成共通):**
1. ダイアログ展開直後 (初期フォーカス=No、► は No 上に固定表示): **`ArrowUp` ×2 → `Enter`** → `Confirm` のドロップダウン (Disabled/Enabled) が開く (screenshot size ~11866 で確認。►×1 では不足)。
2. ドロップダウンで **`ArrowDown` → `Enter`** → `Enabled` 選択。`Confirm [Enabled]` になり `Yes` が選択可能化。
3. **`ArrowDown` → `Enter`** → `Yes` を選択して commit。**Confirm=Enabled 後は ► が実際に `Yes` (caret y~221) へ可視移動する**ので screenshot で確認できる。
4. "The operation has been performed successfully / ►OK" ポップアップを **`Enter`** で閉じる (この左寄せ ►OK 型は Enter で閉じる)。

**Create VD (RAID0) 全自動シーケンス (FW 9.69F、実証済み):**
1. Main → `ArrowRight` (Advanced tab) → AVAGO row (cursor_y=393) → `Enter` → AVAGO dashboard。
2. `Enter` (Main Menu) → `Enter` (Configuration Management) → `Enter` (Create Virtual Drive)。VD が無い時のみ Config Mgmt 先頭が Create Virtual Drive。RAID Level は **[RAID0] がデフォルト**で変更不要。
3. フォームで `Select Drives` 行 (highlight y~147) へ → `Enter` → drives popup。
4. drives popup で `Check All` 行 (y~412) → `Enter` → 全 drive [Enabled]。
5. `Apply Changes` (上部 y~70 を `ArrowUp` で狙うのが確実。下部 y~450 への navy は all-Enabled 行の bright cluster で highlight 誤爆) → `Enter` → ►OK を `Enter` で閉 → フォームに戻る (VD Size に容量反映、例: 4×837GB RAID0 = 3.272 TB)。
6. `Save Configuration` (フォーム最上部、cursor 初期位置) → `Enter` → 作成確認ダイアログ → 上記 commit レシピ。

**Clear Configuration (削除) 全自動シーケンス:** AVAGO dashboard → `Enter` (Main Menu) → `Enter` (Config Mgmt) → `Clear Configuration` 行 → `Enter` → 削除確認ダイアログ → 上記 commit レシピ。

**🚨 検証は必ず Virtual Drive Management で**: `AVAGO dashboard` の `Virtual Drives:`/`Drive Groups:` カウントと `Configuration Management` のメニュー項目は **stale でキャッシュされ、作成/削除直後に古い状態を表示する** (作成後も VD:0、削除後も「View Drive Group Properties/Clear Configuration」を表示し続ける)。実態は **Main Menu → Virtual Drive Management** が反映 (例: "Virtual Drive 0: RAID0, 3.272TB, Optimal")。

これにより **iRMC S4 KVM (FW 9.69F) で BIOS メニュー経由の RAID 削除→再作成が (単一健全セッションで) 自動化可能**と確定 (2026-06-01、RAID0 で実証)。※ RAID10 の Create VD form 内 `Select RAID Level` への到達は依然 dead-end (2026-05-17 #4) だが、RAID0/1/5/6 はデフォルト or Profile-Based で作成可能。参考実装: `tmp/<sid>/kvm_server.py` (永続セッション + コマンドファイル駆動 + ► 不可視前提の per-key 検証)。

#### 🚨 無人 N サイクル自動ループの落とし穴 (2026-06-01、9 回ループ試行中に判明)
単発の削除/作成は自動化できたが、**無人で N サイクル回す**のは以下の脆さで非常に困難。harden するには下記を厳守:

1. **制御テストに F1 (General Help) を使うな**。F1 が開く Help モーダルは Esc で**閉じないことがあり**、開いたまま残ると以降の全ナビゲーションキーをブロックする (caret が固定値に張り付き「キー不達」に見える = 過去「KVM 劣化」と誤診した症状の主因)。制御確認は **ArrowRight→ArrowLeft のタブ切替** (画面 size 変化で判定、popup を開かない) を使う。
2. **BIOS 最上位タブ (Main/Advanced) で Esc を押すな**。「Exit Without Saving (Quit without saving? Yes/No)」モーダルが開き、これも synthesized 入力を受けず以降をブロックする。AVAGO サブメニュー内の Esc は安全 (上位へ戻るだけ)。
3. **Advanced タブ下部の密集項目で AVAGO 行への正確な着地が困難**。iSCSI(caret y≈368) / AVAGO MegaRAID(≈393) / LSI Software RAID(≈406) が ~13px 間隔で、caret 検出 ±8px では 393 と 406 を区別しきれず LSI SW RAID 等に誤入する。要・狭 tol + 着地後の screenshot 文言確認 (「AVAGO MegaRAID」の文字)。
4. **KVM master セッションは閉じると数分スロットが残存**。次の接続はスレーブ (キー無反応) になり再接続が要る。無人ループは **1 セッションを開いたまま全サイクル実行**し、開閉を繰り返さないこと。
5. **詰まった modal / スレーブ状態からの確実な復旧 = host を ForceOff → BMC reboot (Manager.Reset) → host を BIOS に起動**。⚠️ **Manager.Reset は host が ON / BIOS 設定中だと `Fujitsu.1.0.ActionRelatedFeatureBlocked` で恒久ブロックされる。必ず先に host を ForceOff してから** Manager.Reset すると通る (2026-06-01 実証、ユーザ指摘)。BMC 復帰後に boot-override BiosSetup + power on で fresh な BIOS Main タブ + 健全 KVM + セッション無し状態になり、その「最初の接続」だけが master かつ健全。
6. 状態確認は KVM セッションを消費しない **OEM Screenshot (`irmc-oem-screenshot.sh`)** を優先 (KVM master を奪わない)。
7. **🚨 AVAGO のメニュー階層は入場ごとに見え方が変わる — caret_y やサイズで盲判定するな、必ず各画面の文字を読め**。確認された 2 形態: (A) フル dashboard = `Main Menu / Help / PROPERTIES: Status.. / ACTIONS: Configure..` (Virtual Drives 数が見える)、その Main Menu を Enter すると `Configuration Management / Controller Management / Virtual Drive Management / Drive Management / Hardware Components` の **5 項目**。(B) コンパクト = AVAGO 行 Enter 直後にいきなり `Controller Management / Virtual Drive Management / Drive Management` の **3 項目だけ** (Configuration Management が無い = Create/Clear に到達できない)。2026-06-01 の careful ラウンドは (B) に入ったのに (A) のつもりで操作し、Controller Management 内を delete/create と誤認して空振りした。**対策: AVAGO 進入後まず画面の文字を読み、`Configuration Management` 行が見える形態か確認する。無ければ一段 Esc して入り直す**。VD の有無は最終的に **Virtual Drive Management** ページの `Virtual Drive 0: RAIDx, ...` 行を OEM で読むのが唯一信頼できる (dashboard カウントは stale)。
8. **per-key 駆動を徹底**: 1 キー送るたびに screenshot を撮り、その画像の文字を読んでから次を決める。複数キーを 1 つの cmd にまとめて送ると、メニュー階層の取り違え・silent drop で容易に道を見失う (2026-06-01 で複数回実証)。eff率化は手順が完全に固まってから。
9. RAID 構成は **コントローラ NVRAM に永続**し、host 電源断・BMC reboot では消えない (2026-06-01、VD0 が複数回の cold reset を生き延びて確認)。クリーン状態に戻したい時も RAID は明示的に Clear Configuration しない限り残る。
7. 推奨フロー: [host off → BMC reboot → host on(BIOS) → OEM で BIOS 到達確認 → 介在セッション無しで単一セッションを開き全サイクル実行]。それでも Advanced→AVAGO の初回ナビ精度が課題で、無人完走の信頼性は低い。**現実的には削除/作成の各 confirm を人手 (Web UI KVM) で行う協調方式が最も確実** (2026-06-01 で 1 サイクル実証済)。

#### KVM セッション運用の知見 (本セッションで確立)
- iRMC S4 は KVM master を 1 セッションのみ許可。**閉じた master セッションが数分間スロットを保持**し、その間に開いた新セッションは read-only スレーブ (キー silent drop)。スレーブは master 失効後も自動昇格しない (再接続が必要)。
- → **単一の永続 KVM セッションを保持し続ける**運用が必須 (open/close を繰り返さない)。master 取得の確認は **F1 で General Help が開くか (screenshot size 変化 +3000 程度)** でテストできる。取れなければ close → 40s 待 → 再接続をリトライ。参考: `tmp/503d9361/kvm_server.py` (コマンドファイル駆動の永続セッションサーバ)。
- viewer 再接続直後は `#cursor_canvas` overlay で canvas が一時 invisible になり screenshot が timeout することがある → bounding_box の width/height>100 を待つ。

### 🎯🎯🎯 2026-06-01 (503d9361): 削除→再作成 3 サイクル完遂 — レシピ反復再現性確定 + ハードニング知見

cosmic-aho 続きで確立した削除→再作成レシピを **3 サイクル連続で完遂し、反復再現性を確定** (issue #73)。構成: ベースライン作成 + 3×(削除→検証→再作成→検証) = **削除レシピ ×3 + 作成レシピ ×4 を全て KVM canvas + OEM 真VGA で二重裏取り**。最終状態 VD0 RAID0 3.272TB Optimal。

このセッションで上記レシピ (確認ダイアログ commit / Create VD / Clear Configuration) はそのまま安定動作し、信頼できると確定。ただし無人完走には以下の per-key ハードニングが必須:

1. **🆕 KVM canvas にスクリーンショット遅延がある** — press が実際には登録済でも、直後に撮った shot が **1 つ前の stale フレーム**を返す。ArrowLeft を 2 回送って「1 回目が効いてない」と誤認したが、実際は両方効いており shot が遅れていただけだった (Security→Advanced→Main と 2 タブ動いていた)。→ **press 後に `sleep 2.5` を挟んでから shot を撮る**。盲目で「効いてない」と判断して再送するとオーバーシュートする。
2. **🆕 コミット確認ダイアログは 2 段階に分けて裏取りする** — 確認レシピ (ArrowUp×2→Enter→ArrowDown→Enter→ArrowDown→Enter) を盲目で一括送信せず: **(段階1)** `ArrowUp×2→Enter→ArrowDown→Enter` まで送り **Confirm が [Enabled] になったか** screenshot 確認 → **(段階2)** `ArrowDown` を送り **Yes の反転背景 (ハイライト) を確認**してから最後の `Enter` (commit)。commit は不可逆なので Yes ハイライトの目視確認は必須。**▶No は静的マーカーで実フォーカスを示さない** — 判定は必ず「反転背景 (白背景に暗い文字)」で行う。
3. **🆕 Create VD form の Select Drives ナビは ArrowDown×2 が 1 手前に着地することがある** — キードロップで `Select Drives` (▶) でなく `Select Drives From [Unconfigured Capacity]` で止まる。右ヘルプ `Dynamically updates to display as Select Drives or Select Drive Group based on the selection made in Select Drives From.` が出る行が `Select Drives` (▶)。ズレたら `ArrowDown`/`ArrowUp` で **±1 キー補正**。**`CONFIGURE VIRTUAL DRIVE PARAMETERS` ヘッダ行はカーソルがスキップ**するので ArrowDown 1 で `Select Drives`→`Virtual Drive Name` へ飛ぶことに注意。
4. **🆕 作成完了の 2 つ目メッセージは Escape、削除完了の OK は Enter** — 作成 commit 後の `"The operation has been performed successfully." (►OK)` を Enter で閉じると次に `"Virtual Drive creation was successful. All free configurable space has been used."` (OK ボタン無し) が出る → **Escape で閉じる**。一方削除 commit 後の `"The operation has been performed successfully." (►OK)` は **Enter 1 回**で Config Mgmt に戻る (2 つ目メッセージ無し)。
5. **🆕 ArrowDown が稀に ArrowRight に誤登録**しタブ移動 (Advanced→Security 等) が起きる → 各操作後にタブ名を確認、ズレたら ArrowLeft で戻す。
6. **🆕 アイドルタイムアウトからの復旧フローを実証** — `kvm_server.py` の idle timeout (7200s) で master を失った場合: `killall.sh` → `pw.sh forceoff` (host Off 確認) → `bmc-reset-retry.sh` (Manager.Reset、host Off なので通る) → `wait-bmc-boot.sh` (boot-override BiosSetup + power on) → `wait-post-snap.sh` (POST 待ち + OEM で BIOS 到達確認) → `kvm_server.py` を再起動し `=== KVM server READY ===` を待つ。**復旧後 master は attempt 数回でクリーン取得でき、RAID は NVRAM 永続なので無影響**。復旧後は BIOS Main タブから AVAGO へ再ナビ (Main→ArrowRight→Advanced→ArrowDown×14→AVAGO 行)。
7. **🆕 画像分析はサブエージェントに委任** — 各 screenshot を general-purpose サブエージェントに Read させ「選択タブ / カーソル行 / 右ヘルプ / 反転背景の位置 / 黒画有無」を構造化報告させると、per-key の状態確認が確実かつ context 消費を抑えられる。

**運用ニュアンス (頻度・等価性):**

8. **drives popup の Apply Changes は上部/下部どちらでも等価** — Check All の後 `ArrowDown×2` が wrap して「上部 Apply Changes」に着地することがあるが、上部・下部とも右ヘルプは `"Submits the changes made to the entire form."` で機能同一。どちらに着地しても Enter でよい (どちらかに固執して補正し過ぎない)。
9. **Select Drives ナビのキードロップは散発** — `ArrowDown×2` での Select Drives 着地は 3 サイクル中ほぼピタリで、1 手前 (Select Drives From) に止まるのは散発 (4回中1回)。毎回ズレる訳ではないので、まず ×2 を送って右ヘルプで確認し、ズレた時だけ ±1 補正すればよい。
10. **OEM 真VGA スクショは初回空振り→retry することがある** — `irmc-oem-screenshot.sh` は健全時でも `Preview not available after 12s, retrying` で 1 回目空振り→2 回目成功になることがある (frame buffer 詰まりとは別)。retry 機構が吸収するので失敗扱いせず待つ。
11. **Config Management メニューは VD 有無で項目数が変わる + stale は非決定的** — VD あり時の正常 = `View Drive Group Properties / Clear Configuration` (2項目)、VD なし時の正常 = `Create Virtual Drive / Create Profile Based Virtual Drive / Clear Configuration` (3項目)。操作直後は前状態の構成を残す (stale) ことがあるが**回によって stale になったりならなかったり**する。→ Clear Configuration の行位置は構成で変わる (2項目なら ArrowDown 1、3項目なら ArrowDown 2) ので**行位置を固定送信せず、行テキスト + 右ヘルプ `"Deletes all existing configurations..."` を確認してから Enter**。VD 有無の最終判定は常に Virtual Drive Management で。
12. **🆕 KVM セッションは正常終了 (close/quit) させてから切ると次の master 取得が速い** — idle timeout で `exit 0` 正常終了した後の復旧では lingering master が残らず初回接続で即 master 取得できた (cosmic-aho の「BMC reset 直後 slave 着地リトライ要」と対照的)。無人運用で session を畳む時は強制 kill より quit を優先。

> 確立済みツール群 (`tmp/503d9361/`): `kvm_server.py` (永続セッション + コマンドファイル駆動、idle timeout 7200s)、`kvmlib.py` (FW 9.69F cookie ログイン open_viewer)、`pw.sh` (config から env export して bmc-power.sh 呼出)、`snap.sh` (OEM 真VGA screenshot)、`bmc-reset-retry.sh` / `wait-bmc-boot.sh` / `wait-post-snap.sh` / `killall.sh` (復旧フロー)。次回これらを scripts/ に正式昇格する価値あり (今回は時間優先で tmp に温存)。詳細な per-key ログ + 確立レシピ = `tmp/503d9361/CYCLE_LOG.md`。

### ⚠️ AVAGO HII の重大落とし穴 (2026-05-17 新発見)

#### #28. RAID 10 は最低 2 span 必須

LSI MegaRAID の RAID 10 では **`Span 0 = N drives + Span 1 = N drives`** (各 span 同数) が必須。 4-drive RAID 10 を作る場合は Span 0=2 + Span 1=2 構成。 単一 Span に 4 drives を入れると Save Configuration で:

> "To create Virtual Drives for the selected RAID level, more than one span and an equal number of Drives in each span is required."

Create VD form では:
- Span 0 の Select Drives popup で **個別に 2 drives を toggle**
- Apply Changes
- **Add More Spans** で Span 1 追加
- Span 1 の Select Drives popup で **残り 2 drives を toggle (Check All で OK)**
- Apply Changes
- Save Configuration

#### #29. AVAGO controller NVRAM の Pending state 永続

Create VD form の Pending state (RAID Level、 Span 構成、 drive 選択など) は **AVAGO controller NVRAM に永続化される**。 Host reboot しても消えない。 `S1+S2` (Manager.Reset + boot-override + cycle) してもリセットされない。

リセット手段は **Configuration Management → Clear Configuration** のみ:
1. Configuration Mgmt submenu に navigate (M1+M2+M3)
2. ArrowDown 2 → Clear Configuration
3. Enter → Clear Config dialog
4. Confirm field を [Enabled] に toggle (+ キー)
5. ArrowDown → Yes
6. Enter → クリア確定

#### #30. AVAGO HII drives popup の個別 toggle 信頼性問題

drives popup 内で **ArrowDown 4 + Enter** で個別 drive を toggle する経路は、 WAIT_MS=1500ms でも 30-50% の確率でキーが silent drop。 Playwright keyboard.press が CDP で送られても BMC frame buffer pipeline で drop されるケースあり。

回避策:
- **screenshot で位置 verify** + 想定外位置ならリトライ (アダプティブ navigation)
- **Check All / Uncheck All** ボタンで bulk toggle (single key で済むため信頼性高い)
- 個別 drive toggle が必須なら、 各 ArrowDown 後に screenshot 取得 + size 比較で cursor 位置確認

詳細→ [report/2026-05-17_054151_tx1320_raid10_playwright_partial.md](../../../report/2026-05-17_054151_tx1320_raid10_playwright_partial.md) + [reference.md](reference.md)

### 🚨 Manager.Reset 多用注意 (2026-05-16 #69、 #25 と関連)

BMC OEM Screenshot pipeline 詰まりの回復に Manager.Reset が必要になるが、 多用すると 1 回 200s のコスト + (前述の通り KVM 自体は壊さないと判明したものの) 各種 BMC 内部状態への影響が読みにくい。 **OEM Screenshot は milestone ごと 1 回限定** に絞り、 Make POST → 5-15s 待 → Preview の単一サイクルで完結させる運用に統一する。

**制限事項**:
- 連続して OEM Screenshot Make を投げると **BMC 全体 (Web UI/Redfish) が 60-90s 程度無応答**になる。 撮影回数を限定し、 各 oem-shot 失敗時は早期 fail (poll_timeout=5s, max_attempts=3) で BMC を休ませる
- 新規 viewer session の最初の sendkeys が swallowed されることあり (canvas focus 確立に時間)。 `wait:5; oem-shot:initial.jpg;` を冒頭に置いて canvas refresh + focus を establish してから sendkeys する
- KVM canvas screenshot は黒のまま使えない (oem-shot を使う)

**現状の workaround**:
1. ~~BMC Manager Reset → VGA pipeline 再初期化~~ — **改善せず** (#69 検証済み)
2. OS Live ISO + `storcli` で RAID 作成 (broadcom 提供 CLI) — **推奨次手** ([reference.md](reference.md) の代替案参照)
3. AVAGO HII を粘り強く操作: 1 viewer session 内で all-in-one、 OEM Screenshot は要所のみ (Main 進入、 AVAGO Main、 Create VD form、 Save 完了)
4. Aptio BIOS の "BIOS Frame Buffer Mode" 設定変更 (HII でしか変更不可で chicken-and-egg)

### `raid status` 手順

1. iRMC Web UI (https://10.254.254.9/) にブラウザで接続
2. claude / Claude123 でログイン
3. 左メニュー → System Information → Storage タブ
4. RAID コントローラ Model、VD、物理ディスク (Slot, Size, Status) を確認

### `raid create-r10` 手順 (BIOS RAID Configuration Utility 経由)

1. `bios enter` で BIOS Setup に入る (上述)
2. iRMC Web UI → Console Redirection → KVM (HTML5) 起動
3. BIOS Setup → Advanced → RAID Configuration Utility (LSI MegaRAID 系なら "MegaRAID Configuration Utility")
4. Configure Virtual Drives → Create New VD
   - RAID Level: RAID 10
   - 物理ディスク 4 本選択
   - Stripe Size: 64 KB (デフォルト)
   - Initialization: Fast
5. Save → Exit → 再起動
6. 起動後に `raid status` で VD0 (≒ 1.8 TB) が `Optimal` で表示されることを確認

> 物理ディスクのセクタサイズ (520B / 528B) で BIOS RAID Util から認識されない場合は、OpenWrt rescue image ([reference: training_tx1320 memory](memory)) で `sg_format --size=512 --pinfo=0` を実施してから再試行。

### `raid delete` 手順

同様に BIOS RAID Configuration Utility → Virtual Drives → Delete。データ消失するためユーザ確認必須。

## SOL (Serial Over LAN)

本 skill では電源・BIOS が中心だが、SOL も使える (次セッションの OS install 監視用)。

```sh
# 一度だけ payload 有効化 (claude = user 4, channel 2)
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload enable 2 4
# Activate
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol activate
# Deactivate
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol deactivate
```

## 注意事項

- `oplog.sh` で電源・boot-override 系は記録すること (`./oplog.sh ./scripts/bmc-power.sh ...`)
- `pve-lock.sh` は不要 (training-tx1320 は PVE クラスタ非メンバー)
- BIOS Setup へ入った後、boot-override は自動で消費される (`Once`)。明示的に `boot-override-reset` する必要はない
- Web UI ログインは Basic Auth で通らない。form login が必要 (Console Redirection 等の機能ページに到達するには)

## RAID10 storcli + preseed 経路 (2026-05-17 #5 d-eager-island で確立)

KVM HII 経路 (`raid create-r10` の自動化試行) は 2026-05-17 #4 で **dead end 確定**:
- Aptio HII Create VD form の "Select RAID Level" (y=128) に ArrowDown/Up/Tab/Click/Home/End/PageUp/PageDown の全 9 経路で navigation 不能
- Profile-Based VD は Generic RAID 0/1/5/6 のみで RAID 10 不在
- 詳細: [report/2026-05-17_101536_tx1320_raid10_dead_end.md](../../../report/2026-05-17_101536_tx1320_raid10_dead_end.md)

新方針: **Debian preseed `partman/early_command` で storcli64 を実行して RAID10 を作成 → そのまま OS install へ続行**。
KVM 操作を一切使わずに RAID10 + Debian + 必要パッケージまで 1 ISO・1 boot で完結する。

Web 版 Claude の知見:
- MegaRAID は RAID 10 を「**RAID 1 + Span 2**」として実装 (基本 level: 0/1/5/6 + spans: 10/50/60)
- HII Profile-Based に RAID 10 が無いのは仕様 (シンプルウィザード保護)
- `storcli /c0 add vd type=raid10 size=all drives=<EID>:0-3 pdperarray=2` が業界標準の一発作成

### 使い方 (一発実行)

```sh
./scripts/tx1320-raid10-orchestrate.sh apply config/training_tx1320.yml
```

これで以下が順番に実行される:

1. `scripts/fetch-storcli-deb.sh` で Broadcom 公式 zip から `storcli_007.2705.0000.0000_all.deb` を抽出 → `/var/samba/public/storcli64.deb` (既存ならスキップ)
2. `scripts/generate-preseed.sh --with-raid10-storcli` で `partman/early_command` directive 入り preseed.cfg 生成
3. `scripts/remaster-debian-iso.sh --include=...` で `debian-13.3.0-amd64-netinst.iso` を base に preseed + storcli64.deb + setup-raid10-storcli.sh を ISO ルート同梱 → `debian-training-tx1320-raid10.iso`
4. `scripts/irmc-virtualmedia.sh config` で SMB (10.1.6.1/public) CDImage に新 ISO を mount
5. `scripts/bmc-power.sh boot-override Cd UEFI` + `forceoff` + `on` で CD boot

その後 SOL 監視:

```sh
./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml --timeout 1800
```

### preseed 経由で実行される RAID10 作成 (`scripts/setup-raid10-storcli.sh`)

ISO 内 `/cdrom/setup-raid10-storcli.sh` が installer 環境で実行される。 内部処理:

1. `dpkg -i /cdrom/storcli64.deb` (失敗時は `in-target` 経由 + `dpkg-deb -x` fallback)
2. `storcli64 /c0 show` で controller 認識確認
3. `storcli64 /c0/vall delete force` で既存 VD クリア (失敗は無視)
4. `storcli64 /c0/eall/sall show` で物理ドライブ列挙 → awk で先頭 4 本の EID:Slot を抽出
5. `storcli64 /c0 add vd type=raid10 size=all drives=<EID:Slot,...> pdperarray=2 wb ra direct strip=256`
6. `storcli64 /c0/vall show | grep RAID-?10` で assert

ログは `/var/log/raid10-setup.log` に蓄積 (install 完了後 SSH で `cat /var/log/raid10-setup.log` 確認可)。

終了コード意味:
- 0 = OK
- 4 = `/cdrom/storcli64.deb` 不在 (ISO remaster 失敗 / mount 失敗)
- 5 = storcli64 install 失敗 / 認識不可 (controller 型が想定外)
- 6 = 物理ドライブ数 < 4 (drive 故障 / slot 構成変更)
- 7 = `add vd type=raid10` が成功しなかった (controller がコマンド拒否)

### 検証

OS install 完了後、 DHCP で取得した IP に SSH:

```sh
ssh -F ssh/config <dhcp_ip> 'lsblk; storcli64 /c0/vall show all'
# 期待: /dev/sda 単一 ~1.6 TiB block device、 VD0 = RAID-10 / Optl / 1.636 TB
```

### 失敗時のフォールバック

| トリガ | 対応 |
|---|---|
| Broadcom URL が dead | `fetch-storcli-deb.sh` の `STORCLI_URL` env で旧バージョン指定。`https://downloadmirror.intel.com/685225/StorCLI_007.1704.0000.0000.zip` が Intel mirror として使える |
| `dpkg -i /cdrom/storcli64.deb` が installer 環境で失敗 | `setup-raid10-storcli.sh` が `in-target` 経由再試行 + `dpkg-deb -x` で `/usr/local/bin/storcli64` 直接配置にフォールバック |
| `add vd type=raid10` 失敗 | controller が SAS3108 ではない可能性。`storcli64 /c0 show all | grep -iE 'product\|type'` を SOL ログから確認。代替で MegaCLI (Debian universe) を試す |
| **iRMC SMB Virtual Media attach 失敗 → 解決済 (2026-05-17 #6 p-effervescent-kahn)** | 真因: スクリプトが `irmc-virtualmedia.sh config` に smb_user/smb_pass を渡さず **空文字列で PATCH** していた → iRMC が guest 認証として処理せず silent reject。 `Members@odata.count=0` のまま、 Samba log にも接続痕跡なし、 ARP L2 reachable でも attach trigger されない症状を呈していた。 解決策: `config/training_tx1320.yml` に `smb_user: guest` / `smb_pass: guest` を追加 + `tx1320-raid10-orchestrate.sh` の deploy で yq 読み込み + `irmc-virtualmedia.sh config` に引数 7-8 として明示渡し。 加えて、 OEM Action `POST /redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia {"VirtualMediaAction":"DisconnectCD"}` → `ConnectCD` で USB redirector を fresh attach できる (BIOS POST 中 USB enumeration の遅延を吸収して boot-override Cd UEFI が機能する)。 注意: `VirtualMediaAction@Redfish.AllowableValues` は接続状態に応じて Connected→`["DisconnectCD"]` / Disconnected→`["ConnectCD"]` で動的、 BIOS Setup 中は `[]` で発行不可。 |
| boot 進まない / GRUB 出ない | Secure Boot 状態を BIOS Setup で確認、ISO の hybrid UEFI 構成 (`-update efi.img`) が成功しているか remaster ログで確認 |
| **installer cdrom-detect が iRMC Virtual CD を見つけない → kernel cmdline 注入は無効 (2026-05-18 #7 s-peaceful-hinton)** | 症状: CD boot + kernel boot は成功するが、 d-i `[!!] Detect and mount installation media — No device for installation media was detected` で停止し、 `Load drivers from removable media? <Yes><No>` dialog で input 待ち。 #7 で kernel cmdline (GRUB legacy / ISOLINUX / EFI 全 3 経路) と preseed.cfg.template の両方に `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` を仕込んで再試行 → **効かず**。 真因仮説: iRMC OEM CDImage は GRUB レベル (BIOS USB CD-ROM emulation) では読めるが、 Linux 起動後の installer cdrom-detect は udev/sysfs に依存し、 iRMC の USB CD emulation が installer の udev rule にマッチしない。 preseed.cfg は `/cdrom/preseed.cfg` から load される設計上 cdrom-detect 失敗の時点で適用されない (chicken-and-egg)。 次に試す候補 (優先順、 未実施): (1) initrd preseed 注入 + `preseed/early_command` で自前 `mount /dev/sr0 /cdrom` (cdrom-detect/cdrom_device=/dev/sr0 等 combined cmdline も試す)、 (2) iRMC HDImage (USB Mass Storage) 経由配信 — CDImage の代わりに HDImage で ISO を送れば `/dev/sdX` として block device 認識される可能性、 (3) hd-media モード (vmlinuz-hd-media + initrd-hd-media.gz) + ISO ファイル mount、 (4) PXE / netboot 経路 — 完全に iRMC Virtual Media 廃止、 (5) Live ISO + 手動 storcli RAID 作成 + 別経路で OS install pivot |
| 全自動化失敗 | last resort: iRMC KVM Web UI をブラウザで開いて Aptio HII で Select RAID Level に直接 mouse click → 手動で RAID 10 作成 |

## 🎯 NFS Virtual Media 経路 (2026-05-21 s-snuggly-goblet → s-linear-gizmo で確立)

### 背景: SMB 死亡 → NFS bypass

iRMC S4 FW 9.08F の **SMB worker は 2026-05-20 以降死亡継続中** (silly-token で `Manager.Reset` / `VirtualMediaServiceRestart` / `RemoteMountEnabled toggle` / OEM `ConnectCD` / 物理電源切離 の 5 経路すべて試行で復活せず確認)。 代替として s-snuggly-goblet が **NFS worker は別 process で生存している**ことを実機実証 (`report/2026-05-21_081642_tx1320_raid10_nfs_attempt.md`)。

s-linear-gizmo (Phase 2) で本コードに統合済。 `training_tx1320` のデフォルト経路は NFS。

### SMB vs NFS スキーマ比較

| 項目 | SMB | NFS |
|------|-----|-----|
| `CDImage.ShareType` | `"SMB"` | `"NFS"` |
| `CDImage.UserName` / `Password` | 必須 (`guest`/`guest`) | 空文字列 (iRMC が null 化) |
| `CDImage.ShareName` | `"public"` (バックスラッシュ無し) | `"/var/samba/public"` (POSIX export path) |
| AutoAttach (`RemoteMountEnabled=true` で attach 成立) | ✅ する (worker 生存時) | ❌ **しない** — ConnectCD POST 必須 |
| `Actions...VirtualMediaAction@Redfish.AllowableValues` | 動的: `["ConnectCD"]` ↔ `["DisconnectCD"]` | 同左 |
| 認証 | Samba ACL | IP based (`/etc/exports` の subnet 指定) |
| 交渉 protocol | SMB1/2/3 (worker bug で 4.19.5 死亡) | NFSv4 (`v4root` pseudo-fs 自動 export) |

### 使い方 (NFS)

`config/training_tx1320.yml` に NFS keys が設定済:

```yaml
virtual_media_type: nfs
nfs_host: 10.1.6.6
nfs_export_path: /var/samba/public
```

orchestrator は yq でこれを読み、 Phase 5a で以下を自動実行:

```sh
./scripts/irmc-virtualmedia.sh --share-type=NFS config \
    10.254.254.9 claude Claude123 \
    10.1.6.6 /var/samba/public debian-training-tx1320-raid10.iso
./scripts/irmc-virtualmedia.sh connect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS mount 10.254.254.9 claude Claude123
```

`mount` は `/redfish/v1/Systems/0` の `Actions.Oem.#FTSComputerSystem.VirtualMedia.VirtualMediaAction@Redfish.AllowableValues` を 12 回 × 5 秒で polling し、 `["DisconnectCD"]` 出現で attach 成立と判定。

### NFS server (10.1.6.6) セットアップ

s-snuggly-goblet で構築済 (`nfs-kernel-server` + `rpcbind`):

```sh
# /etc/exports.d/tx1320.exports
/var/samba/public 10.0.0.0/8(ro,no_subtree_check,all_squash,insecure,anonuid=65534,anongid=65534)
```

`sudo exportfs -ra` で reload。 ISO は `/var/samba/public/debian-training-tx1320-raid10.iso` に配置 (orchestrator が build したものを rsync で push)。

### 落とし穴

| 症状 | 対処 |
|------|------|
| PATCH HTTP 412 | ETag が古い。 `irmc_get_etag` で再取得 (既存 quirk) |
| ConnectCD HTTP 204 だが AllowableValues 未遷移 | `/redfish/v1/Systems/0` を見ているか確認 (OEM VM endpoint には AllowableValues は無い)。 NFS server 側で `sudo tcpdump -i ens19 -nn 'host 10.254.254.9 and port 2049'` で packet 到達確認。 0 packet なら L2/route、 packet あって stuck なら export 権限 |
| ConnectCD だけで Web UI 上は接続表示なし | 正常。 host が PowerState=Off の間は DMTF `/Managers/iRMC/VirtualMedia` の Members.count は 0 のまま。 host boot 時に USB redirector が device を expose する |
| NFS export 範囲外 (10.0.0.0/8 以外から) | training-tx1320 (10.254.254.9) は 10.0.0.0/8 内。 別 server を使う場合は export 範囲を調整 |
| **✅ GRUB→kernel jump 後 SOL/VGA 完全沈黙 (2026-05-22 Phase 13 silly-rocket で真因確定・解消、 詳細は本 skill 末尾の Phase 13-19 セクション)** | NFS attach + GRUB boot は正常で `Booting Automated Install` まで届く。 ところが直後の kernel printk が 0 行、 KVM VGA も完全黒で host 凍結。 Phase 3 で **`quiet` 除去でも `earlyprintk=ttyS0,115200n8,keep` 追加でも効かず**、 さらに NFS pcap で host からの READ packet が一切無いことを確認 (kernel が CD-ROM device を access していない = USB CD-ROM enumeration 以前で hang/panic)。 真因は kernel cmdline option では治らない。 次セッションは BIOS XML backup (`bios backup`) で Console Redirection / Secure Boot / Boot Mode を 2026-05-18 SMB session #6 当時と比較 + `git log --since=2026-05-15 -- scripts/remaster-debian-iso.sh` で cmdline diff 確認、 USB stick 等で NFS Virtual Media を bypass した切り分けが必要。 詳細 → `report/2026-05-22_004000_tx1320_raid10_kernel_silent_persist.md` + memory `training_tx1320_kernel_silent_post_grub.md` |

### SMB フォールバック (緊急時のみ)

万一 NFS worker も死亡した場合:

```sh
./scripts/irmc-virtualmedia.sh disconnect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=SMB config 10.254.254.9 claude Claude123 \
    10.1.6.1 public debian-training-tx1320-raid10.iso guest guest
# + config/training_tx1320.yml の virtual_media_type を smb に戻す
```

ただし FW 9.08F の SMB worker 死亡は wontfix 確定なので、 NFS が動かない場合は別 NFS server (proxy-ARP 配下) を立てる方が現実的。

## RAID10 storcli + preseed 経路 — 2026-05-17 #5 d-eager-island の実機検証結果

- ✅ `scripts/fetch-storcli-deb.sh` で Broadcom 公式 zip → storcli64.deb (2 MB) 取得成功 (URL: `https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip`)
- ✅ `scripts/generate-preseed.sh --with-raid10-storcli` で preseed に `partman/early_command` directive 挿入確認
- ✅ `scripts/remaster-debian-iso.sh --include=...` で 764 MB の Debian + storcli64.deb + setup-raid10-storcli.sh 同梱 ISO 生成成功
- ✅ `irmc-virtualmedia.sh config` で OEM Redfish に CDImage 設定書込成功 (HTTP 200、 ETag 通る)
- ❌ **iRMC が SMB 経由で CDImage を実際に attach しない** — `/Managers/iRMC/VirtualMedia/Members` 0 のまま、 Samba 側にも接続痕跡なし、 ConnectCD OEM action 発行も無効
- ❌ BIOS は boot-override Cd UEFI を消費したが、 attach されていない CD は boot 不可 → BIOS Setup に fallback
- 次セッションへ: 上記フォールバック表の (b)〜(d) のいずれかで配信経路を解決すれば、 残りのワークフローは即実行可能

---

## Phase 13-19 で確定・解消した課題 + PXE 経路への pivot

### 🎯 Phase 13 (2026-05-22 silly-rocket): kernel silent hang の真因 = `console=tty0`

D3373 では cmdline に **`console=tty0` が含まれると kernel が VGA console init で hang** する (SOL printk ゼロ、 VGA も凍結)。 これが Phase 2-12 で「kernel hang」 「triple-fault」 と切り分けに苦労した silent 沈黙の真因。

- 対策済: `scripts/remaster-debian-iso.sh` L124/L134/L197、 `scripts/generate-preseed.sh` (CONSOLE_ORDER) から `console=tty0` 削除済 (commit 履歴参照)
- 検証手順: cmdline 変更後 ISO/preseed 再生成 → deploy → SOL に `Linux version` printk が出れば成功
- 詳細: `report/2026-05-22_*_tx1320_raid10_phase13*.md`、 memory `training_tx1320_kernel_silent_post_grub.md`

### ✅ Phase 15 (2026-05-23 bubbly-ripple): cdrom-detect sr0→sr1 patch

cdrom-detect が物理空 DVD (`/dev/sr0`) を先に試して諦め、 iRMC 仮想 CD (`/dev/sr1`) をスキャンしない問題。 `remaster-debian-iso.sh` に `PVESE_PATCH_CDROM_DETECT=1` 環境変数 + awk in-place patch を実装、 `/dev/sr1` 優先 block 挿入で fall-through 化。 Phase 16 で実機検証済。

### ⚠️ Phase 16-18 (2026-05-23): iRMC USB redirector 累積劣化は FW 9.69F でも解消しない

- Phase 16-17: NFS Virtual Media + PSU cold reset で apt/partman 段階まで到達。 ただし install 中も USB redirector が累積劣化 → 3 deploy で BIOS POST 99 stuck
- Phase 18: iRMC FW **9.08F → 9.21F → 9.69F** 段階 update を `scripts/irmc-fw-update.sh` (multipart field 名 = `"file"` empirical 検証、 `/irmcprogress` Value=0/8/9 解読、 flashSelect=255 で両 image 書込) で完遂。 ブリックなし、 auth/network/BIOS drift なし。 だが **BIOS POST 99 stuck は FW level では解消しない** (`config/training_tx1320.yml` に FW 9.69F 適用済)
- **FW 9.69F の OEM Redfish API 破壊的変更**: `VirtualMediaAction` → **`FTSVirtualMediaAction`**、 `ResetType` (OEM Reset) → `FTSResetType`、 `ScreenshotType` → `FTSScreenshotType`。 FW 9.08F は両形式受容、 9.69F は schema-qualified のみ。 `scripts/irmc-virtualmedia.sh` 修正済 (commit `86f9f7e`)
- **教訓**: iRMC USB redirector は長時間運用で累積劣化し、 FW update では回復しない HW level の現象。 install 経路は USB redirector を bypass する **PXE pivot** が決定打

### 🎉 Phase 19 (2026-05-30 phase19a): PXE pivot で完遂 → `pxe-deploy` skill

iRMC USB redirector を完全 bypass する **PXE/netboot** 経路を確立、 Debian 13 + HW RAID10 install + claude 自力 SSH 到達まで物理操作なしで達成。 詳細手順 + 9 つの壁 + 落とし穴は **`pxe-deploy` skill** に分離記録 (skill サイズ + 経路独立性のため)。

#### PXE pivot に向けた **iRMC BIOS の事前準備** (本 skill の `bios apply-config` で実施)

UEFI PXE boot option が生成されるよう、 `config/<host>.yml` の `bios_settings.supported` に追加:

```yaml
bios_settings:
  supported:
    # 既存 (UEFI 化)
    BootOptionFilter: "UEFI only"
    LaunchPxeOpRomPolicy: "UEFI only"
    # …
    # Phase 19 で必須 (PXE boot option 生成の前提)
    NetworkStack: "Enabled"        # UEFI Network Stack を有効化
    IPv4PxeSupport: "Enabled"      # IPv4 PXE boot option を生成 (NetworkStack 依存)
```

→ `bios apply-config` で BSPBR backup → 編集 → restore → cycle (boot phase で適用)。 これが Disabled だと boot-override Pxe が BIOS Setup に落ちる (Phase 19 壁 #1 で実証)。

#### 関連知見 (本 skill にも記録すべきもの)

- **SOL は read-only** (D3373 は Console Redirection 機能なし、 SOL stdin は host UART RX に届かない)。 console login 不可。 状態判断は `scripts/irmc-oem-screenshot.sh` (真の VGA capture) が一次情報、 KVM canvas は黒画 artifact なので使用禁止 (本 skill の Playwright KVM セクションでも既述)
- **install 進捗の真の指標**: nginx access.log (preseed/storcli/phonehome fetch)。 sol-monitor の stage 検出は SOL ring buffer replay で誤検出する (前回 boot 内容を新しい install の進捗と誤認)
- **闇ネット (10.0.0.0/8) 経由 SSH**: PXE install 後の installed host は eno1 (拠点 LAN、 NAT 背後で claude 不達) + eno2 (闇ネット、 gateway なし、 claude 到達可) の 2 NIC DHCP。 IP 特定は `ip neigh | grep <eno2-MAC>` (phone-home が cross-site 不達でも代替可能)

詳細は `pxe-deploy` skill + `report/2026-05-30_050830_tx1320_raid10_phase19_pxe_autonomous_ssh.md` + 総括 `report/2026-05-30_053607_tx1320_raid10_overview_phase1-19_summary.md`。
