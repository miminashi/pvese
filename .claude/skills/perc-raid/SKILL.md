---
name: perc-raid
description: "PERC H710 RAID セットアップ。VNC スクリーンショット + キーストロークで PERC BIOS を操作し、VD 作成・削除を行う。7-9号機対応。"
argument-hint: "<subcommand: enter|screenshot|create|delete|status>"
---

# PERC RAID スキル

Dell PowerEdge R320 (7-9号機) の PERC H710 Mini RAID コントローラを VNC 経由で操作する。
KVM スクリーンショット + キーストロークのインタラクティブ方式で PERC BIOS Configuration Utility を操作する。

| サブコマンド | 用途 |
|-------------|------|
| `enter <server>` | サーバを再起動し、POST 中に Ctrl+R で PERC BIOS に入る |
| `screenshot <server>` | 現在の VNC 画面をスクリーンショット |
| `create <server>` | 新規 VD を作成 |
| `delete <server>` | VD を削除 |
| `status <server>` | racadm で現在の RAID 構成を確認 |

## 前提条件

### VNC ビデオキャプチャのリセット

iDRAC7 VNC はセッション切断後にビデオキャプチャが停止し、再接続しても SYSTEM IDLE または黒画面になる。
**操作前に必ず `racadm racreset` で iDRAC をリセット**すること。

```sh
# Step 1: racreset (90-120秒で復帰)
./oplog.sh ssh -F ssh/config idrac8 racadm racreset

# Step 2: SSH 復帰を待機
# ホスト鍵が変わる場合がある
ssh-keygen -R $BMC_IP -f ssh/known_hosts
# SSH 接続テスト (2分程度待つ)
ssh -F ssh/config idrac8 racadm getsysinfo
```

racreset 後は VNC 接続が安定し、独立した接続でもスクリーンショットが正常に取れる。

### VNC 接続パラメータ

| 項目 | 値 |
|------|-----|
| ポート | 5901 |
| パスワード | `Claude1` |
| プロトコル | RFB 3.008 |
| 解像度 (POST) | 800x600 |
| 解像度 (PERC BIOS) | 738x414 |

### 対象サーバ

| サーバ | iDRAC IP | SSH ホスト | PERC |
|--------|----------|------------|------|
| 7号機 | 10.10.10.27 | idrac7 | PERC H710 Mini |
| 8号機 | 10.10.10.28 | idrac8 | PERC H710 Mini |
| 9号機 | 10.10.10.29 | idrac9 | PERC H710 Mini |

## ツール

### idrac-kvm-interact.py — VNC 操作

```sh
# スクリーンショット撮影
python3 ./scripts/idrac-kvm-interact.py \
    --bmc-ip $BMC_IP screenshot tmp/<sid>/perc.png

# キー送信 (最終結果のみ撮影)
python3 ./scripts/idrac-kvm-interact.py \
    --bmc-ip $BMC_IP sendkeys Ctrl+r x20 \
    --wait 2000 --screenshot tmp/<sid>/result.png --post-wait 1000

# キー送信 (各キー後にスクリーンショット)
python3 ./scripts/idrac-kvm-interact.py \
    --bmc-ip $BMC_IP sendkeys ArrowDown Enter \
    --wait 300 --screenshot-each tmp/<sid>/nav --post-wait 500

# テキスト入力
python3 ./scripts/idrac-kvm-interact.py \
    --bmc-ip $BMC_IP type "vd_name" \
    --screenshot tmp/<sid>/typed.png
```

### racadm — RAID 状態確認

```sh
ssh -F ssh/config idrac8 racadm raid get vdisks -o -p Layout,Size,Name,State
ssh -F ssh/config idrac8 racadm raid get pdisks -o -p Size,State,MediaType
ssh -F ssh/config idrac8 racadm raid get controllers
```

## PERC BIOS 進入手順

### POST タイミング (power cycle 後)

| 経過秒 | 画面 |
|--------|------|
| 0-10 | Configuring Memory |
| 10-15 | Dell BIOS ロゴ |
| 15-20 | **"Press \<Ctrl\>\<R\> to Run Configuration Utility"** |
| 20-30 | F/W Initializing → PERC BIOS 進入 |

### 進入手順

```sh
# 1. Power cycle
./oplog.sh ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 chassis power cycle

# 2. 20秒待機
sleep 20

# 3. Ctrl+R を 20回送信 (2秒間隔, screenshot なし)
#    screenshot-each はつけない (解像度変更で接続が切れるため)
python3 ./scripts/idrac-kvm-interact.py \
    --bmc-ip $BMC_IP --timeout 60 \
    sendkeys Ctrl+r x20 --wait 2000

# 4. 新しい接続でスクリーンショット確認
python3 ./scripts/idrac-kvm-interact.py \
    --bmc-ip $BMC_IP screenshot tmp/<sid>/perc_entered.png
```

**重要**: Ctrl+R の送信中に `--screenshot-each` をつけないこと。POST → PERC BIOS で解像度が 800x600 → 738x414 に変わり、フレームバッファ要求の不整合で VNC 接続が切れる。

### VNC 接続の制約

- **解像度変更**: POST (800x600) → PERC BIOS (738x414) の遷移で VNC 接続が切れることがある。再接続で回復する
- **タイムアウト**: 長時間キーを送り続けると接続がタイムアウトする場合がある
- **対策**: 操作を短いバッチに分け、各バッチで独立した VNC 接続を使う

## PERC BIOS メニュー構造

### タブ

| タブ | 切替キー | 内容 |
|------|---------|------|
| VD Mgmt | (デフォルト) | VD/DG ツリー表示、VD 作成・削除 |
| PD Mgmt | Ctrl+N | PD 一覧、状態確認 |
| Ctrl Mgmt | Ctrl+N x2 | コントローラ設定 |
| Properties | Ctrl+N x3 | コントローラプロパティ |

タブ切替: Ctrl+N (Next) / Ctrl+P (Prev)

### VD Mgmt タブの操作キー

| キー | 機能 |
|------|------|
| F1 | Help |
| **F2** | **Operations メニュー** (カーソル位置で内容が変わる) |
| F5 | Refresh |
| Ctrl+N | 次のタブ |
| Ctrl+P | 前のタブ |
| ArrowUp/Down | ツリー内移動 |
| Enter | 展開/折りたたみ |
| Escape | PERC BIOS 終了確認 |

### F2 Operations メニュー

**コントローラ行 (ルート) で F2**:
1. **Create New VD** — VD 新規作成
2. Clear Config — 全 VD 一括削除
3. Foreign Config →
4. Manage Preserved Cache
5. Security Key Management →
6. Create CacheCade Virtual Disk

**VD 行で F2**:
1. Initialization →
2. Consistency Check →
3. **Delete VD**
4. Properties
5. Expand VD size

## VD 作成手順

### Create New VD フォーム

RAID Level 選択後、ArrowDown で PD リストに移動し、Space で各 PD をトグル選択する。

**フォームのナビゲーション**:
- RAID Level → ArrowDown → PD リスト (ArrowDown で移動、Space で選択) → Tab → VD Size → VD Name → OK/CANCEL
- PD リストは **Tab ではなく ArrowDown** で到達する
- PD 選択は **Space** でトグル (選択時 `[X]`、未選択時 `[ ]`)
- 選択済み PD の `#` 列に数字が表示される

**操作シーケンス (検証済み)**:
```
1. ルート行で F2 → Enter (Create New VD)
2. RAID Level: Enter → ArrowDown x N → Enter (RAID レベル選択)
   - RAID-0: デフォルト (変更不要)
   - RAID-1: ArrowDown x1
   - RAID-5: ArrowDown x2
   - RAID-6: ArrowDown x3
   - RAID-10: ArrowDown x4
3. PD 選択: ArrowDown → Space (1本目), ArrowDown → Space (2本目), ...
4. Tab x5 → Enter (OK)
   Tab 順序: VD Size → VD Name → Advanced Settings → Secure VD → OK
5. 初期化スキップ確認: Tab → Enter (OK を選択)
```

**注意**: 初期化確認ダイアログが表示される。初期フォーカスは Cancel。Tab で OK に移動して Enter。

### サポートされる RAID レベル

| RAID | 最小 PD | 容量効率 |
|------|--------|---------|
| RAID-0 | 1 | 100% |
| RAID-1 | 2 | 50% |
| RAID-5 | 3 | (N-1)/N |
| RAID-6 | 4 | (N-2)/N |
| RAID-10 | 4 | 50% |

## VD 削除手順 (検証済み)

1. VD Mgmt タブで対象 VD の ID 行 ("ID: N, ...") にカーソル移動
2. F2 → **ArrowDown x1** → Enter (Delete VD)
   - F2 メニューの初期カーソルは **Consistency Check** (2番目)
   - Delete VD は 3 番目 → ArrowDown **x1** で到達
3. 確認ダイアログ: Tab (YES に移動) → Enter
   - 初期フォーカスは NO。Tab で YES に移動

**注意**: F2 メニューの初期位置は Consistency Check であり Initialization ではない。
ArrowDown x2 だと Properties が開くので注意。

## PERC BIOS 終了

```
Escape → "Are you sure you want to exit?" → OK (Enter)
```

## 8号機の物理ディスク構成

| Bay | Disk ID | Size | Vendor | 用途 |
|-----|---------|------|--------|------|
| 0 | 00:01:00 | 558.37 GB | HP | VD0 (system, RAID-1) |
| 1 | 00:01:01 | 558.37 GB | HGST | VD0 (system, RAID-1) |
| 2 | 00:01:02 | 837.75 GB | HITACHI | Unconfigured |
| 3 | 00:01:03 | 837.75 GB | NETAPP | Blocked |
| 4 | 00:01:04 | 837.75 GB | SEAGATE | Unconfigured |
| 5 | 00:01:05 | 837.75 GB | HITACHI | Unconfigured |
| 6 | 00:01:06 | 837.75 GB | SEAGATE | Unconfigured |

## 既知の制約

### VNC ビデオキャプチャの停止と stale framebuffer

iDRAC7 VNC は**一度ビデオキャプチャが停止すると、同一セッション外からは回復不可能**。
停止後の VNC 接続は最後にキャプチャされたフレーム（stale）を返し続ける。

- `VNCServer.Enable` の Disable/Enable → **効果なし**
- Ctrl キー (wake) → **効果なし**
- ArrowDown+ArrowUp → **効果なし**
- F5 (Refresh) → PERC BIOS は再描画するが BMC がキャプチャしない
- **racadm racreset → 唯一の回復手段** (90-120 秒)

### VNC 操作の鉄則

1. **racreset 後の最初の VNC セッション**でのみスクリーンショットが信頼できる
2. **同一セッション内**のスクリーンショットは常に正しい（BMC がアクティブにキャプチャ中）
3. **セッション切断→再接続**後のスクリーンショットは stale になる可能性が高い
4. **複数ステップの PERC BIOS 操作は 1 つの VNC セッション内で完結**させること
5. 操作結果の最終確認は **racadm** (PERC BIOS 終了後) で行う

### 推奨ワークフロー

```
1. racadm racreset → 120秒待機
2. power cycle → sleep 25
3. 単一 VNC セッションで: Ctrl+R → PERC BIOS 操作 → Escape で終了
4. POST 完了後に racadm raid get vdisks で結果確認
```

### VNC 解像度変更

POST (800x600) → PERC BIOS (738x414) の遷移で VNC 接続が切れることがある。
Ctrl+R 送信中は `--screenshot-each` をつけず、PERC BIOS 進入後に新しい接続でスクリーンショットを取る。

### Create New VD フォームの Tab 順序 (検証済み)

PD 選択後の Tab 順序:
```
PD リスト → (Tab1) VD Size → (Tab2) VD Name → (Tab3) Advanced Settings
→ (Tab4) Secure VD → (Tab5) OK → (Tab6) CANCEL → (Tab7, wraps) RAID Level
```

**OK は PD リストから Tab x5**。
初期化確認ダイアログ: 初期フォーカスは Cancel → **Tab → Enter** で OK。

### VD Mgmt ツリーのラッピング

ArrowUp/Down はツリーの先頭/末尾で**循環する**（ラップ）。
ルートからさらに ArrowUp すると最後のアイテムに移動する。
正確なアイテム数に依存するため、ArrowUp x N の N は慎重に選ぶこと。

### F2 メニューの初期カーソル位置

| F2 の対象 | メニュー | 初期カーソル |
|-----------|---------|-------------|
| ルート行 | Create New VD, Clear Config, ... | **Create New VD** (1番目) |
| VD ID 行 | Initialization, Consistency Check, Delete VD, ... | **Consistency Check** (2番目) |

### PERC BIOS と Lifecycle Controller

電源サイクル後の POST で "Lifecycle Controller: Collecting System Inventory..." が表示され、2-5 分かかることがある。この間は Ctrl+R が受け付けられない。LC 初期化が完了してから再度 power cycle して Ctrl+R を送る。

### PD の Blocked 状態

Bay 3 (00:01:03) は "Blocked" 状態で Create VD の PD リストに表示されない。物理的な問題または Foreign Config の可能性。

## 参照

- [idrac7 スキル](../idrac7/SKILL.md) — iDRAC7 基本操作
- [Dell PERC H710 User's Guide](https://dl.dell.com/manuals/all-products/esuprt_ser_stor_net/esuprtl_adapters/poweredge-rc-h310_user's%20guide_en-us.pdf)
