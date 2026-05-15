# Round 3 Summary

| trial | server | result | wall time | phase total | install attempt | 主要トピック |
|-------|--------|--------|-----------|-------------|-----------------|--------------|
| 3 | server14 | success | 78m03s | 38m | 2 | partman stuck at stage 5/9 "No matching physical volumes" → racreset soft で回復 |
| 3 | server15 | success | 58m35s | 40m37s | 1 | LINBIT linstor-common (56MB) ダウンロード遅延、eno1 default DOWN |

## Round 2.5 改善 6-9 の検証

| 改善 | 結果 |
|------|------|
| 6. LINBIT GPG empty-file detect → 事前配置 | ✓ 両 trial で機能 (trial2 keyring 再利用) |
| 7. build-essential 事前 install | ✓ DKMS build 一発成功 |
| 8. SCP Export job 完了待ち | ✓ s14 で発動 (Export Status Running→Completed)、s15 では Export job 自体 unspawned (条件依存) |
| 9. sol-login printf > file WARN 誤検知 | ✓ 両 trial で誤検知確認 (実体は成功) |

## 新規 skill 改善候補 (Round 3.5)

### 改善 10: partman-auto-lvm 固着の早期判定 (R430 hardware-class issue)
- **問題**: 3 trial 中 1 回 (33%) R430 で partman が "No matching physical volumes found" の後 stage 5/9 で 25 分以上固着。Round 2 s15 の GRUB sector read fail と同種の R430+PERC 不安定挙動
- **修正**: SKILL.md Phase 5 step 4 / step 5 に「stage 5/9 で 15 分以上停滞 + installer-syslog が同種エラー (`No matching physical volumes`, `partman: ...failed`) で沈黙 → 真の失敗。3 連続失敗を待たずに即 racreset soft + 再 install」を追記

### 改善 11: sol-login.py DETECTING timeout 延長
- **問題**: R430 Debian 13 minimal の最初の boot 後、sol-login.py が 180 秒で login prompt 検出を諦める
- **修正**: SKILL.md Phase 6 step 3 で「最初の sol-login.py が DETECTING で fail したら 120-180 秒待って再試行」または `--detect-timeout 360` 推奨を追記

### 改善 12: eno1 DHCP iface を preseed late_command で auto に
- **問題**: preseed `netcfg/choose_interface select eno2` の副作用で `eno1` が `/etc/network/interfaces` に未記述、boot 後 DOWN 状態。SOL から `ip link set eno1 up` + `dhcpcd` を毎回実行する必要
- **修正**: preseed-server14.cfg / preseed-server15.cfg の late_command に `printf 'auto eno1\niface eno1 inet manual\n' >> /target/etc/network/interfaces` を追記。または SKILL.md Phase 6 step 3 のコマンドリストに `ip link set eno1 up` を明記

### 改善 13: ssh-wait.sh の iDRAC SSH user/key 対応
- **問題**: `ssh-wait.sh` は `root@host` のみ試行し iDRAC SSH (claude user, key auth) に対応していない
- **修正**: SKILL.md Phase 5 step 4 (racreset soft) で「iDRAC SSH 復旧確認は `ssh -F ssh/config idrac<N> racadm getsysinfo` を 30 秒間隔でポーリングする」を明記。ssh-wait.sh の機能拡張は別 issue 化

### 改善 14: LINBIT linstor-common ダウンロード時間に注意
- **問題**: `packages.linbit.com` から `linstor-common` (56.6 MB) ダウンロードが ~150 KB/sec で 5-15 分かかる
- **修正**: SKILL.md Phase 7 step 4 で「LINBIT 経由ダウンロードは時間依存性が高い。apt が止まっているように見えても `/var/cache/apt/archives/partial/` のファイルサイズが増えていれば正常」を注記
