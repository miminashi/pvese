# Trial 7 / 10 — server15 (R430)

- 開始: 2026-05-12 11:10 JST (powerdown 直後の最初の RAID resetconfig 着手)
- 終了: 2026-05-12 12:10 JST (cleanup マーク完了)
- 所要時間: 約60m (wall) / 33m38s (phase合計)
- 結果: success
- install-monitor attempt 回数: 1 (一発成功)
- 失敗時の原因: なし (install attempt 自体は1回成功)

## 観測された問題 / 既知事象の再現

### Phase A — RAID 整備時の罠 (新発見)

trial 7 では Phase A の `racadm raid createvd` 1 回目が **PR34 (internal retry exceeded) で Failed** した。原因は手順内で `jobqueue create ... -r pwrcycle` を発行した直後にこちらが `racadm serveraction hardreset` を上書き発行し、Lifecycle Controller のジョブ実行ウィンドウを途中で奪ったため。これは skill にも report にもない手順誤り。

**再発防止メモ**: `jobqueue create -r pwrcycle` を出した後は手動で powercycle を上書きしないこと。LC が自動的にスケジュールされた pwrcycle を実行する。途中で hardreset すると job は途中で aborted → `Failed PR34: internal retry attempt limit`。

**回復手順 (今回機能した)**:
1. `racadm jobqueue delete --all` でジョブ消去
2. `racadm raid createvd ...` を再発行 → `STOR023 Configuration already committed` (storage stack に pending committed が残る)
3. `racadm racreset soft` で iDRAC を再起動 → ~3 分で SSH 復旧
4. racreset 後の SCP Export job (`JID_785711595248`) が completed まで待つ (~4 分)
5. `racadm raid createvd ...` を再発行 → success
6. **`racadm jobqueue create RAID.Integrated.1-1 --realtime`** で pwrcycle なしで適用 → 1 分で `Completed (100)`

`--realtime` は pwrcycle 不要で OS が動いていなくても LC が即適用するので、今回の状況に最適だった。BGI 開始の State=Online + Background Initialization で createvd 完了。所要時間 wall ~26 分 (11:10 → 11:36)。

### Phase 5-7 — Round 6 既知事象の再現

- **post-reboot 中の default route 消失** は **6 trial 連続再現** (Round 4-6 と同じ)。`pve-setup-remote.sh --phase post-reboot` 1 回目が exit 100 で停止 → `pre-pve-setup.sh` 再実行 → `pve-setup-remote.sh post-reboot` 再実行で完走。skill 通り
- **LINBIT keyring 事前配置 (Round 6 で必須化された改善 19)** は今回も奏功。trial 6 の `tmp/t6s15-01/linbit-keyring.gpg` を `tmp/trial7/` に流用 → `scp` で `/usr/share/keyrings/linbit-keyring.gpg` に配置 → post-reboot の `apt-get update` で LINBIT InRelease を 1 回目から正常取得 → linstor-common 56MB を 33 秒 (~3.5 MB/s) で完走
- **partman 5/9 stuck (改善 16)** は発動なし。install attempt 1 で LOADING_COMPONENTS → FINISH まで一直線 (stage progression: 0→1 (LOADING_COMPONENTS) → DETECTING_NETWORK → CONFIGURING_APT → 5 → INSTALLING_SOFTWARE (6) → INSTALLING_GRUB (7) → POWER_DOWN, 6.3 min)
- **改善 17 (pve-bridge-setup.sh 必須)** は問題なく実行 — final reboot → route fix → `pve-bridge-setup.sh --static-iface eno2 --static-ip 10.10.10.215/8 --dhcp-iface eno1` で vmbr0/vmbr1 作成。Web UI 200 / vmbr0 UP / default route via vmbr1 確認済
- **改善 18 (final reboot 後の route 消失)** — final reboot 後 default route 消失 (Round 5-6 と同じ)。`pre-pve-setup.sh` 再実行で確実に救済。skill 通り
- **PowerState API 30s timeout** は install-monitor 中に複数回発生 (Round 4-6 と同じ): BMC が POST/boot 移行期に Redfish API を一時的にブロック。sol-monitor.py は None を受けても継続実行する設計で、Stage 観測 + EOF + 30s 後 PowerState=Off で完了判定。skill 既存挙動と一致。改善不要
- **完全リセット直後の `racadm raid resetconfig` 後の SCP Export job** — 今回も発生 (`JID_785704009695` resetconfig 完了直後 + `JID_785711595248` racreset soft 後)。createvd 前に Completed 確認、skill 通り

## 新発見 / skill 改善候補

### 改善 22: `racadm jobqueue create ... -r pwrcycle` 発行後の手動 hardreset は禁止

今回最大の罠。skill には次のように記載がある:

> ```sh
> ./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac<N> racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle
> ```
> `racadm jobqueue view` を 30 秒間隔でポーリングして `Completed (100)` を待つ (3-5 分目安)。

**問題**: skill 上は「pwrcycle で適用」と書いてあるが、`-r pwrcycle` job が auto-applied されるタイミングは LC の内部スケジュールに依存。手動で `racadm serveraction hardreset` を被せると LC が job を取り上げる前後で server 状態が変わり、PR34 で fail することがある (今回 trial 7 で実証)。

**改善案**: SKILL.md Phase 4 ステップ 0 (RAID 事前整備) に明示:
- 「**`jobqueue create -r pwrcycle` 発行後は手動 power 操作を行わず、`racadm jobqueue view` のポーリングのみで完了を待つこと**」を強調
- 既に server を粗く再起動したい場合は **`--realtime`** を使う代替手順を併記

`--realtime` の利点 (今回実証):
- LC が即座に config を適用 (BGI なし、Online 直行)
- pwrcycle 待ち不要 (1 分程度で完了)
- 自動付随する SCP Export 待ちのみ
- 既存 pwrcycle 手順より速い (resetconfig + createvd で wall ~10 分 → ~5 分に短縮可能)

**コマンド例** (resetconfig は -r pwrcycle のまま、createvd は --realtime):
```sh
ssh -F ssh/config idrac<N> racadm raid resetconfig:RAID.Integrated.1-1
ssh -F ssh/config idrac<N> racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle
# poll resetconfig Completed + SCP Export Completed
ssh -F ssh/config idrac<N> racadm raid createvd:RAID.Integrated.1-1 -rl r1 -pdkey:... -name OS_RAID1
ssh -F ssh/config idrac<N> racadm jobqueue create RAID.Integrated.1-1 --realtime
# poll createvd Completed (~1 min) + SCP Export Completed
```

## 主要ログ

- `tmp/trial7/sol-install-s15.log` (SOL 監視ログ、stage 0→7 observed、PowerState=Off + Power down 検出で正規完了)
- `tmp/trial7/sol-commands-s15.txt` (post-install-config SOL コマンド)
- `tmp/trial7/linbit-keyring.gpg` (LINBIT keyring、trial 6 から流用)
- `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
bmc-mount-boot           1m36s
install-monitor          7m25s
post-install-config      7m49s
pve-install             16m03s   (post-reboot を 2 回走らせた合計 + LINSTOR + DRBD DKMS)
cleanup                  0m45s   (bridge setup 含む)
---
total                   33m38s
```

注: wall time は約 60 分 (Phase A の RAID 失敗 → racreset soft → createvd --realtime 全体 ~26 分を含む)。
phase合計 33m38s は bmc-mount-boot 以降のフェーズ所要時間。

## 検証コマンド結果

| 検証項目 | 結果 |
|---------|------|
| `pveversion` | `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)` |
| `cat /etc/os-release` (PRETTY_NAME) | `Debian GNU/Linux 13 (trixie)` |
| `uname -r` | `7.0.2-2-pve` |
| `ip -brief addr show vmbr0` | `vmbr0 UP 10.10.10.215/8` |
| `ip -brief addr show vmbr1` | `vmbr1 UP 192.168.39.121/24` |
| `ip route` default | `default via 192.168.39.1 dev vmbr1` |
| `curl -sk https://10.10.10.215:8006` | `200 OK` (HTML) |
| `dpkg -l drbd-dkms drbd-utils linstor-*` | 全 `ii` (Installed)、no failure |
| `racadm raid get vdisks` | `Disk.Virtual.0 State=Online Layout=Raid-1 (BGI in progress)` |
| `/etc/machine-id` mtime | install-monitor.start より新しい (fresh install 確認) |

## Round 1-7 比較

| trial | wall | phase total | install attempt | RAID reset job | install-monitor stage | 主な遅延要因 |
|-------|------|-------------|-----------------|----------------|----------------------|----------------|
| 1 | 49m | 36m | 1 | n/a (first install) | 9 | initial baseline |
| 2 | 70m | 25m | 2 | + 6 min | 7 (att2) | GRUB sector read error → racreset soft |
| 3 | 59m | 41m | 1 | + 12 min | 9 | LINBIT linstor-common 56MB が 12 分かかる |
| 4 | 49m | 35m | 1 | + 12 min | 6 | post-reboot route 消失 → 1 回追加実行 (+ 約 6 分) |
| 5 | 76m | 29m | 2 | + ~3 min | 7 (att2) | partman 5/9 stuck → racreset soft + post-reboot route 消失 |
| 6 | 48m | 34m | 1 | ~10 min | 7 | post-reboot route 消失 + LINBIT keyring 不在の合わせ技 (1 回追加実行) |
| 7 | 60m | 34m | 1 | ~26 min | 7 | createvd 1 回目 PR34 → racreset soft + createvd --realtime で回復 |

## 次 trial への引き継ぎ

- preseed-server15.cfg の `netcfg/choose_interface select eno2` 確定 (7 trial 連続で機能)
- `racadm racreset soft` 回復手順は trial-2 (GRUB), trial-5 (partman), trial-7 (createvd PR34) で実証、trial-3, 4, 6 では発動不要 (3/7 = 43% 発生率)
- **post-reboot 中の default route 消失は再現性確定** (Round 4, 5, 6, 7 連続再発、4/4 = 100%)。`pre-pve-setup.sh` 再実行で確実救済
- **LINBIT keyring は事前配置が必須** (Round 6 で確定、Round 7 でも有効性確認)。`tmp/trial7/linbit-keyring.gpg` は次 trial で再利用可
- `dhcpcd -1 -t 30 eno1` 事前実行は引き続き必須 (Debian 13 minimal の DHCP timing 問題)。今回 1 回目は成功、2-3 回目は timeout → dhclient fallback
- LINBIT linstor-common (56.6MB) は今回 33 秒で完走 (3.6 MB/s、帯域標準)
- `pve-bridge-setup.sh` は cleanup ステップで実行、Phase 8 完了に必要
- final reboot 後の default route 消失も再現、`pre-pve-setup.sh` 再実行で救済
- **新規 trap (Round 7)**: `jobqueue create -r pwrcycle` 発行後の手動 hardreset 禁止。SKILL.md Phase 4 ステップ 0 に追記候補 (改善 22)

## 新規 skill 改善候補 (Round 7)

### 改善 22: `racadm jobqueue create ... -r pwrcycle` 後の power 操作禁止

- **問題** (Round 7 trial 7 s15): RAID createvd 後の `jobqueue create -r pwrcycle` job が scheduled 状態のとき、手動で `racadm serveraction hardreset` を発行すると LC が job を取り上げる前後で server 状態が変わり、**PR34 (internal retry attempt limit) で job が Failed** する。Failed すると VD が作成されず、racadm raid get vdisks が `STOR0104: No virtual disks` で再 createvd できなくなる (STOR023 Configuration already committed)。回復には `racadm racreset soft` (~3 分) が必要
- **修正**: SKILL.md Phase 4 ステップ 0 「VD 作成」の手順に次の警告を追加:
  ```
  > **⚠️ `jobqueue create ... -r pwrcycle` 発行後の手動 power 操作禁止** (Round 7 で実証):
  > LC が自動的に pwrcycle を実行する間 (~30 秒 - 数分) は手動で
  > `racadm serveraction (hardreset|powerdown|powerup)` を発行しないこと。
  > Job が aborted → PR34 (internal retry attempt limit) で Failed し、
  > storage stack に pending committed が残って次の createvd が
  > STOR023 で reject される。回復には racreset soft が必要。
  ```
- **代替手順**: createvd には **`--realtime`** を使うのが安全 (pwrcycle 不要、即時適用、~1 分で完了):
  ```sh
  ssh -F ssh/config idrac<N> racadm jobqueue create RAID.Integrated.1-1 --realtime
  ```

Trial 7 server15: success (60min, attempt 1)
