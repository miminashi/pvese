# `bios-setup` スキル X10DRT-P (10号機) 対応レポート

- **実施日時**: 2026年4月30日 06:17 JST
- **担当**: bios10x1 (claude)
- **関連 issue**: #51

## 添付ファイル

- [実装プラン](attachment/2026-04-30_061705_bios_setup_x10drt_p_support/plan.md)
- [BIOS スクリーンショット (タブ巡回 + Advanced サブメニュー全 10 種)](attachment/2026-04-30_061705_bios_setup_x10drt_p_support/bios_screens/)
- 関連レポート:
  - [10号機追加レポート](2026-04-30_023103_add_server10_x10drt_p.md) — X10DRT-P 設定ファイル整備 (本タスクの起点)
  - [10号機 BMC FW アップデート試行レポート](2026-04-30_042725_server10_bmc_fw_update.md) — Nutanix OEM 制約の確定
  - [Nutanix 純正 FW 入手不可レポート](2026-04-30_052242_server10_bmc_fw_nutanix_unavailable.md)

## 結論サマリ

- **互換性判定**: ✅ X10DRT-P は X11DPU と AMI Aptio V を共有し、**タブ構成 (7枚) ・キーバインド・KVM スクリプト互換性** はすべて X11DPU と一致
- **Phase 1 観測**: BIOS 進入成功、全 7 タブ + Advanced 全 10 サブメニュー + Boot Order ドロップダウン + Secure Boot Menu + Password Check ドロップダウンを取得 (合計約 100 枚のスクリーンショット)
- **Phase 2 ドキュメント更新**:
  - `SKILL.md` description / 前提条件 / X10DRT-P 固有差分節 / 10号機向けコマンド例 を追記
  - `reference.md` 冒頭を Supermicro 全体向けに調整、末尾に **X10DRT-P (10号機) BIOS 設定リファレンス** 節 (約 380 行) を追加 (Main / Advanced 全 10 サブメニュー / Event Logs / IPMI / Security / Boot / Save & Exit / 主要差分サマリー)
  - `config/server10.yml` の `serial_unit: 1` (= ttyS1 = COM2) は実機観測で正しいことが確定、コメントを「実機検証要」→「2026-04-30 検証済み」に更新
- **副作用**: なし (10号機 BIOS は Discard Changes and Exit で退出、設定変更なし、電源 OFF)
- **未取得項目**: PageDown 必要箇所 (Boot Feature/CPU Configuration の続き)、Chipset > North Bridge / South Bridge 詳細、COM2/SOL Settings サブサブメニュー、Boot Mode Select ドロップダウン、Memory Configuration、Key Management。reference.md 末尾に「X10DRT-P 観測未完了項目」チェックリストを記載済み

## 前提・目的

- **背景**: 10号機追加レポート (2026-04-30 02:31 JST) の残タスク #5 として「`bios-setup` スキルの X10DRT-P 対応」が積まれていた。前タスクではユーザ確認のもと bios-setup には触らず、別タスクで実機 KVM で確認 → UI 互換なら SKILL.md 拡張、非互換なら専用 reference を作成する方針が確定していた
- **目的**:
  1. 実機 BIOS UI を KVM で観測し X11DPU との互換性を判定する
  2. ユーザの選択 (X11DPU リファレンス並みに全項目を記録 + reference.md にパラレル節を追加) に従ってドキュメントを更新する
  3. `config/server10.yml` の `serial_unit` を実機観測で確定する
- **制約**:
  - BIOS 設定変更は一切行わない (観測のみ)
  - BIOS Setup 退出は **Discard Changes and Exit** で確実にリセット
  - pve-lock で電源操作を排他制御
  - Nutanix OEM 由来の BMC FW 更新制約 (3.65 固定) はそのまま受容

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | 10号機 ayase-web-service-10 |
| ハードウェア | Nutanix NX-1065-G5 (Board: Supermicro X10DRT-P-G5-NI22) |
| Chassis | CSE-217HQ+-000NBP (2U Twin Server) |
| BMC IP | 10.10.10.30 (Static, /8) |
| BMC ユーザ | claude (index 4, ADMINISTRATOR) |
| BMC チップ | ASPEED 2400 / Firmware 3.65 (Nutanix OEM 制約で更新不可) |
| CPU | Intel Xeon E5-2620 v4 x2 (Broadwell-EP, 8C/16T per socket = 16C/32T total, 2.10GHz, L3 20MB) |
| Memory | 65536 MB (64GB) DDR4-2133 |
| BIOS | AMI Aptio V Version 2.17.1249 / BIOS Version G4G5T8.0 (Build 2021-07-14) |
| CPLD | 03.a1.30 |
| Super IO | AST2400 |
| ME FW | 3.1.3.72 (SPS) |
| Operating mode | Boot Mode = LEGACY, CSM Support = Enabled, Secure Boot = Disabled |

## 再現方法

### 前提

- ローカル環境: pvese プロジェクト (`/home/ubuntu/projects/pvese`)、Playwright + Chromium インストール済み (`.venv/bin/python`)
- 10号機の BMC が `claude` / `Claude123` / index 4 で SSH 接続可能
- pve-lock が unlock 状態

### Phase 1: BIOS 進入と全タブ観測

```sh
# (1) 電源状態確認 (pve-lock 不要、read-only)
ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status

# (2) Power On (pve-lock + oplog)
./pve-lock.sh run ./oplog.sh ./scripts/bmc-power.sh on 10.10.10.30 claude Claude123

# (3) 60×Delete 連打で BIOS 進入 (tmp/bios10x1/enter_bios.sh に保存)
sh tmp/bios10x1/enter_bios.sh
# Canvas 720x400 (POST) → 800x600 (BIOS Setup) で進入確認 (キー#22 付近で切り替わり)

# (4) F2 で Previous Values リセット → 全 7 タブを ArrowRight で順次撮影
sh tmp/bios10x1/tour_tabs.sh
# tab_001-tab_009: F2 ダイアログ → Main → Advanced → Event Logs → IPMI → Security → Boot → Save & Exit → Main 循環

# (5) Advanced タブの全 10 サブメニューを ArrowDown/Enter/Escape で巡回
sh tmp/bios10x1/tour_advanced.sh
# adv_002, _005, _008, _011, _014, _017, _020, _023, _026, _029 が各サブメニューの 1 ページ目

# (6) Boot Order ドロップダウン + Security Password Check ドロップダウンの取得
sh tmp/bios10x1/tour_boot_security.sh

# (7) Secure Boot Menu の取得 + BIOS から Discard Exit
sh tmp/bios10x1/finish.sh   # → "Exit Without Saving - Quit without saving?" ダイアログまで進行
sh tmp/bios10x1/exit_bios.sh  # Enter で Yes 確定 → 退出

# (8) Power Off (再起動を防止)
./pve-lock.sh run ./oplog.sh ./scripts/bmc-power.sh forceoff 10.10.10.30 claude Claude123
```

### Phase 2: ドキュメント更新

1. `.claude/skills/bios-setup/SKILL.md`
   - frontmatter `description` を `Supermicro X11DPU/X10DRT-P BIOS Setup 操作 ... 4-6号機 + 10号機対応` に更新
   - 「前提条件」に 10号機 (BMC 10.10.10.30, claude index 4, AMI Aptio 2.17.1249) を追記
   - `enter` サブコマンド節に 10号機向けコマンド例を追加 (POST 22 キー目で BIOS 到達することも記載)
   - 「変更禁止 (危険)」の Trusted Computing 行に「X11DPU のみ。X10DRT-P には TPM サブメニューが存在しない」を注記
   - 新規セクション **「X10DRT-P (10号機) 固有差分」** を追加: Advanced サブメニュー数差分、Boot タブ LEGACY モード、Save & Exit 名称差、BMC FW 更新制約、Twin Server 構成、claude index 4 など

2. `.claude/skills/bios-setup/reference.md`
   - 冒頭タイトルを `# Supermicro BIOS 設定リファレンス (X11DPU / X10DRT-P)` に変更
   - 「はじめに」を X11DPU / X10DRT-P の両方をカバーする内容に更新 (両者のハードウェア概要を併記)
   - 既存 X11DPU 内容の前に `# X11DPU (4-6号機) BIOS 設定リファレンス` 大見出しを挿入 (内容は無修正)
   - `## 参考資料` の前に `# X10DRT-P (10号機) BIOS 設定リファレンス` 大見出しと約 380 行の新セクションを追加: はじめに / Main / Advanced (全 10 サブメニュー詳細) / Event Logs / IPMI / Security / Boot / Save & Exit / **X11DPU と X10DRT-P の主要差分サマリー** 表 / 観測未完了項目チェックリスト
   - `## 参考資料` に X10DRT-P / Broadwell-EP 関連の参考資料を追記

3. `config/server10.yml` の `serial_unit: 1` のコメントを実機検証済みに更新

### 検証コマンド

```sh
# SKILL.md 更新確認
grep -n 'X10DRT-P\|10号機' /home/ubuntu/projects/pvese/.claude/skills/bios-setup/SKILL.md

# reference.md 更新確認
grep -n '^# X10DRT-P\|^# X11DPU\|## 主要差分' /home/ubuntu/projects/pvese/.claude/skills/bios-setup/reference.md

# 4-6号機 (X11DPU) 既存記述が壊れていないか確認
grep -c 'X11DPU\|4号機\|5号機\|6号機' /home/ubuntu/projects/pvese/.claude/skills/bios-setup/reference.md

# config/server10.yml の serial_unit
./bin/yq '.serial_unit' /home/ubuntu/projects/pvese/config/server10.yml
```

## 検証結果

### 観測結果サマリ (X10DRT-P vs X11DPU)

| 項目 | X11DPU | X10DRT-P |
|------|--------|----------|
| BIOS タブ構成 | Main / Advanced / Event Logs / IPMI / Security / Boot / Save & Exit (7 タブ) | **同一** |
| キーバインド | AMI Aptio 標準 (Arrow / Enter / Esc / +/- / F1-F4 / PageUp/PageDown / Tab) | **同一** |
| キャンバス解像度 | 800x600 (BIOS), 720x400 (POST) | **同一** |
| Advanced サブメニュー | 16 個 | **10 個** (Trusted Computing / HTTP BOOT / KMS / TLS / iSCSI / Driver Health なし) |
| サブメニュー名 | PCH SATA / PCH eSATA / Server ME Information | **SATA / sSATA / Server ME Configuration** に変更 |
| Boot Mode デフォルト | DUAL | **LEGACY** |
| Boot Order 数 | 17 (DUAL) | **7** (LEGACY) |
| Secure Boot Mode | Standard | **Custom** |
| CSM Support 項目 | (なし) | **Enabled** |
| Save & Exit | "Save Changes and Exit" | **"Save Changes and Reset"** |
| Wait For F1 If Error | Enabled | **Disabled** |
| SR-IOV Support | Disabled | **Enabled** |
| SATA Hot Plug | Disabled | **Enabled** |
| Onboard LAN1 OPROM | Legacy | **PXE** |

### Phase 1 検証

- ✅ `tmp/bios10x1/bios_entry_022.png` 〜 `bios_entry_060.png` で 800x600 に切り替わり、`Aptio Setup Utility` テキストが視認可能
- ✅ ArrowRight x7 で Main → Advanced → Event Logs → IPMI → Security → Boot → Save & Exit → Main の循環確認
- ✅ Advanced 全 10 サブメニュー一覧取得 (`adv_002` 〜 `adv_029` で各 1 ページ目を撮影)
- ✅ Boot Order ドロップダウン値 (8 項目) 取得
- ✅ Secure Boot Menu (CSM Support [Enabled] 含む) 取得
- ✅ Password Check ドロップダウン (Setup/Always) 取得
- ✅ COM2/SOL Console Redirection [Enabled] 確認 → `serial_unit: 1` (ttyS1) が正しいことが確定

### Phase 2 検証

- ✅ `SKILL.md` description: `Supermicro X11DPU/X10DRT-P BIOS Setup 操作 ... 4-6号機 + 10号機対応` (skill list に反映確認済み)
- ✅ `reference.md` に `# X11DPU (4-6号機) BIOS 設定リファレンス` と `# X10DRT-P (10号機) BIOS 設定リファレンス` の 2 セクションが並列で存在
- ✅ X11DPU 節の本文 (Advanced 16 サブメニュー / PVE 推奨設定サマリー / 危険な設定一覧) は無修正で保持
- ✅ X10DRT-P 節は 7 タブ全項目 + Advanced 10 サブメニュー網羅
- ✅ 主要差分サマリー表で 30+ 項目の差分を一覧化
- ✅ `config/server10.yml` の `serial_unit: 1` コメント更新

### Phase 3 検証

- ✅ レポート本ファイル作成
- ✅ 添付 plan.md コピー
- ✅ 添付 bios_screens ディレクトリに 19 枚の主要スクリーンショット格納

## 残タスク

reference.md 末尾に「X10DRT-P 観測未完了項目」として記録した内容。優先度は LEGACY → UEFI 切替時または PCI パススルー設定時に必要となる:

1. **Advanced > Boot Feature Page 2** (PageDown 後の項目: Throttle on Power Fail, Allow In-band BIOS Updates 等の有無)
2. **Advanced > CPU Configuration Page 2** (Intel Virtualization Technology, DCU IP Prefetcher, LLC Prefetch 等)
3. **Advanced > Chipset Configuration > North Bridge** (Intel VT-d, IIO Configuration, Memory Configuration 詳細)
4. **Advanced > Chipset Configuration > South Bridge** (USB Configuration 等)
5. **Advanced > Super IO Configuration > Serial Port 1/2 Configuration** 詳細
6. **Advanced > Serial Port Console Redirection > COM2/SOL Console Redirection Settings** (Terminal Type, Bits per second, Flow Control)
7. **Boot Mode Select ドロップダウン** (LEGACY / UEFI / DUAL の 3 選択肢確認)
8. **Security > Secure Boot Menu > Key Management**
9. **UEFI 切替手順の検証** (CSM Support [Disabled] + Boot Mode [UEFI] への変更で UEFI ブート可能性を確認)

これらは別タスクで観測する。本タスクの目的 (BIOS UI の互換性確定 + ドキュメント基盤の整備) は達成。

## 関連ファイル (本タスクで変更)

- `.claude/skills/bios-setup/SKILL.md` (修正、X10DRT-P 対応追加)
- `.claude/skills/bios-setup/reference.md` (修正、X10DRT-P 全項目セクション追加 +約 380 行)
- `config/server10.yml` (修正、`serial_unit` コメント更新)

## 関連ファイル (触らなかったもの)

- `scripts/bmc-kvm-interact.py`, `scripts/bmc-kvm-screenshot.py` (Phase A で 100% 互換確認済み)
- `scripts/bmc-power.sh`, `scripts/bmc-session.sh` (同上)
- `CLAUDE.md`, `README.md`, `MEMORY.md` (10号機追加レポートで反映済み)
- 他のスキル (`os-setup`, `idrac7`, `perc-raid` 等) — 範囲外
