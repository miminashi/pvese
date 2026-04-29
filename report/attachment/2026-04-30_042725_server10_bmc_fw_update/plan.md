# 10号機 (X10DRT-P) BMC FW アップデート プラン

## Context

- **目標**: 10号機 (Supermicro X10DRT-P, BMC `10.10.10.30`) の BMC ファームウェアを supermicro.com 配布の最新版に更新する
- **動機**:
  - X10DRT-P は前世代 Supermicro マザーで、出荷時 BMC FW が古い可能性がある
  - 既存 4-6号機 (X11DPU) は出荷時 FW のまま運用しているが、X10 世代はセキュリティ修正・互換性改善のため更新しておきたい
  - 既存 Supermicro 系スクリプト (`bmc-power.sh`, `bmc-session.sh`, `bmc-virtualmedia.sh`, `bmc-kvm-*.py`) が X10DRT-P でも動くか同時検証する
- **本タスクのスコープ** (ユーザ確認済み):
  - 操作確認 → FW ダウンロード → 実機書き込み → 検証まで完遂
  - 10号機の状態: BMC 設定済み (`claude` / `Claude123`)、OS 未インストール
  - **chassis power は扱わない** (BMC 単体の更新のみ。システム電源 ON/OFF/Reset は行わない)。BMC FW 更新は BMC 自身のリセットのみで完結する
- **本タスクのスコープ外**:
  - BIOS / Bundle FW の更新 (BMC FW のみ)
  - OS インストール、LINSTOR 参加
  - `bios-setup` スキルの X10DRT-P 対応

## 重要な制約・ルール

- **BMC ファクトリーリセット禁止**: `ipmitool raw 0x3c 0x40` 系は実行しない (CLAUDE.md 規定。claude ユーザ・ネットワーク設定が消失する)
- **Preserve Configuration の扱い (X10 ATEN UI 仕様)**:
  - チェックボックスは「Preserve Configuration」「Preserve SDR」「Preserve SSL」の3つのみ存在 (「Preserve User」「Preserve LAN」は独立しておらず、Preserve Configuration に内包)
  - **Preserve Configuration は all-or-nothing** — OFF にすると **ユーザ・LAN 設定 (IP/Mask/GW)・SNMP・SSL すべてが工場出荷時にリセット**される。BMC は **DHCP モード + ADMIN/ADMIN** に戻る
  - **本環境固有の制約**: 10号機の管理 LAN `10.0.0.0/8` には **DHCP サーバが存在しない**。Preserve OFF で更新すると BMC は DHCP リース取得失敗で **IP を完全に失い、ネットワーク経由のアクセスが不能** になる
  - 復旧手段はすべて物理アクセスを要する (KVM + BIOS IPMI Setup / AC 電源サイクル / DOS Recovery flash) — 10号機は OS 未インストールのため `ipmicfg` ホスト経由の復旧も不可
- **本タスクの方針 (上記制約より)**:
  - **同マイナー系列の最新 FW のみを対象とする** (Phase A2 で取得した現行 FW のメジャー番号と一致する最新版)
  - **メジャー版跨ぎが必要な場合は本タスクを Phase A 完了時点で中断**し、レポートに「物理アクセス手配後に別タスクで実施」と記録して終了する
  - これにより `Preserve Configuration=ON` を貫き、claude ユーザと `10.10.10.30` の静的 IP を確実に保持する
- **Preserve オプション既定値** (同マイナー系列更新時):
  - `Preserve Configuration` = **ON** (claude ユーザ・LAN 設定保持)
  - `Preserve SDR` = **ON**
  - `Preserve SSL` = **OFF** (古い自己署名証明書を引き継がない)
- **chassis power 操作なし**: `ipmitool chassis power` は読み取り (`status`) のみ
- **`./oplog.sh` で記録**: BMC FW 書き込みは状態変更操作なので oplog 必須
- **`./pve-lock.sh` 不要**: 10号機は PVE クラスタ外・LINSTOR 未参加・かつ BMC のみの操作
- **SSH 不可**: OS 未インストール。BMC 経由 (ipmitool / Redfish / CGI / Web UI / Playwright) のみ
- **`tmp/<sid>/`**: セッション固有ディレクトリ。FW zip / .bin / cookie / ログを全部ここに置く

## Phase A: BMC 操作確認 (read-only)

目的: 既存スクリプトが X10DRT-P で動くか検証し、BMC 現 FW バージョンを記録する。

| Step | コマンド | 期待値 | 失敗時 |
|------|---------|-------|-------|
| A1 | `ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status` | `System Power : on/off` 取得 | 認証失敗 → BMC ユーザ未作成。Phase 中断、ユーザ確認 |
| A2 | `ipmitool ... mc info` | **`Firmware Revision : <X.YY>` 取得** (更新前ベースライン)。**メジャー番号 (先頭桁) を記録** — Phase C で Preserve Configuration の ON/OFF 判定に使う | timeout → BMC 過負荷? 1分待って再試行 |
| A3 | `ipmitool ... fru print 0` | `Product Name : X10DRT-P` 確認 | 取得失敗を記録 |
| A4 | `ipmitool ... lan print 1` | BMC IP/Mask/GW 取得 | 同上 |
| A5 | `./scripts/bmc-power.sh status 10.10.10.30 claude Claude123` | Redfish 経由で電源状態 | 404/500 → Redfish 未対応の可能性、CGI のみで継続 |
| A6 | `curl -sk -u claude:Claude123 https://10.10.10.30/redfish/v1/Managers/1` | JSON で Manager 情報・FW バージョン取得 | 同上 |
| A7 | `./scripts/bmc-session.sh login 10.10.10.30 claude Claude123 tmp/<sid>/bmc-cookie` | `Login OK` | login 失敗 → 旧 CGI パスを Playwright で偵察 |
| A8 | `./scripts/bmc-session.sh csrf 10.10.10.30 tmp/<sid>/bmc-cookie` | CSRF トークン (16進) | トークン未抽出 → 応答 HTML を `tmp/<sid>/` に保存し regex 修正検討 |
| A9 | `.venv/bin/python scripts/bmc-kvm-screenshot.py --bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123 --output tmp/<sid>/kvm-pre.png` | PNG > 1KB | 失敗時は古い iKVM (Java Web Start) の可能性。Phase B/C には非影響なので記録のみ |

各出力を `tmp/<sid>/bmc-check/` に保存。

## Phase B: FW ファイル取得

### B1. ダウンロードページ偵察
- Playwright で `https://www.supermicro.com/en/support/resources/downloadcenter/firmware/MBD-x10drt-p/BMC` を開く
- ページ構造を `tmp/<sid>/dl-page.html` / スクリーンショットで保存
- **配布形式**: zip ファイル (`.bin` 内包想定)
- **EULA**: 同意ボタンが出る場合は Playwright でクリック

### B2. ダウンロードスクリプト作成
- `scripts/supermicro-fw-download.py` を新規作成 (`dell-fw-download` を参考。**スキル化は今回しない**、スクリプト単体で OK)
- 引数: `<motherboard-id>` `<save-dir>` (例: `MBD-x10drt-p` `tmp/<sid>/`)
- 出力: zip ファイル + sha256 ハッシュ

### B3. zip 展開と版数情報の確認
- `unzip tmp/<sid>/<fw>.zip -d tmp/<sid>/fw-extracted/`
- `.bin` ファイルパスを特定 (`tmp/<sid>/fw-extracted/*.bin`)
- **新 FW のバージョンとメジャー番号** をファイル名 / 内包 README から抽出し記録
- **段階的アップグレードパス確認**: README / リリースノートに「特定の中継バージョン経由必須」の記載があるか目視確認 (Playwright で表示できない場合はユーザに確認依頼)
- **Phase A2 のメジャー番号と比較**:
  - メジャー一致 → Phase C へ進む (`Preserve Configuration=ON`)
  - メジャー違い → **Phase C 以降を中断**、レポートに「物理アクセス手配後に別タスクで実施」と記録して終了
- **同メジャーで複数バージョン候補がある場合**は最新版を選択。中継版必須の記載があれば、中継版が同メジャー内に収まる場合のみ採用 (収まらなければ中断)

### B4. 失敗時のフォールバック
- Playwright が EULA クリックに失敗、または DL 認証/Captcha で詰まった場合 → ユーザに **手動 DL 依頼** (URL とファイル名を提示)
- ユーザが zip を `tmp/<sid>/` にアップロードしてからの再開で構わない

## Phase C: BMC FW 書き込み

### 方式選定
ユーザの「chassis power 操作なし」制約下で、X10 世代で実用的な方式は以下の通り:

| 方式 | 採用可否 | 理由 |
|------|---------|------|
| **Web UI 経由 (Playwright)** | **採用** | BMC 単体リセットのみ、chassis power 不要。X10 世代も Web UI Maintenance > Firmware Update を備える |
| ipmitool hpm upgrade | 不採用 | X10 世代は HPM.1 形式の正式配布が稀 |
| SUM (Supermicro Update Manager) | 補欠 | ローカル未配置。Web UI で詰まった場合のみ別途検討 |
| IPMICFG | 不採用 | サーバローカル実行が必要、SSH 不可状況では使えない |

### C0. 設定バックアップ (実施可能なら)
- `ipmicfg -fde tmp/<sid>/bmc-backup.cfg` 相当を Web UI の `Configuration → Save Configuration` 経由 (Playwright) で取得
- もしくは Phase A の `lan print` / `user list` 出力をバックアップとみなす
- 失敗しても Phase 中断はしない (記録のみ)

### C1. 事前準備
- BMC Web UI に Playwright でログイン (`https://10.10.10.30/`)
- ナビゲーション: `Maintenance` → `Firmware Update`
- 画面構造を `tmp/<sid>/fw-update-screen.png` に保存 (X10 世代の UI を確認)
- **Preserve オプションの UI 要素を実画面で確認**: `Preserve Configuration`, `Preserve SDR`, `Preserve SSL` のチェックボックスが期待通り存在するか

### C2. Update Mode 突入
- 「Enter Update Mode」ボタンクリック (BMC 自体がリセットモードに入る)
- 警告ダイアログを承諾 (Playwright で OK クリック)
- BMC は数秒〜十数秒応答停止 → Playwright で再接続待機

### C3. FW アップロード
- ファイルアップロード input に `tmp/<sid>/fw-extracted/*.bin` を指定
- Upload ボタンクリック
- アップロード完了後、確認画面で Preserve オプション群が表示される

### C4. Preserve オプション設定
Phase B3 でメジャー一致が確認されている前提 (跨ぐ場合は到達しない):
- `Preserve Configuration` = **ON** (claude ユーザ・LAN 保持)
- `Preserve SDR` = **ON**
- `Preserve SSL` = **OFF** (古い自己署名証明書を引き継がない)

UI で各チェックボックスの状態をスクリーンショットで証跡保存してから Start Upgrade に進む。

### C5. Start Upgrade
- Start Upgrade ボタンクリック
- 進捗バー監視 (Playwright スクリーンショット 30秒ごと)
- 推定所要時間: X10 で 2-5 分
- 「Update Complete」表示まで Playwright で待機 (max 10分)
- 完了後 BMC が自動リセット → 再ログイン待機 (60-180秒)
- **応答タイムアウト 10分超 → リカバリ手順発動**: `ipmitool -H 10.10.10.30 -U <user> -P <pass> mc reset cold` を試行 (chassis power 操作ではない)。それでも復活しない場合はユーザに AC 電源サイクルを依頼

### C6. ロギング
- 全ての操作を `./oplog.sh` で記録
- Playwright スクリプトは `tmp/<sid>/fw-write.py` に書き、`./oplog.sh .venv/bin/python tmp/<sid>/fw-write.py` で実行

## Phase D: 検証

### D1. BMC 疎通復活確認
- `ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status` (5回まで再試行、間隔 30秒)
- claude ユーザ生存 = Preserve Configuration=ON 成功
- 失敗時 (Preserve OFF 経路 or ON でも失敗): `ADMIN/ADMIN` で再ログイン試行 → Phase D5 でユーザ再作成

### D2. FW バージョン確認
- `ipmitool ... mc info` の `Firmware Revision` が更新後バージョンになっているか確認 (Phase A2 のベースラインと比較)
- Redfish `/redfish/v1/Managers/1` の `FirmwareVersion` 値も確認

### D3. 既存スクリプト互換性再確認
- Phase A の Step A5-A9 を再実行し、更新後も同じ結果 (または改善) であることを確認
- 特に CGI ログイン (A7) と CSRF 取得 (A8) — 新 FW で API 変更がないか

### D4. claude ユーザ・ネットワーク設定保持確認 (Preserve ON 経路)
- `ipmitool ... user list 1` で claude ユーザがあること
- `ipmitool ... lan print 1` で IP / Mask / GW が更新前と同じこと

### D5. POST への影響なし確認
- `ipmitool ... chassis status` で `System Power` が更新前と同じ (= OFF か ON のまま) こと
- (chassis power 操作はしない宣言のため、システム電源状態が変わっていれば異常)

## Phase E: ドキュメント整備

### E1. レポート作成 (REPORT.md ルール準拠)
- パス: `report/<timestamp>_server10_bmc_fw_update.md`
- 添付: `report/attachment/<timestamp>_server10_bmc_fw_update/` に
  - `bmc-check-pre/*.txt` (Phase A の出力)
  - `dl-page.png`, zip ファイル sha256 (Phase B)
  - `fw-update-screen.png`, `fw-progress-*.png` (Phase C)
  - `bmc-check-post/*.txt` (Phase D)
  - `fw-write.py` (Playwright スクリプト)

### E2. MEMORY.md 更新
- 10号機の BMC FW バージョン (更新前→更新後) 記録
- X10DRT-P での既存スクリプト互換性結果を反映
- 既存の `bmc_api.md` に X10DRT-P の差異 (もしあれば) を追記

### E3. 補助スクリプトのプロジェクト配置
- `scripts/supermicro-fw-download.py` を `scripts/` 配下に commit 候補として残す
  - 後続で `supermicro-fw-update` スキルを作る際の前提となる
  - 今回スキル化はしない (実証 1 サーバのみ、汎用化は早い)

## 関連ファイル

### 参照のみ
- `scripts/bmc-power.sh`, `bmc-session.sh`, `bmc-virtualmedia.sh`, `bmc-kvm-*.py`
- `config/server10.yml` (BMC 認証情報・IP)
- `.claude/skills/dell-fw-download/SKILL.md`, `idrac7-fw-update/SKILL.md` (パターン参照)
- `.claude/skills/playwright/SKILL.md` (Playwright セットアップ)
- `MEMORY.md` の `bmc_api.md`, `bmc_kvm.md`

### 新規作成
- `scripts/supermicro-fw-download.py` — Playwright で supermicro.com から FW zip 取得
- `tmp/<sid>/fw-write.py` — Playwright で BMC Web UI から FW 適用 (今回限りのスクリプト)
- `tmp/<sid>/bmc-check/` — Phase A の出力ログ
- `tmp/<sid>/fw-extracted/` — zip 展開後の .bin
- `report/<timestamp>_server10_bmc_fw_update.md` + `attachment/`

### 修正候補
- `MEMORY.md` (auto-memory) — FW バージョン記録、X10DRT-P 互換性メモ
- `MEMORY.md` の `bmc_api.md` — X10 世代差異追記 (差異が出た場合のみ)

## リスクと対策

| リスク | 影響 | 対策 |
|--------|------|------|
| **claude ユーザ消失** | BMC 完全アクセス不能 | 同マイナー系列に限定するため Preserve Configuration=ON で保持される。万一消失したら Phase C5 のリカバリ手順 (`mc reset cold` → ユーザに AC 電源サイクル依頼) で対応 |
| **メジャー跨ぎで Preserve OFF が必須なのに 10号機は IP 失効リスク** | BMC アクセス完全断 (DHCP サーバ無し環境) | Phase B3 でメジャー一致を確認し、不一致なら **本タスクを Phase A 完了時点で中断**。物理アクセス手配後に別タスク扱い |
| **メジャー跨ぎで Preserve ON のまま BMC が semi-brick** | 復旧困難 | 上記の中断方針により、そもそもメジャー跨ぎ更新を本タスクで試みない |
| **FW 書き込み中断 (ネットワーク切断)** | BMC ブリック (復旧困難) | 書き込み中は他の BMC 操作禁止。Playwright を Bash run_in_background で実行し、進捗ログを監視 |
| **Playwright で Web UI が操作できない** | Phase C 進行不能 | 古い X10 世代 UI 構造を C1 で先に観察し、ボタン/input セレクタを実画面から取得。詰まったらユーザに手動操作依頼 |
| **EULA / DL 認証で zip 取得不可** | Phase B 進行不能 | 手動 DL 依頼にフォールバック。URL とファイル名を提示しユーザに `tmp/<sid>/` 配置を依頼 |
| **BMC 再起動後に Redfish/CGI の API パスが変わる** | 既存スクリプト動作不能 | Phase D で動作確認、変更があればレポートに記録、別タスクで対応 |
| **chassis power が誤って ON になる** | ユーザ宣言違反 | 全コマンドを read-only に限定。ipmitool は `status` のみ、CGI は `status`/`config_iso` 系を呼ばない |
| **FW 書き込み失敗で BMC が応答しない** | サーバ管理不能 | フェイルセーフとして「電源 AC OFF/ON で BMC リセット」手順をレポートに残し、ユーザ依頼で復旧 |

## 検証 (How to verify end-to-end)

1. **Phase A 完了**: `tmp/<sid>/bmc-check/mc-info-pre.txt` に `Firmware Revision` が記録されている
2. **Phase B 完了**: `tmp/<sid>/fw-extracted/*.bin` が存在し、サイズが妥当 (数十 MB)、sha256 一致
3. **Phase C 完了**: Playwright スクリプトが exit 0、`Update Complete` スクリーンショット保存済み
4. **Phase D 完了**: 更新後の `mc info` で `Firmware Revision` が更新前より新しい、claude ユーザで再ログイン成功
5. **Phase E 完了**: レポート + 添付ファイルが `report/` 配下に存在し、REPORT.md ルール (タイムスタンプ JST 形式、attachment ディレクトリ) に準拠

## 残タスク (別タスクで実施)

1. **`supermicro-fw-update` スキル新設** — 本タスクで動いた `tmp/<sid>/fw-write.py` を雛形に、汎用スキル化 (X11DPU, X10DRT-P 両対応)
2. **`supermicro-fw-download` スキル新設** — `dell-fw-download` 風に、マザーボード ID 指定でダウンロード自動化
3. **BIOS/Bundle FW 更新** — BMC とは別に BIOS FW も最新化が必要なら別タスク
4. **NIC 名・disk・serial_unit の実機確認** — OS インストール時に確定 (BMC FW 更新とは独立)
5. **既存 4-6号機 (X11DPU) の BMC FW 更新** — 本タスクで確立した方式を 4-6号機にも展開する場合の別タスク
6. **メジャー版跨ぎ更新が必要だった場合** — 物理 KVM/モニタ・キーボード・AC 電源アクセスを手配した上で別タスクで実施。手順は (a) 設定バックアップ → (b) Preserve OFF で更新 → (c) 物理 KVM で BIOS IPMI Setup から `10.10.10.30` 再設定 → (d) claude ユーザ再作成 → (e) 検証 の流れ
