(see /home/ubuntu/.claude/plans/report-2026-05-16-235440-tx1320-raid10-k-golden-candle.md — copied content below)

# TX1320 M3 RAID10 自動構成 — Playwright 改修 + KVM 経路再開

## Context

前セッション ([report/2026-05-16_235440_tx1320_raid10_kvm_kbd_dead.md](../../2026-05-16_235440_tx1320_raid10_kvm_kbd_dead.md)) の続き。 training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4) で BIOS UEFI 化と AVAGO MegaRAID HII Main 画面進入までは確定済み。 RAID10 VD0 作成は中断していた。

中断原因は **`scripts/irmc-kvm-interact.py` (Playwright 自動化) の不具合** と確定 (2026-05-17 ユーザ手動検証で BMC HTML5 KVM 自体は健全):

1. **canvas screenshot が常に真っ黒** — `canvas#kvm.toDataURL()` が画素 sum=0。 viewer.min.js が WebGL `preserveDrawingBuffer: false` で canvas を作っていると推定 (DevTools の要素 screenshot は OK)
2. **キー送信が host に届かない** — `focus_kvm()` の `processing_maindiv` overlay 隠し → `canvas.focus()` → `click(force=True)` 経路で viewer.min.js の listener に届かない可能性

本セッションのゴール:

- **A**: `irmc-kvm-interact.py` を改修し、 ArrowDown 1 回送って実機 cursor が動くことを smoke test で確定
- **B**: dispatcher `setup-raid10` (S1-S10) で BIOS Setup 再進入 → AVAGO HII キーシーケンス探索 → RAID10 VD0 作成 → 検証まで通す
- **C**: `config/training_tx1320.yml` の `raid_setup.*` を埋め、 次回以降の再現可能性を担保

[完全な plan 内容は /home/ubuntu/.claude/plans/report-2026-05-16-235440-tx1320-raid10-k-golden-candle.md 参照]
