<!-- 自動生成 (tmp/biosref/gen_bios_md.py) — WinSCU XML bios-backup-initial.xml (2026-05-16, D3373-B1x) 由来。
     手で 解説/PVE推奨 を追補し、KVM 確認後に「KVM 確認」を更新する。再生成時は手追補が消えるので注意。 -->

# Power タブ — TX1320 M3 (D3373-B1x) BIOS 設定リファレンス

> Wake-on-LAN・電源復帰ソース等。値は 2026-05-16 WinSCU XML 由来。所属は KVM 確認で確定。

## 🔬 KVM 実機確認 (2026-06-10、training-tx1320)

実機 Power タブを巡回確認。XML 3 設定すべて可視。**Power-on Source はメイン画面**、
**LAN / Wake On LAN boot は Wake-Up Resources サブメニュー内**。

**Power メイン画面 (= "Power Settings")**:
- Power-on Source (`0x00FF`) — ✅ 可視 [BIOS Controlled]
- ▶ Wake-Up Resources (サブメニュー)

**▶ Wake-Up Resources サブメニュー**:
- LAN (`0x0011`) — ✅ 可視 [Enabled]
- Wake On LAN boot (`0x001B`) — ✅ 可視 [Boot Sequence]

> 注: サーバの電源喪失後自動復帰は本タブではなく **Server Mgmt > Power Failure Recovery
> [Always On]** で制御される (training-tx1320 実測)。

#### LAN  (`WakeupLAN`, setupItemID `0x0011`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Allows the system to be switched on via a LAN wakeup."
- **KVM 確認**: ✅ 2026-06-10 (可視・冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Allows the system to be switched on via a LAN wakeup.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Wake On LAN boot  (`ForceLANBoot`, setupItemID `0x001B`)
- **選択肢**: Boot Sequence / Force LAN Boot
- **デフォルト**: Boot Sequence
- **現在値 (2026-05-16)**: Boot Sequence
- **ヘルプ**: 
  > [Boot Sequence]
  > Use Boot Sequence order after Wake On LAN.
  > [Force LAN Boot]
  > Force LAN boot after Wake On LAN (Option "Launch PXE OpROM" must be enabled to actually force a network boot).
- **KVM 確認**: ✅ 2026-06-10 (可視・冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) [Boot Sequence]
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Power-on Source  (`PowerOnSource`, setupItemID `0x00FF`)
- **選択肢**: BIOS Controlled / ACPI Controlled
- **デフォルト**: BIOS Controlled
- **現在値 (2026-05-16)**: BIOS Controlled
- **ヘルプ**: 
  > [BIOS Controlled]
  > Power-on sources are controlled by BIOS. Also valid for ACPI operating systems.
  > [ACPI Controlled]
  > Power-on sources are controlled by an ACPI operating system.
- **KVM 確認**: ✅ 2026-06-10 (可視・冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) [BIOS Controlled]
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

<!-- TODO: capture — XML 非対象のメニュー項目 (読み取り専用情報・サブメニュー) を KVM で追補 -->
