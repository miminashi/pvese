# Iteration 10: 6号機 os-setup 中断レポート

- **実施日時**: 2026年4月1日 13:00〜16:30 JST
- **所要時間**: 約3.5時間 (未完了で中断)
- **対象**: 6号機 (ayase-web-service-6, Supermicro X11DPU)
- **前回レポート**: [Issue #38/#39 修正](2026-04-01_081643_issue38_39_fix.md)

## 添付ファイル

- [実装プラン](attachment/2026-04-01_163002_iteration10_server6_blocked/plan.md)

## 前提・目的

Iteration 10 として、6号機 (Supermicro X11DPU) で os-setup スキルの通しテストを実施し、Issue #38 (IPoIB 自動起動) と Issue #39 (LINBIT リポジトリ + enterprise.sources 除去) のコード修正を Supermicro プラットフォームで検証する予定だった。

## 完了した作業

### 1. LINSTOR ノード離脱 (成功)

4号機を起動し、6号機を LINSTOR クラスタから安全に離脱させた。
- 6号機にはリソースが存在しなかったため、`linstor node delete` で即座に完了
- 4号機は LINSTOR コントローラとして稼働継続

### 2. os-setup Phase 1-3: ISO 準備 (成功)

- Phase 1: ISO キャッシュ利用 (SHA256 検証 OK)
- Phase 2: preseed 生成完了
- Phase 3: ISO キャッシュ利用 (preseed ハッシュ一致)

### 3. os-setup Phase 4: BMC VirtualMedia + Boot (一部成功、問題発生)

VirtualMedia のマウントは成功 (Redfish verify: Inserted=true)。しかし CD ブートで複数の問題に遭遇:

#### 問題 1: Redfish BootOptions が空

6号機の Redfish API は `BootOptions` コレクションが空を返し、`find-boot-entry "ATEN Virtual CDROM"` が機能しなかった。4号機・5号機では正常に動作していた API パス。

#### 問題 2: Redfish boot-override が無効

`boot-override Cd UEFI` および `boot-override Cd Legacy` を設定しても、実際のブートには反映されなかった。BootSourceOverrideEnabled は "Once" に設定されて消費されるが、サーバは常にディスクからブートした。

#### 問題 3: UEFI Boot Entry の CDROM 記述子が stale

`efibootmgr -v` で確認した Boot0006 (UEFI: ATEN Virtual CDROM) の CDROM セクタオフセット `CDROM(1,0x5db74,0x59e0)` が、ISO リマスター後も変わらず。`efibootmgr -n 0006` でブートを試みたが、エントリが stale で CD からのブートに失敗し、フォールスルーでディスクブートになった。

#### 問題 4: ISOLINUX チェックサムエラー (旧 ISO)

旧リマスター ISO (3月7日作成) で BBS/Legacy CD (Boot0005) ブートを試みたところ `ISOLINUX: Image checksum error, sorry...` が表示。ISO を再リマスターして解決。

#### 問題 5: ISOLINUX の不明な動作

新 ISO で Boot0005 ブートを試みたところ、ISOLINUX 6.04 の著作権表示が VGA に表示された。しかし preseed の `timeout 30` (3秒) 後にカーネルが serial console (ttyS1) に切り替わったため、VGA は ISOLINUX バナーのまま変化なしに見えた。**実際にはインストーラが起動し、NVMe を再パーティションした可能性が高い**。

### 4. BootOrder 破損

`efibootmgr -o 0006,0005,0004,0001,0002,0003` で CD エントリを最優先に変更した。CD メディアをアンマウント後、UEFI が CD エントリ (0006, 0005) を試行 → 失敗 → ディスク (0004) に到達するも、ディスクが ISOLINUX インストーラによって上書きされていた場合、Boot0004 の EFI パスが無効になりブート不能に。

### 5. DIMM P2-DIMMA1 エラー発見

繰り返しの ForceOff/On 中に `Failing DIMM: DIMM location. (Uncorrectable memory component found) P2-DIMMA1` エラーが POST 画面に表示された。このエラーは以前は発生していなかった（セッション開始時は正常にPVE が動作していた）。

### 6. BIOS Setup でのブートオーダー修正試行

bios-setup スキルを使用して BIOS Setup に進入:
- 60回の Delete キーを1秒間隔で送信し、POST 後半の `Entering Setup...` をキャッチ
- Boot タブで Boot Option #1 を変更 (UEFI Hard Disk:debian に設定)
- F4 → Enter で Save & Exit
- しかし、サーバは依然としてブート不能 (SSH 不可、SOL ログインプロンプト検出不可)

## 重要な発見: Debian インストールは完了していた

バックグラウンドの SOL monitor (bkejipy5l) のログにより、**ISOLINUX 経由の Debian インストールが実際に完了していたことが判明**:

- 13:12 — ISOLINUX が BBS/Legacy CD (Boot0005) からブート開始
- 13:34 — SOL monitor がインストール監視開始 (PowerState: On)
- 13:47:55 — **PowerState Off 検出 → `Installation completed` で exit code 0 終了**

preseed による Debian 13 自動インストールが約13分で正常完了し、サーバは自動シャットダウンした。つまり **NVMe には新規 Debian 13 がインストールされている**。

ただし BBS/Legacy ブートでインストールされたため、GRUB が Legacy BIOS モード (MBR) でインストールされた可能性がある。既存の UEFI EFI エントリ (Boot0004: debian) とは異なるブートパスになっている可能性が高い。

**ブート不能の原因**: 新規インストールされた Debian の GRUB が Boot0004 の EFI パス (`\EFI\debian\shimx64.efi`) と一致しないか、Legacy BIOS モードでのみブート可能な状態。BIOS Boot Mode が DUAL のため Legacy エントリも試行されるはずだが、DIMM エラーとの複合で正常ブートに至っていない。

## 問題サマリ

| # | 問題 | 重大度 | 状態 |
|---|------|--------|------|
| 1 | Redfish BootOptions が空 | 中 | 6号機固有。4/5号機では未発生 |
| 2 | Redfish boot-override が無効 | 中 | 6号機固有 |
| 3 | UEFI CD Boot Entry stale | 中 | ISO リマスター後も CDROM 記述子が更新されない |
| 4 | ISOLINUX 旧 ISO チェックサムエラー | 低 | 再リマスターで解決 |
| 5 | ISOLINUX がサイレントにインストール実行 | 高 | NVMe が上書きされた可能性 |
| 6 | BootOrder 破損 | 高 | CD エントリ優先 + ディスク上書きでブート不能 |
| 7 | DIMM P2-DIMMA1 エラー | 高 | ハードウェア問題。物理対応が必要 |

## Issue 作成

- **Issue #41**: 6号機: DIMM P2-DIMMA1 Uncorrectable memory エラー + BootOrder 破損でブート不能

## 復旧手順 (次回セッション向け)

1. **DIMM 物理確認**: P2-DIMMA1 の DIMM を差し直すか交換。メモリテスト実施
2. **BIOS Setup で BootOrder 修正**: Boot Option #1 を UEFI Hard Disk に確実に設定
3. **ディスク状態確認**: NVMe に Debian/PVE が残っているか確認。ISOLINUX がインストールを実行した場合は新規 Debian が存在する可能性あり
4. **os-setup 再実行**: ディスクが上書きされていた場合は os-setup Phase 4 (VirtualMedia ブート) から再実行。BIOS Boot Menu (F11) で直接 CD ブートを選択するアプローチを推奨

## os-setup スキル改善点

| 改善項目 | 内容 |
|---------|------|
| Redfish BootOptions 空の場合のフォールバック | `efibootmgr` 経由で Boot ID を取得するパスを追加 |
| UEFI CD Boot 失敗時のフォールバック | BIOS Boot Menu (F11) での直接選択を手順に追加 |
| BootOrder 変更の安全策 | CD エントリを BootOrder 最優先にしない。`efibootmgr -n` (BootNext) のみ使用 |
| ISOLINUX の進行確認 | BBS/Legacy ブート時は VGA スクリーンショットで installer TUI の表示を確認してから次に進む |

## 環境状態

| サーバ | 状態 |
|--------|------|
| 4号機 | **稼働中** (LINSTOR コントローラ) |
| 5号機 | Off |
| 6号機 | **Off (ブート不能)** — DIMM エラー + BootOrder 破損 |
| 7-9号機 | Off |
