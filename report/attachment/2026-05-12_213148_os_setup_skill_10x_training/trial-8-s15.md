# Trial 8 / 10 — server15 (R430)

- 開始: 2026-05-12 12:17:51 JST (Phase A 完全リセット着手)
- 終了: 2026-05-12 13:11:19 JST (Phase 8 cleanup マーク完了)
- 所要時間: 約53m (wall) / 32m18s (phase合計)
- 結果: success
- install-monitor attempt 回数: 1 (一発成功)
- 失敗時の原因: なし

## 観測された問題 / 既知事象の再現

### Phase A — RAID 整備 (Round 7 改善 22 適用、スムーズに完走)

trial 7 の罠 (jobqueue create -r pwrcycle 発行後の手動 hardreset → PR34 fail) を回避するため、Round 7 改善 22 の方針に従う:

1. `racadm jobqueue delete --all` (前 trial 7 の completed job をクリア)
2. `racadm raid resetconfig:RAID.Integrated.1-1`
3. `racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle` (resetconfig は pwrcycle 必要)
4. resetconfig job (JID_785739947238) Completed 待ち — 約 60 秒
5. SCP Export job (JID_785742055314) Completed 待ち — 約 1 分
6. `racadm raid createvd:RAID.Integrated.1-1 -rl r1 -pdkey:Bay.0,Bay.1 -name OS_RAID1`
7. `racadm jobqueue create RAID.Integrated.1-1 --realtime` (createvd は realtime で即適用)
8. createvd realtime job (JID_785749317197) Completed — 約 15 秒
9. **手動 power 操作なし** — LC が自動でハンドリング、Round 7 の罠を回避

**所要時間**: Phase A 全体で約 8 分 (12:17 → 12:25)。Round 7 の 26 分から大幅短縮 (改善 22 適用効果)。

VD は createvd 直後 `State=Online, OperationalState=Background Initialization, Progress=3%` で boot 可能。BGI は OS install と並行進行 (cleanup 時 61%、I/O 性能には影響あるが install には影響しない)。

### Phase 1-3 — ISO/preseed cache 再利用

- ISO sha256 既存ファイルが一致 → ダウンロードスキップ (`iso-download` 11秒)
- preseed sha256 と保存済みハッシュが一致 → リマスタースキップ (`iso-remaster` 9秒)
- preseed-server15.cfg は trial 7 から変更なし (`netcfg/choose_interface select eno2` 確定済)

### Phase 5 — install-monitor 1 attempt 成功

- BIOS SerialComm=OnConRedirAuto, RedirAfterBoot=Enabled (前 trial で復元済、変化なし)
- SOL 監視 stage 進行: 0 → 1 (LOADING_COMPONENTS) → 2 (DETECTING_NETWORK) → 3 (CONFIGURING_APT) → 5 → 6 (INSTALLING_SOFTWARE) → 7 (INSTALLING_GRUB) → PowerState Off (検出から 23s 確認待ち)
- 所要時間: 7m36s
- PowerState API timeout (`bmc-power.sh status` 30s timeout) を install 中に 4 回観測 — Round 4-7 と同じ既知事象。sol-monitor.py は None 受信でも継続実行、Stage 観測 + PowerState=Off 確認で正規完了判定
- partman stuck / GRUB sector read error は **発生なし**

### Phase 6 — post-install-config

- SOL 経由でユーザ設定、SSH 鍵配置、静的 IP 設定 → 一発成功
- 「Command may have failed」警告 2 件発生 (printf > file, chmod 600) — 既知の false positive
- ssh-wait.sh attempt 1 で即接続 (0s)
- /etc/machine-id mtime (1778557616) > install-monitor.start (1778557360) → fresh install 確認

### Phase 7 — pve-install (Round 4-7 既知問題が連続発動)

#### 既知事象: pre-pve-setup の DHCP probing 失敗 (新観測)

`dhcpcd -1 -t 30 eno1` 1 回目で probing が IPv4LL に倒れる (192.168.39.122 を offered → probing → IPv4LL 169.254.x で確定)。`dhclient` は Debian 13 minimal で不在。**`ip addr flush dev eno1` → `dhcpcd -1 -t 60` 再実行で 192.168.39.122 取得成功**。Round 1-7 では発生していない新観測。

#### 既知事象: post-reboot 中の default route 消失

- `pve-setup-remote.sh --phase post-reboot` 1 回目が exit 100 で停止 (proxmox-ve install 中に ifupdown 再初期化で default route 消失)
- `pre-pve-setup.sh` 再実行 → default route 復旧 + LINBIT InRelease cache 確認
- `pve-setup-remote.sh --phase post-reboot --linstor` 再実行 → 冪等性で resume、LINSTOR / DRBD DKMS 込みで完走
- Round 4-7 と同じ振る舞い、4/4 → 5/5 trial 連続再現 = **100% 必発確定**

#### 既知事象: LINBIT keyring 事前配置

- `tmp/trial7/linbit-keyring.gpg` を `tmp/trial8/` にコピー → `/usr/share/keyrings/linbit-keyring.gpg` に scp → chmod a+r
- 結果: post-reboot の `apt-get update` で `https://packages.linbit.com/public proxmox-9 InRelease` を 1 回目から正常取得
- linstor-common 56.6 MB を 18 秒 (6.3 MB/s、帯域良好) で完走
- DRBD DKMS ビルド成功 (build-essential 事前 install 効果)

#### 既知事象: final reboot 後の default route 消失

- final reboot 後 default route なし → `pre-pve-setup.sh` 再実行で復旧
- Round 5-7 と同じ振る舞い (3/3 → 4/4 trial 連続)

### Phase 8 — cleanup + bridge setup

- `pve-bridge-setup.sh --static-iface eno2 --static-ip 10.10.10.215/8 --dhcp-iface eno1` → vmbr0/vmbr1 即時 UP
- vmbr0: 10.10.10.215/8、vmbr1: 192.168.39.122/24 (DHCP)
- default route: 192.168.39.1 dev vmbr1
- Web UI: curl https://10.10.10.215:8006 → 200

## 新発見 / skill 改善候補

### 改善 23: dhcpcd probing 失敗対策 (低優先)

- **問題** (Round 8 trial 8 s15): pre-pve-setup 1 回目で `dhcpcd -1 -t 30 eno1` が「offered → probing → IPv4LL」で 169.254.x に倒れた。`dhclient` は Debian 13 minimal で不在 (`isc-dhcp-client` パッケージ未 install)
- **回復**: `ip addr flush dev eno1` → `dhcpcd -1 -t 60 eno1` 再実行で 192.168.39.122 取得成功
- **修正候補**: `pre-pve-setup.sh` の DHCP timing logic に「IPv4LL (169.254.x) を取得したら 1 回 flush + 再試行」を追加。または skill 側で「Debian 13 minimal の dhcpcd 初回 timing 問題」として明記
- **発生頻度**: 8 trial で初観測 (1/8 = 13%、低頻度)。要再現性確認後の skill 改善判断

## 主要ログ

- `tmp/trial8/sol-install-s15.log` (SOL 監視ログ、stage 0→7 observed)
- `tmp/trial8/sol-commands-s15.txt` (post-install-config SOL コマンド)
- `tmp/trial8/linbit-keyring.gpg` (LINBIT keyring、trial 7 から流用)
- `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
iso-download             0m11s
preseed-generate         0m05s
iso-remaster             0m09s
bmc-mount-boot           3m19s
install-monitor          7m36s
post-install-config      3m11s
pve-install             16m38s   (post-reboot 2 回 + LINSTOR + DRBD DKMS)
cleanup                  1m09s   (bridge setup 含む)
---
total                   32m18s
```

注: wall time は約 53 分 (Phase A の RAID resetconfig + createvd で約 8 分を含む、Round 7 改善 22 適用で約 18 分短縮)。phase合計 32m18s は iso-download 以降のフェーズ所要時間。

## 検証コマンド結果

| 検証項目 | 結果 |
|---------|------|
| `pveversion` | `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)` |
| `cat /etc/os-release` (PRETTY_NAME) | `Debian GNU/Linux 13 (trixie)` |
| `uname -r` | `7.0.2-2-pve` |
| `ip -brief addr show vmbr0` | `vmbr0 UP 10.10.10.215/8` |
| `ip -brief addr show vmbr1` | `vmbr1 UP 192.168.39.122/24` |
| `ip route` default | `default via 192.168.39.1 dev vmbr1` |
| `curl -sk https://10.10.10.215:8006` | `200 OK` (HTML) |
| `dpkg -l drbd-dkms drbd-utils linstor-*` | 全 `ii` (Installed)、no failure |
| `lsmod \| grep drbd` | `drbd 843776 0` + `lru_cache 16384 1 drbd` (module loaded) |
| `racadm raid get vdisks` | `Disk.Virtual.0 State=Online Layout=Raid-1 (BGI 61% at cleanup)` |
| `/etc/machine-id` mtime | install-monitor.start より新しい (fresh install 確認) |

## Round 1-8 比較

| trial | wall | phase total | install attempt | RAID reset job | install-monitor stage | 主な遅延要因 |
|-------|------|-------------|-----------------|----------------|----------------------|----------------|
| 1 | 49m | 36m | 1 | n/a (first install) | 9 | initial baseline |
| 2 | 70m | 25m | 2 | + 6 min | 7 (att2) | GRUB sector read error → racreset soft |
| 3 | 59m | 41m | 1 | + 12 min | 9 | LINBIT linstor-common 56MB が 12 分かかる |
| 4 | 49m | 35m | 1 | + 12 min | 6 | post-reboot route 消失 → 1 回追加実行 (+ 約 6 分) |
| 5 | 76m | 29m | 2 | + ~3 min | 7 (att2) | partman 5/9 stuck → racreset soft + post-reboot route 消失 |
| 6 | 48m | 34m | 1 | ~10 min | 7 | post-reboot route 消失 + LINBIT keyring 不在の合わせ技 |
| 7 | 60m | 34m | 1 | ~26 min | 7 | createvd 1 回目 PR34 → racreset soft + createvd --realtime で回復 |
| 8 | 53m | 32m | 1 | ~8 min | 7 | Round 7 改善 22 適用 (createvd --realtime 単独でスムーズ) + dhcpcd 初回 probing 失敗 |

## 次 trial への引き継ぎ

- preseed-server15.cfg の `netcfg/choose_interface select eno2` 確定 (8 trial 連続で機能)
- `racadm jobqueue create ... --realtime` (createvd 適用) は Round 7 改善 22 の通り安全・高速で機能
- `racadm racreset soft` 回復手順は trial-2 (GRUB), trial-5 (partman), trial-7 (createvd PR34) で実証、trial-3, 4, 6, 8 では発動不要 (3/8 = 38% 発生率)
- **post-reboot 中の default route 消失は再現性確定** (Round 4, 5, 6, 7, 8 連続再発、5/5 = 100%)。`pre-pve-setup.sh` 再実行で確実救済
- **LINBIT keyring 事前配置** (Round 6 で確定) は Round 7, 8 でも有効。`tmp/trial8/linbit-keyring.gpg` は次 trial で再利用可
- **新規 trap (Round 8)**: `dhcpcd -1 -t 30 eno1` 1 回目が IPv4LL に倒れることがある。`ip addr flush` + 再 dhcpcd-t60 で復旧。再現性 1/8 = 13%、要追跡
- LINBIT linstor-common (56.6MB) は今回 18 秒で完走 (6.3 MB/s、帯域良好)
- `pve-bridge-setup.sh` は cleanup ステップで実行、Phase 8 完了に必要
- final reboot 後の default route 消失も再現、`pre-pve-setup.sh` 再実行で救済

## 新規 skill 改善候補 (Round 8)

### 改善 23: dhcpcd 初回 probing IPv4LL fallback への対処

- **問題** (Round 8 trial 8 s15): pre-pve-setup.sh 1 回目で `dhcpcd -1 -t 30 eno1` が「offered 192.168.39.122 → probing 192.168.39.122/24 → IPv4LL 169.254.x」のシーケンスで本来の DHCP リースを破棄し IPv4LL に倒れた。これにより apt-get update が DNS resolve failure で fail
- **再現性**: 1/8 trial (13%、低頻度)。Debian 13 minimal install 直後の特定の timing で発生?
- **修正候補**: skill SKILL.md Phase 7 ステップ 0 に「dhcpcd が IPv4LL (169.254.x) に倒れたら `ip addr flush dev <iface>` + `dhcpcd -1 -t 60 <iface>` で再試行」を明示。または pre-pve-setup.sh の DHCP wait ループに IPv4LL 判定 + flush + 再試行を組み込む (script-side fix)
- **優先度**: **低** — 8 trial に 1 回、回復手順が明確。本 trial では問題なく回復

Trial 8 server15: success (53min, attempt 1)
