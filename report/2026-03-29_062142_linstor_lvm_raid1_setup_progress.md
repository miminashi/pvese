# LVM RAID1 LINSTOR セットアップ — 中間レポート (RAID 構成フェーズ)

- **実施日時**: 2026年3月28日 09:06 - 3月29日 06:21 JST
- **種別**: 中間レポート（Phase 2 完了、Phase 3 進行中）

## 添付ファイル

- [実装プラン](attachment/2026-03-29_062142_linstor_lvm_raid1_setup_progress/plan.md)

## 前提・目的

### 背景

LINSTOR/DRBD 環境で LVM RAID1 (`--type raid1 -m 1`) によるディスク冗長性を実験する。
7,8,9号機 (DELL PowerEdge R320, PERC H710 Mini) に物理ディスクを増設済み。

### 目的

1. 300/600GB × 2本 → PERC H710 RAID-1 → OS (Debian 13 + PVE 9)
2. 残りの 900GB ディスク → LINSTOR ストレージ (LVM RAID1)
3. fio ベンチマーク (GbE + IPoIB × 3回)

## 環境情報

### 増設後のディスク構成

| サーバ | 総ディスク数 | OS ディスク | データディスク | 不良ディスク |
|--------|------------|-----------|-------------|------------|
| 7号機 | 8本 | Bay 0+1 (278.88GB×2 SAS) | Bay 2-7 (837.75GB×6 SAS) | なし |
| 8号機 | 7本 | Bay 0+1 (558.38GB×2 SAS) | Bay 2,4,5,6 (837.75GB×4 SAS) | Bay 3: Blocked (0.00GB) |
| 9号機 | 7本 | Bay 0+1 (558.38GB×2 SAS) | Bay 2-6 (837.75GB×5 SAS, Bay 2 は STOR062) | Bay 2: 選択不可 |

### ディスクメーカー (8号機, Phase 1 で確認)

| Bay | Size | Vendor | Model |
|-----|------|--------|-------|
| 0 | 558.38 GB | HP | EG0600FBVFP |
| 1 | 558.38 GB | HP | EG0600JETKA |
| 2 | 837.75 GB | HITACHI | - |
| 3 | 837.75 GB | NETAPP | X423 TAL13900A10 |
| 4 | 837.75 GB | SEAGATE | - |
| 5 | 837.75 GB | HITACHI | - |
| 6 | 837.75 GB | SEAGATE | - |

## Phase 1: ディスク検出・健全性チェック (完了)

- racadm 経由で全ディスクの状態を確認
- 全ディスク Online/Ready（8号機 Bay 3 = Blocked を除く）
- サーバが電源オフのため SMART チェックは実施せず

## Phase 2: PERC H710 RAID 構成変更 (完了)

### 最終 RAID 構成

| サーバ | VD0 (OS) | データ VD | 状態 |
|--------|----------|----------|------|
| **7号機** | RAID-1 278.88 GB (Bay 0+1) | RAID-0 × 6 (Bay 2-7, 各 837.75 GB) | **完了** |
| **8号機** | RAID-1 558.38 GB (Bay 0+1) | RAID-0 × 3 (Bay 2,4,5, 各 837.75 GB) | **完了** (Bay 3 Blocked, Bay 6 選択不可) |
| **9号機** | RAID-1 558.38 GB (Bay 0+1) | RAID-0 × 4 (Bay 3-6, 各 837.75 GB) | **完了** (Bay 2 STOR062) |

### 発生した問題と対処

#### 1. racadm VD 作成ジョブの繰り返し失敗 (全3台)

**症状**: `racadm raid createvd` で VD を作成し `jobqueue create -r pwrcycle` でジョブを投入するも、ジョブが `Running 34%` で長時間停滞後 `Failed (PR21/PR34)` になる。

**原因**: PERC H710 の "Missing VDs" プロンプトが POST をブロックし、LC がジョブ処理フェーズに到達できない。SOL 経由の Enter 送信では安定的にプロンプトを通過できなかった。

**対処**:
- 7号機・9号機: 複数回の power off/on + SOL Enter 送信の繰り返しで最終的に成功
- 8号機: racadm 経由のジョブが完全に失敗。**perc-raid スキル** (VNC + キーストローク) で PERC BIOS から VD を手動作成

#### 2. STOR023 (Configuration already committed)

**症状**: VD 作成ジョブが失敗すると committed config がスタックし、新しい VD 作成コマンドが `STOR023` エラーで拒否される。`jobqueue delete --all` でもクリアできない。

**対処**: `racadm racreset` で iDRAC をリセットして committed config をクリア。その後 `resetconfig` で全 VD を削除してから再構成。

#### 3. STOR062 (Physical Disk full)

**症状**: 9号機 Bay 2、8号機 Bay 2 で `STOR062: One or more Physical Disks specified is full` エラー。resetconfig 後でも発生。

**対処**: 8号機は resetconfig 再実行後に Bay 2 が使用可能に回復。9号機 Bay 2 は回復せず除外。

#### 4. 8号機 Bay 3 Blocked

**症状**: Bay 3 が `Blocked (0.00 GB)` 状態。PERC BIOS の PD リストにも表示されない。

**対処**: 物理的な問題（ディスク故障またはバックプレーン接触不良）と判断。除外して運用。

#### 5. 8号機 iDRAC SSH の racreset 後消失

**症状**: `racadm racreset` 後に SSH 鍵認証が失敗し、SSH サービスが応答しなくなる。

**対処**: iDRAC Web UI から SSH を無効→有効にトグルして復旧。ユーザーが telnet も有効化。paramiko でのパスワード認証 + 鍵再登録は iDRAC 起動タイミングにより不安定。

#### 6. perc-raid スキルの活用 (8号機)

racadm 経由のジョブが完全に機能しなかった8号機では、VNC 経由で PERC BIOS Configuration Utility を直接操作する `perc-raid` スキルを使用:
- Clear Config で全 VD 削除
- Create New VD で RAID-1 (OS) + RAID-0 × 3 (データ) を作成
- VNC スクリーンショットで各ステップを確認

#### 7. racadm vs PERC BIOS の不整合

**症状**: PERC BIOS で VD を作成し、画面上で確認できたが、PERC BIOS 終了後に racadm で VD が見えない。

**原因**: VNC の stale framebuffer 問題。racreset 後の最初の VNC セッション以外ではスクリーンショットが古いフレームを表示する可能性がある。

## Phase 3: OS セットアップ (進行中)

### 実施済み

- Phase 4 (bmc-mount-boot): VirtualMedia マウント + boot-once VCD-DVD 設定 + power on
- 7号機: POST → LC Collecting System Inventory まで確認
- 9号機: POST 中

### 未解決問題

**VirtualMedia ブート失敗**: 7号機で最初の boot-once VCD-DVD が UEFI ブートシーケンスで認識されず "No boot device available" になった。RAID resetconfig で UEFI NVRAM のブートエントリがクリアされた可能性。2回目の power off/on + boot-once 再設定後に LC Collecting Inventory まで到達したが、VirtualMedia からのブート成功は未確認。

## 次セッションでの作業

1. **Phase 3 続行**: VirtualMedia ブート問題を解決して OS インストール
   - F11 Boot Manager で VirtualMedia を手動選択
   - または Legacy BIOS モード切替を検討
2. **Phase 4**: LINSTOR セットアップ (LVM RAID1 `--type raid1 -m 1`)
3. **Phase 5**: ベンチマーク (GbE + IPoIB × 3回 × 6テスト)
4. **Phase 6**: レポート作成 (matplotlib グラフ付き)

## 知見・メモリ更新事項

| 知見 | 詳細 |
|------|------|
| racadm RAID ジョブの不安定性 | 複数 VD の一括作成ジョブは PERC H710 で頻繁に失敗する。1 VD ずつのジョブに分割するか PERC BIOS を使用 |
| PERC Missing VDs プロンプト | SOL Enter 送信では安定的に通過できない。VNC + ユーザーの手動介入が最も確実 |
| STOR023 committed config | ジョブ失敗後に committed config がスタック。racreset でクリア可能 |
| 8号機 iDRAC SSH | racreset 後に SSH が消失する固有問題。Web UI からのトグルで復旧。telnet をフォールバックとして有効化 |
| perc-raid スキル | racadm が使えない場合の VNC 経由 PERC BIOS 操作が有効 |
| VNC stale framebuffer | racreset 後の最初のセッション以外では stale データの可能性あり。操作結果は racadm で確認すべき |
