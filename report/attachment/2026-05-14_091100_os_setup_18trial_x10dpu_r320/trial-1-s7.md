# Trial 1 server7 レポート

- **結果**: success
- **開始時刻**: 2026-05-14 13:49:31 JST
- **完了時刻**: 2026-05-14 14:45:44 JST
- **所要時間 (wall)**: 約 56 分 (Phase 1-8 合計 54m46s)
- **attempt 数**: 1 (Phase 4-8 一発完走、iDRAC リカバリ・install 再試行なし)

## 発動したリカバリ

| リカバリ | 回数 | 理由 |
|---------|------|------|
| `racadm racreset soft` | 0 | install 一発成功のため不要 |
| VirtualMedia umount → 再 mount | 1 | Phase 4 開始時に "remote image is already configured" で初回 mount が拒否 → umount → 5s 待機 → 再 mount で成功 |
| `pre-pve-setup.sh` 再実行 | 2 | (a) Phase 7 step 0: 初回 DHCP 取得失敗 (eno2 が UP したが lease が来ず) → `dhcpcd -1 -t 30 eno2` で 192.168.39.198 取得後に再実行で apt 成功。 (b) Phase 7 ステップ 3 (reboot 後): default route 喪失 → 再実行で復旧 |
| `pve-setup-remote.sh --phase post-reboot` 再実行 | 1 | 1回目に proxmox-ve 導入後の ifupdown2 再初期化で default route 消失 → pre-pve-setup 再実行 → post-reboot を resume (冪等) で linstor-* インストール完了 |
| `dhclient -1 -v eno2` (Phase 7 final reboot 後) | 1 | 最終リブート後 default route 喪失 → DHCP 再取得 |
| LINBIT keyring 事前配置 | 1 | SKILL.md の必発罠対策として Ubuntu keyserver から事前取得・配置 |

## 観察した問題

### 既知問題 (SKILL.md / MEMORY.md 記載済み)
- **Phase 7 post-reboot 中 default route 消失** (5 trial 連続再現の既知罠): proxmox-ve install 中の ifupdown2 再初期化で発生。記載通り `pre-pve-setup.sh` 再実行 → post-reboot resume で復旧
- **Phase 7 final reboot 後の default route 消失** (Round 5-7 連続観測): `dhclient -1 -v eno2` で復旧
- **VirtualMedia 既存セッション干渉**: `idrac-virtualmedia.sh mount` が `RAC0730: remote image already configured` を返す。umount → 5s → 再 mount で正常 (idrac7 既知挙動)
- **Debian 13 minimal の DHCP 取得タイムアウト**: SKILL.md 記載通り、`dhcpcd -1 -t 30 eno2` での明示 DHCP 取得が必要
- **sol-login.py の "Command may have failed" 誤検知** (Round 2 s15 既知)

### 新規問題

**検出なし**。
- Supermicro X11DPU (server4-6) で発見した既知デグレ (`generate-preseed.sh` 由来) は preseed が手動管理 (`preseed/preseed-server7.cfg`) のため**影響なし**
- iDRAC 固有の新規問題も発生せず
- **NVRAM 枯渇 (#47) は発火せず**: preseed の `early_command` が efivarfs を mount → 既存 Boot#### を全削除 → BootOrder/BootNext 削除を実行しており、効果的に NVRAM 枯渇を予防している

## 最終検証 (success)

```
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)
uname -r: 7.0.2-2-pve

ip -brief addr:
  vmbr0  UP  10.10.10.207/8       (eno1 配下、静的)
  vmbr1  UP  192.168.39.198/24    (eno2 配下、DHCP)
  ibp10s0 UP  192.168.101.7/24    (IPoIB connected mode, MTU 65520)

ip route:
  default via 192.168.39.1 dev vmbr1
  10.0.0.0/8 dev vmbr0 proto kernel scope link src 10.10.10.207
  192.168.39.0/24 dev vmbr1 proto kernel scope link src 192.168.39.198
  192.168.101.0/24 dev ibp10s0 proto kernel scope link src 192.168.101.7

curl -sk https://10.10.10.207:8006/ → HTTP 200
```

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 0m18s |
| preseed-generate | 0m00s |
| iso-remaster | 1m55s |
| bmc-mount-boot | 2m45s |
| install-monitor | 11m14s |
| post-install-config | 12m18s |
| pve-install | 23m57s |
| cleanup | 2m19s |
| **total** | **54m46s** |

## ログ参照

- `tmp/e28df8d0/trial-1-s7.log`
- `tmp/e28df8d0/sol-install-s7.log` (SOL 監視ログ 全 11 stage 観測)
- `tmp/e28df8d0/installer-syslog-s7.log` (4208 lines)
- `tmp/e28df8d0/sol-commands-s7.txt`
- `state/os-setup/server7/`

## まとめ

iDRAC R320 + iDRAC7 FW 2.65.65.65 で Round 1 trial-1-s7 を 1 attempt で完走。x10dpu 系 (server4-6) で発見した generate-preseed.sh デグレは手動管理 preseed のため非該当。iDRAC 固有の新規問題も検出なし。発動したリカバリはすべて SKILL.md / MEMORY.md 記載済みの既知罠への対処で、5-7 round と同等のパターン (post-reboot 中 / final reboot 後の default route 喪失) を再現した。NVRAM 枯渇 (#47) は preseed early_command の efivarfs クリーンアップが機能しており発火せず。
