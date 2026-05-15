# Round 9 Summary

| trial | server | result | wall time | install attempt | 主要トピック |
|-------|--------|--------|-----------|-----------------|--------------|
| 9 | server14 | success | 53min | 3 | partman stuck + initramfs dropout (新規) |
| 9 | server15 | success | 76min | 2 | partman stuck → racreset soft |

## 新規 skill 改善候補 (Round 9.5)

### 改善 24: sol-monitor false-success + initramfs dropout
- **問題** (s14 trial 9 attempt 2): sol-monitor exit 0 で「installation completed」を返したが、実 OS が `(initramfs)` プロンプトで停止していた。partman の「No root file system」dialog が preseed に auto-confirm されたが rootfs が実際は空のまま install monitor 完了
- **検出**: SOL probe で Enter flood して `(initramfs)` プロンプトが返ってきたら判定可
- **修正**: SKILL.md Phase 5 step 5 の False positive 防止に「`(initramfs)` プロンプト検出」を追加。`/etc/machine-id` mtime チェックでも検出可だが、その前段で initramfs に落ちた場合 SSH 不到達のため stage 5 検証が必要

### 改善 25: preseed-server15.cfg を server14 と同パターンに統一
- preseed-server15.cfg の partman early_command が `for disk in $(list-devices disk)` を使い /dev/sdb (vFlash SD slot) を catch する
- preseed-server14.cfg は `for disk in /dev/sda; do [ -b "$disk" ] || continue` で明示制限
- 修正: preseed-server15.cfg を server14 と同じパターンに更新

## 累積統計 (Trial 1-9 = 18 server-trials)

- partman stuck: 5/18 = **28%** (R430 hardware-class、racreset soft で 100% 復旧)
- GRUB sector read error: 1/18 = 6%
- sol-monitor false success + initramfs: 1/18 = 6% (新規)
- post-reboot route loss: 9/18 = **50%** (s14 で連続必発)
- LINBIT keyring absent: 6/18 ≈ 33%
- 1 attempt 成功率: 11/18 = **61%**
- 最終成功率: 18/18 = **100%**
