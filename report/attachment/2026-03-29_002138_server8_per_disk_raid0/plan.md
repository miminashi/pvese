# 8号機 Bay 3 / Bay 6 — 単体ディスク RAID-0 VD 作成

## Context

8号機の PERC H710 で RAID 作成が繰り返し失敗している。現在 VD1-3 (RAID-0) は作成済みだが、Bay 3 と Bay 6 が未割り当て (Ready 状態)。ユーザの指示により、1ディスクずつ RAID-0 を作成して各ディスクの動作を検証する。

## 現状

| VD | Layout | Size | 構成 | 状態 |
|----|--------|------|------|------|
| VD0 | RAID-1 | 558 GB | Bay 0+1 | Online |
| VD1 | RAID-0 | 837 GB | (Bay 2 or 4 or 5) | Online |
| VD2 | RAID-0 | 837 GB | (Bay 2 or 4 or 5) | Online |
| VD3 | RAID-0 | 837 GB | (Bay 2 or 4 or 5) | Online |
| — | — | — | **Bay 3** | **Ready** (以前 Blocked) |
| — | — | — | **Bay 6** | **Ready** |

## 作業手順

### Step 1: racreset + PERC BIOS 進入

1. `ssh -F ssh/config idrac8 racadm racreset` → 120秒待機
2. `ipmitool ... chassis power cycle` → 25秒待機
3. `idrac-kvm-interact.py sendkeys Ctrl+r x20 --wait 2000`
4. スクリーンショットで PERC BIOS 進入を確認

### Step 2: Bay 3 で RAID-0 VD 作成

1. ルート行で F2 → Enter (Create New VD)
2. RAID Level: デフォルト RAID-0 のまま
3. ArrowDown で PD リストへ → Bay 3 を見つけて Space で選択
   - 既に VD に割り当て済みの PD はリストに表示されないため、リストには Bay 3 と Bay 6 のみ表示されるはず
   - 最初の PD (Bay 3) を Space で選択
4. Tab x4 → Enter (OK)
5. 初期化確認: Tab → Enter (OK)
6. スクリーンショットで確認

### Step 3: Bay 6 で RAID-0 VD 作成

1. 再度ルート行に移動 (ArrowUp x10 でツリー先頭へ)
2. F2 → Enter (Create New VD)
3. RAID Level: RAID-0 のまま
4. ArrowDown → Space (残りの Bay 6 を選択)
5. Tab x4 → Enter (OK)
6. 初期化確認: Tab → Enter (OK)

### Step 4: PERC BIOS 終了 + racadm で検証

1. Escape → Enter で PERC BIOS 終了
2. POST 完了後 `racadm raid get vdisks` で VD4, VD5 が作成されていることを確認
3. `racadm raid get pdisks` で全ディスクが Online であることを確認

## Step 5: レポート作成

作業完了後（成功・失敗問わず）、`report/` にレポートを作成する。

- ファイル名: `report/2026-03-28_HHMMSS_server8_per_disk_raid0.md`
- 内容:
  - 目的（各ディスク個別 RAID-0 作成による動作検証）
  - 各 Bay の作成結果（成功/失敗、エラー内容）
  - 失敗した場合の調査結果と根本原因
  - 最終的な VD/PD 状態
  - 結論と次のアクション
- フォーマット: REPORT.md に従う

## 重要ファイル

- `scripts/idrac-kvm-interact.py` — VNC 操作ツール
- `.claude/skills/perc-raid/SKILL.md` — PERC RAID スキル手順
- `ssh/config` — SSH ホスト設定 (idrac8 = 10.10.10.28)

## 検証方法

- `racadm raid get vdisks`: VD0-VD5 の 6 つが全て Online
- `racadm raid get pdisks`: 全 7 ディスクが Online
- 特に Bay 3 (以前 Blocked) が正常に VD として機能するかを確認

## 失敗時の調査手順

VD 作成が失敗した場合（racadm で VD が増えていない、PD が Ready/Blocked のまま等）:

### 調査 1: PERC BIOS スクリーンショットの確認
- VD 作成操作後にスクリーンショットを撮り、エラーメッセージの有無を確認
- 「Not enough physical disks」「PD in foreign state」等のエラー

### 調査 2: Foreign Config の確認と処理
- Bay 3 は以前 Blocked だったため Foreign Config が残っている可能性
- `racadm foreign get` で Foreign Config の有無を確認
- PERC BIOS: ルート行 F2 → ArrowDown x2 → Enter (Foreign Config) → Import / Clear

### 調査 3: PD 状態の詳細確認
- `racadm raid get pdisks -o` で全プロパティを表示
- PERC BIOS PD Mgmt タブ (Ctrl+N) で各 PD の詳細状態を確認
- State が Blocked / Foreign / Failed の場合、原因を特定

### 調査 4: ディスクごとの切り分け
- Bay 3 単体で失敗 → Bay 3 のディスク固有の問題（Foreign Config, 物理故障等）
- Bay 6 単体で失敗 → Bay 6 のディスク固有の問題
- 両方失敗 → PERC コントローラ側の問題（VD 数上限、キャッシュ等）
- PERC H710 の VD 数上限: 最大 64 VD（問題なし）

### 調査 5: Pending Jobs の確認
- `racadm jobqueue view` で未完了ジョブがないか確認
- Pending ジョブがあると新規 RAID 操作がブロックされることがある
- 必要に応じて `racadm jobqueue delete -i JIDxxx` でクリア
