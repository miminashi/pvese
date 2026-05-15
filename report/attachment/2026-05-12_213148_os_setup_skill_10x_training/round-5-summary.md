# Round 5 Summary

| trial | server | result | wall time | install attempt | 主要トピック |
|-------|--------|--------|-----------|-----------------|--------------|
| 5 | server14 | success | 44min | 1 | LC062 createvd retry, post-reboot default route loss 再現 |
| 5 | server15 | success | 76min | 2 | partman stuck → racreset soft (Round 3.5 改善 10 trigger 検証 OK) |

## Round 4.5 改善 15 (post-reboot default route loss) の検証
- **再現**: Trial 4 s15, Trial 5 s14/s15 で連続再発 → 安定再現する R430 + Debian 13 + PVE 9 の hardware-class 問題
- **対処**: `pre-pve-setup.sh` 再実行 → `pve-setup-remote.sh --phase post-reboot` 再実行 (冪等性で resume) で確実に回復
- 優先度高 → 改善 17 で pre-flight check ロジック明文化を検討

## 新規 skill 改善候補 (Round 5.5)

### 改善 16: partman stuck の SOL screen patterns
- **問題** (s15 trial 5): SOL に byobu status bar 表示 + installer-syslog で `No matching physical volumes found` 沈黙 12 分 で固着
- **修正**: SKILL.md Phase 5 step 4 の "partman stuck" 判定基準に「SOL に byobu status bar が表示されたまま」を追記

### 改善 17: pve-bridge-setup.sh 必須を明示
- **問題** (s15 trial 5): agent が `pve-setup-remote.sh` 後に `pve-bridge-setup.sh` 実行を見落とし、vmbr0 未作成のまま Web UI チェックして fail
- **状態**: SKILL.md Phase 8 step 5 に既に記述あり (`pve-bridge-setup.sh --static-iface eno2 ...`)。agent が読み落としたのでチェックリスト形式に強化
- **修正**: Phase 8 完了確認に「**必須**: `ssh root@<ip> ip link show vmbr0` で vmbr0 存在確認」を追記

### 改善 18: final reboot 後の default route 消失パターン
- **問題** (s14 trial 5): pve-bridge-setup の前段で default route 消失することがある (Round 4 改善 15 とは別箇所)
- **修正**: SKILL.md Phase 8 step 5 で「bridge setup 前に `ip route` 確認 → 必要なら `dhclient -1 -v <dhcp_iface>` で復旧」を追記
