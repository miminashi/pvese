# TX1320 KVM 駆動ツールの scripts/ 正式昇格 + サブエージェント画像分析の標準手順化

- **実施日時**: 2026年6月1日 23:39 (JST)
- **対象**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F / BMC 10.254.254.9)
- **issue**: #73 (TX1320 BIOS メニュー RAID 削除→再作成 + スキル反映) の続き
- **セッション**: jiggly12 (plan: jiggly-toasting-peach)
- **コミット**: `81afde8`

## 添付ファイル

- [実装プラン](attachment/2026-06-01_233917_tx1320_kvm_tools_promotion_subagent_standard/plan.md)

## 参照した過去レポート

- [2026-06-01_204658 TX1320 BIOS RAID 削除→再作成 3サイクル検証 (503d9361)](2026-06-01_204658_tx1320_bios_raid_3cycle_validation.md)
- [2026-06-01_065958 TX1320 BIOS RAID 削除→再作成 (cosmic-aho)](2026-06-01_065958_tx1320_bios_raid_delete_recreate.md)

## 前提・目的

`irmc-bios-raid` スキルの per-key 画像判読は、これまで「主エージェントがインラインで
screenshot を Read する」前提で書かれており、サブエージェント委任は SKILL.md に Tips 1 行
として記載されているだけだった。また 3 サイクル検証 (503d9361) で機能した KVM 駆動・復旧
ツールは `tmp/503d9361/` / `tmp/iter/` に使い捨てのまま温存されていた。

- **目的**:
  1. サブエージェント画像分析を**スキルの標準手順に格上げ** (報告フィールド + プロンプト雛形を明記)
  2. 検証で機能した使い捨てツールを `scripts/` に**正式昇格** (認証情報の引数化・session dir パラメータ化・復旧フローの 1 スクリプト集約)
  3. 昇格物とサブエージェントフローを**実機で 2 サイクル再現検証**
- **前提条件**: 作業開始時 host=Off、VD0 (RAID0 3.272TB) が NVRAM に存在 (前検証の残置)。

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | Fujitsu PRIMERGY TX1320 M3 (D3373) |
| BMC | iRMC S4 FW **9.69F** (BMC IP 10.254.254.9) |
| RAID コントローラ | AVAGO MegaRAID PRAID EP400i (FW 03.25.05.10) |
| 物理ディスク | SAS HDD 837.843GB × 4 (Port 0-3:01:00〜03, 512B) |
| BIOS | Aptio Setup Utility v2.18.1263 |
| KVM 駆動 | `scripts/irmc-kvm/server.py` (Playwright headless, FW 9.69F cookie ログイン) |
| 真VGA 裏取り | OEM `FTSComputerSystem.Screenshot` (`scripts/irmc-oem-screenshot.sh`) |
| 画像判読 | general-purpose サブエージェント (Agent ツール) に委任 |
| 拠点間 latency | ping 34〜312ms (0% loss、変動あり) |

## 結果サマリ

**全タスク完了。削除→再作成を 2 サイクル完遂し、全段を KVM canvas + OEM 真VGA の二重で裏取り。**

| 段階 | 操作 | KVM 検証 (Virtual Drive Management) | OEM 真VGA | 判定 |
|------|------|-----------------------------------|-----------|------|
| ベースライン | (既存 VD 確認) | "Virtual Drive 0: RAID0, 3.272TB, Optimal" | baseline_vd_present_oem.jpg | ✅ |
| サイクル1 | 削除 | "no Virtual Drives currently available" | c1_del_vdm_oem.jpg | ✅ |
| サイクル1 | 再作成 | "Virtual Drive 0: RAID0, 3.272TB, Optimal" | c1_recreate_oem.jpg | ✅ |
| サイクル2 | 削除 | "no Virtual Drives currently available" | c2_del_oem.jpg | ✅ |
| サイクル2 | 再作成 | "Virtual Drive 0: RAID0, 3.272TB, Optimal" | c2_recreate_oem.jpg | ✅ |

最終状態: **VD0 RAID0 3.272TB Optimal**。確認ダイアログ commit レシピは計 4 回 (削除2 + 作成2) 成功。

## 昇格したツール (commit 81afde8)

| 昇格先 (新規) | 元 | 主な変更 |
|---|---|---|
| `scripts/irmc-kvm/_util.py` | `tmp/iter/_util.py` | ナビ/検出エンジン (stdlib + PIL のみ、自己参照 sys.path)。改変最小 |
| `scripts/irmc-kvm/fingerprints.json` | `tmp/iter/fingerprints.json` | AVAGO 画面 size 指紋。`_util.py` がロード時に要求 (実装中に判明した追加依存) |
| `scripts/irmc-kvm/kvmlib.py` | `tmp/503d9361/kvmlib.py` | FW 9.69F cookie ログイン open_viewer。`sys.path` を `__file__` 基準に修正 |
| `scripts/irmc-kvm/server.py` | `tmp/503d9361/kvm_server.py` | argparse 化 (`--bmc-ip/user/pass/--srv-dir/--idle-timeout 7200`)、`gain_control` に creds をスレッド (ハードコード除去)、`sys.path` を `__file__` 基準に |
| `scripts/irmc-bmc-reset-retry.sh` | `tmp/503d9361/bmc-reset-retry.sh` | creds 引数化 + `BMC_CURL_OPTS` env。Manager.Reset を "Blocked" の間リトライ |
| `scripts/irmc-kvm-recover.sh` | `wait-bmc-boot.sh`+`wait-post-snap.sh`+`killall.sh` 統合 | config 駆動の復旧フロー 1 スクリプト (kill→forceoff→reset-retry→poll→boot-override BiosSetup+on→POST 待ち→OEM 裏取り) |

**昇格しなかったもの**: `cycle_runner.py` (caret 盲信欠陥)、`pw.sh`/`snap.sh` (既存スクリプトの薄ラッパー)。
`tmp/503d9361/` `tmp/iter/` はコピー元として温存。

## SKILL.md の変更

- 新節「🆕 標準手順: スクリーンショット分析はサブエージェントに委任する」を追加。
  - per-key の各 `shot` は主エージェントが直接 Read せず general-purpose サブエージェントに委任。
  - 報告 6 項目 (選択タブ / カーソル反転背景行 / 右ヘルプ全文 / ダイアログ状態 / 黒画有無 / 見出し) + コピペ用プロンプト雛形。
- 旧 Tips (知見7) を「標準手順へ昇格済」に書換。
- ツール参照を `tmp/503d9361` → `scripts/` に更新、「昇格済みツール (scripts/) と使い方」節を追加。
- 実機検証で判明した新知見を「KVM セッション運用の知見」に追記 (下記)。

## 新たに確立した知見 (実機検証 jiggly12)

1. **🆕🆕 modal ダイアログを開くと KVM canvas がキーボードフォーカスを失う** — Clear/Save
   Configuration 確認ダイアログ・Confirm ドロップダウン・OK メッセージボックスを開いた直後は、
   `press` した矢印キーが**全て silent drop** される。静的マーカー ▶No に騙されて「効いていない」
   と誤認するが実際は届いていない。**対策: ダイアログを開いたら必ず実マウスクリック
   `mouse 512 384` を 1 回送ってフォーカスを再確立してから**ダイアログキーを送る。`focus`
   コマンド (force-click) では不十分で、`mouse` の実クリックが必要。メニュー階層のキーは
   フォーカス喪失の影響を受けない (ダイアログ限定)。Aptio はマウスで選択を動かさないので
   画面中央の空白 `mouse 512 384` はカーソル位置を壊さず安全。
   - 補足: 永続セッション起動直後も同様で、最初に `mouse 512 384` を 1 回送ると F1/矢印キーが
     効くようになる (gain_control の制御テストは canvas 描画差分で誤って成功判定することがある)。
2. **🆕🆕 ダイアログ内 cursor 位置は「Confirm ドロップダウンが開くか」で決定的判定** —
   reverse-highlight は間欠的に非描画になり ▶No は静的なので画面から位置が読めない。
   `ArrowUp×2 → Enter` で Confirm ドロップダウン (Disabled/Enabled) が開けば cursor は
   Confirm 行にいた証拠。最終 commit の `ArrowDown→Enter` も結果で分岐してよい:
   成功メッセージ=Yes 成功 / ドロップダウン再展開=Confirm 上 (Arrow drop) / メニュー復帰=No 上。
   Yes 以外は全て非破壊なので安全にリトライできる。
3. **右ヘルプペインの説明文が cursor 位置の最も信頼できる真実** — reverse-highlight が
   描画されないメニューでも、右ヘルプ文言で行を一意に特定できる (例: "Deletes all existing
   configurations..." = Clear Configuration)。判読サブエージェントには必ず右ヘルプ全文を報告させる。
4. **Config Management メニューは VD 作成/削除直後も stale** (前検証どおり)。VD 有無の最終判定は
   必ず Virtual Drive Management で行う。
5. **`recover.sh` の Manager.Reset は非同期** — reset 受理後に BMC がすぐ落ちず、poll が即
   「応答あり」で抜けて次の Redfish 呼出が connection refused になるレースがあったため、
   reset 後に 90s の settle 待機 + boot-override のリトライを実装で追加 (commit 済)。

## 再現方法

### 0. 健全な KVM セッションの確立 (host=Off から)
```sh
./oplog.sh ./scripts/irmc-kvm-recover.sh config/training_tx1320.yml tmp/<sid>/recover-pre.jpg 170
# recover-pre.jpg をサブエージェントで判読し BIOS Setup 到達を確認
```

### 1. 永続 KVM サーバ起動 (run_in_background)
```sh
.venv/bin/python scripts/irmc-kvm/server.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --srv-dir tmp/<sid>/srv
# "=== KVM server READY ===" を待つ
```

### 2. per-key 操作 + サブエージェント判読
`tmp/<sid>/srv/in/NNN.cmd` (1 行 1 コマンド: `press`/`keyrepeat`/`mouse`/`shot`/`sleep`/`quit`)
を投入 → `NNN.done` 出現待ち → `tmp/<sid>/srv/shots/<name>` を **general-purpose サブエージェント**
に渡して構造化報告 (報告 6 項目)。確立済みナビ・レシピ:
- ナビ: `mouse 512 384` (初回フォーカス) → Main→ArrowRight→Advanced→ArrowDown×14→AVAGO→Enter→Main Menu
- 削除: Configuration Management → Clear Configuration → Enter → **(ダイアログ後 `mouse 512 384`)**
  → `ArrowUp×2→Enter` (Confirm dropdown) → `ArrowDown→Enter` (Enabled) → `ArrowDown→Enter` (Yes commit) → OK Enter
- 作成: Create Virtual Drive → ArrowDown で Select Drives → Enter → ArrowDown×8 Check All → Enter
  → ArrowDown×2 Apply Changes → Enter → OK → form → Save Configuration → Enter →
  **(ダイアログ後 `mouse 512 384`)** → 同 commit レシピ → OK Enter → 2nd msg Escape

### 3. 各サイクルの裏取り
```sh
./scripts/irmc-oem-screenshot.sh 10.254.254.9 claude Claude123 tmp/<sid>/cN_xxx_oem.jpg 12 5
```
KVM (Virtual Drive Management) と OEM 真VGA の両方で VD 有無を確認。

## 未解決・残課題

- RAID10 の KVM HII 自動作成は依然 dead-end (Select RAID Level 到達不可)。検証はフォーム既定 RAID0。
- 矢印キーの間欠 silent drop / mis-registration は残存。1 キー/1 コマンド + 十分な待機 +
  右ヘルプ/dropdown プローブでの裏取りで実用上は確実に運用できるが、無人 N サイクル自動化は
  依然非推奨 (per-key 手動 + サブエージェント判読が最も安定)。
- `scripts/irmc-kvm/server.py` の `gain_control` 制御テスト (ArrowRight タブ切替) は canvas 描画差分で
  誤成功判定することがある → 起動後に `mouse 512 384` で明示フォーカスする運用を推奨。
