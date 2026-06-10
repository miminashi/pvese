# BIOS リファレンス キャプチャ作業手順書 + 進捗チェックリスト

このリファレンスは **WinSCU XML を主データ源 + KVM で実機存在確認**して作る (2026-06-07 ユーザ承認)。
本書は ① XML からの再生成手順、② KVM 実機確認の手順、③ 進捗チェックリストを恒久化する。

## ① XML からの (再)生成

- 主データ: `report/attachment/2026-05-16_130950_tx1320_bios_uefi_auto/bios-backup-initial.xml` (91 設定)。
  最新化したい場合は `scripts/irmc-bios.py backup config/training_tx1320.yml <out.xml>` で再取得
  (boot phase 実行 = 電源サイクル要、`./oplog.sh` で記録)。
- パース: `tmp/<sid>/parse_bios_xml.py` (settings.json 出力) → `tmp/<sid>/gen_bios_md.py`
  (advanced/boot/security/power.md + index マスターテーブルを生成)。
  ⚠️ **再生成は手で追補した 解説/PVE推奨 を上書きする**。タブ振り分け (MAP)・リスク・OVERRIDE を更新したら再生成し、
  手追補は OVERRIDE 辞書側に寄せる運用にする (md 直編集の手追補は再生成で消える)。
- 雛形スクリプトは本リファレンス初版作成時の `tmp/biosref/` を参照 (parse/gen 両方)。

## ② KVM 実機存在確認 (ユーザ要請: 各設定が実機にも在ることを確認)

再利用する既存資産 (新規スクリプトは作らない):
- `./scripts/irmc-kvm-recover.sh config/training_tx1320.yml <shot> <wait>` — BIOS 進入 + KVM 健全化 (env 内包)
- `./scripts/irmc-kvm/server.py` — 永続 KVM (`press`/`navy`/`keyrepeat`/`shot`/`mouse`/`focus`)
- `./scripts/irmc-oem-screenshot.sh` — 真 VGA capture (一次情報。KVM master を消費しない)
- スクショ判読は **general-purpose サブエージェントに委任** ([../SKILL.md](../SKILL.md) の 6 項目報告 + 雛形)

手順 (タブ単位):
1. **事前**: `ping 10.254.254.9` で latency 確認 (拠点間 558ms+ 間欠 loss あり)。`./oplog.sh` で電源操作を記録。
   ※ `bmc-power.sh` 前に `BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"` 等を export
   (未 export だと TLS rc=52)。または recover ラッパー経由。
2. **BIOS 進入**: host ForceOff → boot-override BiosSetup → power on → POST 待ち → OEM で Main 着地確認。
   **変更は一切保存しない** (退出は Discard / ForceOff)。
3. **KVM master**: `server.py` 起動 → `press ArrowRight`+`shot` でタブ移動確認。
4. **タブ巡回**: ArrowRight で目的タブへ (毎回 shot で着地検証、ドロップ時リトライ。上位タブで Esc 禁止)。
5. **ページ列挙**: OEM screenshot を撮り subagent に「全項目名 + [bracket 現在値] + 右ヘルプ」を列挙させる。
   マスターテーブルの該当項目が実画面に**存在するか照合** → 各項目の「KVM 確認」を `✅ <日付>` に更新。
   - 実画面に在るが XML に無い項目 → per-tab に新規追記 (現在値は KVM 実測)。
   - XML に在るが実画面に無い項目 → "⚠️ KVM 未検出 (要再確認)" と注記。
6. **サブメニュー**: Enter で進入 → 列挙 → Esc (サブメニュー内 Esc は安全) で戻る。
7. **選択肢の追加採取** (任意): Boot Mode/CSM/Network Stack/OpROM/SATA 等はドロップダウンを Enter で開き
   全選択肢を OEM で読む → **必ず Esc で閉じ、別値で Enter コミットしない**。
8. **AVAGO RAID HII**: 進入 → Main Menu/Config Mgmt/VDM を読むだけ (Create/Clear/Save しない)。
9. **退出**: Discard Changes and Exit か ForceOff。RAID 非破壊を OEM で裏取り (VD 状態が作業前と同一)。
10. **詰まったら** `irmc-kvm-recover.sh` で復旧 → 該当タブから再開。1 作業セッション中は単一 KVM を保持
    (開閉反復しない)。作業を跨ぐ際は recover で master 取り直し、本チェックリストから再開。

## ③ 進捗チェックリスト

### XML 由来の自動生成 (実機不要)
- [x] settings.json パース (91 設定)
- [x] advanced.md / boot.md / security.md / power.md 生成
- [x] index.md マスターテーブル
- [x] main.md / server-mgmt.md / save-exit.md / raid-avago-hii.md 雛形

### KVM 実機存在確認 (タブ単位、各 per-tab ファイル冒頭「🔬 KVM 実機確認」節に可視/非表示を明記)

**2026-06-10 全タブ巡回完了** (s-7f32b4be、shot 群は `tmp/biosref/tabsweep/srv/shots/`)。
最重要発見 = **XML ⊋ Setup UI** (NVRAM 全集合 vs HW 構成依存の可視部分集合)。詳細は各 per-tab 冒頭節 + index.md。

- [x] Main タブ + System Information サブメニュー (CPU E3-1220 v6 / Mem 24576MB@2400 / SPS 4.1.4.54 等採取)
- [x] Boot タブ (XML 8/9 可視、PXE boot wait time ❌非表示、Boot Option Priorities 採取)
- [x] Save & Exit タブ (アクション 10 種 + Boot Override 一覧確定)
- [x] Security タブ (メイン 3 + Secure Boot Configuration サブ確認、Password Severity ❌)
- [x] Power タブ (Power-on Source + Wake-Up Resources サブ内 LAN/WoL boot、3/3 可視)
- [x] Server Mgmt タブ (XML 非対象、メインページ全項目採取: FW9.69F/Power Failure Recovery[Always On]/Serial Multiplexer[System] 等)
- [x] Advanced > Onboard Devices Configuration (LAN1/2 Controller・Oprom 可視、iGPU/DVMT ❌非表示)
- [x] Advanced > PCI Status (Slot1-4、Slot4=RAID)
- [x] Advanced > PCI Subsystem Settings (ASPM/Above 4G 可視、PCI Error Logging/PERR#/SERR# ❌)
- [x] Advanced > CPU Configuration (9 項目可視、HT/Execute Disable/TXT/SGX/X2APIC/Power Limit 群 ❌非表示)
- [x] Advanced > Memory Status (DIMM-2A 空 + 1A/2B/1B Enabled、ECC Mem Error Logging ❌)
- [x] Advanced > SATA Configuration (SATA Mode [RAID Mode])
- [x] Advanced > CSM Configuration (Launch CSM [Disabled]、OpROM policy 群は CSM 無効で ❌抑制)
- [x] Advanced > Trusted Computing (TPM Support [Enabled] / NO Security Device Found、TPM State 等 ❌)
- [x] Advanced > USB Configuration (Legacy USB + USB Port Security>USB Port Control 可視、他 ❌)
- [x] Advanced > Super IO Configuration (PILOT3 + Serial Port 1 Config>Serial Port[En]/IO=3F8h IRQ=4)
- [x] Advanced > Network Stack Configuration (Network Stack/Ipv4/Ipv6 PXE 全可視・Enabled)
- [x] Advanced > Option ROM Configuration (Launch Slot1-4 OpROM、Slot4=Enabled)
- [x] Advanced > VIOM (VIOM-flag [Disabled])
- [ ] Advanced > iSCSI Configuration (サブメニュー存在のみ確認、内部項目未採取 — 優先度低)
- [ ] Advanced > AVAGO MegaRAID HII (raid-avago-hii.md は既存知見で確立済、本巡回では非破壊のため非進入)
- [ ] (任意) iRMC LAN Parameters / Console Redirection サブメニュー内部 (BMC NW/SOL は Redfish/ipmitool 運用のため優先度低)
- [ ] (任意) 各設定のドロップダウン全選択肢の追加採取 (PVE/PXE 影響項目は XML possibleValue で既知)
