# TX1320 (D3373-B1x) BIOS 全項目 網羅リファレンス — 実機キャプチャ + タブ単位分割

## Context

`bios-setup` スキルには Supermicro X11DPU/X10DRT-P の BIOS 全設定項目を網羅した
`reference.md`(1748 行)がある。ユーザは TX1320 M3 (Fujitsu PRIMERGY / iRMC S4 / AMI Aptio /
board **D3373-B1x**) についても同等の網羅リファレンスを作りたい。ただし 1 ファイルが肥大化
しないよう**タブ単位で分割**する。

調査の結果、TX1320 の BIOS 各項目の選択肢・値を埋めるデータは現状プロジェクト内に存在しない
(既知なのは ① 7 タブ名、② Advanced の 15 サブメニュー名と並び順、③ AVAGO MegaRAID HII 詳細、
④ Boot/CSM/Network Stack の挙動 のみ)。よってユーザ選択に従い **training-tx1320 実機から
KVM/OEM screenshot で各項目を逐次キャプチャ**し、構造化して per-tab ファイルに編纂する。

これは決定論的でない高 latency・KVM 劣化リスクのある作業なので、**ファイル雛形を先に作って
タブ単位で増分的に埋める**(部分進捗を commit 可能にする)方針とする。

成果物の置き場所は既存 `irmc-bios-raid` スキル配下の新規 `bios/` サブディレクトリ。

### 🆕 データ源の更新(2026-06-07、ユーザ承認): WinSCU XML を主 + KVM で存在確認

実機から Redfish BSPBR で取得済みのコミット済み **WinSCU XML**
(`report/attachment/2026-05-16_130950_tx1320_bios_uefi_auto/bios-backup-initial.xml`、~90 設定)が、
各設定の **`name`(項目ラベル)/ `default` / `current`(2026-05-16 時点)/ 全 `possibleValue`(選択肢)/
`<description>`(BIOS ヘルプ全文)** を構造化保持していると判明。これは項目フォーマットが要求する
データそのもので、KVM/OEM スクリーンショットより高品質・非破壊・即時。

**よって方法を「XML 主 + KVM 存在確認」に変更**(ユーザ承認):
- **値・選択肢・デフォルト・ヘルプは XML を一次源**にする(`current` は 2026-05-16 スナップショットと明記)。
- **各設定がいま実機の BIOS Setup にも存在することを KVM/OEM で必ず確認**する(ユーザ要請)。KVM 巡回は
  併せて ① タブ/サブメニューの正しい所属、② XML に無い読み取り専用情報・メニュー項目、③ AVAGO RAID HII を採取。
- XML はタブ所属情報を持たない(setupItemID 順のフラットリスト)ため、`name` から best-effort で振り分け、
  KVM 確認で確定する。各項目に **KVM 確認ステータス(確認日 or 未確認)** を付す。

### 「網羅」の定義(成果物スコープ — 約束と中身の食い違いを防ぐため明示)

- **構造の網羅は初版で完成させる**: 全 7 タブ + Advanced 15 サブメニューを漏れなくファイル化し、
  各画面に存在する設定項目を**項目名・現在値・右ヘルプまで列挙**する(= どの設定が存在するかは全数把握)。
- **値の網羅は増分で埋める**: 各項目の「全選択肢」「デフォルト」はドロップダウン展開や追加確認が要るため、
  PVE/PXE 影響項目を優先して採取し、未採取は `(未展開)` / `(未確認)` と**正直に明示**する(空欄や捏造はしない)。
- したがって本リファレンスは「**全項目を構造的に網羅し、値は出処付きで段階的に充足する**」もの。
  初版で骨格 + 既知 + 優先項目が揃い、以後のキャプチャで `(未展開)`/`(未確認)` を潰していく。

---

## 既知の確定事実(キャプチャ前から reference.md / memory で確証済み)

- **BIOS タブ (7)**: `Main / Advanced / Security / Power / Server Mgmt / Boot / Save & Exit`
  (`reference.md` #22)。タブ列は **wrap する**(Main で ArrowLeft → 最右 Save & Exit)。
- **Advanced サブメニュー (15, ArrowDown×14 で最下 AVAGO)**: Onboard Devices Configuration →
  PCI Status → PCI Subsystem Settings → CPU Configuration → Memory Status →
  SATA Configuration → CSM Configuration → Trusted Computing → USB Configuration →
  Super IO Configuration → Network Stack Configuration → Option ROM Configuration →
  VIOM → iSCSI Configuration → AVAGO MegaRAID `<PRAID EP400i>` Configuration Utility。
  (空行は cursor が skip。iSCSI≈y368 / AVAGO≈y393 / LSI SW RAID≈y406 が近接で誤入注意)
- **AVAGO HII** は既に詳細記録あり(Main Menu/Configuration Management/Virtual Drive Management/
  Create VD フォーム/Clear Configuration/確認ダイアログ/RAID Level RAID0-6,00,10)。
- **画面取得の一次情報は OEM screenshot に固定する**。`irmc-oem-screenshot.sh` が真 VGA を撮るので
  項目テキスト・bracket 値・右ヘルプの**列挙は必ず OEM を読む**。KVM canvas (`server.py shot`) は
  描画する場面では cursor 反転ハイライトの確認に**補助的に**使うが、黒画でも hang と判定しない
  (framebuffer artifact のことがある)。「OEM = 値の根拠 / KVM = カーソル位置の補助」と役割を固定。

---

## 成果物(ファイル構成)

新規ディレクトリ `.claude/skills/irmc-bios-raid/bios/`:

| ファイル | 内容 |
|---|---|
| `index.md` | HW スペック表 / **リスクレベル定義** / **タブ構成 + ナビ map** / 項目記述フォーマット凡例 / キャプチャ出処(provenance)注記 / 各 per-tab ファイルへのリンク |
| `main.md` | Main タブ(System Date/Time、読み取り専用情報: BIOS版/CPU/メモリ容量) |
| `advanced.md` | Advanced タブ。15 サブメニューを `###` 連番で。各サブメニュー内の設定項目を `####` で網羅 |
| `security.md` | Security タブ(Administrator/User Password, Secure Boot, TPM 連携 等) |
| `power.md` | Power タブ(電源復帰ポリシー, Wake-on 系 等) |
| `server-mgmt.md` | Server Mgmt タブ(BMC/iRMC 連携, FRB, OS Watchdog, SOL 設定 等) |
| `boot.md` | Boot タブ(Boot Mode=UEFI/Legacy, Boot Option Priorities, CSM 連動) |
| `save-exit.md` | Save & Exit タブ(Save/Discard/Load Defaults, Boot Override) |
| `raid-avago-hii.md` | AVAGO MegaRAID `<PRAID EP400i>` HII の全画面・項目(既存知見を集約 + 追補) |
| `_capture-runbook.md` | キャプチャ作業手順書 + **タブ/サブメニュー別の進捗チェックリスト**(再開可能にするため。下記 capture 手順を恒久化) |

> Advanced が肥大化した場合のみ、後段で `advanced-cpu.md` / `advanced-sata.md` 等に
> 二次分割する(index に分割境界を追記)。初版は `advanced.md` 1 本で開始。

既存ファイルの更新:
- `.claude/skills/irmc-bios-raid/SKILL.md` — frontmatter `description` に「BIOS 設定リファレンス」
  を追記 + 冒頭に `[bios/index.md](bios/index.md)` への参照節を追加。
- `.claude/skills/irmc-bios-raid/reference.md` — 末尾「参考資料」付近に bios/ へのリンク。

---

## 項目記述フォーマット(全 per-tab ファイル共通の凡例 — index.md に明記)

```markdown
#### <設定項目名>  (XML id: <id>, setupItemID <0xNNNN>)
- **選択肢**: <値1> / <値2> / ...            ← XML possibleValue。XML 外なら KVM ドロップダウン
- **デフォルト**: <値>                         ← XML default 属性
- **現在値(2026-05-16)**: <値>                ← XML current 属性。スナップショット日を明記
- **ヘルプ**: "<description 全文>"             ← XML `<description>` CDATA をそのまま引用
- **KVM 確認**: ✅ <日付> / ⏳ 未確認          ← 実機 BIOS Setup に存在することを KVM/OEM で確認した日
- **解説**: <技術背景 1-3 文>
- **PVE/PXE 推奨**: <推奨値 + 理由>
- **リスク**: Safe / Moderate / High / Critical
```

- 読み取り専用項目は「選択肢/デフォルト」を省き「設定値(現在)」のみ。
- **リスクレベル定義表は bios-setup/reference.md と同一**(Safe/Moderate/High/Critical)を index に転記。
- 値の出処を明確化するため、index に「現在値 = training-tx1320 実測(BIOS版・キャプチャ日を明記)、
  デフォルト = 別途 Load Defaults 未実施のため一部未確認」と provenance を記載。

---

## キャプチャ手順(`_capture-runbook.md` に恒久化 / 既存ツールを再利用)

再利用する既存資産(新規スクリプトは作らない):
- `./scripts/bmc-power.sh boot-override BiosSetup` + power on で BIOS Setup へ
- `./scripts/irmc-kvm/server.py`(永続 KVM、コマンドファイル駆動: `press`/`navy`/`keyrepeat`/`shot`/`mouse`/`focus`)
- `./scripts/irmc-oem-screenshot.sh`(真 VGA capture = BIOS の一次情報。KVM master を消費しない)
- `./scripts/irmc-kvm-recover.sh config/training_tx1320.yml`(modal/スレーブ詰まりからの復旧 1 本)
- スクショ判読は **general-purpose サブエージェントに委任**(SKILL.md の 6 項目報告 + プロンプト雛形)

手順(タブ単位で反復):
1. **事前確認**: `ping` で latency 確認(memory: 拠点間 558ms+ 間欠 loss あり)。`./oplog.sh` で電源操作記録。
2. **BIOS 進入**: host ForceOff → `boot-override BiosSetup` → power on → POST 待ち → OEM screenshot で Main 着地確認。
   ⚠️ `bmc-power.sh` 実行前に **`BMC_CURL_OPTS` の cipher env を export**(未 export だと TLS rc=52、
   memory #10 真因)。または既存ラッパー `irmc-kvm-recover.sh`(env を内包)経由で BIOS 進入する。
   ※ BIOS 変更は**一切保存しない**(読むだけ)。退出は ForceOff か Save&Exit→Discard Changes。
3. **KVM master 取得**: `server.py` 起動 → READY → `press ArrowRight`+`shot` でタブ移動確認(master テスト)。
4. **タブ巡回**: 目的タブまで `ArrowRight ×n`(必ず `shot` で着地検証、ドロップ時リトライ。Esc は上位タブで禁止=Exit modal 罠)。
5. **ページ列挙**: OEM screenshot でページ全文を撮り subagent に「全項目名 + [bracket 現在値] + 右ヘルプ」を列挙報告させる。
   長いリストは `keyrepeat ArrowDown` でスクロールし各状態を撮る。
6. **サブメニュー**: `Enter` で進入 → 同様に列挙 → `Esc`(サブメニュー内 Esc は安全)で戻る。
7. **選択肢の採取(重要項目優先)**: Boot Mode / CSM / Network Stack / Option ROM Policy / SATA Mode 等、
   PVE/PXE deploy に効く項目はドロップダウンを `Enter` で開き全選択肢を OEM で読む →
   **必ず `Esc` で閉じて元の値を維持(別の値で `Enter` コミットしない)**。それ以外は初版「(未展開)」で可。
   ※ ドロップダウンを開いただけ・カーソル移動だけでは NVRAM は変わらず、Save しない限り無変更。誤って
   値を変えても **Save&Exit→Discard / ForceOff** で破棄されるが、原則コミット操作自体を行わない。
8. **編纂**: subagent 報告を per-tab ファイルの項目フォーマットに転記。出処スクショパスは残さず値のみ記載。
9. **詰まったら** `irmc-kvm-recover.sh` で復旧 → 該当タブから再開。**1 回の作業セッション中は単一 KVM
   セッションを保持**(open/close を反復しない=スレーブ落ち防止)。作業を跨ぐ(別日/別セッション)際は
   recover で health な master を取り直し、`_capture-runbook.md` の進捗チェックリストから再開する。

> RAID/AVAGO HII は構成を破壊しないよう **Create/Clear/Save は実行せず**、画面の読み取り(進入→列挙→Esc)のみ。

---

## 実行順(増分・各ステップ独立 commit 可能)

1. **雛形作成**: `bios/` に index.md + 8 per-tab ファイル + `_capture-runbook.md` を作成。
   index に確定事実(タブ map・Advanced 15 サブメニュー・リスク定義・フォーマット凡例)を記入。
   各 per-tab ファイルは見出し骨子 + 未取得項目を `<!-- TODO: capture -->` で placeholder。
2. **SKILL.md / reference.md** にリンク追記。
3. **キャプチャ(タブ単位、捕れた分から埋める)**: Main → Boot → Save & Exit(小)→ Security → Power →
   Server Mgmt → Advanced(大、最後)→ raid-avago-hii(既知集約 + 追補)。各タブ完了ごとに該当ファイル更新。
4. 各タブの選択肢採取は「PVE/PXE 影響項目優先」で行い、残りは TODO を残して次セッションへ。

> 1〜2 は実機不要で即完遂可能。3 は実機状態・latency 次第で複数セッションに跨る前提。
> 雛形 + 確定事実だけでも「網羅の骨格 + 既知部分」は揃い、以後の増分が容易になる。

5. **リグレッションテスト(下記専用節、e2e ×3)** — skill 修正完了後の最終検証として実施。

---

## リグレッションテスト(skill 修正後の e2e ×3)

**目的**: 本作業の skill 修正(`irmc-bios-raid/SKILL.md` の frontmatter/参照節追記 + `bios/` 新設)が
既存の自動化経路(opus の BIOS HII RAID Clear + sonnet の deploy→PVE 通し)を壊していないことを
**実機 e2e で 3 回**確認する。手順は `report/2026-06-04_003431_tx1320_sonnet_e2e_10run.md` の
「再現方法」と**同一**(10run 時の 1 試行をそのまま 3 回)。

> 実行タイミング: このリグレッションの**トリガは skill ファイル編集(実行順 Phase 1-2: 雛形 + frontmatter +
> 参照リンク)の完了**。BIOS キャプチャ(Phase 3-4)は **ドキュメント追加のみで実行スクリプト・挙動は
> 無改変**なので、リグレッション結果の妥当性はキャプチャ進捗に依存しない(キャプチャ完了を待つ必要はない)。
> ただし実機・KVM master を共有するため**キャプチャと e2e は同時並行しない**(フェーズを直列化)。推奨は
> 全作業の最終に回すこと。各試行の step 1 RAID Clear が機械をクリーン状態へ戻すので、直前のキャプチャで
> 触れた BIOS/KVM 状態のリセットも兼ねる。

各試行(opus 統括、レポート「再現方法」準拠):
1. **BIOS HII RAID Clear (opus)**: `irmc-kvm-recover.sh` → `irmc-kvm/server.py` 起動 → 検証付き Clear
   コマンド投入(size 指紋 tab=17919 / avago=18051 / clearrow=10135 / vdm=9758、ArrowRight ドロップ時は
   shot 検証 + 再送)。BIOS Clear ハードニング(READY 後単一 ArrowRight・size 非依存・タブ wrap 注意)は
   `irmc-bios-raid/SKILL.md` 記載どおり。
2. **sonnet エージェント spawn(Agent: general-purpose, model=sonnet)**: プロンプト = `pxe-deploy/SKILL.md`
   の「sonnet 自律実行 runbook」節を上から実行 + 試行番号 + anti-yield 強調(sol-monitor は foreground・
   最終報告まで yield 禁止)+ 報告テンプレ。sonnet が env export → `irmc-ipxe-cd-deploy.sh` →
   `sol-monitor.py`(#15 は合計~10min 停滞で ForceOff→再 deploy)→ boot-override Hdd+on → eno2 IP 特定
   (ping-sweep + `ip neigh | grep 4c:52:62:14:de:f0`)→ `tx1320-pve-setup.sh` → 検証 を自律実行。
3. **判定 + 記録**: 各試行の成否・retry 回数・新規ブロッカー有無を記録。

**合格基準(各試行)**: PVE 9.2.x + `pveproxy/pvedaemon/pve-cluster` active + web UI `https://<ip>:8006` HTTP 200
+ `storcli64 /c0/vall show` で `RAID10 Optl 1.635TB`。**3/3 成功 = リグレッションなし**。新規ブロッカーが
出た場合は既知 8 件(nginx/known_hosts/yield/wait_ssh/#15/RAID直読/巨大ログ/ConnectCD)か切り分け、
skill 修正起因なら修正をロールバック/是正してから再試行。

**所要時間目安**: 1 試行 ~40-80min(BIOS Clear ~7-8min + install ~10-25min + PVE setup ~30-55min)。
3 試行で半日規模。結果は `report/` に簡易リグレッションレポートとして残す(10run レポートにリンク)。

---

## Verification

- **構造**: `bios/index.md` から全 per-tab ファイルへのリンクが解決すること(リンク切れ無し)。
  Markdown が GitHub flavor で正しくレンダリングされること(表・見出し階層)。
- **整合**: index のタブ map・Advanced サブメニュー並びが `reference.md` #22 と一致すること。
- **キャプチャ妥当性**: 各項目の「設定値(現在)」「右ヘルプ」が OEM screenshot の subagent 報告に基づくこと
  (推測値は「(未確認)」と明示、捏造しない)。RAID 構成を変更していないこと(作業後 OEM screenshot で
  VD 状態が作業前と同一 = 非破壊を確認)。
- **退出健全性(キャプチャ作業のみ)**: BIOS キャプチャの各作業セッション終了時に host を ForceOff
  (または Save&Exit→Discard)し、BIOS に変更を保存していないこと。
  ※ これはキャプチャ phase の話。**リグレッション e2e の最終状態は PVE 稼働(電源 on + web UI 200)が正常**で、
  ここでの「ForceOff で終わる」は適用しない。
- **電源操作ログ**: BIOS 進入/退出・e2e の電源操作が `./oplog.sh` に記録されていること。
- **リグレッション**: e2e ×3 が **3/3 成功**(各試行で PVE 9.2.x active + web UI 200 + RAID10 Optl 1.635TB)。
  skill 修正起因の新規ブロッカーが無いこと。結果を `report/` に記録。

## critical files

- 新規: `.claude/skills/irmc-bios-raid/bios/{index,main,advanced,security,power,server-mgmt,boot,save-exit,raid-avago-hii,_capture-runbook}.md`
- 更新: `.claude/skills/irmc-bios-raid/SKILL.md`(frontmatter description + bios/ 参照節)
- 更新: `.claude/skills/irmc-bios-raid/reference.md`(参考資料リンク)
- 再利用ツール: `scripts/bmc-power.sh` / `scripts/irmc-kvm/server.py` / `scripts/irmc-oem-screenshot.sh` / `scripts/irmc-kvm-recover.sh`
- 形式の手本: `.claude/skills/bios-setup/reference.md`(項目フォーマット・リスク定義)
- リグレッション e2e 手順の典拠: `report/2026-06-04_003431_tx1320_sonnet_e2e_10run.md`(再現方法)
- リグレッションで使う既存資産: `scripts/irmc-ipxe-cd-deploy.sh` / `scripts/sol-monitor.py` / `scripts/tx1320-pve-setup.sh` / `pxe-deploy/SKILL.md`(sonnet 自律 runbook)/ `ipxe-tx1320.iso`
- 新規(リグレッション結果): `report/<日時>_tx1320_bios_reference_regression_e2e_3run.md`
