# TX1320 BIOS RAID 削除→再作成 3サイクル検証 + irmc-bios-raid スキル堅牢化

- **実施日時**: 2026年6月1日 20:46 (JST)
- **対象**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F / BMC 10.254.254.9)
- **issue**: #73 (TX1320 BIOS メニュー RAID 削除→再作成 + スキル反映)
- **セッション**: 503d9361 (crystalline-bengio を継承)

## 添付ファイル

- [実装プラン](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/plan.md)
- [per-key 操作ログ (CYCLE_LOG)](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/CYCLE_LOG.md)
- OEM 真VGA 裏取り画像: [baseline](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/baseline_vdm_oem.jpg) /
  [c1 削除](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/c1_del_oem.jpg) /
  [c1 再作成](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/c1_recreate_oem.jpg) /
  [c2 削除](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/c2_del_oem.jpg) /
  [c2 再作成](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/c2_recreate_oem.jpg) /
  [c3 削除](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/c3_del_oem.jpg) /
  [c3 再作成](attachment/2026-06-01_204658_tx1320_bios_raid_3cycle_validation/c3_recreate_oem.jpg)

## 参照した過去レポート

- [2026-06-01_065958 TX1320 BIOS RAID 削除→再作成 (cosmic-aho、確認ダイアログレシピ確立 + 訂正)](2026-06-01_065958_tx1320_bios_raid_delete_recreate.md)
- [2026-05-17_101536 TX1320 RAID10 dead end](2026-05-17_101536_tx1320_raid10_dead_end.md)

## 前提・目的

`irmc-bios-raid` スキルを堅牢化するため、training-tx1320 の BIOS メニュー (AVAGO MegaRAID HII / Aptio Setup Utility) を iRMC S4 KVM (HTML5) 経由で操作し、**RAID0 仮想ドライブの削除→再作成を 3 サイクル反復**して、前セッションで確立した自動操作レシピの**反復再現性**を検証する。

- **背景**: 前セッション (cosmic-aho) で確認ダイアログ自動操作レシピを確立し削除→再作成を 2 回成功させたが、当初指示の反復回数は未達。さらに自律ループ (`cycle_runner.py`) は caret_y=393 を盲信して Enter する欠陥で Intel NIC 設定画面へ誤入し「完遂」と誤報告する事故を起こした。
- **目的**: per-key 手動 (1キーごとに screenshot で画面文字を確認) で 3 サイクル完走し、各サイクルを OEM 真VGA で裏取りする。検証で実際に機能したツールとレシピをスキルへ反映する。
- **前提条件**: host は作業開始時に Off。当初は「VD0 が存在」との引き継ぎだったが、**実機の真の状態は VD なし (空)** と 3 経路 (AVAGO ダッシュボード PROPERTIES / OEM 真VGA / Virtual Drive Management) で確定。このためまず**ベースライン VD を作成**してから 3 サイクルを実施した。

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | Fujitsu PRIMERGY TX1320 M3 |
| BMC | iRMC S4 FW 9.69F (BMC IP 10.254.254.9) |
| RAID コントローラ | AVAGO MegaRAID PRAID EP400i (FW 03.25.05.10、LSI SAS3008) |
| 物理ディスク | SAS HDD 837.843GB × 4 (Port 0 - 3:01:00〜03、Unconfigured Good、512B) |
| 作成した VD | RAID0 / 4 ドライブ / 3.272 TB / Strip 256KB (フォーム既定値) |
| BIOS | Aptio Setup Utility (AMI) v2.18.1263 / Core 5.0.0.11 |
| KVM 接続 | Playwright (headless Chromium) で iRMC HTML5 KVM viewer を駆動。FW 9.69F は cookie ベースログイン |
| 真VGA 裏取り | OEM `FTSComputerSystem.Screenshot` (`scripts/irmc-oem-screenshot.sh`) |

> ⚠️ RAID10 の KVM HII 作成は依然 dead-end (Create VD form の `Select RAID Level` 行に到達不可、2026-05-17 確定)。本検証は**フォーム既定の RAID0** で実施した。

## 結果サマリ

**全 3 サイクル完遂。削除レシピ ×3 + 作成レシピ ×4 を全て KVM canvas + OEM 真VGA の二重で裏取り。**

| 段階 | 操作 | KVM 検証 (Virtual Drive Management) | OEM 真VGA 裏取り | 判定 |
|------|------|-----------------------------------|-----------------|------|
| ベースライン | 作成 | "Virtual Drive 0: RAID0, 3.272TB, Optimal" | baseline_vdm_oem.jpg | ✅ |
| サイクル1 | 削除 | "no Virtual Drives currently available" | c1_del_oem.jpg | ✅ |
| サイクル1 | 再作成 | "Virtual Drive 0: RAID0, 3.272TB, Optimal" | c1_recreate_oem.jpg | ✅ |
| サイクル2 | 削除 | PROPERTIES "Virtual Drives 0" | c2_del_oem.jpg | ✅ |
| サイクル2 | 再作成 | "Virtual Drive 0: RAID0, 3.272TB, Optimal" | c2_recreate_oem.jpg | ✅ |
| サイクル3 | 削除 | "no Virtual Drives currently available" | c3_del_oem.jpg | ✅ |
| サイクル3 | 再作成 | "Virtual Drive 0: RAID0, 3.272TB, Optimal" | c3_recreate_oem.jpg | ✅ |

> ⚠️ **検証方法の注記**: サイクル2 削除のみ、復旧後 AVAGO ダッシュボードに着地したため **ダッシュボード PROPERTIES "Virtual Drives 0" で判定**した (c1/c3 削除は Virtual Drive Management の "no Virtual Drives" で判定)。後述のとおりダッシュボードのカウントは原則 stale で最終判定には非推奨だが、本ケースでは (a) KVM と OEM の両方が同じ "Virtual Drives 0" を示し、(b) 直後のサイクル2 再作成時に Config Management が空構成 (Create VD 系3項目) を表示=削除反映済みであることが裏取りされ、(c) 再作成が VDM で成功確認された、の3点で間接的に整合を担保している。**厳密には c2 削除の一次検証は VDM でやり直すのが望ましい** (本筋の結論は変わらない)。

最終状態: **VD0 RAID0 3.272TB Optimal が存在**。確認ダイアログ commit レシピは計 **7 回** (作成 4 + 削除 3) 連続成功。

途中、サイクル2 削除 commit 直後に KVM サーバが idle timeout (7200s) で master を喪失したが、復旧フロー (ForceOff → BMC Manager.Reset → BIOS Setup 再起動 → KVM サーバ再起動) で**完全復旧し、RAID 状態は NVRAM 永続のため無影響**で 3 サイクルを完走した。

## 確立したレシピ (スキル昇格済み)

### ナビ: BIOS Main → AVAGO ダッシュボード
`Main → ArrowRight (Advanced、先頭 Onboard Devices Configuration) → ArrowDown×14 → AVAGO 行 (右ヘルプ "Manage RAID Controller Configurations.") → Enter`

### 作成レシピ (4 回成功)
`ダッシュボード → Enter (Main Menu) → Configuration Management (Enter) → Create Virtual Drive (Enter) → form (RAID0 既定) → ArrowDown×2〜3 で "Select Drives" (▶、右ヘルプ "Dynamically updates to display as Select Drives...") → Enter → popup → ArrowDown×8 で Check All → Enter (4台 [Enabled]) → ArrowDown×2 で Apply Changes → Enter → OK (Enter) → form 戻り (Size 3.272 TB 自動) → Save Configuration (Enter) → 確認ダイアログ → コミットレシピ → OK (Enter) → 2nd msg → Escape`

### 削除レシピ (3 回成功)
`Main Menu → Configuration Management (Enter) → Clear Configuration (右ヘルプ "Deletes all existing configurations on the RAID controller.") → Enter → 確認ダイアログ → コミットレシピ → OK (Enter 1 回で閉じる、Escape 不要)`

### コミットレシピ (確認ダイアログ、作成/削除共通、7 回成功)
状態: `Confirm [Disabled] / Yes / No`、**▶No は静的マーカーで実フォーカスを示さない**。
`ArrowUp×2 (Confirm へ) → Enter (ドロップダウン) → ArrowDown (Enabled へ) → Enter (Confirm [Enabled] 化) → ArrowDown (Yes へ) → Enter (commit)`
**裏取り必須**: (1) Confirm [Enabled] 化を確認、(2) ArrowDown 後に **Yes の反転背景 (ハイライト)** を確認してから最後の Enter。判定は ▶ でなく反転背景で。

### 検証
`Main Menu → Virtual Drive Management → Enter`。
- VD あり: `"Virtual Drive 0: RAID0, 3.272TB, Optimal"`
- VD なし: `"Unable to display Virtual Drive summary as there are no Virtual Drives currently available."`

## 新たに確立したハードニング知見

1. **KVM canvas にスクリーンショット遅延がある** — press が登録済でも直後の shot が 1 つ前の stale フレームを返す。press 後に `sleep 2.5` を挟んでから shot を撮る。盲目で「効いてない」と判断して再送するとオーバーシュートする (復旧時 ArrowLeft 2 連で実証)。
2. **コミット確認ダイアログは 2 段階に分けて裏取り** — Confirm [Enabled] 化を確認 → ArrowDown 後に Yes の反転背景を確認 → commit。盲目の一括送信はしない。
3. **Create VD form の Select Drives ナビは ArrowDown×2 が 1 手前 (Select Drives From) に着地する場合がある** — キードロップ。右ヘルプ "Dynamically updates to display as Select Drives..." で確認し ±1 キー補正。`CONFIGURE VIRTUAL DRIVE PARAMETERS` ヘッダ行はカーソルがスキップ。
4. **作成完了の 2 つ目メッセージは Escape / 削除完了の OK は Enter 1 回** — 挙動差。
5. **ArrowDown が稀に ArrowRight に誤登録**しタブ移動 (Advanced→Security) が起きる → 都度タブ名を確認、ズレたら ArrowLeft で戻す。
6. **Config Management メニューは stale** — 削除/作成後も古い項目構成を残す → 必ず Virtual Drive Management で裏取り。
7. **アイドルタイムアウトからの復旧フローを実証** — `killall.sh → pw.sh forceoff → bmc-reset-retry.sh → wait-bmc-boot.sh → wait-post-snap.sh → kvm_server.py 再起動`。RAID は NVRAM 永続で無影響。
8. **画像分析はサブエージェントに委任** (ユーザ指示) — 各 screenshot を general-purpose サブエージェントに Read させ「選択タブ / カーソル行 / 右ヘルプ / 反転背景 / 黒画有無」を構造化報告させる方式が確実。

## 補足知見 (運用ニュアンス)

本筋 (3サイクル完遂・レシピ確定) を変えるものではないが、無人化・効率化の際に有用な実務ニュアンス:

1. **Apply Changes は wrap して上部/下部どちらに着地しても等価** — drives popup で Check All の後 `ArrowDown×2` が「下部 Apply Changes」でなく wrap して「上部 Apply Changes」に着地することがある (c3 で観測)。ただし上部・下部とも右ヘルプは同一 `"Submits the changes made to the entire form."` で機能も同一なので、どちらに着地しても Enter でよい。
2. **Select Drives ナビのキードロップは散発** — `ArrowDown×2` での Select Drives 着地は **4回中3回はピタリ (baseline/c1/c2)、ドロップ (1手前=Select Drives From) は c3 の1回のみ**。±1キー補正が要るのは散発で、大半は素直。
3. **OEM 真VGA スクショは初回空振り→retry することがある** — `snap.sh` (irmc-oem-screenshot.sh) は c2/c3 で `Preview not available after 12s, retrying` の後 attempt 2 で成功 (baseline/c1 は 1 回で成功)。OEM 撮影は時々 1 回目が空振りするため retry 前提で扱う (スクリプトの retry 機構が吸収)。
4. **KVM セッションを正常終了させてから切ると次の master 取得が速い** — 今回のアイドルタイムアウトは KVM サーバが `exit 0` で正常終了したため lingering master が残らず、復旧後の**初回接続でいきなり master 取得** (attempt 1.2, delta +3278)。cosmic-aho の「BMC reset 直後は slave 着地でリトライ要」とは異なり、close を伴わない正常終了は次接続を速くする。
5. **Config Management メニューは「2項目構成」と「3項目構成」があり、stale は非決定的** —
   - VD あり時の正常表示 = `View Drive Group Properties / Clear Configuration` (2項目)
   - VD なし時の正常表示 = `Create Virtual Drive / Create Profile Based Virtual Drive / Clear Configuration` (3項目)
   - 操作直後は前状態の項目構成を残す (stale) が、**回によって stale になったりならなかったり** (c3 削除後 cmd606 は削除済なのに2項目を残し、一方 cmd600 では正しく表示)。
   - 実務影響: 削除時の Clear Configuration 行位置が構成で変わる (2項目なら ArrowDown 1、3項目なら ArrowDown 2)。**行位置を固定で送らず、必ず行テキスト + 右ヘルプ `"Deletes all existing configurations..."` を確認してから Enter**。最終的な VD 有無判定は常に Virtual Drive Management で行う。

## 再現方法

### 0. 健全な KVM セッションの確立 (host=Off から)
```sh
sh tmp/<sid>/killall.sh
./oplog.sh sh tmp/<sid>/pw.sh forceoff          # host Off 確認
./oplog.sh sh tmp/<sid>/bmc-reset-retry.sh      # Manager.Reset (host Off 必須)
./oplog.sh sh tmp/<sid>/wait-bmc-boot.sh        # BMC 復帰 + boot-override BiosSetup + power on
sh tmp/<sid>/wait-post-snap.sh                  # POST 待ち + OEM で BIOS 到達確認
.venv/bin/python tmp/<sid>/kvm_server.py        # run_in_background、=== KVM server READY === を待つ
```

### 1. per-key 操作
`kvm_server.py` のコマンドファイル (`srv/in/NNN.cmd`、1 行 1 コマンド: `press <key> [ms]` / `keyrepeat <key> <n> [ms]` / `sleep <s>` / `shot <name>`) を投入し、`srv/in/NNN.done` 出現を待ってから `srv/shots/<name>` をサブエージェントで分析。上記レシピに従い 1 キーずつ進める。

### 2. 各サイクルの裏取り
```sh
sh tmp/<sid>/snap.sh c<N>_del_oem        # 削除後 OEM
sh tmp/<sid>/snap.sh c<N>_recreate_oem   # 再作成後 OEM
```
削除後: VD 不在、再作成後: "Virtual Drive 0: RAID0, 3.272TB, Optimal" を OEM 画像で確認。

## ツール昇格の内訳

| ツール (`tmp/503d9361/`) | 機能 | 判断 |
|----|------|------|
| `kvm_server.py` | 永続 KVM セッション + コマンドファイル駆動 (idle 7200s) | スキルに参照記載。次回 scripts/ 正式昇格候補 |
| `kvmlib.py` | FW 9.69F cookie ログイン open_viewer | 同上 (既存 `scripts/irmc-kvm-interact.py` と統合してから移すべき) |
| `pw.sh` / `snap.sh` / `killall.sh` / `bmc-reset-retry.sh` / `wait-bmc-boot.sh` / `wait-post-snap.sh` | 電源/復旧/OEM 撮影フロー | スキルの復旧フロー節に手順記載済 |
| `cycle_runner.py` | 自律ループ | **昇格しない** (caret 盲信欠陥、前セッションで NIC 誤入の原因) |

> 今回は per-key レシピとハードニング知見の**スキル + メモリ反映**を優先し、scripts/ への正式昇格 (重複整理込み) は次回に持ち越した。確立済みツールは `tmp/503d9361/` に温存。

スキル反映先: `.claude/skills/irmc-bios-raid/SKILL.md` の新節「🎯🎯🎯 2026-06-01 (503d9361): 削除→再作成 3 サイクル完遂」。

## 未解決・残課題

- RAID10 の KVM HII 自動作成は依然 dead-end (Select RAID Level 到達不可)。RAID0/1/5/6 のみ可。
- 確立済みツール (`kvm_server.py` 等) の `scripts/` 正式昇格 (既存 `irmc-kvm-*.py` との重複整理込み) は次回。
- 無人 N サイクル自動ループは依然非推奨 (per-key 手動 + サブエージェント画像分析が安定)。
