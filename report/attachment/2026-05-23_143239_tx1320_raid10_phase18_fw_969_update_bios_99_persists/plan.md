# Phase 18: iRMC S4 FW 9.08F → 9.69F update + install 完遂

## Context

Phase 17 (2026-05-23 0dfdbfdc / wise-book) で、F6 wholesale commit (5 分割) + F7 marker SOL 可視化 + F8 deploy 105s pad 統合 + F1 FW 9.69F リサーチが完遂したが、 install は **3 deploy attempts 全て BIOS POST 99 stuck** で未達。iRMC USB redirector の累積劣化が Phase 16 (PSU reset 2-3 秒で復活) より深刻化し、 Phase 17 では PSU cold reset (2-3 秒 + 10-15 秒) でも復活せず。

Phase 17 リサーチで iRMC S4 FW 9.69F_sdr03.18 (2024-11-07 公開、 72 MB、 公開 directory、 7z extract 可) の取得経路と 3 つの update 経路が判明。ユーザは **2026-05-23 に BMC ブリックリスク認識した上で F1 FW update 実施を明示承認**。

Phase 18 の目的: iRMC FW を 9.08F → 9.69F に **段階 update** (9.21F 中継) で更新し、 USB redirector 累積劣化問題の根本解消を狙う。 成功すれば再 deploy で OS install (preseed + RAID10 + SSH login) を完遂。 失敗時 (USB redirector 未改善 / BMC ブリック) は Phase 19 で F2 PXE pivot を持ち越し。

ユーザ判断 (本セッション):
- 段階 update (9.08F → 9.21F → 9.69F) 採用
- update 中 chassis は **ForceOff**
- 新規 `scripts/irmc-fw-update.sh` は **動作実証後に main commit** (Phase 17 Option B パターン踏襲)

## 対象機

- **training-tx1320** (Fujitsu PRIMERGY TX1320 M3, BMC 10.254.254.9)
- iRMC S4 FW 9.08F → 9.69F_sdr03.18 (目標)
- BIOS V5.0.0.11 R1.22.0 / D3373-B1x
- HW RAID10 (VD0 = /dev/sda 1.80 TB) は構成済
- NFS Virtual Media: 10.1.6.6:/var/samba/public (Phase 17 維持)

## Phase 構造

| Phase | 内容 | 工数 | go/no-go gate |
|------|------|------|---------|
| 18A | FW download + 7z extract + ReadMe 確認 | 15-30 min | BIN exist + 互換性確認 |
| 18B | Pre-update state capture (Redfish + BIOS XML) | 10 min | 4-6 ファイル exist |
| 18C | 段階 update (9.21F → verify → 9.69F → verify) | 30-45 min | version=9.69F + auth OK |
| 18D | Post-update verification (FW + auth + network + BIOS) | 10 min | 全 4 項目 pass |
| 18E | Install retry (deploy + SOL monitor + SSH login) | 60-90 min | SSH login + `pveversion` |
| 18F | Failure handling (各 phase の fallback) | 状況依存 | — |

## 重要な制約 (CLAUDE.md 由来)

- 一時ファイルは `tmp/<sid>/` (8 桁 UUID、 Glob `pattern: "*.jsonl", path: "/home/ubuntu/.claude/transcripts"` で取得)
- スクリプトは `./` 付き相対パス + `./oplog.sh` ラップ (状態変更操作)
- BMC factory reset (`ipmitool raw 0x3c 0x40`) **禁止**
- `git push` は手動承認
- パイプ・複合コマンドは分割 or `sh tmp/<sid>/x.sh`
- 入力リダイレクト `<` 禁止
- iRMC HTTPS は `--ciphers DEFAULT@SECLEVEL=0` 必須、 `If-Match` etag は **引用符なし**

---

## Phase 18A: FW download + extract

### 手順

1. **9.69F download** (必須):
   ```sh
   ./oplog.sh wget -O tmp/<sid>/irmc-9.69F.exe 'https://support.ts.fujitsu.com/globalflash/ManagementController/iRMC%20S4-TX13x0M3/09.69F_sdr03.18/zip_irmc_s4-tx13x0m3_09.69f_sdr03.18.exe'
   ```
2. **9.21F download** (中間版):
   ```sh
   ./oplog.sh wget -O tmp/<sid>/irmc-9.21F.exe 'https://support.ts.fujitsu.com/globalflash/ManagementController/iRMC%20S4-TX13x0M3/09.21F_sdr03.17/zip_irmc_s4-tx13x0m3_09.21f_sdr03.17.exe'
   ```
   (URL は Phase 17 リサーチ時点で `9.21F_sdr03.17` を想定。 公開 directory から実在を確認すること)
3. サイズ + sha256 確認: `ls -l tmp/<sid>/*.exe` + `sha256sum tmp/<sid>/*.exe > tmp/<sid>/exe-sha256.txt`
4. 抽出:
   ```sh
   ./oplog.sh 7z x tmp/<sid>/irmc-9.69F.exe -otmp/<sid>/9.69F/
   ./oplog.sh 7z x tmp/<sid>/irmc-9.21F.exe -otmp/<sid>/9.21F/
   ```
5. ファイル構造確認: Glob `pattern: "**/*.BIN", path: "/home/ubuntu/projects/pvese/tmp/<sid>"` で BIN ファイル特定
6. `Read` ツールで `ReadMe.txt` / `Release Notes` を読み、 (a) TX1320 M3 互換性、 (b) 9.08F → 9.21F → 9.69F の段階パスが推奨か、 (c) BIOS 依存記述、 (d) Known Issues を確認

### Go/no-go

- **Go**: 両方の BIN ファイル exist + ReadMe で TX1320 M3 段階パスに block 記述なし
- **No-go**:
  - download 失敗 (拠点間 100% packet loss 間欠あり) → 3 リトライ + sha256 検証 + user 介入
  - ReadMe で「9.08F からは 9.21F 経由必須」明記 → そのまま段階継続
  - ReadMe で「TX1320 M3 非互換」明記 → 即 Phase 19 (PXE) へ escalation

---

## Phase 18B: Pre-update state capture

ブリック時の参照 + post-update drift 検出用。

### 手順 (各結果を `tmp/<sid>/pre-update/` に保存)

1. **FW version + Manager**:
   ```sh
   ./oplog.sh curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 https://10.254.254.9/redfish/v1/Managers/iRMC -o tmp/<sid>/pre-update/manager.json
   ```
2. **System**: `/redfish/v1/Systems/0` を保存 (BIOS version, PowerState)
3. **AccountService**: `/redfish/v1/AccountService/Accounts/4` を保存 (claude user RoleId, Enabled)
4. **Network**: `/redfish/v1/Managers/iRMC/EthernetInterfaces/0` 保存
5. **BIOS XML backup**:
   ```sh
   ./oplog.sh ./scripts/irmc-bios.py backup 10.254.254.9 claude Claude123 tmp/<sid>/pre-update/bios-backup.xml
   ```
   失敗しても **block しない**, log + 続行
6. **VirtualMedia state**:
   ```sh
   ./scripts/irmc-virtualmedia.sh status 10.254.254.9 claude Claude123 > tmp/<sid>/pre-update/vm.txt
   ```
   (注: `--share-type=NFS` フラグが必要か確認、 既存 script の usage に従う)

### Go/no-go

- **Go**: manager.json + Systems/0 + Accounts/4 + EthernetInterfaces/0 が取得できれば go (4 ファイル必須)
- **No-go**: 認証失敗 → 既に BMC が異常な可能性、 user に状況報告 + abort

---

## Phase 18C: Update execution (段階 update)

### 新規スクリプト: `scripts/irmc-fw-update.sh`

**初期実装場所**: `tmp/<sid>/irmc-fw-update.sh` で開発、 動作実証後に `scripts/` へ移動 + commit (ユーザ承認方針)。

サブコマンド構成:

| サブコマンド | 役割 |
|------------|------|
| `upload <bmc_ip> <user> <pass> <bin_path>` | `curl -F data=@<bin> "https://<ip>/irmcupdate?flashSelect=255"` HTTP 200/202 確認 |
| `progress <bmc_ip> <user> <pass>` | `GET /irmcprogress` XML、 percent + state 抽出 |
| `wait <bmc_ip> <user> <pass> [--timeout 600]` | progress 30s 間隔 poll、 100%/Completed/Idle 復帰で OK |
| `wait-reboot <bmc_ip> <user> <pass> [--timeout 300]` | ping → fail → ping 復活 + Redfish GET 成功 (connection refused 60s grace) |
| `version <bmc_ip> <user> <pass>` | `/Managers/iRMC` から `FirmwareVersion` 抽出 |
| `flash <bmc_ip> <user> <pass> <bin_path>` | upload → wait → wait-reboot → version wrapper |

### 設計ポイント

- `#!/bin/sh` + `set -eu`
- `IRMC_CURL_OPTS="-sk --ciphers DEFAULT@SECLEVEL=0 --max-time 600"` (flash upload は時間がかかる)
- HTTP 503 / connection refused は flash phase 正常挙動として 60s grace
- 失敗時 `tmp/<sid>/fw-update-<step>.log` に curl 全 stdout/stderr 保存 (post-mortem 用)
- 参考: `scripts/irmc-virtualmedia.sh` の curl + etag pattern を流用

### 実行 sequence

#### Stage 1: 9.21F 適用

1. `./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123` + 30s settle
2. PowerState=Off 確認
3. `./oplog.sh sh tmp/<sid>/irmc-fw-update.sh flash 10.254.254.9 claude Claude123 tmp/<sid>/9.21F/<BIN>`
4. version 確認: `9.21F` 出力
5. **Mini-verify** (Phase 18D 簡易版): auth OK + ping OK + Redfish `/Managers/iRMC` GET OK
6. 60s 安定待ち

#### Stage 2: 9.69F 適用

7. `./oplog.sh sh tmp/<sid>/irmc-fw-update.sh flash 10.254.254.9 claude Claude123 tmp/<sid>/9.69F/<BIN>`
8. version 確認: `9.69F` 出力
9. Phase 18D へ

### Go/no-go

- **Go**: Stage 2 後の `version` が `9.69F_sdr03.18` + 認証 OK + Network 到達 OK
- **No-go**:
  - upload で HTTP 4xx (BIN reject) → BIN file path 再確認 → 別 BIN 試行 → escalation
  - `progress` が 5 min 以上 stall → 5 min 追加 wait → ping 確認 → 復活なら継続 / 不復活なら **ブリック疑い (user 通知)**
  - reboot 後 ping 復活せず 10 min → user に PSU cold reset 依頼 (30-60 秒、 完全放電) → 復活なければブリック確定 → escalation
  - Stage 1 後の mini-verify で auth/network 喪失 → Stage 2 中止 + escalation

---

## Phase 18D: Post-update verification

### 手順

1. **FW version**: `irmc-fw-update.sh version` → `9.69F_sdr03.18` 確認
2. **Auth**:
   ```sh
   curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 https://10.254.254.9/redfish/v1/AccountService/Accounts/4
   ```
   200 + `UserName=claude` + `RoleId=Administrator` を確認。401 なら admin/admin (factory default) 試行 → 復旧後 claude user 再作成
3. **Network**: `ping -c 3 10.254.254.9` 全 reply、 IPv4StaticAddresses が pre-capture と一致
4. **BIOS drift**:
   ```sh
   ./scripts/irmc-bios.py backup 10.254.254.9 claude Claude123 tmp/<sid>/post-update/bios.xml
   diff tmp/<sid>/pre-update/bios-backup.xml tmp/<sid>/post-update/bios.xml > tmp/<sid>/bios-diff.txt
   ```
   drift があれば: `./scripts/irmc-bios.py apply-config config/training_tx1320.yml --restore-now` (host PowerOn 時 BIOS phase で適用)
5. **PowerState**: Off のまま (Phase 18E で改めて on)
6. **VirtualMedia**: `irmc-virtualmedia.sh status` で CD config が保持 or 空 (どちらも許容)

### Go/no-go

- **Go**: 1-3 全 pass で go。4 の drift は許容 + 後段で apply-config

---

## Phase 18E: Install retry

### 手順

1. **ISO build**:
   ```sh
   SKIP_STORCLI_FETCH=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
   ```
   Phase 17 build と同等。 既存 ISO を再利用する場合は skip 可
2. **Deploy** (F8 統合 105s pad):
   ```sh
   ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
   ```
3. **SOL monitor** (orchestrate.sh の monitor wrapper bug 回避で直接起動):
   ```sh
   ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload enable 2 4
   .venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60
   ```
4. **期待 SOL markers** (出現順、 各 ≥ 1 行):
   - `Linux version 6.12` (kernel boot)
   - `pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount` (F7 marker)
   - `Configuring apt`
   - `partman-auto-raid` または `Partitioning`
   - `Installation complete`
   - GRUB boot + login prompt
5. **OEM screenshot** (deploy 後 5 分): BIOS POST 99 stuck 検知用
   ```sh
   ./scripts/irmc-oem-screenshot.sh 10.254.254.9 claude Claude123 tmp/<sid>/screen-5min.jpg
   ```
6. **SSH 完遂判定**:
   ```sh
   ssh -F ssh/config -o StrictHostKeyChecking=accept-new debian@10.254.254.250 hostname
   ssh -F ssh/config root@10.254.254.250 pveversion
   ```
   `training-tx1320` + PVE 8.x 出力で OK

### Go/no-go

- **Go**: SSH login 成功 + `pveversion` が PVE 8.x 報告 → Phase 18 完了、 Issue #72 close
- **Soft no-go**: kernel boot 到達するも install 中断 → retry 1 回まで OK
- **Hard no-go**: BIOS POST 99 stuck 再発 (FW update が問題解決していない) → Phase 19 (PXE) へ持ち越し

---

## Phase 18F: Failure handling

### Phase 別 fallback マトリクス

| 失敗 phase | 症状 | 1st action | 2nd action | Escalation |
|-----------|------|-----------|-----------|-----------|
| 18A download | wget 失敗 / 拠点間 packet loss | 3 リトライ + sha256 検証 | user に手動取得依頼 | user 介入 |
| 18A extract | 7z 失敗 | `unzip` 試行 → `file <exe>` で format 確認 | wine fallback (skip) | user 介入 |
| 18A ReadMe | TX1320 M3 非互換記述 | 9.21F のみ適用に切替 | full skip → Phase 19 (PXE) | 即 escalation |
| 18C upload | HTTP 4xx | BIN mismatch / file path 再確認 | 9.21F BIN に差し戻し | user 介入 |
| 18C progress stall | 5 min stall | 5 min 追加 wait | iRMC ping 確認 | **ブリック疑い → user 通知** |
| 18C reboot wait | 5 min ping 復活せず | 10 min 追加 wait | user に PSU cold reset 依頼 (30-60 秒) | ブリック確定 → escalation |
| 18C auth lost | post-update で claude/Claude123 失敗 | admin/admin (factory default) 試行 → claude user 再作成 | **`ipmitool raw 0x3c 0x40` は CLAUDE.md で禁止** → user 手動依頼 | user 介入 |
| 18D BIOS drift | 設定値が default リセット | `./scripts/irmc-bios.py apply-config --restore-now` | host PowerOn 時 BIOS phase で apply 待ち | continuing |
| 18E POST 99 stuck | FW update でも USB redirector 復活せず | PSU cold reset 30-60 秒 (user 依頼) → 再 deploy 1 回 | **Phase 19 (PXE pivot) へ持ち越し** | F2 着手判断 user |
| 18E kernel boot 後の中断 | apt/partman で hang | 30 min wait 後、 再 deploy 1 回 | preseed 修正は Phase 19 で | continuing |

### BMC ブリック escalation 手順 (最重要)

1. ping/Redfish 完全 unavailable が 10 min 継続で「ブリック疑い」判定
2. `tmp/<sid>/pre-update/` の全 capture を `report/attachment/` に保存
3. **user に提示**:
   - PSU 完全切断 30-60 秒 → 接続 → 5 min 待機
   - 復活しない場合: 物理的 BMC battery 抜き (TX1320 M3 motherboard) — lab 環境での実施可否を user 判断
   - JTAG / serial reflash は実現困難
   - `ipmitool raw 0x3c 0x40` (factory reset) は **CLAUDE.md 禁止**、 Claude からは実行しない
4. これ以上の自動復旧は **行わない**、 user の物理対応を待つ

### Phase 19 持ち越し条件

- 18E で BIOS POST 99 stuck 再発 = USB redirector が FW 9.69F でも修復されない
- 18C で 9.21F flash 自体失敗 (= 9.69F に進めない)

→ `report/attachment/2026-05-23_113500_*/f2-pxe-pivot-notes.md` を再 review し dnsmasq + TFTP + HTTP セットアップから Phase 19 着手

---

## 新規・修正ファイル一覧

| ファイル | 種別 | LOC 目安 | 内容 |
|---------|------|---------|------|
| `tmp/<sid>/irmc-fw-update.sh` (開発) → `scripts/irmc-fw-update.sh` (動作実証後 commit) | **新規** | ~180 | upload/progress/wait/wait-reboot/version/flash サブコマンド |
| `tmp/<sid>/9.69F/`, `tmp/<sid>/9.21F/` | 新規 (一時) | — | 7z extract 結果、 commit しない |
| `tmp/<sid>/pre-update/*`, `tmp/<sid>/post-update/*` | 新規 (一時) | — | 状態 capture、 失敗時のみ report attach |
| `tmp/<sid>/install.log` | 新規 (一時) | — | SOL monitor log |
| `report/2026-05-23_<HHMMSS>_tx1320_raid10_phase18_*.md` | 新規 | — | 完了レポート (REPORT.md フォーマット) |
| `config/training_tx1320.yml` | 修正候補 | — | post-update で `# iRMC FW: 9.69F_sdr03.18` コメント追加 (機能変更なし) |
| 既存 `scripts/tx1320-raid10-orchestrate.sh` 等 | 修正なし | — | Phase 17 完成形をそのまま流用 |

## リスク評価 + mitigation

| リスク | 確率 | 影響 | Mitigation |
|------|------|------|----------|
| BMC ブリック | 低 | **致命** (lab 復旧困難) | flashSelect=255 (redundant store)、 段階 update、 user 承認済 |
| Auth リセット (default 復元) | 中 | 中 | pre-capture で AccountService 保存、 admin/admin 試行手順準備 |
| BIOS 設定 drift | 中 | 低 | XML backup + diff + apply-config |
| USB redirector 未改善 | 中-高 | 中 | F2 pivot メモ事前準備、 Phase 19 smooth transition |
| Network 設定 drift | 低 | 中 | pre-capture で network/0 保存、 Redfish PATCH 復元 |
| 拠点間 packet loss (250-330ms / 間欠 100%) | 中 | 低 | curl `--max-time 600`、 wait コマンド retry 内蔵 |
| 9.21F → 9.69F 中間で auth 喪失 | 低 | 中 | 9.21F 適用直後 mini-verify 必須化 |

## 検証手順サマリー (each phase go/no-go)

- **18A**: BIN ファイル exist (9.21F + 9.69F)、 ReadMe 読了、 互換性問題なし
- **18B**: `tmp/<sid>/pre-update/` に 4-6 ファイル exist
- **18C**: `irmc-fw-update.sh version` が `9.69F_sdr03.18` 返答 + ping 復活 + 認証 OK
- **18D**: FW version + auth + network + (BIOS drift apply-config) 完了
- **18E**: SSH `debian@10.254.254.250` で hostname 取得成功 + `pveversion` 出力

## Critical Files for Implementation

- `/home/ubuntu/projects/pvese/scripts/irmc-fw-update.sh` (**新規**、 動作実証後 commit)
- `/home/ubuntu/projects/pvese/scripts/irmc-virtualmedia.sh` (流用 curl + If-Match パターン)
- `/home/ubuntu/projects/pvese/scripts/irmc-bios.py` (BSPBR backup/restore + apply-config)
- `/home/ubuntu/projects/pvese/scripts/bmc-power.sh` (PowerState 操作)
- `/home/ubuntu/projects/pvese/scripts/tx1320-raid10-orchestrate.sh` (deploy retry 用、 105s pad 済)
- `/home/ubuntu/projects/pvese/scripts/sol-monitor.py` (SOL + PowerState 監視)
- `/home/ubuntu/projects/pvese/scripts/irmc-oem-screenshot.sh` (BIOS POST 99 stuck 検知)
- `/home/ubuntu/projects/pvese/config/training_tx1320.yml` (BMC auth + iRMC 設定の単一情報源)

## セッション設定

- セッション ID: `<sid>` (8 桁、 開始時に Glob で取得 + `mkdir -p tmp/<sid>`)
- Issue: #72 を `./issue.sh start 72 --owner phase18-<sid>` で再取得
- 完了時: `./issue.sh complete 72` (install 完遂時) or `./issue.sh block 72 "Phase 19 PXE pivot 持ち越し"` (USB redirector 未解決時)

## ユーザ判断 (本セッション確認済)

1. **段階 update** (9.08F → 9.21F → 9.69F) 採用
2. **ForceOff** で update 実施
3. `scripts/irmc-fw-update.sh` は **動作実証後 commit** (Phase 17 Option B パターン)
