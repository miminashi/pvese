# Main タブ — TX1320 M3 (D3373-B1x) BIOS 設定リファレンス

読み取り専用の情報表示タブ。設定変更可能なのは System Language / System Date / System Time。
**KVM 確認: ✅ 2026-06-07** (OEM 真 VGA screenshot で全項目確認)。WinSCU XML 非対象。

> AMI Aptio Setup Utility Version **2.18.1263** (Copyright 2018 AMI)。タブ列:
> `Main / Advanced / Security / Power / Server Mgmt / Boot / Save & Exit` を実機で確認。

## BIOS Information (読み取り専用)

| 項目 | 値 |
|------|----|
| BIOS Vendor | American Megatrends |
| Customized by | Fujitsu |
| Core Version | 5.0.0.11 |
| Compliancy | UEFI 2.4; PI 1.3 |
| Access Level | Administrator |

## サブメニュー

#### ▶ System Information
- **KVM 確認**: ✅ 2026-06-10 (サブメニュー内全項目を OEM/KVM で採取)
- **右ヘルプ**: "This submenu provides details on the system configuration"
- **解説**: CPU 型番・メモリ構成・各種バージョン等のシステム詳細を表示する読み取り専用サブメニュー。
- **リスク**: Safe (情報表示のみ)

System Information サブメニュー内の表示項目 (読み取り専用、2026-06-10 実測):

| グループ | 項目 | 値 |
|---------|------|----|
| Board & Firmware Details | BIOS Revision | R1.22.0 |
| | Build Date and Time | 12/18/2018 08:14:34 |
| | Board GS | D3373-B12 3 |
| | Product Name | PRIMERGY TX1320 M3 |
| | Ident Number | MABK035229 |
| | UUID | 80E0F020-C0C9-4222-A774-BA264F9EC23C |
| | SPS Firmware Version | 4.1.4.54 |
| Network Controller Details | LAN 1 MAC Address | 4C:52:62:14:A5:5C |
| | LAN 2 MAC Address | 4C:52:62:14:DE:F0 (= eno2 dark-net、deploy で IP discovery に使う MAC) |
| | LAN 1 / LAN 2 FW Revision | 1.40 / 1.40 |
| Processor Details | Processor Type | Intel(R) Xeon(R) CPU E3-1220 v6 @ 3.00GHz |
| | CPU-/Patch-ID | 906E9 / 0000009A |
| | Processor Speed | 3000 MHz |
| | Cache Counts & Sizes | 4x64 KB / 4x256 KB / 1x8 MB (L1/L2/L3) |
| | Active Package, Core | 1(1) Package(s) 4(4) Core(s) |
| | Thread Count (maximum) | 4(4) Thread(s) |
| Memory Details | Memory Size / Frequency | 24576 MB (2400 MHz) |

#### ▶ Open Source Software License Information
- **KVM 確認**: ✅ 2026-06-07
- **解説**: OSS ライセンス表示。設定なし。
- **リスク**: Safe

## 設定可能項目

#### System Language
- **選択肢**: English (他言語の有無は要確認)
- **現在値 (2026-06-07)**: [English]
- **KVM 確認**: ✅ 2026-06-07
- **解説**: BIOS Setup の表示言語。
- **リスク**: Safe

#### System Date
- **形式**: [曜 MM/DD/YYYY]
- **現在値 (2026-06-07)**: [Sun 06/07/2026]
- **KVM 確認**: ✅ 2026-06-07
- **解説**: システム日付。OS が NTP で上書きするため通常変更不要。
- **リスク**: Safe

#### System Time
- **形式**: [HH:MM:SS]
- **現在値 (2026-06-07)**: [07:47:40] (採取時刻)
- **KVM 確認**: ✅ 2026-06-07
- **解説**: システム時刻 (ローカルタイム)。OS が NTP で上書きする。
- **リスク**: Safe

## 読み取り専用情報 (一部は System Information サブメニュー内、未採取)

| 項目 | 値 |
|------|----|
| BIOS Core Version | 5.0.0.11 |
| BIOS 完全版数 | V5.0.0.11 R1.22.0 for D3373-B1x (Redfish `BiosVersion`) |
| AMI Aptio Version | 2.18.1263 |
| System ID | TX1320M3F2 |
| MainBoard | FUJITSU D3373, PartNumber S26361-D3373-B12, Version WGS03 GS03 (Redfish) |
| Serial Number | MABK035229 |
| CPU 型番 / 周波数 / コア数 | Intel(R) Xeon(R) CPU E3-1220 v6 @ 3.00GHz / 3000 MHz / 4C4T (2026-06-10 実測) |
| Total Memory | 24576 MB = 24 GiB (System Information / Redfish `MemorySummary` 一致) |
| Memory Frequency | 2400 MHz (2026-06-10 実測) |
| SPS Firmware Version | 4.1.4.54 |
| BIOS Build Date | 12/18/2018 08:14:34 (R1.22.0) |
