# Round 4 Summary

| trial | server | result | wall time | install attempt | 主要トピック |
|-------|--------|--------|-----------|-----------------|--------------|
| 4 | server14 | success | 44min | 1 | クリーン 1 attempt 成功 |
| 4 | server15 | success | 49min | 1 | default route が apt 中に消失 → pre-pve-setup 再実行で回復 |

## Round 3.5 改善 10-14 の検証

| 改善 | 結果 |
|------|------|
| 10. partman/GRUB 早期 racreset trigger | 両 trial で発動せず (1 attempt 成功) |
| 11. sol-login DETECTING timeout 延長 | s15 で SSH 到達後 sol-login 経由したため発動せず |
| 12. eno1 DOWN preventive | s15 で SOL `ip link set eno1 up` 明示実行で問題なし |
| 13. iDRAC SSH 復旧確認 | 発動せず |
| 14. LINBIT linstor-common ダウンロード時間 | s14/s15 で許容範囲 |

## 新規 skill 改善候補 (Round 4.5)

### 改善 15: post-reboot 中の default route 消失対応
- **問題**: `pve-setup-remote.sh --phase post-reboot` 実行中に **`ifupdown2` 再初期化** (proxmox-ve パッケージインストール時) が default route via 192.168.39.1 を消し、続く `apt update`/`apt install` が `Temporary failure resolving 'packages.linbit.com'` で失敗。`Unable to locate package drbd-dkms` も併発
- **修正**: SKILL.md Phase 7 step 4 で「post-reboot が apt fail で止まったら `pre-pve-setup.sh` を再度実行してルート修復 → post-reboot 再実行」を明記。または `pve-setup-remote.sh` の各 apt 系ステップ前に default route 検証を入れる (別 issue)
