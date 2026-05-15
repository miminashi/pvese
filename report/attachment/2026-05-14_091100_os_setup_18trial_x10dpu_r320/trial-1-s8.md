# Trial 1 server8 レポート

- **結果**: success
- **開始時刻**: 2026-05-14 14:49:05 JST
- **完了時刻**: 2026-05-14 15:33:48 JST
- **所要時間 (wall)**: 約 44 分 43 秒
- **attempt 数**: 1 (install 1 回完走、Phase 7 のみ DKMS リカバリで 1 ステップ追加実行)

## 発動したリカバリ

| 既知罠 | 発生 | 対処 | 回数 |
|--------|------|------|------|
| VirtualMedia "remote image already configured" | Phase 4 | `idrac-virtualmedia.sh umount` → sleep 6s → 再 mount | 1 回 |
| LINBIT keyring 事前配置 | Phase 7 (pre-empt) | tmp/e28df8d0/linbit-keyring.gpg を scp で `/usr/share/keyrings/` に配置 | 1 回 (preventive) |
| drbd-dkms ビルド失敗 (`stdio.h: No such file`) | Phase 7 post-reboot | `apt-get install -y build-essential` → drbd-dkms 自動再ビルド → post-reboot 再実行で resume | 1 回 |

## 観察した問題

### 既知 (server7 と同じか SKILL.md 記載のもの)

- **VirtualMedia "remote image already configured"** (SKILL.md 記載) — Phase 4 で発火。umount → 5s → 再 mount のリカバリで一発復旧。server7 と同症状
- **drbd-dkms `stdio.h: No such file` 失敗** (SKILL.md Round 2 s14 で記載) — `--linstor` 完了後の DKMS ビルドが build-essential / libc6-dev 不在で失敗。事前 `apt install build-essential` を入れていなかったため発火 (pre-empt 手順を取り損ねた)。事後リカバリ手順 (apt install build-essential → drbd-dkms 自動再ビルド → `pve-setup-remote.sh --phase post-reboot --linstor` 再実行) で復旧
- **Phase 6 第1回 SSH 失敗** — 初回 SSH 鍵未配置のため `ssh-wait.sh` (root key auth) が timeout した。skill 通り `sol-login.py` で鍵を deploy → SSH 即接続成功 (server7 同様)
- **R320 POST 長時間** — Phase 6 (Power On → SSH 到達) は約 190s、Phase 7 final reboot 後の SSH 到達も約 180s。R320 + iDRAC7 の Lifecycle Controller 初期化込みで POST 2-3 分という SKILL 記載どおり

### 新規 (server7 で見えなかった iDRAC 固有問題、server8 個体差)

- **server7 (trial-1-s7) では drbd-dkms ビルド失敗が発生しなかった** が server8 では発火。両 trial とも build-essential 事前 install を skip したが server7 trial 時点では drbd-dkms が成功した模様。両回トライアル間の package 状態差か個体差で再現性が中程度であることが示唆される (今後の trial で build-essential 事前 install を pre-empt 手順に固定化推奨)
- **Phase 7 final reboot 後の default route が壊れていなかった** — SKILL.md の「Phase 7 final reboot 後 default route 消失 → dhclient -1 -v eno2」が server8 では発生せず。pve-setup-remote.sh の `/etc/network/if-up.d/z-fix-default-route` hook が server8 では効いた

## 最終検証 (success)

```
pveversion:    pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)
ip -brief addr:
  vmbr0            UP       10.10.10.208/8
  vmbr1            UP       192.168.39.129/24
ip route show default: default via 192.168.39.1 dev vmbr1
Web UI:        https://10.10.10.208:8006 → HTTP 200
IB:            (server8 は IB 非搭載、Phase 8 IB セットアップ skip)
```

## ログ参照

- `tmp/e28df8d0/trial-1-s8.log`
- `tmp/e28df8d0/sol-install-s8.log` (Stage progression: LOADING_COMPONENTS → CONFIGURING_APT → INSTALLING_SOFTWARE → INSTALLING_GRUB → POWER_DOWN)
- `state/os-setup/server8/`
- `preseed/preseed-server8.cfg`

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 0m19s |
| preseed-generate | 0m00s |
| iso-remaster | 1m57s |
| bmc-mount-boot | 2m06s |
| install-monitor | 10m41s |
| post-install-config | 8m11s |
| pve-install | 19m28s |
| cleanup | 1m12s |
| **total** | **43m54s** |

(参考: trial-1-s7 は 54m46s。server8 は 11 分短縮)
