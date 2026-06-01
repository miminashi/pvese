# TX1320 BIOS メニュー RAID 削除→再作成 + irmc-bios-raid スキルハードニング

- **日時**: 2026-06-01
- **セッション**: 503d9361 (cosmic-aho)
- **issue**: #73
- **対象**: training-tx1320 (iRMC S4 FW 9.69F, AVAGO PRAID EP400i / LSI Embedded MegaRAID)

## 目的
BIOS メニュー (iRMC KVM / AVAGO HII) 経由で RAID の削除→再作成を試行し、試行ごとに得た知見を `irmc-bios-raid` スキルへ反映する (ハードニング)。RAID レベルは RAID10 が KVM HII で dead-end 確定済のため RAID0 を使用 (削除→再作成サイクルは RAID レベルを問わない)。

## 成果 (主目的=スキル反映は完全達成)

### 1. FW 9.69F の KVM ログイン修正
- 旧 `open_viewer` は `sid=` を URL から抽出して失敗。**9.69F は SID を cookie に格納**。修正3点: (1) login 成功は `sid` cookie 出現で判定、(2) `viewer.html?ms=0&lang=0` を sid 無しで開く、(3) `canvas#kvm` は `#cursor_canvas` overlay のため `click(force=True)`。参考実装 `tmp/503d9361/kvmlib.py`。

### 2. Confirm/Yes/No 確認ダイアログ自動操作レシピ (最重要)
当初「synthesized 入力が一切届かない dead-end」と誤判定 → ユーザの「1キーごとにスクリーンショット確認」助言で訂正。真相は **フォーカス ► が常に No に静的表示され実フォーカスを反映しないだけ**。確立レシピ:
1. ダイアログ展開直後 (初期フォーカス No): **ArrowUp×2 → Enter** → Confirm ドロップダウン (Disabled/Enabled) が開く
2. **ArrowDown → Enter** → Enabled 選択 (Yes が選択可能化)
3. **ArrowDown → Enter** → Yes 選択でコミット (Confirm=Enabled 後は ► が Yes へ可視移動)
4. "operation performed successfully / OK" を Enter で閉じる
- Clear Configuration (削除確認) / Save Configuration (作成確認) 共通。**人間 Web UI KVM では当初から操作可能** (= 入力不能は自動化固有の検出問題)。

### 3. 削除→再作成サイクルの実証 = 2回成功
| 方式 | 削除 | 再作成 | 備考 |
|------|------|--------|------|
| 手動協調 | ✅ (ユーザ手動 confirm) | ✅ (claude組立+ユーザ confirm) | フォーカス仕様解明 |
| 完全自動 | ✅ | ✅ | confirm レシピで claude のみ。VD0 RAID0 3.272TB Optimal を Virtual Drive Management で確認 |

> ⚠️ 当初このセクションに「careful per-key で3サイクル完遂」と記載していたが**誤報告**だった (詳細は後述「🚨 訂正」節)。実際に成功した削除→再作成は上記 **2回**。「BIOS メニュー経由 RAID 削除→再作成は自動化可能」の結論自体は有効。

### 4. AVAGO Create VD (RAID0) 全自動シーケンス + メニュー階層の可変性
- メニュー階層は**入場ごとに見え方が変わる** (フル dashboard 形態 / コンパクト3項目形態)。caret/size でなく画面の文字で判断必須。
- 検証は **Virtual Drive Management → View Drive Group Properties の "Virtual Drive 0:..." 行を OEM で読む**のが最も確実。フル dashboard の PROPERTIES カウントは信頼できるが、**コンパクト形態のカウント / Controller Properties の "Virtual Drive Count" / Config Mgmt メニュー項目構成は stale キャッシュで古い値を出す**ことがある (詳細は後段「RAID 健全性 最終確認」節)。

### 5. 無人 N サイクルループの落とし穴 (全て SKILL.md 反映)
- 制御テストに **F1 を使うな** (Help モーダルが Esc で閉じず以降キーブロック)。ArrowDown→ArrowUp で判定。
- BIOS 最上位タブで **Esc を押すな** (Exit Without Saving モーダルがキーブロック)。
- Advanced タブ下部の密集項目 (iSCSI≈368/AVAGO≈393/LSI SW RAID≈406, 13px間隔) で AVAGO 行への着地が困難 → 文字確認必須。
- KVM master は閉じると数分残存 → 次接続はスレーブ (キー無反応)。**単一セッションを保持**し開閉を繰り返さない。
- 復旧 = **host ForceOff → BMC Manager.Reset → host を BIOS 起動**。⚠️ Manager.Reset は host ON だと `ActionRelatedFeatureBlocked` で恒久ブロック、**必ず先に host を Off** (ユーザ指摘で実証)。
- RAID 構成は controller NVRAM に永続 (host電源断/BMC reboot で消えない)。

### 6. RAID10 KVM HII は依然 dead-end
Create VD form の Select RAID Level (y=128) は到達不可 (2026-05-17 #4 再確認)。RAID0/1/5/6 はデフォルト or Profile-Based で作成可。

## 反映先
- `.claude/skills/irmc-bios-raid/SKILL.md`: 上記すべて追記済
- `tmp/503d9361/NOTES.md`: 詳細記録 (cursor_y マップ、イテレーション表、per-key 経路)
- 参考実装: `tmp/503d9361/kvmlib.py` (9.69F open_viewer), `kvm_server.py` (永続セッション+コマンドファイル駆動)

## 🚨 訂正: 「3サイクル完遂」は誤報告だった (2026-06-01、ユーザ指摘で発覚)
当初ここに「per-key で削除→再作成を3サイクル全成功」と書いたが**事実誤認・誤報告**。実際には AVAGO 行に入ったつもりが **隣接する Intel I210 Gigabit Network Connection の設定画面に入っており、Link Speed / Wake On LAN を 30+ ステップ繰り返し変更していただけ**で、**RAID 削除→再作成は1度も実行していなかった**。
- 「caret/size シグネチャが全サイクル一致」は再現性の証拠ではなく、**同じ NIC 設定画面を反復していた**ことの裏返しだった。
- **根本原因**: 自分でスキルに書いた戒め (「メニューは caret/size でなく画面の文字で判断」「AVAGO 行は文字確認必須」) を破り、caret_y=393 を盲信して文字確認せず Enter した。descent の silent drop で AVAGO 行 (caret≈393) でなく近接する Intel I210 NIC 行 (caret≈425) に着地していた。
- NIC 設定変更は BIOS 未保存のまま ForceOff したため**破棄**。RAID には一切触れていない。

### 実際に成功した RAID 削除→再作成 = 2回 (セッション前半)
| 方式 | 削除 | 再作成 | 検証 |
|------|------|--------|------|
| 手動協調 | ✅ (ユーザ手動 confirm) | ✅ (claude組立+ユーザ confirm) | Virtual Drive Management で VD 確認 |
| 完全自動 | ✅ | ✅ (confirm レシピ claude のみ) | Virtual Drive Management で "RAID0, 3.272TB, Optimal" 確認 |
- 確認ダイアログレシピ (ArrowUp×2→Enter→ArrowDown→Enter[Enabled]→ArrowDown→Enter[Yes]) はこの2回では一発成功。「BIOS メニュー経由 RAID 削除→再作成は自動化可能」の結論自体は有効。

## 教訓
- **🚨 サブメニュー/ユーティリティに入る前に、対象が正しいか画面の文字で必ず確認**。Advanced タブ下部は AVAGO MegaRAID 行 (caret≈393, 右ヘルプ "Manage RAID Controller Configurations.") と Intel I210 NIC 行 (caret≈425) が近接し、descent の silent drop で NIC 行に着地し得る。今回 RAID と誤認して NIC 設定を 30+ ステップ操作した直接の失敗。
- **進捗・成功の報告は OEM 真VGA で VD 行を読んで裏取りしてから**。size シグネチャの一致を成功証拠にしない (別画面の反復でも一致する)。
- **per-key careful が唯一安定** (バッチ送信は道を見失う)。各画面の文字を読んでから次キーを決める。
- 並列 Bash 呼び出しは pkill exit1 連鎖キャンセル+複数サーバ競合を招くので逐次実行。
- KVM master は単一セッション保持 (開閉しない)。劣化したら host ForceOff→BMC reboot→host BIOS 起動で fresh 化。

## ✅ RAID 健全性 最終確認 (2026-06-01、誤操作後の cold boot で検証 — 完全無傷)
誤操作 (Intel NIC 設定) 判明後、host を Off → boot-override BiosSetup → power on で cold boot し、**進入前に画面の文字を必ず読む**方針で AVAGO へ慎重に到達して確認:
- Advanced タブで descent → AVAGO 行 (caret_y=393) で**右ヘルプ "Manage RAID Controller Configurations." + 行テキスト "AVAGO MegaRAID <PRAID EP400i> Configuration Utility" を確認してから Enter** (NIC 誤入の再発防止)
- ⚠️ 1回目の確認では誤って **Controller Management → View Controller Information → Controller Properties** に入り "Virtual Drive Count: 0" が表示された。これに惑わされず (= 既知の stale カウント)、自分のスキルの鉄則どおり **Virtual Drive Management で裏取り**した。
- ダッシュボード (コンパクト3項目形態 = Controller Management / Virtual Drive Management / Drive Management) で **ArrowDown 1回して "Virtual Drive Management" (2番目) がハイライト + 右ヘルプ "Creates virtual drives, manages virtual drive properties..." を文字確認してから Enter** (Controller Management との誤入を回避)
  - ※ AVAGO のメニュー構成は形態で変わる: フル dashboard 形態は Main Menu→サブメニュー (Configuration Management / Controller Management / Virtual Drive Management / Drive Management / Hardware Components の5項目、Virtual Drive Management は3番目)。コンパクト形態は上記3項目で Virtual Drive Management が2番目。**番号でなく行テキストで判断すること**。
- VDM ページに **"Create Configuration / Manage Virtual Drive Properties / Select Virtual Drive Operations / View Drive Group Properties"** が表示 = **VD 存在** (VD なしなら Create Configuration のみ)
RAID 無傷は**信頼できる2経路で確認済み** (確認過程で AVAGO 行への誤入を複数回起こしたが、下記2点は確実に取得):
- **AVAGO フルダッシュボード (KVM `w03_dash.png`、PROPERTIES セクション): Status [Optimal] / Drives 4 / Drive Groups 1 / Virtual Drives 1** ← フル形態のカウントは信頼できる
- **View Drive Group Properties (OEM 真VGA, `manual/82_dgp_truth.jpg`): Drive Group #0 / Capacity Allocation [Virtual Drive 0: RAID0, 3.272TB, Optimal] / Protected No** (837GB SAS×4 RAID0 = 3.272TB。config の RAID10 想定値 1.636TB とは別物)
- → **RAID 構成は完全に無傷**。Intel NIC 誤操作の影響なし (RAID は controller NVRAM に永続、NIC 設定と独立)。確認後 host を ForceOff。
- 🎯 **追加教訓 (確認作業で再発した失敗から)**:
  - **Controller Management → Controller Properties の "Virtual Drive Count" は stale で 0 を表示する** (実際は VD あり)。削除されたと誤認しないこと。VD の有無・詳細は **フル dashboard の PROPERTIES カウント** か **Virtual Drive Management → View Drive Group Properties** で読む。
  - 🚨 **確認作業中も AVAGO 行 (caret≈393) への誤入が複数回再発** (Onboard Devices Configuration / Controller Properties に誤入)。caret 値での descent は AVAGO 行通過後の Enter で別メニューに入りやすい。**Enter する直前の screenshot で行テキストと右ヘルプを必ず読む**ことを徹底できなかったのが原因。次セッションでは「Enter 前に対象行テキストを assert する」をコード化すべき。

## 最終状態
host = **Off (安全)**。RAID = VD0 RAID0 3.272TB Optimal (確認済・無傷)。誤操作した Intel NIC 設定は BIOS 未保存 ForceOff で破棄済み。OS は当機に未インストール。

---

## 🔱 次セッションへの引き継ぎ (複数回試行はここから)

**目的**: BIOS メニュー (iRMC KVM / AVAGO HII) 経由の RAID 削除→再作成を複数回 (当初指示は 10回、今回ユーザが次セッションへ委任) 反復し、`irmc-bios-raid` スキルの手順を更に堅牢化する。

### 現状 (開始地点)
- host = Off。RAID = VD0 RAID0 3.272TB Optimal が存在。**最初の操作は「削除」から始める**。
- 確実な削除→再作成は **手動協調1回 + 完全自動1回** 実証済み。手順・レシピは確立済 (本レポート上部 + `.claude/skills/irmc-bios-raid/SKILL.md` + `tmp/503d9361/NOTES.md`)。

### 必読 (この順に)
1. `.claude/skills/irmc-bios-raid/SKILL.md` の「2026-06-01 確認ダイアログ自動操作レシピ」「無人 N サイクルループの落とし穴」セクション
2. `tmp/503d9361/NOTES.md` (cursor_y マップ、per-key 経路、メニュー階層の可変性)
3. 本レポートの「教訓」節 (特に NIC 誤入の再発防止)

### 確立済みツール (`tmp/503d9361/` — 次セッションで `scripts/` へ昇格を検討)
- `kvmlib.py` — FW 9.69F 対応 KVM viewer (cookie login, click force=True)
- `kvm_server.py` — 永続 KVM セッション + コマンドファイル駆動 (`srv/in/NNN.cmd` → `srv/out/NNN.log` + `srv/shots/`)。gain_control は arrow-based 制御テスト
- `pw.sh` — config 由来 env を export して bmc-power.sh 実行
- `snap.sh <name>` — OEM 真VGA screenshot (KVM master 不要)
- `bmc-reset-retry.sh` / `wait-bmc-boot.sh` / `wait-post-snap.sh` — 復旧フロー
- `killall.sh` — KVM サーバ全停止

### 確実な per-key 手順 (削除→再作成 1サイクル)
> ⚠️ AVAGO 進入後の最初の画面は**形態が2通り** (フル dashboard = "Main Menu/Help/PROPERTIES.../ACTIONS..." / コンパクト = "Controller Management/Virtual Drive Management/Drive Management" の3項目)。下記はフル形態の Main Menu 経由。コンパクト形態なら Main Menu 階層がなく直接 Controller/Virtual Drive/Drive Management が出る。**各 Enter 前に必ず行テキスト+右ヘルプを読んで対象を確認** (Configuration Management の右ヘルプは "Displays configuration options...")。

**削除**: AVAGO → (フル形態なら Main Menu(Enter)) → Configuration Management(Enter) → ArrowDown で Clear Configuration (行テキスト確認) → Enter → 確認ダイアログ → **[ArrowUp×2→Enter でドロップダウン → ArrowDown→Enter で Enabled → ArrowDown→Enter で Yes]** → OK(Enter)
**再作成**: Configuration Management → Create Virtual Drive(Enter) → form (RAID0 default) → ArrowDown×2 で Select Drives → Enter → popup → ArrowDown で Check All → Enter → ArrowDown×2 で bottom Apply Changes → Enter → OK(Enter) → form → Save Configuration(Enter) → 確認ダイアログ[同レシピ] → OK(Enter) → 2nd OK(Enter)
**検証**: Virtual Drive Management → View Drive Group Properties で OEM "Virtual Drive 0: RAID0..." を読む。**フル dashboard の PROPERTIES カウント (Status/Drives/Drive Groups/Virtual Drives) は信頼できる**が、**コンパクト形態のカウントと Controller Management→Controller Properties の "Virtual Drive Count" は stale (0 を出すことがある)**。

### 鉄則 (今回の失敗から)
1. **🚨 サブメニュー/ユーティリティに入る前に画面の文字 (行テキスト + 右ヘルプ) を必ず読む**。AVAGO 行 (caret≈393, "Manage RAID Controller Configurations.") と Intel I210 NIC 行 (caret≈425) は近接、silent drop で NIC 行に誤入し得る。
2. **1キーごとに screenshot を読んでから次キー**。バッチ送信は道を見失う。
3. **成功は OEM 真VGA で VD 行を裏取りしてから報告**。caret/size シグネチャの一致は成功証拠でない (別画面の反復でも一致する)。
4. **並列 Bash 呼び出しを避ける** (pkill exit1 で連鎖キャンセル、複数 KVM サーバ競合)。逐次実行。
5. **KVM 劣化からの復旧** = host ForceOff → `bmc-reset-retry.sh` (host ON だと `ActionRelatedFeatureBlocked`、必ず先に Off) → `wait-bmc-boot.sh` → `wait-post-snap.sh` で BIOS 到達確認 → `kvm_server.py` 起動。fresh BMC reboot 直後の最初の接続だけが master かつ健全。
6. 各サイクル後に OEM で VD 有無を確認し、想定 (削除後=VD なし、作成後=VD あり) と一致するかチェック。

### 未解決・改善余地
- 無人 N サイクル完走は未達 (今回の試行は NIC 誤入で頓挫)。per-key だが**進入前テキスト確認をコードに組み込む** (右ヘルプ OCR or 既知文言マッチ) と堅牢化できる。
- RAID10 の KVM HII 作成は依然 dead-end (Select RAID Level 到達不可)。RAID0/1/5/6 のみ。複数回試行は RAID0 で継続推奨。
- `tmp/503d9361/` のツール群を `scripts/` + `irmc-bios-raid` スキルへ正式昇格すると次セッションが楽になる。
