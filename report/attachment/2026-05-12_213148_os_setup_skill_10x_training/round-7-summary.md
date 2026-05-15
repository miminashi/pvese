# Round 7 Summary

| trial | server | result | wall time | install attempt | 主要トピック |
|-------|--------|--------|-----------|-----------------|--------------|
| 7 | server14 | success | 64min | 2 | partman stuck (改善 10 trigger 2回目) → racreset soft |
| 7 | server15 | success | 60min | 1 | 1 attempt success |

## 累積統計 (Trial 1-7)

- **R430 partman stuck**: 2/7 trial = 29% (改善 10 で対処、racreset soft 100% 復旧)
- **GRUB sector read error**: 1/7 trial = 14% (Round 2 s15)
- **post-reboot default route loss**: 6/7 trial = 86% (改善 14 mitigation で対処)
- **LINBIT keyring absent**: 4/7 trial = 57% (改善 19 mitigation で対処)
- **最終成功率**: 7/7 = 100%
- **1 attempt 成功率**: 4/7 = 57% (失敗 3 件はすべて R430 hardware-class、racreset soft で 100% 復旧)

## skill 改善履歴の評価

| 改善 | trigger 回数 | 効果 |
|------|--------------|------|
| 0-1 (resetconfig / racreset soft / SCP Export 待ち / build-essential / GPG keyring) | 各 6-7 trial で全 trial 発動 | ✓ 必須 |
| 10 (partman early trigger) | 2 trial で発動 | ✓ 即時回復 |
| 14 (post-reboot route loss) | 6 trial で発動 | ✓ 確実回復 |
| netcfg/choose_interface select eno2 | 全 trial | ✓ |

## 新規 skill 改善候補 (Round 7.5)

### 改善 22: `z-fix-default-route` hook 不全
- **問題** (s14 trial 7): `pve-setup-remote.sh` が `/etc/network/if-up.d/z-fix-default-route` を install するが、final reboot 後の default route loss を防げていない
- **修正候補**: skill 範囲外 (script 修正)。skill では「final reboot 後も `dhclient -1 -v <dhcp_iface>` で route 復旧を確認」を追記
