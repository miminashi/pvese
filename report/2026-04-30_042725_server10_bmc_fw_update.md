# 10号機 (X10DRT-P / Nutanix NX-1065-G5) BMC FW アップデート試行レポート

- **実施日時**: 2026年4月30日 03:18 JST 〜 05:00 JST 頃

## 添付ファイル

- [実装プラン](attachment/2026-04-30_042725_server10_bmc_fw_update/plan.md)
- [Phase A サマリ](attachment/2026-04-30_042725_server10_bmc_fw_update/A-summary.md)
- [Phase B サマリ](attachment/2026-04-30_042725_server10_bmc_fw_update/B-summary.md)
- [Phase A 各種ログ](attachment/2026-04-30_042725_server10_bmc_fw_update/) (A1〜A4b, A9-kvm-pre.png)
- [Phase D 各種ログ](attachment/2026-04-30_042725_server10_bmc_fw_update/) (D1〜D4b)
- 関連レポート: [10号機追加レポート](2026-04-30_023103_add_server10_x10drt_p.md)

## 結論サマリ

- **BMC 操作確認 (Phase A)**: ✅ 全項目成功 (既存スクリプト 100% 互換)
- **FW ファイル取得 (Phase B)**: ✅ 成功 (3.94 zip + AlUpdate v2.08 取得、SHA256 一致)
- **FW 適用 (Phase C)**: ⚠️ AlUpdate は "Update Complete" まで進行、BMC リブートも確認したが、**FW バージョンは 3.65 のまま反映されず** (silent reject の疑い)
- **検証 (Phase D)**: BMC 完全動作・claude ユーザ保持・LAN 設定保持。**ただし FW 更新は未反映**
- **副作用**: なし (システム電源 OFF のまま、データ・設定保持、運用継続可能)
- **推定原因**: Nutanix OEM (NX-1065-G5) の保護機構が Supermicro stock FW を silently reject した可能性が最有力
- **最終状態**: ユーザが Web UI から「Enter Update Mode → Cancel」操作で BMC を Update Mode から解除。FW は 3.65 のまま、通常運用状態に復帰。本タスクはここで終了し、Nutanix Foundation 経由 OEM FW 取得は別タスクへ

## 前提・目的

- 背景: [10号機追加レポート](2026-04-30_023103_add_server10_x10drt_p.md) で追加した 10号機 (Supermicro X10DRT-P) の BMC FW を最新版に更新したい
- 目的: BMC FW を supermicro.com 配布の最新 (3.94) に更新する。準備として既存 Supermicro 系スクリプトの X10 互換性確認も同時に行う
- 制約 (ユーザ確認):
  - chassis power 操作なし (BMC 単体の更新のみ)
  - Preserve Configuration=ON で強行 (公式 PDF の OFF 推奨は本環境では IP 失効リスクが高いため)
  - Nutanix OEM への Supermicro stock FW 適用は全責任上で実行する

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | 10号機 ayase-web-service-10 |
| ハードウェア | **Nutanix NX-1065-G5** (Board: Supermicro X10DRT-P-G5-NI22) |
| Chassis | CSE-217HQ+-000NBP (2U Twin Server) |
| BMC IP | 10.10.10.30 (Static, /8) |
| BMC ユーザ | claude (index 4, ADMINISTRATOR) |
| BMC チップ | ASPEED 2400 |
| BMC FW (更新前/更新試行後) | **3.65 / 3.65** (= 反映されず) |
| MAC | ac:1f:6b:18:0e:04 |
| 適用試行 FW | `BMC_X10AST2400-C001MS_20211001_03.94_STD.bin` (32 MiB) |
| 更新ツール | AlUpdate v2.08 (Linux x64, 2018-10-09 build, ATEN Technology) |

## 再現方法

### Phase A: BMC 操作確認 (read-only)

既存 Supermicro 系スクリプトを順に実行し、X10DRT-P での動作を検証:

```sh
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 mc info        # FW = 3.65 baseline
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 fru print 0
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 lan print 1
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 user list 1

./scripts/bmc-power.sh status 10.10.10.30 claude Claude123
curl -sk -u claude:Claude123 https://10.10.10.30/redfish/v1/Managers/1
./scripts/bmc-session.sh login 10.10.10.30 claude Claude123 tmp/<sid>/bmc-cookie
./scripts/bmc-session.sh csrf 10.10.10.30 tmp/<sid>/bmc-cookie

.venv/bin/python scripts/bmc-kvm-screenshot.py \
  --bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123 \
  --output tmp/<sid>/bmc-check/A9-kvm-pre.png --timeout 60
```

結果: 全項目 OK。**既存 Supermicro スクリプト群 (`bmc-power.sh`, `bmc-session.sh`, `bmc-kvm-screenshot.py`) は X10DRT-P でそのまま動作する**。

### Phase B: FW ファイル取得

Playwright スクリプトで supermicro.com からダウンロード:

1. `https://www.supermicro.com/en/support/resources/downloadcenter/firmware/MBD-X10DRT-P/BMC` を開く
2. Cookie/EULA Accept ボタンをクリック
3. BMC 行の Download ボタンをクリック
4. Sign-in ダイアログで "Continue as Guest"
5. EULA Accept ダイアログをもう一度クリック
6. zip ダウンロード (`BMC_X10AST2400-C001MS_20211001_03.94_STD.zip`, 27,200,160 bytes)

```sh
.venv/bin/python tmp/157391a8/sm-fw-download.py tmp/157391a8
```

ハッシュ検証 (公式表示と一致):

| 項目 | 値 |
|------|-----|
| zip SHA256 | `80fcf01d2073cabe81118140a8494c8a65431dd5d20460c12272db110b5f8d21` ✅ |
| .bin SHA256 | `6a1424f04cef6257da62b8ed81639ffbe5a70ebd5918a3fb1e9be067a4b34dc2` |

### Phase C: FW 適用

事前バックアップ (IPMI config を AlUpdate でダンプ):

```sh
./oplog.sh /home/ubuntu/projects/pvese/tmp/157391a8/fw-extracted/.../AlUpdate \
  -c -d tmp/157391a8/c0a-ipmi-config-backup.bin \
  -i lan -h 10.10.10.30 623 -u claude -p Claude123
```

→ `c0a-ipmi-config-backup.bin` (17,784 bytes) 取得成功。

FW 適用:

```sh
./oplog.sh /home/ubuntu/projects/pvese/tmp/157391a8/fw-extracted/.../AlUpdate \
  -f tmp/157391a8/fw-extracted/.../BMC_X10AST2400-C001MS_20211001_03.94_STD.bin \
  -i lan -h 10.10.10.30 623 -u claude -p Claude123 -r y
```

進捗 (Monitor で観察):
- Phase 1 transfer: Part 0 (126 KB), Part 1 (15 MB), Part 2 (1.4 MB), Part 3 (2.2 MB) 順次完了
- Phase 2 flash: 0% → 10% → 20% → 30% → ... → 90% → **`Update Complete, Please wait for BMC reboot, about 1 min`**
- AlUpdate プロセスは exit code 1 で終了 (BMC リブートで IPMI セッション断 = 想定内)

### Phase D: 検証

```sh
sh tmp/157391a8/d-verify.sh
```

→ BMC リブート後 (約 1 分待機) に以下を実行し、各項目が正常に応答することを確認:
1. `ipmitool ... chassis status` → OK (Power Off)
2. `ipmitool ... mc info` → **OK だが Firmware Revision = 3.65** (更新前と同じ)
3. Redfish `/Managers/1` → **OK だが FirmwareVersion = 3.65** + DateTime が 2015-01-01 にリセット (BMC リブート確証)
4. `bmc-power.sh status` → OK
5. CGI login + CSRF → OK
6. `user list 1` → claude (index 4) 健在
7. `lan print 1` → 静的 IP `10.10.10.30/8` 保持

念のため BMC cold reset を実行し再確認:

```sh
./oplog.sh ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 mc reset cold
```

→ 再 boot 後も **FW Revision 3.65 のまま**。Image 切り替えなし = 新 FW (3.94) は実際には書き込まれていないか rollback された。

### Web UI 「Service is not available during upgrade」と Update Mode 解除

検証中、ユーザが Web UI にログインすると `Service is not available during upgrade.` というアラートが出ることが判明 (= BMC は **Update Mode に入ったまま** だった)。BMC のフラッシュコミットは弾かれていたが、Update Mode 自体は解除されていなかった。

ユーザが Web UI から **Maintenance > Firmware Update > Enter Update Mode → Cancel** の操作を行い、BMC が再起動。再起動後は `Service is not available during upgrade` は出なくなり、BMC は通常モードに復帰。

通常モード復帰後の確認:
- `mc info` Firmware Revision: **3.65** (変化なし、更新完全未反映で確定)
- chassis status: Power Off (維持)
- claude ユーザ (index 4): 生存
- 静的 IP `10.10.10.30`: 保持

→ **本セッションで AlUpdate による FW 更新は反映されず、BMC は更新前と同等の通常運用状態に戻った**。

## 検証結果

### Phase A (BMC 操作確認) — ✅ 全項目成功

| Step | 内容 | 結果 |
|------|------|------|
| A1 | chassis status | OK (Power Off) |
| A2 | mc info → FW 3.65 取得 | OK |
| A3 | fru print 0 → Nutanix NX-1065-G5 / Board X10DRT-P-G5-NI22 判明 | OK |
| A4 | lan print 1 | OK (Static 10.10.10.30) |
| A4b | user list 1 → claude=index 4 確認 | OK |
| A5 | bmc-power.sh status (Redfish) | OK |
| A6 | Redfish Manager → ASPEED, Redfish 1.0.1 | OK |
| A7 | CGI login | OK |
| A8 | CSRF token (Base64 風 43 文字) | OK |
| A9 | KVM HTML5 スクリーンショット | OK (Power Off で 300x150) |

→ **既存 Supermicro 系スクリプトは X10DRT-P でそのまま使える**。CGI トークン形式は X11DPU と異なるが既存 regex で抽出可能。

### Phase B (FW 取得) — ✅ 成功

- zip: 27,200,160 bytes、SHA256 一致
- .bin: 33,554,432 bytes (32 MiB)
- 同梱: AlUpdate Linux x64 v2.08, IPMI Firmware Update PDF, Redfish Reference

### Phase C (FW 適用) — ⚠️ "Update Complete" は出たが反映されず

- AlUpdate LAN 経由実行成功 (exit 1 は BMC リブートで想定内)
- "Update Complete, Please wait for BMC reboot, about 1 min" メッセージ確認
- BMC リブート確認 (DateTime が 2015 にリセット)
- **しかし FW バージョンは 3.65 のまま**

### Phase D (検証) — BMC 動作 OK だが FW 未更新

| 項目 | 結果 | 備考 |
|------|------|------|
| BMC 疎通 | ✅ OK | claude ユーザで全プロトコル接続可能 |
| FW Revision | ❌ 3.65 のまま | 期待: 3.94 |
| Redfish FirmwareVersion | ❌ 3.65 のまま | 期待: 3.94 |
| claude ユーザ保持 | ✅ OK | Preserve Configuration=ON が機能 |
| 静的 IP 10.10.10.30 保持 | ✅ OK | 同上 |
| DateTime リセット | ✅ 2015 にリセット | BMC リブート確証 |
| システム電源 | ✅ Off のまま | chassis power 操作なし宣言通り |

## 推定原因

最有力仮説: **Nutanix OEM (NX-1065-G5) の BMC は、Supermicro stock FW を silently reject する保護機構を持つ**

根拠:
1. `fru print` で Manufacturer = Nutanix と確認 (Board だけ Supermicro 名義、Product/Asset Tag は Nutanix)
2. AlUpdate は "Update Complete" を表示し正常終了相当だが、実際の image 切り替えが行われない
3. BMC は確実にリブートしている (DateTime リセット) ので、書き込みプロトコルは BMC 側で受理されているが、フラッシュコミットの最終ステップで弾かれる挙動が想定される
4. Preserve Configuration=ON は機能している = AlUpdate プロトコル自体は動いている

代替仮説:
- AlUpdate v2.08 (2018年) と FW 03.94 (2021年) のツール非互換 (RSA 署名検証関連)
- Twin Server の BIOS/BMC 共有領域での衝突 (Nutanix Twin 構成特有)

## 副作用と現状

- **副作用なし** — システムは更新前と同じ状態で動作継続可能
- claude ユーザ・LAN 設定保持 (Preserve Configuration=ON 機能成功)
- BMC 安定動作 (cold reset 後も問題なし)
- システム電源 Off のまま (操作対象外)

## 残タスク (別タスクで実施)

1. **Nutanix Foundation / Phoenix 経由の FW 取得** — Nutanix OEM 専用 BMC FW (NX-1065-G5 用) を Nutanix Portal 経由で取得し再試行
2. **Web UI 経由の FW 適用試行** — AlUpdate ではなく Web UI (Maintenance > Firmware Update) で試行 (Playwright 自動化)。エラーメッセージが見える可能性
3. **Update Mode 強制** — Web UI の "Enter Update Mode" 経由でなら、Nutanix の保護機構をバイパスできる可能性
4. **AlUpdate のデバッグ実行** — `strace` 等で AlUpdate と BMC の通信を取り、最終フェーズ (image commit) のレスポンスを確認
5. **本タスクで動作確認した補助スクリプトの恒久化** — 必要なら以下を `scripts/` 配下に commit:
   - `scripts/sm-fw-download.py` (Supermicro FW ダウンロード Playwright スクリプト) — 雛形は `tmp/157391a8/sm-fw-download.py`
6. **既存 4-6号機 (X11DPU、Nutanix OEM ではない)** で同手順を再現すれば、Nutanix OEM 起因か否かを切り分け可能
7. **`supermicro-fw-update` / `supermicro-fw-download` スキル新設** — 本タスクの知見を踏まえ、Nutanix OEM 検出ロジック付きで設計

## 関連ファイル

### 修正なし (既存スクリプトの動作確認のみ)
- `scripts/bmc-power.sh`, `scripts/bmc-session.sh`, `scripts/bmc-kvm-screenshot.py`
- `config/server10.yml`

### 新規作成
- `tmp/157391a8/sm-recon.py` — Supermicro DL ページ偵察スクリプト (Playwright)
- `tmp/157391a8/sm-fw-download.py` — Supermicro FW ダウンロード自動化スクリプト
- `tmp/157391a8/c0a-config-backup.sh` — IPMI config backup ラッパ
- `tmp/157391a8/c0b-fw-dump.sh` — FW dump ラッパ (本タスクでは中断)
- `tmp/157391a8/c1-fw-apply.sh` — FW 適用 ラッパ
- `tmp/157391a8/d-verify.sh` — Phase D 検証スクリプト

### 参考データ (添付フォルダ参照)
- 各 Phase の出力ログ (A/B/D)
- IPMI config backup (`c0a-ipmi-config-backup.bin`, 17,784 bytes、`tmp/157391a8/` に残存)
- FW zip + 展開ファイル (`tmp/157391a8/BMC_X10AST2400-C001MS_20211001_03.94_STD.zip` および `tmp/157391a8/fw-extracted/`)

## ログ抜粋

### Phase A2: 更新前 mc info (FW 3.65)
```
Device ID                 : 32
Firmware Revision         : 3.65
IPMI Version              : 2.0
Manufacturer Name         : Super Micro Computer Inc.
Product Name              : X10DRT-P
```

### Phase A3: Nutanix OEM 判明
```
Board Mfg             : Supermicro
Board Part Number     : X10DRT-P-G5-NI22
Product Manufacturer  : Nutanix
Product Part Number   : NX-1065-G5
```

### Phase D2: 更新試行後 mc info (FW 3.65 のまま)
```
Firmware Revision         : 3.65
Product Name              : X10DRT-P
```

### Phase D2b: Redfish 抜粋
```
"Model": "ASPEED",
"FirmwareVersion": "3.65",
"DateTime": "2015-01-01T08:37:01+00:00"   # NTP 未設定で 2015 にリセット = リブート確証
```
