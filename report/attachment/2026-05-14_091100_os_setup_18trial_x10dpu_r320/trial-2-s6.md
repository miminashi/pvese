# Trial 2 server6 レポート

- **結果**: **giveup** (ハードウェア物理故障による恒久的失敗)
- **開始時刻**: 2026-05-14T17:55:47+09:00
- **完了時刻**: 2026-05-14T19:25:08+09:00
- **所要時間 (wall)**: 約 1h29m
- **attempt 数**: 4 (3 attempt 連続失敗の上で念のため 4 回目を実施し HW 故障を確定)

## preseed workaround の必要性
**必要** (4 件すべて、Round 1+2 確定パターンと同じ):
- `netcfg/choose_interface select eno2np1` → `select auto`
- `apt-setup/use_mirror boolean false` → `boolean true`
- `apt-setup/no_mirror boolean true` → `boolean false`
- `apt-setup/cdrom/set-next boolean false` → `boolean true`

## 発動したリカバリ
- 既知問題 1 (find-boot-entry) → `boot-override Cd UEFI` workaround で成功
- Round 2 server4 と同じ orphan socat (UDP 5514) を検出・kill
- 各 attempt 間で ForceOff → umount → re-login → re-mount → boot-override → on

## 観察した問題

### 🚨 新規 (Round 2 server6 固有) — **物理ハードウェア故障**

1. **Failing DIMM P2-DIMMA1 (Uncorrectable memory component)**: 起動 POST に表示。Redfish Memory Health=Warning、System Health=Critical、TotalSystemMemoryGiB=16 GiB に低下 (Round 1 時より減)
2. **DXE--CSM Initialization (POST code AD) で 5 分以上停滞** (attempt 2): DIMM 故障で legacy ROM 初期化が異常に遅い
3. **ISOLINUX checksum / Failed to load ldlinux.c32** (attempt 1, 2): Legacy CSM 経路に流れ ISO 読み出しでメモリ破壊
4. **🚨 Kernel panic: Initramfs unpacking failed: uncompression error / Failed to execute /init (error -2)** (attempt 4 の KVM screenshot で確定): GRUB → kernel をロード → initramfs を解凍する際に DIMM 不良メモリ領域に当たって解凍失敗 → kernel panic → reboot loop
5. **BMC KVM canvas が完全 stale** (attempt 3 で 4 連続同一ハッシュ): GRUB 画面で停滞中
6. **SOL keepalive のみで stage 0** (attempt 1, 3, 4): kernel が console に到達する前に panic、SOL に installer 出力なし

### 既知 (workaround で対処済み)
- 問題 1 (find-boot-entry "ATEN Virtual CDROM" 失敗) → `boot-override Cd UEFI` で回避
- Round 2 server4 既発見の orphan socat (UDP 5514) — 開始時に検出 1 件 kill

## 最終検証
- SSH `root@pve6 pveversion`: **不到達** (OS install 未完了のため)
- vmbr0/vmbr1: **未構築**
- Web UI https://10.10.10.206:8006: **不到達**
- BMC は ForceOff、VirtualMedia umount、Boot Override Reset 済み (クリーン状態)

## ログ参照
- 試行ログ: `tmp/e28df8d0/trial-2-s6.log`
- SOL ログ: `tmp/e28df8d0/sol-install-s6-r2*.log`
- **決定的証拠 KVM screenshot (kernel panic)**: `tmp/e28df8d0/check-s6-r2-16.png`
- POST 停滞 (DXE--CSM): `tmp/e28df8d0/check-s6-r2-4.png`, `check-s6-r2-9.png`
- DIMM error 表示: `tmp/e28df8d0/check-s6-r2-3.png`
- ISOLINUX 失敗: `tmp/e28df8d0/check-s6-r2-1.png`, `check-s6-r2-6.png`

## Phase 別所要時間
| Phase | 時間 | 状態 |
|------|------|------|
| iso-download | 0m07s | done (cached) |
| preseed-generate | 0m23s | done (workaround 4 件) |
| iso-remaster | 0m09s | done (ハッシュ一致、skip) |
| bmc-mount-boot | 2m37s | done |
| install-monitor | failed | **kernel panic: initramfs uncompression error** |
| post-install-config 以降 | pending | (未到達) |

## 結論

Trial 1 (Round 1) ではメモリエラーが顕在化せず 33m38s で success だったが、Round 2 では DIMM P2-DIMMA1 の Uncorrectable memory error が POST に明示表示され、initramfs 展開を破壊することで kernel panic を引き起こす状態に進行した。

**ソフトウェア・設定では回復不可能な物理ハードウェア故障** であり、DIMM を物理的に交換・抜去するまで本機での OS install は不可能。

Issue #65 のデグレ検証目的では「server6 の物理故障」として記録。Round 3 では再試行するが結果は giveup 確実。**os-setup スキルのデグレではない**。
