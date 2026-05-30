# TX1320 M3 RAID10 自動構成 (KVM リトライ路線)

## Context

`report/2026-05-16_130950_tx1320_bios_uefi_auto.md` の続き。 training-tx1320 (Fujitsu PRIMERGY TX1320 M3、 iRMC S4) の BIOS UEFI 化 (WinSCU XML 経由) は完了したが、 RAID10 自動構成 (BIOS UEFI HII の AVAGO MegaRAID Configuration Utility 経由) は **VGA frame buffer が更新されない問題** で中断していた。

本セッションでは前回 Phase 3 を再トライする。 ユーザ確定方針:

- **アプローチ**: BMC Manager Reset → KVM 自動化リトライ (Live OS + storcli ではない)
- **終着点**: RAID10 VD0 作成完了まで (OS install は別セッション)
- **BMC Manager Reset 許可** (Manager.Reset / FTSManager.Reset OEM ソフトリブート相当。 BMC ファクトリーリセットは別物で禁止)
- **他機種 (`bios-setup` / `perc-raid` skill) のアプローチを参考**: 同セッション完結、 screenshot-each、 長め wait、 frame refresh 誘発

(完全な plan は本セッション開始時の Plan モード成果物。 主要内容は本報告書本文のセクションに反映済み。)
