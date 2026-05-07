# Plan: pve10 boot loop 復旧 + AOS Phoenix Foundation imaging 再試行

## Context

[Phase 4 レポート](/home/ubuntu/projects/pvese/report/2026-05-07_053810_server10_hw_err_phase4.md) の Plan B-alt 終端で pve10 が以下の状態に陥った:

- Debian の `/etc/default/grub` に `mpt3sas.prot_mask=1` を追加 → device 名が swap (sda=Seagate, sdb=Toshiba boot) → `grub-probe: error: cannot find a GRUB drive for /dev/sdb1` の状態で `grub-reboot` 実行
- 結果、UEFI Boot Manager が boot device を解決できず PXE fallback → `Reboot and Select proper Boot device` の boot loop
- ユーザにより BMC ForceOff 済 (現在電源 Off)

また、Phase 4 で AOS Phoenix Foundation imaging を BMC VirtualMedia 経由で試みたが、~10Mbps 帯域で `tar.p00` (~5GB) の読み込みが 10 分以上停滞し打ち切った。pve10 sda には Plan B-alt の遺産として Debian 13 + `/aos-ce.iso` (6.7GB = `phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso`) が残っているため、これを **GRUB loopback boot** で local I/O から再試行できる。

本プランは以下を達成する:
1. boot loop を BIOS Setup 介入 (A1) で復旧 → sda の Debian と AOS ISO を温存
2. Debian 安定化 (B): `mpt3sas.prot_mask=1` を grub config から削除し、device 名を元 (sda=Toshiba, sdb/sdc=Seagate) に戻す
3. AOS imaging を GRUB loopback (C1) で再試行 — local sda I/O (~13MB/s) で `tar.p00` 5GB を 6-7 分で読み込み完走を期待
4. Phase C の成否を Phase 4 レポートで未確定だった「AOS imaging 完走後に host から Seagate HDD への write が解禁されるか」の最終検証材料とする

完了条件 (Phase 4 と同じ):
- pve10 で `dd if=/dev/zero of=/dev/sdc bs=512 count=1 oflag=direct` が AOS imaging 後に成功する
- または ASC=0x81 が依然として発生し「opcode filter は drive firmware で host bypass 不能」の Phase 3/4 結論が確定

リスク受容 (Phase 4 と同じ): HDD brick 許容、PVE OS 再インストール許容、累積タイムボックスは Phase 4 セッション分を含めて 18 時間以内。

## ユーザの意思決定 (確認済)

- Phase A: **A1 BIOS Setup 介入** (sda の Debian + AOS ISO 温存)
- Phase C: **C1 GRUB loopback boot** (local I/O で imaging)

C1 が PHOENIX label 解決失敗で dracut shell に落ちた場合は、ユーザに再相談して C3 (BMC VirtualMedia 60-90 分待機) に切替判断する。

## 環境

| 項目 | 値 |
|------|------|
| ホスト | pve10 / ayase-web-service-10 / 10.10.10.210 |
| BMC | 10.10.10.30 (claude / Claude123、10号機 BMC ユーザ index=4) |
| OEM | Nutanix NX-1065-G5 / Supermicro X10DRT-P |
| 残存 ISO | sda 上 `/aos-ce.iso` (6.7GB) + SMB host `\\10.1.6.1\public\phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso` (fallback 用) |
| Boot Mode | UEFI (Phase 4 で Debian preseed が UEFI installer を使用) |

(以下、実装ステップ・重要ファイル・CLAUDE.md 制約・検証・工数見積は実装中に Phase A2/C3 へ動的調整。詳細は元プラン参照。)
