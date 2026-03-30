# 8号機 ディスク個別 RAID-0 VD 作成実験レポート

- **実施日時**: 2026年3月29日 08:30 - 15:55 JST
- **種別**: 実験レポート

## 添付ファイル

- [実装プラン](attachment/2026-03-29_002138_server8_per_disk_raid0/plan.md)

## 前提・目的

### 背景

8号機 (Dell PowerEdge R320, PERC H710 Mini) の RAID 作成が繰り返し失敗していた。VD0 (RAID-1, Bay 0+1) と VD1-VD3 (RAID-0, Bay 2/4/5) は作成済みだが、Bay 3 と Bay 6 が未割り当て (Ready 状態) のまま残っていた。

### 目的

1ディスクずつ RAID-0 VD を作成し、各ディスクの動作を個別に検証する。

### 参照レポート

- [PERC RAID スキル作成レポート](2026-03-28_092032_perc_raid_skill.md)
- [PERC RAID 30イテレーション検証](2026-03-28_180042_perc_raid_30_iterations.md)
- [LINSTOR ディスク個別プール調査](2026-03-28_000658_linstor_per_disk_pool_investigation.md)

## 環境情報

- **サーバ**: 8号機 (Dell PowerEdge R320)
- **RAID コントローラ**: PERC H710 Mini (FW 21.3.0-0009)
- **iDRAC**: 10.10.10.28 (FW 2.65.65.65)
- **RealtimeConfigurationCapability**: Incapable (RAID 設定変更に再起動が必要)

### 物理ディスク構成 (実験前)

| Bay | Disk ID | Size | Vendor/Model | State | VD |
|-----|---------|------|-------------|-------|----|
| 0 | 00:01:00 | 558.38 GB | HP EG0600JETKA | Online | VD0 (RAID-1) |
| 1 | 00:01:01 | 558.38 GB | HGST HUC101860CSS204 | Online | VD0 (RAID-1) |
| 2 | 00:01:02 | 837.75 GB | HITACHI HUC109090CSS600 | Online | VD1 (RAID-0) |
| 3 | 00:01:03 | 837.75 GB | NETAPP X423 TAL13900A10 | Ready | なし |
| 4 | 00:01:04 | 837.75 GB | SEAGATE ST900MM0168 | Online | VD2 (RAID-0) |
| 5 | 00:01:05 | 837.75 GB | HITACHI HUC109090CSS600 | Online | VD3 (RAID-0) |
| 6 | 00:01:06 | 837.75 GB | SEAGATE ST900MM0168 | Online | なし |

## 実験手順と結果

### 手順 1: PERC BIOS VNC 操作 (失敗)

最初に VNC 経由の PERC BIOS 操作を試みた。

1. `racadm racreset` → 120秒待機
2. `ipmitool chassis power cycle` → 25秒待機
3. `Ctrl+R` x20 で PERC BIOS 進入

**問題**: Create New VD フォームの PD リストに Bay 6 (100:01:06) のみ表示され、Bay 3 は表示されなかった。Bay 3 は PERC BIOS 上で **Blocked** 状態。

さらに、PD 選択の Space キーが VNC 個別接続では正しく動作しなかった。

- `idrac-kvm-interact.py` の個別接続では ArrowDown → Space で PD を選択できず
- `raid-cycle-v2.py` 方式の単一セッションスクリプトでも、フォーム上で PD 選択の反映が不安定
- VNC セッション間でフォーカス位置が保持されないことが原因と推定

### 手順 2: racadm コマンドライン (部分成功)

VNC 操作の代替として `racadm raid createvd` コマンドを使用。

```sh
# Bay 6: 成功
ssh -F ssh/config idrac8 racadm raid createvd:RAID.Integrated.1-1 -rl r0 \
    -pdkey:Disk.Bay.6:Enclosure.Internal.0-1:RAID.Integrated.1-1
# → RAC1040: Successfully accepted

# Bay 3: 受理されるがジョブ実行時に失敗
ssh -F ssh/config idrac8 racadm raid createvd:RAID.Integrated.1-1 -rl r0 \
    -pdkey:Disk.Bay.3:Enclosure.Internal.0-1:RAID.Integrated.1-1
# → RAC1040: Successfully accepted

# ジョブ作成
ssh -F ssh/config idrac8 racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle
```

**結果**:
- Bay 6 の VD4 作成: **成功** (RAID-0, 837.75 GB, Online)
- Bay 3 の VD 作成: **失敗** (PR21: Job failed.)

### 手順 3: Bay 3 単独での再試行 (失敗)

Bay 3 のみで再度 createvd + jobqueue を実行。34% まで進行後に **PR21: Job failed** で失敗。

### 手順 4: Bay 3 の追加調査

| 調査項目 | 結果 |
|---------|------|
| `racadm raid get pdisks` (一括) | State = Blocked, Size = 0.00 GB |
| `racadm raid get pdisks:Bay3` (個別) | State = Ready, Size = 837.75 GB, Status = Ok |
| FailurePredicted | NO |
| ForeignKeyIdentifier | null |
| `converttoraid` | STOR013: デバイスが適切な状態にない |
| `converttononraid` | STOR058: この操作はサポートされていない |
| `importconfig` | STOR018: Foreign drive なし |
| PERC BIOS PD リスト | Bay 3 は Blocked 表示、Create VD に表示されない |

### racadm STOR023 の対処

`racadm jobqueue delete --all` でジョブを削除しても、pending 設定が "committed" 状態で残り、次の `createvd` が STOR023 エラーになる問題が発生。

**解決方法**: `racadm serveraction powercycle` で再起動すると pending 設定がクリアされる。

## 最終結果

### VD 構成 (実験後)

| VD | Layout | Size | Bay | State |
|----|--------|------|-----|-------|
| VD0 | RAID-1 | 558.38 GB | 0+1 | Online |
| VD1 | RAID-0 | 837.75 GB | 2 | Online |
| VD2 | RAID-0 | 837.75 GB | 4 | Online |
| VD3 | RAID-0 | 837.75 GB | 5 | Online |
| **VD4** | **RAID-0** | **837.75 GB** | **6** | **Online** (新規作成) |

### PD 構成 (実験後)

| Bay | State | 備考 |
|-----|-------|------|
| 0-2, 4-6 | Online | VD に割り当て済み |
| **3** | **Blocked** | **VD 作成不可 (NETAPP X423)** |

## 結論

1. **Bay 6 (SEAGATE ST900MM0168)**: racadm 経由で RAID-0 VD 作成に成功。`racadm raid createvd` は PERC BIOS VNC 操作よりも確実
2. **Bay 3 (NETAPP X423 TAL13900A10)**: RAID VD 作成が不可能。PERC BIOS では Blocked、racadm ジョブは PR21 で失敗。ディスク自体は Spun-Up で FailurePredicted = NO だが、PERC H710 との互換性問題と推定される
3. **racadm vs PERC BIOS**: racadm コマンドラインの方が VNC 操作よりも信頼性が高い。ただし RealtimeConfigurationCapability = Incapable のため再起動が必要
4. **racadm の注意点**: `jobqueue delete --all` だけでは pending 設定がクリアされない。`serveraction powercycle` での再起動も必要

## 追加実験: Bay 3 ローレベルフォーマット試行

### PERC BIOS PD Mgmt での操作 (失敗)

Bay 3 の Blocked 状態を解除するため、PERC BIOS PD Mgmt タブの F2 メニューを調査した。

**Bay 3 (Blocked) の F2 メニュー構造**:

| 項目 | 状態 | ArrowDown 位置 |
|------|------|---------------|
| Rebuild | サブメニューあり | 初期位置 |
| Replace Member | サブメニューあり | Down 1 |
| LED Blinking | **グレーアウト** | — |
| Force Online | 選択可能 | Down 2 |
| Force Offline | 選択可能 | Down 3 |
| Make Global HS | **グレーアウト** | — |
| Remove Hot Spare | **グレーアウト** | — |
| **Instant Secure Erase** | **グレーアウト** | — |

**Instant Secure Erase (ローレベル消去) がグレーアウトで使用不可**。Blocked 状態のディスクに対してはコントローラが消去操作を拒否する。

### 操作事故と復旧

PERC BIOS VNC 操作中にカーソル位置の不一致が発生し、Bay 6 に対して誤って Force Offline を実行してしまった。

- **原因**: VNC セッション間でカーソル位置が保持されず、スクリプトが Bay 3 ではなく Bay 6 を操作
- **影響**: Bay 6 (VD4) が Offline に遷移
- **復旧**: F2 → Down x2 → Enter (Force Online) → Tab → Enter で Bay 6 を Online に復旧
- **復旧確認**: PD Mgmt で Bay 6 = Online, DG 04 を確認

### ローレベルフォーマット不可の結論

| 方法 | 結果 | 理由 |
|------|------|------|
| PERC BIOS Instant Secure Erase | **不可** | Blocked ディスクではグレーアウト |
| racadm cryptographicerase | **不可** | 構文エラー (PCIeSSD 専用コマンド) |
| racadm createvd → ジョブ | **失敗** | PR21: Job failed (2回再現) |
| racadm converttoraid | **不可** | STOR013: 適切な状態にない |
| racadm converttononraid | **不可** | STOR058: 非サポート |
| sg_format (OS レベル) | **不可** | Blocked ディスクは OS に非公開 |

PERC H710 Mini は HW RAID コントローラで JBOD モード非対応 (`CurrentControllerMode = Not Supported`)。Blocked ディスクはコントローラによって完全にブロックされており、ファームウェアレベルで拒否されている。

## 次のアクション

1. **Bay 3 のディスクを別のマシンに接続して sg_format でローレベルフォーマット**し、フォーマット後に 8号機に戻して再試行する
2. または Bay 3 のディスクを互換性のある HITACHI/SEAGATE ディスクに物理交換する
3. または Bay 3 を諦めて 4本構成 (VD1-VD4) で運用する
4. perc-raid スキルに racadm 経由の VD 作成手順を追加する
