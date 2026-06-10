<!-- 自動生成 (tmp/biosref/gen_bios_md.py) — WinSCU XML bios-backup-initial.xml (2026-05-16, D3373-B1x) 由来。
     手で 解説/PVE推奨 を追補し、KVM 確認後に「KVM 確認」を更新する。再生成時は手追補が消えるので注意。 -->

# Boot タブ — TX1320 M3 (D3373-B1x) BIOS 設定リファレンス

> ブート順・NumLock・Quiet Boot 等。値は 2026-05-16 WinSCU XML 由来。所属は KVM 確認で確定。

## 🔬 KVM 実機確認 (2026-06-10、training-tx1320)

実機 Boot タブを OEM/KVM screenshot で巡回し、各 XML 設定の存在を確認した。**Boot タブは
サブメニューなしのフラット 1 ページ**。8/9 設定が可視、1 設定 (PXE boot wait time) は非表示。

| 設定 (XML) | 実機 | 現在値 (2026-06-10) |
|---|---|---|
| Bootup NumLock State (`0x0024`) | ✅ 可視 | [On] |
| Quiet Boot (`0x0080`) | ✅ 可視 | [Disabled] |
| Check controllers health status (`0x014E`) | ✅ 可視 | [Enabled] |
| Boot error handling (`0x00B0`) | ✅ 可視 | [Continue] |
| Keep Void Boot Options (`0x0102`) | ✅ 可視 | [Disabled] |
| New Boot Option Policy (`0x01BC`) | ✅ 可視 | [Place First] |
| PXE Boot Option Retry (`0x011D`) | ✅ 可視 | [Disabled] |
| Boot Removable Media (`0x0048`) | ✅ 可視 | [Enabled] |
| **PXE boot wait time (`0x014D`)** | ❌ **非表示** | NVRAM 変数のみ (Setup UI に出ない。PXE Retry 等の条件付き抑制と推定) |

**実機の画面並び (上から)**: Bootup NumLock State → Quiet Boot → Check controllers health status →
Boot error handling → Keep Void Boot Options → (空行) → New Boot Option Policy → PXE Boot Option Retry →
Boot Removable Media → (空行) → **Boot Option Priorities** セクション。

**Boot Option Priorities (2026-06-10 実測、deploy 済 PVE 状態)**:
- Boot Option #1 / #2: `debian` (インストール済 PVE の UEFI ブートエントリ ×2)
- Boot Option #3: `UEFI: IP4 Intel(R) I210 Gigabit Network Connection`
- Boot Option #4: `UEFI: IP6 Intel(R) I210 Gigabit Network Connection`
- Boot Option #5: `UEFI: IP4 Intel(R) I210 Gigabit Network Connection`
- Boot Option #6: `UEFI: IP6 Intel(R) I210 Gigabit Network Connection`

> 注: Boot Option Priorities / Boot Override の各エントリは XML には無い動的項目。Redfish
> `bmc-power.sh boot-override <Hdd|Cd|Pxe>` で 1 回限りのオーバーライドを行う方が確実。

#### Bootup NumLock State  (`Numlock`, setupItemID `0x0024`)
- **選択肢**: On / Off
- **デフォルト**: Off
- **現在値 (2026-05-16)**: On  ⚠️ デフォルトと相違
- **ヘルプ**: "Select the keyboard NumLock state"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Select the keyboard NumLock state
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Boot Removable Media  (`BootfromRemovableMedia`, setupItemID `0x0048`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "This option enables/disables support for booting to removable devices, such as USB flash drives."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) This option enables/disables support for booting to removable devices, such as USB flash drives.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Quiet Boot  (`QuietBoot`, setupItemID `0x0080`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enables or disables Quiet Boot option"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables or disables Quiet Boot option
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Boot error handling  (`BootErrorHandling`, setupItemID `0x00B0`)
- **選択肢**: Continue / Pause and wait for key
- **デフォルト**: Continue
- **現在値 (2026-05-16)**: Continue
- **ヘルプ**: 
  > Determines what to do on boot errors:
  > Pause and wait for key OR
  > continue.
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Determines what to do on boot errors:
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Keep Void Boot Options  (`KeepOrphanFwBootOption`, setupItemID `0x0102`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: 
  > [Enabled] Keeps the FW boot options for devices no longer connected to the system. Useful to keep the position of the void boot options in the boot order list until next re-connection to a device.
  > [Disabled] Remove the FW boot options for devices no longer connected to the system.
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) [Enabled] Keeps the FW boot options for devices no longer connected to the system. Useful to keep the position of the void boot options in the boot order list until next re-connection to a device.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### PXE Boot Option Retry  (`PxeBootOptionRetry`, setupItemID `0x011D`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "This will continually retry NON-EFI based PXE boot options without waiting for user input."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) This will continually retry NON-EFI based PXE boot options without waiting for user input.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### PXE boot wait time  (`PxeBootWaitTime`, setupItemID `0x014D`)
- **選択肢**: 範囲 0–5 (数値)
- **デフォルト**: 0
- **現在値 (2026-05-16)**: 0
- **ヘルプ**: "Wait time to press ESC key to abort the PXE boot"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Wait time to press ESC key to abort the PXE boot
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Check controllers health status  (`CheckControllersHealthStatus`, setupItemID `0x014E`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enables or disables checking of health status of hardware components"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables or disables checking of health status of hardware components
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### New Boot Option Policy  (`wBootOptionPolicy`, setupItemID `0x01BC`)
- **選択肢**: Default / Place First / Place Last
- **デフォルト**: Place First
- **現在値 (2026-05-16)**: Place First
- **ヘルプ**: "Controls the placement of newly detected UEFI boot options, for non removable media"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Controls the placement of newly detected UEFI boot options, for non removable media
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

<!-- TODO: capture — XML 非対象のメニュー項目 (読み取り専用情報・サブメニュー) を KVM で追補 -->
