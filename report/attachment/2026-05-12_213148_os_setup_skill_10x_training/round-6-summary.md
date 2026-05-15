# Round 6 Summary

| trial | server | result | wall time | install attempt | 主要トピック |
|-------|--------|--------|-----------|-----------------|--------------|
| 6 | server14 | success | 49min | 1 | post-reboot default route loss 5 trial 連続再現 (構造化) |
| 6 | server15 | success | 48min | 1 | LINBIT keyring absent + default route loss combined |

## 連続再現する hardware/scripts-class 問題

| 問題 | 再現回数 | 暫定対処 | 恒久対処候補 |
|------|----------|----------|--------------|
| post-reboot default route loss | 5/5 (Trial 2-6, s14/s15 共通) | `pre-pve-setup.sh` 再実行 | `pve-setup-remote.sh` 内部に route check + dhclient 埋込 |
| LINBIT keyring absent | 3/6 trial | 事前 ubuntu keyserver 取得 + scp 配置 | keyring 配置を mandatory step 化 |
| partman stuck (R430 hw issue) | 2/10 trial (20%) | racreset soft 回復 | (hardware-class, mitigation のみ) |
| GRUB sector read error | 1/10 trial (10%) | racreset soft 回復 | (hardware-class, mitigation のみ) |

## 新規 skill 改善候補 (Round 6.5)

### 改善 19: LINBIT keyring 事前配置を必須化
- **問題**: `pve-setup-remote.sh --linstor` 内部 GPG 取得は 50% で empty file (404)。次の apt が GPG 検証 fail
- **修正**: SKILL.md Phase 7 step 4 で keyring 事前配置を **必須ステップ** に格上げ (現状は「note」)

### 改善 20: pre-pve-setup.sh の冪等再実行を推奨パターンに
- **問題**: post-reboot で default route loss が安定再現 → pre-pve-setup.sh 再実行は推奨ではなく **必須回避策**
- **修正**: SKILL.md Phase 7 ステップ列に「step 3 (route 修正) → step 4 (post-reboot)」の通常フローに加え、「**post-reboot が apt fail で停止したら step 3 → step 4 を必ずもう 1 回実行する**」を追記

### 改善 21: post-reboot の root cause を別 issue 化
- 5 trial 連続再現は `pve-setup-remote.sh` 側の root-cause fix が必要 (skill 範囲を超える)
- skill 内では mitigation を強化、別 issue で `pve-setup-remote.sh` 改修を提起
