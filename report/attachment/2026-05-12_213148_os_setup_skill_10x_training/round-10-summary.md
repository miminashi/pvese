# Round 10 Summary (Final)

| trial | server | result | wall time | install attempt | 主要トピック |
|-------|--------|--------|-----------|-----------------|--------------|
| 10 | server14 | success | **28min** | **1** | 最速、partman stuck 不発 |
| 10 | server15 | success | 48min | **1** | preseed-server15.cfg vFlash 除外 改善 25 実証 → partman 一発 |

## Round 9.5 改善 25 (preseed-server15 vFlash 除外) の検証

Round 9 attempt 1 では 8 min stuck → Round 10 では 7m11s で完走 (1 attempt)。**改善が実機で効果実証**。

## 累積最終統計 (Trial 1-10 = 20 server-trials)

| 指標 | 値 |
|------|-----|
| 最終成功率 | **20/20 = 100%** |
| 1 attempt 成功率 | 13/20 = 65% |
| 平均 wall time | ~56 min (28-78 min) |
| 平均 Phase total | ~35 min |
| partman stuck | 5/20 = 25% (R430 hw-class、racreset soft で 100% 復旧) |
| GRUB sector read error | 1/20 = 5% |
| initramfs dropout (false success) | 1/20 = 5% |
| post-reboot route loss | 9/10 trial = 90% (script root-cause fix が必要) |
| final reboot route loss | 6/10 trial = 60% |
| LINBIT keyring absent | 7/20 = 35% |
