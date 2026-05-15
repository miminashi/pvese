# Trial 1 server9 レポート

- **結果**: **giveup** (3 attempt 連続失敗)
- **開始時刻**: 2026-05-14 15:35:52 JST
- **完了時刻**: 2026-05-14 16:37:33 JST
- **所要時間 (wall)**: 約 1h 02m
- **attempt 数**: 3

## Phase 別所要時間

| Phase | 所要時間 | 状態 |
|-------|---------|------|
| iso-download | 11s | done (再利用) |
| preseed-generate | 5s | done (手動管理ファイル既存) |
| iso-remaster | 1m 59s | done |
| bmc-mount-boot | 3m 23s | done |
| install-monitor | failed | giveup |
| post-install-config 以降 | -- | pending (未到達) |

## 発動したリカバリ

| リカバリ | 回数 | 結果 |
|---------|-----|-----|
| VirtualMedia "remote image already configured" → umount → 5s → 再 mount | 2 回 | 復旧成功 |
| SOL 経由 Enter 送信 (`<Continue>` ダイアログ脱出 / GRUB Auto Boot 強制起動) | 2 回 | attempt 1: 一時的に installer 再開 / attempt 3: 効果不明 |
| **racreset soft** (early trigger) | 1 回 | iDRAC 復旧 OK だが **VirtualMedia config 消失** → 再 mount 必要 |
| KVM screenshot による状態確認 | 10 回 | 補助情報のみ |

## 観察した問題

### 既知 (SKILL.md 記載済み or server7/8 既出)
- **VirtualMedia "remote image already configured"**: attempt 1/3 開始時。umount → 5s → 再 mount で復旧
- **iDRAC SOL session の `bmc-power.sh status` timeout**: bmc-power.sh は Supermicro 用、sol-monitor の PowerState polling timeout は server7-8 でも観測 (既知挙動)
- **R320 BIOS POST が長い (CSIOR で 1-3 分)**: SKILL.md 通り

### 🚨 新規 (server9 個体差、デグレ検証として重要)

1. **attempt 1: `grub-install /dev/sda failed` → `<Go Back>` ダイアログで installer 停止** (NEW)
   - SOL log で `Executing 'grub-install /dev/sda' failed.` `This is a fatal error.` を観測
   - **Issue #47 (R320 NVRAM 枯渇) の症状と一致**
   - preseed の `early_command` で EFI Boot variables を clear する処理は走ったが、grub-install が最初の試行で fail
   - `--force-efi-extra-removable` フォールバックは走らない (dialog で停止)

2. **attempt 2/3: GRUB menu まで到達するが kernel boot 不能で boot loop** (NEW、非常に異常)
   - SOL に `The highlighted entry will be executed automatically in 3s.` が表示されるが、kernel boot へ進まない
   - manual Enter 送信しても効果なし
   - KVM screenshot で実画面は真っ暗 (resolution 800x600、kernel が VGA framebuffer init していない)
   - SOL log は GRUB menu の refresh のみ。kernel `Loading Linux` 等の出力なし
   - **推定原因**: attempt 1 の grub-install fail 過程で **EFI NVRAM の VirtualMedia boot entry (Optical.iDRACVirtual.1-1) が削除**された (FW 2.65.65.65 の既知バグ)、もしくは ISO の grub config が corrupt

3. **`racreset soft` 後 VirtualMedia config 消去** (新規確認、SKILL.md 未記載):
   - racreset soft 完了後 `idrac-virtualmedia.sh verify` で `Remote File Share is Disabled` を返す
   - 再 mount + boot-once 再設定が必要
   - server7/8 では racreset soft 不要だったので未確認だった

## 最終検証 (success の場合のみ)

**全て未達** (Phase 4 で giveup):
- pveversion / ip route / vmbr / Web UI / IB: いずれも N/A

## ログ参照

- `tmp/e28df8d0/trial-1-s9.log` — タイムスタンプ
- `tmp/e28df8d0/sol-install-s9.attempt1.log` (180 lines, grub-install fail 含む)
- `tmp/e28df8d0/sol-install-s9.attempt1b.log` — post-Enter
- `tmp/e28df8d0/sol-install-s9.attempt2.log` (192KB, BIOS POST loop)
- `tmp/e28df8d0/sol-install-s9.attempt3.log` (191KB, GRUB menu loop)
- `tmp/e28df8d0/check1.png` 〜 `check10.png` — KVM screenshots
- `state/os-setup/server9/` — phase state (install-monitor failed mark 済み)

## build-essential 事前 install で drbd-dkms 失敗を予防できたか

**未検証**: Phase 7 まで到達しなかったため (install-monitor で giveup)、確認できず。

## 追加考察 (Round 1 全体への示唆)

- Round 1 server7/8 では成功した同じ preseed (preseed-server9.cfg は server7/8 とほぼ同形式) で、server9 だけ grub-install fail + kernel boot 不能
- **個体差仮説**: server9 の EFI NVRAM が累積 entry で枯渇、または iDRAC FW 2.65.65.65 の特定 BIOS NVRAM state が破損
- **Round 2 server9 への推奨**: BIOS F3 Load Defaults (Setup から、racadm 経由ではない) で NVRAM をクリーンにする (idrac7 スキルの「VirtualMedia ブート復旧手順」相当)。BootMode・SerialComm の再設定が必要なので racadm + KVM 操作

## Issue 提案 (Round 1 終了時に親が判断)

- **Issue #47 (NVRAM 枯渇 Phase 6) の Phase 5 拡張**: 現在 #47 は post-install grub-install エラー記述だが、server9 では preseed 初回 install 時の grub-install で発火
- **iDRAC 用 sol-monitor stage 検出強化提案**: stage 0 のまま 5 分以上経過 (kernel boot signature 不在) → 別途自動 racreset soft + 再 mount のトリガーを SKILL.md に追加すべき
- **`racreset soft` 後の VirtualMedia config 消失** を SKILL.md に追記
