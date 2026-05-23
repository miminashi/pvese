# F1 リサーチ結果 — iRMC S4 FW 9.08F → 9.69F update 経路

調査日: 2026-05-23 (Phase 17 / session 0dfdbfdc / wise-book)
対象機: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
判断: 本セッションでは **FW flash を実施しない**。 リサーチ結果を次セッション以降の判断材料として記録するのみ。

---

## 1. 取得経路

### 1.1 最新 FW: 9.69F_sdr03.18

- **URL**: https://support.ts.fujitsu.com/globalflash/ManagementController/iRMC%20S4-TX13x0M3/09.69F_sdr03.18/
- **ファイル名**: `zip_irmc_s4-tx13x0m3_09.69f_sdr03.18.exe`
- **サイズ**: 72,518,408 bytes (約 72 MB)
- **公開日**: 2024-11-07
- **対応機種**: TX1320 M3 + TX1330 M3 (iRMC S4-TX13x0M3 family)

### 1.2 中間バージョン

- 9.21F_sdr03.17 (2024-12-13 同 directory) — 中間 update 候補

### 1.3 現在の FW

- 9.08F (training-tx1320 で deploy 中、 USB redirector 累積劣化症状あり)

### 1.4 認証情報

- support.ts.fujitsu.com の DownloadManager 配下は **公開 directory** (匿名 HTTP GET 可)
- 個別アカウント登録不要、 wget/curl で直接 download 可能

---

## 2. .exe ファイルの構造

Fujitsu の `zip_*.exe` は Windows self-extractor が一般的。 中身は:

- `*.BIN` (iRMC firmware binary、 update 用)
- `*.SDR` または `*.sdr` (Sensor Data Record、 runtime FW と version 整合が必要)
- `*.UPD` 等の Windows update tool
- `ReadMe.txt`、 release notes

Linux で extract する方法:

- `7z x zip_irmc_*.exe` (p7zip-full installed)
- `unzip` (Fujitsu self-extractor は内部が zip 形式の場合あり)
- Wine 経由で実行 (overhead 大)

**注意**: Linux で extract できれば .BIN ファイルのみ取り出して update に使える。 SDR は zip 内に同梱されている (FW と version 整合済)。

---

## 3. Update 手順 (3 経路)

### 3.1 経路 A: Web UI (HTTP POST endpoint)

最も documented、 reboot 不要。

```sh
curl -sk -u admin:<pass> \
    --ciphers DEFAULT@SECLEVEL=0 \
    -F "data=@irmc_9.69F.BIN" \
    "https://10.254.254.9/irmcupdate?flashSelect=255"
```

- `flashSelect=255` は「両 image を同時 update」(redundant store の安全パターン)
- 進捗確認: `GET /irmcprogress` (XML response)
- 出典: mmurayama.blogspot.com 2016/07 (古いが今も valid)

### 3.2 経路 B: Redfish OEM UpdateService

modern API、 multipart binary upload。

```
POST /redfish/v1/Managers/iRMC/Actions/Oem/FTSManager.FWUpdate
Content-Type: multipart/form-data
data=@irmc_9.69F.BIN
```

- Task 監視: `GET <Location header from response>` を 10 秒間隔で poll
- Status "Completed" になるまで待機
- 自動 iRMC reboot 発生のため request 中の connection drop を handle 必要
- 参考: https://github.com/mmurayama/fujitsu-redfish-samples/blob/master/scripts/update_irmc_firmware.py

### 3.3 経路 C: PowerShell `Invoke-WebRequest`

```pwsh
$cred = Get-Credential
Invoke-WebRequest -Method POST -Credential $cred -InFile irmc_9.69F.BIN \
    -Uri "https://10.254.254.9/irmcupdate?flashSelect=255"
```

Linux 環境では使わないが、 Windows 管理者向けの公式手順として広く知られる。

---

## 4. 副作用・リスク評価

### 4.1 公式の主張

- iRMC FW update は **OS reboot 不要** (host OS が動作中でも update 可能)
- iRMC 自身は update 完了後に **自動 reboot** (60-120s で SSH/Redfish 復活)
- 「BIN」と「SDR」のバージョン整合性必須 (今回は zip 内同梱で整合済)

### 4.2 ブリックリスク (低-中)

| シナリオ | 発生確率 | 復旧手段 |
|---------|----------|----------|
| Update 中の電源断 | 低 | BMC redundant store (flashSelect=255) で自動 fallback の可能性。 PSU cold reset で初期 image に戻る場合あり |
| BIN ファイル corrupt / 機種不一致 | 低 | iRMC が pre-flash で check sum + machine match 検証。 reject の場合は update skip |
| SDR 不整合 | 低 | zip 内同梱で予防可能 |
| BIOS/iRMC 相互依存 | 不明 | TX1320 M3 BIOS V5.0.0.11 は古いため、 新 iRMC との互換に懸念あり |

### 4.3 復旧手段

- **PSU cold reset**: PowerState 関係なく初期 image に戻る場合あり (Phase 15-16 で USB redirector 劣化のリセットに有効と実証)
- **BMC factory reset** (`ipmitool raw 0x3c 0x40`): CLAUDE.md で **禁止**。 BMC 全 user + network 設定が消失するため
- **JTAG / serial reflash**: 物理的 access 必要、 lab 環境では実現困難

---

## 5. 想定 update 手順 (次セッション以降、 ユーザ承認後)

1. **事前準備**:
   - `wget https://support.ts.fujitsu.com/globalflash/ManagementController/iRMC%20S4-TX13x0M3/09.69F_sdr03.18/zip_irmc_s4-tx13x0m3_09.69f_sdr03.18.exe -O tmp/<sid>/irmc-9.69F.exe`
   - `7z x tmp/<sid>/irmc-9.69F.exe -o tmp/<sid>/irmc-9.69F/` で extract
   - `find tmp/<sid>/irmc-9.69F -name "*.BIN" -exec ls -la {} +` で BIN ファイル特定
   - ReadMe.txt / Release Notes を読んで TX1320 M3 互換性を最終確認

2. **iRMC state 確認**:
   - PowerState=Off にしてから update (推奨)、 もしくは host OS 動作中

3. **段階的 update**:
   - 9.08F → 9.21F → 9.69F の段階 update が安全 (大幅 version jump はリスク高)
   - 9.21F も同じ directory に存在 (2024-12-13 公開)

4. **Update 実行 (Web UI 経路推奨)**:
   ```sh
   curl -sk -u claude:Claude123 --ciphers DEFAULT@SECLEVEL=0 \
       -F "data=@tmp/<sid>/irmc-9.69F/iRMC_S4_9.69F.BIN" \
       "https://10.254.254.9/irmcupdate?flashSelect=255"
   ```

5. **進捗 poll** (5-10 分):
   - `GET /irmcprogress` を 30s 間隔で poll
   - "Completed" 確認まで wait

6. **iRMC 自動 reboot** (60-120s):
   - SSH 切断、 Redfish 一時的 unavailable
   - ping 10.254.254.9 で復活確認

7. **Post-update 確認**:
   - `GET /redfish/v1/Managers/iRMC` で Version=9.69F 確認
   - claude user (index 4) と auth 設定が保持されているか確認
   - 過去 update では「Redfish が default "No Access" にリセット」のケースあり → user 設定の再 apply 必要

8. **deploy 再試行**:
   - 通常の `./scripts/tx1320-raid10-orchestrate.sh deploy` で USB redirector が安定するか確認

---

## 6. ユーザ判断材料の整理

| 観点 | 評価 | コメント |
|------|------|---------|
| **入手容易性** | ◎ | 公開 directory に存在、 認証不要 |
| **Linux 環境での extract** | ◯ | 7z で .BIN を取り出し可能 (実証必要) |
| **update tool 自体の難易度** | ◯ | curl/Redfish で 1 コマンド |
| **ブリックリスク** | 低-中 | redundant store で fallback 可能性、 ただし TX1320 M3 + 古い BIOS の組み合わせ未知 |
| **install 完遂への効果** | 高 | USB redirector 劣化が FW 改修されていれば一気に解決の可能性 |
| **失敗時の影響** | 中-高 | BMC ブリック時 lab 環境では復旧困難。 ただし PSU cold reset で初期化される redundant store の可能性 |

---

## 7. 次セッションで判断すべき事項

- (a) ユーザ承認: F1 を実行するか? それとも F2 PXE pivot 先か?
- (b) 段階 update or direct jump (9.08F → 9.69F)?
- (c) PowerState=Off 確認 + 事前 backup (Redfish FSPBRBackup) を取るか?
- (d) failure 時の復旧手段の事前確認 (PSU cold reset 等)
- (e) update 試行中の monitoring (Redfish + ping)
