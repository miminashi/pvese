# TX1320 BIOS RAID 削除→再作成 3サイクル検証 ログ (引き継ぎセッション)

開始状態: host=BIOS Setup Main タブ到達済 (OEM `manual/30_current_state.jpg` で確認、Mon 06/01/2026)。
RAID=空 (VD なし、前セッション ground truth)。方針=ベースライン作成→3×(削除→検証→再作成→検証)。

cmd 番号は 500+ を使用 (古い NNN.done 衝突回避)。

## イベント記録

- KVMサーバ master 取得 (attempt 1.2、delta +3262)。BIOS Main タブ着地。
- ナビ: Main→ArrowRight→Advanced→ArrowDown×12→VIOM→ArrowDown→iSCSI→ArrowDown→AVAGO行(右ヘルプ "Manage RAID Controller Configurations.")→Enter→AVAGO dashboard。
- AVAGO PROPERTIES: Status[Optimal]/Drives 4/Drive Groups 0/Virtual Drives 0 = **RAID 空 確認** (504_avago_dash.png)。

## ベースラインVD作成 (cmd 505+) ✅完了
ナビ: AVAGO dash→Enter(Main Menu)→Configuration Management(Enter)→Create Virtual Drive(Enter)→
form(RAID0既定)→ArrowDown×2でSelect Drives(Enter)→popup→ArrowDown×8でCheck All(Enter、4台[Enabled])→
ArrowDown×2でbottom Apply Changes(Enter)→OK(Enter)→form戻り(Size 3.272/TB自動)→top Save Configuration(Enter)→
確認ダイアログ→[ArrowUp×2→Enter→ArrowDown→Enter(Enabled)→ArrowDown(Yesフォーカス)→Enter(commit)]→
OK(Enter)→2nd msg"Virtual Drive creation was successful"はEnter効かず**Escapeで閉じる**→Config Mgmt戻り。
検証: VDM→"Virtual Drive 0: RAID0, 3.272TB, Optimal" (527_vdm_list.png + OEM baseline_vdm_oem.jpg 一致)。
⚠️ 知見: 作成commit後の2nd確認メッセージ("...creation was successful. All free configurable space...")はEnter無反応→**Escapeで閉じる**(削除レシピのOKと挙動差)。

## サイクル1: 削除 (cmd 528-539) ✅完了
ナビ: VDM→Esc→Main Menu→Configuration Management(Enter)。**VDあり時のConfig Mgmtは "View Drive Group Properties / Clear Configuration" の2項目**(空時の3項目とは別)。
ArrowDown 1でClear Configuration(右ヘルプ "Deletes all existing configurations...")→Enter→削除確認ダイアログ→
[ArrowUp×2→Enter→ArrowDown→Enter(Enabled)→ArrowDown(Yesフォーカス)→Enter(commit)]→OK(Enter、1回で閉じる)。
⚠️ 削除後もConfig Mgmtメニューは "View Drive Group Properties" を残す **staleメニュー** → VDMで裏取り必須。
検証: VDM→"Unable to display Virtual Drive summary as there are no Virtual Drives currently available." (539 + OEM c1_del_oem.jpg 一致) = VD消失確認。
⚠️ 知見: 削除commitのOKはEnter 1回で閉じる(作成の2nd messageと違いEscape不要)。

## サイクル1: 再作成 (cmd 540-558) ✅完了
削除後Config Mgmtは空構成3項目(Create VD/Create Profile/Clear Config)に戻る=削除が正しく反映。
ナビ: Config Mgmt→Create Virtual Drive(Enter)→form(RAID0)→ArrowDown×2でSelect Drives(Enter)→
popup→ArrowDown×8でCheck All(Enter、4台[Enabled])→ArrowDown×2でApply Changes(Enter)→OK(Enter)→
form戻り(Size 3.272/TB)→Save Configuration(Enter)→確認ダイアログ→
[ArrowUp×2→Enter→ArrowDown→Enter(Enabled)→ArrowDown(Yes)→Enter(commit)]→OK(Enter)→2nd msg→**Escape**。
検証: VDM→"Virtual Drive 0: RAID0, 3.272TB, Optimal" (558 + OEM c1_recreate_oem.jpg 一致)。
**= サイクル1 完了 (削除✅ + 再作成✅、両方KVM+OEM裏取り)**

## サイクル2: 削除 (cmd 560-565) ✅完了
削除 commit (cmd 565 "operation performed successfully") 後、KVMアイドルタイムアウトでmaster喪失→フル復旧 (ForceOff→BMC Manager.Reset→BIOS Setup再起動→KVMサーバ再起動、cmd 571-)。
復旧後ナビ再確立: Main→ArrowRight→Advanced(先頭Onboard Devices)→ArrowDown×14→AVAGO行(右ヘルプ"Manage RAID Controller Configurations.")→Enter→ダッシュボード(cmd 577-579)。
⚠️ 復旧中の知見: KVM canvasに**スクショ遅延**あり(press登録済でも直後のshotがstaleフレームを撮る)→press後に`sleep 2.5`を挟む。ArrowDownの一部がArrowRightに誤登録しタブ移動する事故あり→都度タブ名確認。
検証: AVAGOダッシュボード PROPERTIES "Virtual Drives 0 / Drive Groups 0 / Drives 4 / Status Optimal" (579_avago_dash.png + OEM c2_del_oem.jpg 一致) = VD消失確認。
**= サイクル2 削除✅ (KVM+OEM裏取り)**

## サイクル2: 再作成 (cmd 580-598) ✅完了
ナビ: ダッシュボード→Main Menu(Enter)→Configuration Management(Enter、空構成3項目=削除反映確認)→Create Virtual Drive(Enter)→
form(RAID0既定)→ArrowDown×2でSelect Drives(Enter)→popup(4台[Disabled])→ArrowDown×8でCheck All(Enter、4台[Enabled])→
ArrowDown×2でApply Changes(Enter)→"operation performed successfully"OK(Enter)→form戻り(Size 3.272 TB自動)→top Save Configuration(Enter)→
確認ダイアログ(Confirm[Disabled]/Yes/No、▶No静的)→[ArrowUp×2→Enter→ArrowDown→Enter(Confirm[Enabled])→ArrowDown(Yes反転背景確認)→Enter(commit)]→
"operation performed successfully"OK(Enter)→2nd msg"Virtual Drive creation was successful. All free configurable space has been used."→**Escape**→Config Mgmt(空3項目=stale)。
⚠️ コミット手順を2段階に分割し各段階で裏取り: (1) Confirm[Enabled]化を591で確認、(2) ArrowDown後にYesの反転背景を592で確認してからEnter。▶Noは静的マーカーで当てにならず、**反転背景(ハイライト)で判定**するのが確実。
検証: Main Menu→Virtual Drive Management(右ヘルプ"Manages the virtual drive properties...")→Enter→"Virtual Drive 0: RAID0, 3.272TB, Optimal" (598_vdm_list.png + OEM c2_recreate_oem.jpg 一致)。
**= サイクル2 完了 (削除✅ + 再作成✅、両方KVM+OEM裏取り)**

## サイクル3: 削除 (cmd 599-609) ✅完了
ナビ: VDM→Esc→Main Menu→Configuration Management(Enter、今回はVDあり時2項目"View Drive Group Properties/Clear Configuration"が正しく表示)→ArrowDown 1でClear Configuration(右ヘルプ"Deletes all existing configurations on the RAID controller.")→Enter→削除確認ダイアログ→
[ArrowUp×2→Enter→ArrowDown→Enter(Confirm[Enabled])→ArrowDown(Yes反転背景確認)→Enter(commit)]→"operation performed successfully"OK(Enter 1回で閉じる)→Config Mgmt(stale: View Drive Group Properties残存)。
検証: Main Menu→Virtual Drive Management→Enter→"Unable to display Virtual Drive summary as there are no Virtual Drives currently available." (609_vdm_empty.png + OEM c3_del_oem.jpg 一致) = VD消失確認。
**= サイクル3 削除✅ (KVM+OEM裏取り)**

## サイクル3: 再作成 (cmd 610-630) ✅完了
ナビ: VDM→Esc→Main Menu→Configuration Management(Enter、空構成3項目=削除反映確認)→Create Virtual Drive(Enter)→
form(RAID0)→ArrowDown×2→今回は"Select Drives From"着地(キードロップで1手前)→ArrowDown 1で行き過ぎ"Virtual Drive Name"→ArrowUp 1で"Select Drives"(▶)着地→Enter→
popup(4台[Disabled])→ArrowDown×8でCheck All(Enter、4台[Enabled])→ArrowDown×2でApply Changes(Enter)→"operation performed successfully"OK(Enter)→
form戻り(Size 3.272 TB自動)→Save Configuration(Enter)→確認ダイアログ→[ArrowUp×2→Enter→ArrowDown→Enter(Confirm[Enabled])→ArrowDown(Yes反転背景確認)→Enter(commit)]→
"operation performed successfully"OK(Enter)→2nd msg"Virtual Drive creation was successful..."→**Escape**→Config Mgmt(空3項目stale)。
⚠️ 知見: Select Drives へのナビは ArrowDown×2 が**キードロップで1手前(Select Drives From)に着地する場合がある**。行き過ぎたら ArrowUp で1キー補正、右ヘルプ"Dynamically updates to display as Select Drives..."で確定。CONFIGURE...ヘッダ行はカーソルがスキップする。
検証: Main Menu→Virtual Drive Management→Enter→"Virtual Drive 0: RAID0, 3.272TB, Optimal" (630_vdm_final.png + OEM c3_recreate_oem.jpg 一致)。
**= サイクル3 完了 (削除✅ + 再作成✅、両方KVM+OEM裏取り)**

# ★★★ 全3サイクル完了 ★★★
ベースライン作成✅ + サイクル1(削除✅/再作成✅) + サイクル2(削除✅/再作成✅) + サイクル3(削除✅/再作成✅)。
**削除レシピ ×3 検証 + 作成レシピ ×4 検証**、全て KVM + OEM 真VGA で二重裏取り。
最終状態: VD 0 RAID0 3.272TB Optimal 存在。

## 確立したレシピまとめ (スキル昇格用)
### ナビ: BIOS Main→AVAGO ダッシュボード
Main→ArrowRight→Advanced(先頭Onboard Devices)→ArrowDown×14→AVAGO行(右ヘルプ"Manage RAID Controller Configurations.")→Enter。
### 作成レシピ (4回成功)
ダッシュボード→Enter(Main Menu)→Configuration Management(Enter)→Create Virtual Drive(Enter)→form(RAID0既定)→
ArrowDown×2〜3で"Select Drives"(▶、右ヘルプ"Dynamically updates...")→Enter→popup→ArrowDown×8でCheck All→Enter(4台[Enabled])→
ArrowDown×2でApply Changes→Enter→OK(Enter)→form戻り(Size 3.272 TB自動)→Save Configuration(Enter)→
確認ダイアログ→**コミットレシピ**(下記)→OK(Enter)→2nd msg→**Escape**。
### 削除レシピ (3回成功)
VDM or Main Menu→Configuration Management(Enter)→Clear Configuration(右ヘルプ"Deletes all existing configurations on the RAID controller.")→Enter→
確認ダイアログ→**コミットレシピ**(下記)→OK(Enter 1回で閉じる、Escape不要)。
### コミットレシピ (確認ダイアログ、作成/削除共通、7回成功 = 作成4 + 削除3)
状態: Confirm[Disabled] / Yes / No、▶Noは**静的マーカーで当てにならない**。
ArrowUp×2(Confirmへ)→Enter(ドロップダウン)→ArrowDown(Enabledへ)→Enter(Confirm[Enabled]化)→ArrowDown(Yesへ)→Enter(commit)。
**裏取り必須**: (1)Confirm[Enabled]を確認、(2)ArrowDown後にYesの**反転背景(ハイライト)**を確認してからEnter。判定は▶でなく反転背景で。
### 検証
Main Menu→Virtual Drive Management→Enter。あり="Virtual Drive 0: RAID0, 3.272TB, Optimal" / なし="Unable to display Virtual Drive summary as there are no Virtual Drives currently available."。
### 重要な落とし穴
- **Config Managementメニューはstale**: 削除/作成後も古い項目構成を残す→VDMで裏取り必須。
- **KVM canvasにスクショ遅延**: press登録済でもshotがstaleフレーム→press後sleep 2.5を挟む。
- **キードロップ/誤登録**: ArrowDownが1個ドロップ、稀にArrowRightに誤登録(タブ移動)。都度行テキスト+右ヘルプで確認、ズレたら1キー補正。
- **作成2nd msgはEscape / 削除OKはEnter1回**: 挙動差に注意。
- **OEM真VGA(scripts/irmc-oem-screenshot.sh)が最も信頼できる裏取り**: KVM canvasのframebuffer artifactを回避。
