# Round 8 Summary

| trial | server | result | wall time | install attempt | 主要トピック |
|-------|--------|--------|-----------|-----------------|--------------|
| 8 | server14 | success | 50min | 2 | partman stuck 3 回目 (37.5%) → racreset soft |
| 8 | server15 | success | 53min | 1 | dhcpcd IPv4LL fallback (新規) |

## 累積統計 (Trial 1-8 = 16 server-trials)

- partman stuck: 3/16 = 18.75% (改善 10 で対処)
- GRUB sector read error: 1/16 = 6.25%
- post-reboot default route loss: 8/16 = 50% (s14 で連続必発、s15 で散発)
- 1 attempt 成功率: 12/16 = 75%
- 最終成功率: 16/16 = 100%

## 新規 skill 改善候補 (Round 8.5)

### 改善 23: dhcpcd IPv4LL fallback 対処
- **問題** (s15 trial 8): `dhcpcd -1 -t 30 eno1` 初回で IPv4LL (169.254.x) になり実 DHCP 不取得
- **修正**: SKILL.md Phase 7 ステップ 0 で「dhcpcd で IPv4LL になったら `ip addr flush dev <iface>` → `dhcpcd -t 60 <iface>` 再試行」を追記
