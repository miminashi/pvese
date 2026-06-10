<!-- 自動生成 (tmp/biosref/gen_bios_md.py) — WinSCU XML bios-backup-initial.xml (2026-05-16, D3373-B1x) 由来。
     手で 解説/PVE推奨 を追補し、KVM 確認後に「KVM 確認」を更新する。再生成時は手追補が消えるので注意。 -->

# Security タブ — TX1320 M3 (D3373-B1x) BIOS 設定リファレンス

> Secure Boot・パスワード・FLASH Write 保護等。値は 2026-05-16 WinSCU XML 由来。所属は KVM 確認で確定。

## 🔬 KVM 実機確認 (2026-06-10、training-tx1320)

実機 Security タブを巡回確認。**メイン画面**に 3 設定 + パスワードアクション、**Secure Boot
Configuration サブメニュー**に Secure Boot 系がある。Password Severity は非表示。

**Security メイン画面 (上から)**:
- Password Description (情報): Minimum length **3** / Maximum length **32**
- Administrator Password (アクション、未設定)
- User Password (アクション、未設定)
- Password on Boot (`0x001A`) — ✅ 可視 [Disabled]
- Skip Password on WOL (`0x0013`) — ✅ 可視 [Disabled]
- FLASH Write (`0x0010`) — ✅ 可視 [Enabled]
- ▶ Secure Boot Configuration (サブメニュー)

**▶ Secure Boot Configuration サブメニュー**:
- System Mode: **User** (読み取り専用)
- Vendor Keys: **Not Modified** (読み取り専用)
- Secure Boot Control (`0x00E8`) — ✅ 可視 [Disabled] / 状態 "Not Active"
- Secure Boot Mode (`0x01B0`) — ✅ 可視 [Custom] (XML default=Standard と相違、実機も Custom 確認)
- ▶ Enter Deployed Mode (アクション)
- ▶ Key Management (サブメニュー) — Factory Default Key Provision (`0x00E9`) 等の鍵管理はこの中

| 設定 (XML) | 実機 | 所属 | 現在値 |
|---|---|---|---|
| FLASH Write (`0x0010`) | ✅ 可視 | Security メイン | [Enabled] |
| Skip Password on WOL (`0x0013`) | ✅ 可視 | Security メイン | [Disabled] |
| Password on Boot (`0x001A`) | ✅ 可視 | Security メイン | [Disabled] |
| Secure Boot Control (`0x00E8`) | ✅ 可視 | Secure Boot Configuration | [Disabled] (Not Active) |
| Factory Default Key Provision (`0x00E9`) | ▶ Key Management 内 | Secure Boot Configuration > Key Management | (XML [Enabled]) |
| **Password Severity (`0x0174`)** | ❌ **非表示** | — | NVRAM 変数のみ |
| Secure Boot Mode (`0x01B0`) | ✅ 可視 | Secure Boot Configuration | [Custom] |

#### FLASH Write  (`FlashWrite`, setupItemID `0x0010`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable or Disable FLASH write on Legacy boots."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable or Disable FLASH write on Legacy boots.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Skip Password on WOL  (`OnAutomaticWakeupm`, setupItemID `0x0013`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Password entry is not required on automatic Wakeup from LAN."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Password entry is not required on automatic Wakeup from LAN.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Password on Boot  (`PasswordOnBoot`, setupItemID `0x001A`)
- **選択肢**: On Every Boot / On First Boot / Disabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: 
  > On Every Boot - The password prompt appears on every boot.
  > On First Boot - The password prompt appears on cold boot only.
  > Disabled - The password is always taken from NV storage and there is no password prompt displayed.
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) On Every Boot - The password prompt appears on every boot.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Secure Boot Control  (`SecureBoot`, setupItemID `0x00E8`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Secure Boot can be enabled if 1.System running in User mode with enrolled Platform Key(PK) 2.CSM function is disabled"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Secure Boot can be enabled if 1.System running in User mode with enrolled Platform Key(PK) 2.CSM function is disabled
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: High

#### Factory Default Key Provision  (`DefaultKeyProvisioning`, setupItemID `0x00E9`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Provision factory default keys on next system re-boot while platform is in Setup Mode"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Provision factory default keys on next system re-boot while platform is in Setup Mode
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Password Severity  (`PasswordSeverity`, setupItemID `0x0174`)
- **選択肢**: Standard
- **デフォルト**: Standard
- **現在値 (2026-05-16)**: Standard
- **ヘルプ**: 
  > Standard - Password skip jumper can be used to clear a lost password.
  > Strong - Password skip jumper inoperable. In case of a lost password, unlocking only possible via service.
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Standard - Password skip jumper can be used to clear a lost password.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

#### Secure Boot Mode  (`SecureBootMode`, setupItemID `0x01B0`)
- **選択肢**: Standard / Custom
- **デフォルト**: Standard
- **現在値 (2026-05-16)**: Custom  ⚠️ デフォルトと相違
- **ヘルプ**: "Secure Boot mode selector. 'Custom' Mode allows for more flexibility changing Image Execution policy and Secure Boot Key management."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Secure Boot mode selector. 'Custom' Mode allows for more flexibility changing Image Execution policy and Secure Boot Key management.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: High

<!-- TODO: capture — XML 非対象のメニュー項目 (読み取り専用情報・サブメニュー) を KVM で追補 -->
