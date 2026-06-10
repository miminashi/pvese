# Server Mgmt タブ — TX1320 M3 (D3373-B1x) BIOS 設定リファレンス

iRMC (BMC) 連携・障害復旧 (ASR&R)・ウォッチドッグ等の管理機能タブ。
**WinSCU XML 非対象**のため、項目・値は KVM/OEM screenshot で採取する。

## 🔬 KVM 実機確認 (2026-06-10、training-tx1320)

実機 Server Mgmt タブを OEM/KVM screenshot で巡回。**実機の全項目を上から下まで採取**した
(現在値はすべて 2026-06-10 実測)。

| 項目 | 種別 | 現在値 (2026-06-10) | 備考 |
|------|------|---------------------|------|
| Firmware Version | 読み取り専用 | **9.69F** | iRMC FW (Phase 18 で 9.08F→9.69F 更新済) |
| SDRR Version | 読み取り専用 | **3.18 ID 0458** | Sensor Data Record Repository |
| Asset Tag | 編集可 (文字列) | System Asset Tag | SMBIOS type 3 の asset tag |
| Onboard Video | 設定 | [Enabled] | オンボード VGA (KVM/OEM screenshot が依存) |
| BIOS Parameter Backup | 設定 | [Disabled] | iRMC への BIOS 設定バックアップ |
| Boot Retry Counter | 数値 | 3 | ブート失敗時のリトライ回数 |
| Power Cycle Delay | 数値 | 7 | 電源サイクル時の遅延 (秒) |
| ASR&R Boot Delay | 数値 | 2 | Automatic Server Reconfiguration & Restart の遅延 |
| Temperature Monitoring | 設定 | [Disabled] | |
| Fan Control | 設定 | [Auto] | |
| Event Log Full Mode | 設定 | [Overwrite] | SEL 満杯時の挙動 (上書き) |
| Load iRMC Default Values | 設定 | [No] | iRMC 既定値ロード |
| **Power Failure Recovery** | 設定 | **[Always On]** | 電源喪失後の復帰ポリシー (常に On = 復電で自動起動) |
| **Serial Multiplexer** | 設定 | **[System]** | シリアルを System 側に多重化 (SOL/Console Redirection に関与) |
| Boot Watchdog | 設定 | [Disabled] | OS 応答監視ウォッチドッグ |
| ┗ Timeout Value | 数値 | 100 | Boot Watchdog のタイムアウト |
| ┗ Action | 設定 | [Continue] | タイムアウト時のアクション |
| ▶ iRMC LAN Parameters Configuration | サブメニュー | — | BMC ネットワーク設定 (情報・設定) |
| ▶ Console Redirection | サブメニュー | — | シリアルコンソールリダイレクト設定 |

> 注: 電源・ブート・iRMC ネットワークは Redfish (`scripts/bmc-power.sh` / `scripts/irmc-bios.py`) で操作する方が
> 確実。本タブはあくまで BIOS 内設定の参照用。
> **`Power Failure Recovery [Always On]`** により復電時は自動起動する (電源喪失後の手動 On 不要)。
> **`Serial Multiplexer [System]`** はホスト UART を System 側へ向ける設定。SOL は host が COM1
> (IO=3F8h IRQ=4) を System に出すことで成立する (Super IO > Serial Port [Enabled] と整合)。

<!-- iRMC LAN Parameters Configuration / Console Redirection サブメニューの内部項目は未採取
     (本プロジェクトでは BMC ネットワーク・SOL は Redfish/ipmitool で操作するため優先度低)。 -->
