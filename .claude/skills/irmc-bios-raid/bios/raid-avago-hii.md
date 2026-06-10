# AVAGO MegaRAID `<PRAID EP400i>` HII — TX1320 M3 RAID 設定リファレンス

Advanced タブ最下の **AVAGO MegaRAID `<PRAID EP400i>` Configuration Utility** (SAS3008, FW 03.25.05.10 /
03.x) の HII 画面・項目・操作レシピ。WinSCU XML 非対象 (RAID は BMC eLCM ライセンス無しのため Redfish 不可)
で、操作は **KVM USB HID emulation のみ**。SOL ではキーが届かない (D3373 は Console Redirection なし)。

> 操作の落とし穴・確認ダイアログレシピ・復旧手順は [../SKILL.md](../SKILL.md) の RAID 節と
> memory `tx1320_bios_raid_kvm_69f.md` が一次情報。本ファイルは画面・項目の構造リファレンス。

## 進入

`BIOS Setup → Advanced → ArrowDown ×14 → AVAGO MegaRAID 行ハイライト → Enter 1 回` で Main 画面に入る。

- AVAGO 行 (caret≈y393) は iSCSI(≈368) / LSI SW RAID(≈406) と近接。進入前に右ヘルプ
  "Manage RAID Controller Configurations." を読み、誤って Intel I210 NIC 設定や LSI SW RAID に入らないこと。
- 画面取得は **OEM screenshot が一次情報**。KVM canvas は黒画 artifact のことがある。判読はサブエージェント委任。

## Main 画面 (Dashboard)

cursor 起動位置 `▶ Main Menu`。右ヘルプ "Shows menu options such as Configuration Management,
Controller Management, Virtual Drive Management, Drive Management and Hardware Components."

| 区画 | 内容 |
|------|------|
| PROPERTIES | Status [Optimal] / Backplane 1 / BBU [No] / Enclosure 0 / Drives 4 / Drive Groups N / Virtual Drives N / View Server Profile |
| ACTIONS | Configure / Set Factory Defaults / Update Firmware / Silence Alarm |
| Background Operations | 進行中の初期化・整合性チェック等 |
| MegaRAID Advanced Software Options | RAID6 / RAID5 / FastPath [Enabled] |

> 🚨 メニュー階層は入場ごとに見え方が変わる。caret_y やサイズで盲判定せず**画面の文字を読む**。
> 2 形態あり: (A) フル dashboard → Main Menu を Enter で `Configuration Management / Controller Management /
> Virtual Drive Management / Drive Management / Hardware Components` の 5 項目。(B) コンパクト = AVAGO 行
> Enter 直後にいきなり 3 項目だけ (Configuration Management なし)。(B) に入ったら一段 Esc して入り直す。

## Main Menu サブ項目

| 項目 | 用途 |
|------|------|
| Configuration Management | VD 作成 (Create Virtual Drive) / Clear Configuration / View Drive Group Properties |
| Controller Management | コントローラ設定 (⚠️ RAID 操作ではない。誤入注意) |
| Virtual Drive Management | VD の確認・操作 (`Virtual Drive 0: RAIDx, ...` 行が唯一信頼できる VD 状態) |
| Drive Management | 物理ドライブの確認・操作 |
| Hardware Components | バックプレーン・エンクロージャ等 |

## Create Virtual Drive フォーム (`CONFIGURE VIRTUAL DRIVE PARAMETERS`)

Configuration Management → Create Virtual Drive で開く。cursor は `Select RAID Level` 行に乗って開く。

| 項目 | 値 (ドロップダウン) |
|------|--------------------|
| Select RAID Level | **RAID0 / RAID1 / RAID5 / RAID6 / RAID00 / RAID10** (FW 9.69F で RAID10 在り) |
| Protect Virtual Drive | Disabled (非選択行 — cursor が止まらない) |
| Select Drives From | Unconfigured Capacity / Free Capacity |
| Select Drives | (▶ サブ画面: ドライブ一覧で Enabled/Disabled 選択) |
| Virtual Drive Name | (任意) |
| その他 | Strip Size / Read Policy / Write Policy / IO Policy 等 |

- RAID10 を選ぶと `SELECT SPAN(S)` UI に変化 → Span0 に 2 台 + Add More Spans → Span1 に 2 台 (Check All) → Save。
- `Select RAID Level` から **ArrowDown×2 がちょうど Select Drives** (Protect 行はスキップ、×3 は行き過ぎ)。

## 主要操作レシピ (要約)

| 操作 | 要点 |
|------|------|
| Clear Configuration | Config Mgmt → Clear Configuration (右ヘルプ "Deletes all existing configurations") → 確認ダイアログ commit。検証は Virtual Drive Management が "no Virtual Drives currently available" (OEM size≈9758) |
| Create RAID10 | Create VD → RAID10 → Span0/1 各 2 台 → Save → 成功 msg は Escape で閉じる。VD0 RAID10 1.636TB Optimal を OEM 真VGA で裏取り |
| 確認ダイアログ commit | ダイアログを開いたら `mouse 512 384` でフォーカス再確立 → ArrowUp×2→Enter (Confirm) → ArrowDown→Enter (Enabled) → ArrowDown→Enter (Yes)。判定は反転背景 (▶No は静的で当てにならない) |

> 鍵: (1) keyrepeat は高 latency で多重登録 → 間隔 ≥1600ms か単発 press、(2) 確認ダイアログ操作は 1 コマンド
> ファイルに集約 (分割するとフォーカス喪失で No キャンセル)、(3) modal を開いたら実マウスクリックでフォーカス再確立、
> (4) per-key で screenshot を撮り文字を読んでから次キー、(5) VD の有無は Virtual Drive Management ページの
> `Virtual Drive 0:` 行で裏取り (dashboard カウントは stale)。

## 既知の RAID 構成 (NVRAM 永続)

- SAS HDD 900GB × 4 → **RAID10 実効 1.635 TB Optimal** (pvese 標準セットアップが BIOS HII Clear → install で再作成)。
- RAID 構成はコントローラ NVRAM に永続し、host 電源断・BMC reboot では消えない。

## サブエージェント判読プロンプト

[../SKILL.md](../SKILL.md) の「スクリーンショット分析はサブエージェントに委任する」節の 6 項目報告
(選択中タブ / カーソル行 / 右ヘルプ全文 / ダイアログ状態 / 黒画凍結 / 画面見出し) + プロンプト雛形を使う。
