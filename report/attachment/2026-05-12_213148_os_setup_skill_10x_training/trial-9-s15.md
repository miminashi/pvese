# Trial 9 / 10 — server15 (R430)

- 開始: 2026-05-12 13:13:55 JST (Phase A 完全リセット着手)
- 終了: 2026-05-12 14:29:36 JST (Phase 8 cleanup マーク完了)
- 所要時間: 約76m (wall) / 53m35s (phase合計)
- 結果: **success**
- install-monitor attempt 回数: 2 (attempt1 partman stuck → racreset soft → attempt2 成功)
- 失敗時の原因:
  - **attempt1: partman 8min stuck on "No root file system is defined" dialog** — sol-monitor で stage 5/9 観測後、byobu status bar が `[1*installer]` のまま動かず、SOL 画面に "No root file system is defined" の error dialog が表示されたまま 8 分以上停滞。`partman/confirm boolean true` の auto-confirm は dialog を抜けず、partman が無限ループしていた。
  - 対処: skill Phase 5 ステップ 4 の早期 trigger に従い `racadm racreset soft` (約 90 秒で SSH 復帰) → VirtualMedia umount → 5 秒待機 → 再 mount + verify → boot-once VCD-DVD → 電源 ON。
  - attempt2 は **6m18s** で完走、PowerState=Off + 7 stages 観測 (LOADING_COMPONENTS, DETECTING_NETWORK, CONFIGURING_APT, INSTALLING_SOFTWARE, INSTALLING_GRUB ...) の正規完了パターン。

## 観測された問題 / 既知事象の再現

### Phase A — RAID 整備 (Round 7 改善 22 適用、スムーズに完走)

1. `racadm jobqueue delete --all` — 前 trial 8 の completed job をクリア
2. `racadm raid resetconfig:RAID.Integrated.1-1`
3. `racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle` (resetconfig は pwrcycle 必要)
4. resetconfig job (JID_785774128840) Completed 待ち — 約 90 秒
5. SCP Export job (JID_785776290507) 自動生成、Completed 待ち — 約 30 秒で消失
6. `racadm raid createvd:RAID.Integrated.1-1 -rl r1 -pdkey:Bay.0,Bay.1 -name OS_RAID1`
7. `racadm jobqueue create RAID.Integrated.1-1 --realtime` (createvd は realtime で即適用)
8. createvd realtime job (JID_785784154738) Completed — 約 60 秒
9. **手動 power 操作なし** — LC が自動でハンドリング、Round 7 の罠を回避

**所要時間**: Phase A 全体で約 4 分 (13:21 → 13:25)。Round 8 (8min) からさらに短縮、Round 7 (26min) と比べて 22 分短縮。

VD は createvd 直後 `State=Online, OperationalState=Not applicable` (BGI スキップ、Bay 0+1 同モデル同スペック)。

### Phase 1-3 — ISO/preseed cache 再利用

- ISO sha256 既存ファイルが一致 → ダウンロードスキップ (`iso-download` 14秒)
- preseed sha256 と保存済みハッシュが一致 → リマスタースキップ (`iso-remaster` 3秒)
- preseed-server15.cfg は trial 8 から変更なし (`netcfg/choose_interface select eno2` 確定済、`for disk in $(list-devices disk)` の古いパターン)

### Phase 4 — bmc-mount-boot ⚠️ Redfish "Invalid System id: 1" エラー観測

- Power off → mount → boot-once VCD-DVD → power on のフローで `bmc-power.sh cycle` 内部の Redfish API が `"Invalid System id: 1"` エラーを返した。**しかし server は実際には ON になっており**、bmc-power.sh の get_system_path() は `/redfish/v1/Systems/System.Embedded.1` を正しく返している。原因は ForceOff 時に server が既に Off 状態だったため iDRAC が一時的に「Invalid System id」を返した可能性。Power On 単独実行 (`./scripts/bmc-power.sh on ...`) で問題なく ON 化された。
- skill の bmc-mount-boot フロー (cycle = ForceOff + 20s + On) は **既に Off の server** に対しては ForceOff 失敗を許容する設計に変える価値あり (新観測)。
- **所要時間**: 6m13s — Round 8 (3m19s) より長い (RAID resetconfig 待ちが Phase 4 開始までに既に終わっていなかったため Phase 4 中で待機分が追加)

### Phase 5 — install-monitor 2 attempts (Round 5 と同じ partman stuck パターン)

- attempt1: BIOS POST 完了 → installer boot → Stage 5/9 (PARTITIONING_DISKS) で 8 分以上停滞。SOL に **"No root file system is defined" dialog** が表示されたまま、`Please correct this from the partitioning menu.` メッセージが見える。`partman/confirm boolean true` の auto-confirm がこの dialog には効かない。
- skill Phase 5 ステップ 4 の早期 trigger 条件「partman stage 5/9 15min stuck + syslog 10+min silence」未満 (8min) の段階だが、byobu status bar が完全停滞 + dialog 視認で確定的な fail と判断し、即座に racreset soft を発動した。
- racreset soft 後の復旧手順: VirtualMedia umount → 5s → 再 mount + verify (OK) → boot-once VCD-DVD → Power on
- attempt2: 6m18s で完走、stage 0 → 5 → 6 → 7 → POWER_DOWN 観測。Stage 5 (CONFIGURING_APT) を 2.5min で通過 (attempt1 では同じ位置で 8min 停滞)。最後の "Power down detected, waiting 30s for shutdown..." + "PowerState after shutdown wait: Off" + "Installation completed successfully" でクリーン終了
- PowerState API timeout (`bmc-power.sh status` 30s timeout) を install 中に 2 回観測 — Round 4-8 と同じ既知事象。sol-monitor.py は None 受信でも継続実行
- **install-monitor 全体所要時間: 25m30s** (attempt1 ~ 8min + racreset soft ~ 3min + bmc-remount ~ 4min + attempt2 ~ 6min + 余裕)

### Phase 6 — post-install-config

- SOL 経由でユーザ設定、SSH 鍵配置、静的 IP 設定 → 一発成功
- 「Command may have failed」警告 2 件発生 (chmod 700, chmod 600) — Round 2-8 と同じ既知 false positive
- ssh-wait.sh attempt 1 で即接続 (0s)
- /etc/machine-id mtime (1778562276) > install-monitor.start (1778560939) → fresh install 確認
- **所要時間: 4m22s**

### Phase 7 — pve-install (Round 4-8 既知問題が連続発動 + Round 8 dhcpcd IPv4LL 再現)

#### 既知事象: pre-pve-setup の DHCP probing 失敗 (Round 8 改善 23 再現)

- `pre-pve-setup.sh` 1 回目の `dhcpcd -1 -t 30 eno1` で DHCP timeout (30s timeout、`dhclient` も Debian 13 minimal 不在 → fallback も失敗)
- 回復: 手動 `ssh root@host ip addr flush dev eno1` → `ssh root@host dhcpcd -1 -t 60 eno1` で `offered 192.168.39.123 → leased 192.168.39.123 for 86400 seconds` 取得成功
- その後 `pre-pve-setup.sh` 再実行で `DHCP IPv4 acquired: 192.168.39.123 (0s)` で即時成功
- Round 8 trial 8 と同じパターンを Round 9 でも再現 = **2/9 trial = 22% 発生率**

#### 既知事象: post-reboot 中の default route 消失 (Round 4-8 連続必発、6/6 = 100%)

- `pve-setup-remote.sh --phase post-reboot` 1 回目が exit 100 で停止 (proxmox-ve install 中に ifupdown 再初期化で default route 消失)
- `pre-pve-setup.sh` 再実行 → default route 復旧 + LINBIT InRelease cache 確認
- `pve-setup-remote.sh --phase post-reboot --linstor` 再実行 → 冪等性で resume、LINSTOR / DRBD DKMS 込みで完走
- Round 4-9 連続再現 = **100% 必発確定**

#### 既知事象: LINBIT keyring 事前配置 (Round 6 mitigation)

- `tmp/trial8/linbit-keyring.gpg` を `tmp/c452be97/linbit-keyring.gpg` にコピー → `/usr/share/keyrings/linbit-keyring.gpg` に scp → chmod a+r
- 結果: post-reboot の `apt-get update` で `https://packages.linbit.com/public proxmox-9 InRelease` を 1 回目から正常取得
- linstor-common 56.6 MB を 11 秒 (~5.1 MB/s) で完走
- DRBD DKMS ビルド成功 (build-essential 事前 install 効果)

#### 既知事象: final reboot 後の default route 消失 (Round 5-8 連続再現、5/5 = 100%)

- final reboot 後 default route なし → `pre-pve-setup.sh` 再実行で復旧
- Round 5-9 連続再現 = **100% 必発確定**

**Phase 7 所要時間: 15m52s** — Round 8 (16m38s) と同程度

### Phase 8 — cleanup + bridge setup

- `pve-bridge-setup.sh --static-iface eno2 --static-ip 10.10.10.215/8 --dhcp-iface eno1` → vmbr0/vmbr1 即時 UP
- vmbr0: 10.10.10.215/8、vmbr1: 192.168.39.123/24 (DHCP)
- default route: 192.168.39.1 dev vmbr1
- Web UI: curl https://10.10.10.215:8006 → 200
- **所要時間: 1m15s**

## 新発見 / skill 改善候補

### 改善 24 (新規): partman stuck 早期 trigger を 8min + dialog 視認に短縮

- **問題** (Round 9 trial 9 s15 attempt 1): partman stage 5/9 で **8 min stuck** に "No root file system is defined" dialog が SOL に表示。skill の現行 trigger 条件 (15min + syslog 10min silence) では 7 分以上の追加待機が必要だが、dialog が SOL に視認できる時点で **`partman/confirm boolean true` の auto-confirm が効かない種類の error** と判断でき、即座に racreset soft できる
- **修正候補**: skill SKILL.md Phase 5 ステップ 4 partman stuck 条件に「**SOL に partman error dialog (`No root file system is defined` 等) が 5 分以上残ったら即 racreset soft 発動可**」を追記。これにより partman stuck recovery 時間を 7-10 分短縮できる
- **再現性**: Round 5 (partman stuck), Round 9 (今回) で確認 = 2/9 trial = 22% 発生率

### 改善 25 (新規): bmc-power.sh cycle が既に Off の server で transient error を返すケース

- **問題** (Round 9 trial 9 s15 Phase 4 ステップ初回): server が既に Off 状態の時に `bmc-power.sh cycle` を打つと、内部の ForceOff Redfish API が `"Invalid System id: 1"` エラーを返す (実際は問題なし)。Power On は成功する場合もあるが、Round 9 では Power On も同じエラーを返した。手動の `bmc-power.sh on` で復旧
- **修正候補**: `bmc-power.sh cycle` を「現在の power state を最初に取得 → Off ならスキップして直接 On」のロジックに変更、または `cycle` 内部で ForceOff の HTTP エラーを「server 既に Off」のサインとして許容する
- **再現性**: Round 9 が初観測 = 1/9 trial = 11%、要追跡

## 主要ログ

- `tmp/c452be97/sol-install-s15.log` (attempt1 partman stuck、stage 5/9 で 8min 沈黙)
- `tmp/c452be97/sol-install-s15-att2.log` (attempt2 完走ログ、stage 7/9 観測)
- `tmp/c452be97/sol-commands-s15.txt` (post-install-config SOL コマンド)
- `tmp/c452be97/linbit-keyring.gpg` (LINBIT keyring、trial 8 から流用)
- `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
iso-download             0m14s
preseed-generate         0m06s
iso-remaster             0m03s   (preseed unchanged, 再生成スキップ)
bmc-mount-boot           6m13s
install-monitor         25m30s   (attempt1 partman stuck 8min + racreset soft 復旧 ~7min + attempt2 6m18s + 余裕)
post-install-config      4m22s
pve-install             15m52s   (post-reboot 2 回 + LINSTOR + DRBD DKMS + final reboot route 復旧)
cleanup                  1m15s   (bridge setup 含む)
---
total                   53m35s
```

注: wall time は約 76m (Phase A の RAID resetconfig + createvd を含む)。phase合計 53m35s は iso-download 以降のフェーズ所要時間。

## 検証コマンド結果

| 検証項目 | 結果 |
|---------|------|
| `pveversion` | `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)` |
| `cat /etc/os-release` (PRETTY_NAME) | `Debian GNU/Linux 13 (trixie)` |
| `uname -r` | `7.0.2-2-pve` |
| `ip -brief addr show vmbr0` | `vmbr0 UP 10.10.10.215/8` |
| `ip -brief addr show vmbr1` | `vmbr1 UP 192.168.39.123/24` |
| `ip route` default | `default via 192.168.39.1 dev vmbr1` |
| `curl -sk -o /dev/null -w "%{http_code}" https://10.10.10.215:8006` | `200` |
| `lsmod \| grep drbd` | `drbd 843776 0` + `lru_cache 16384 1 drbd` (module loaded) |
| `racadm raid get vdisks` | `Disk.Virtual.0 State=Online Layout=Raid-1 OperationalState=Not applicable` |
| `/etc/machine-id` mtime | install-monitor.start より新しい (1778562276 > 1778560939、fresh install 確認) |
| `ping -c1 deb.debian.org` | `0% packet loss, 2.86ms` |

## Round 1-9 比較

| trial | wall | phase total | install attempt | RAID reset job | install-monitor stage | 主な遅延要因 |
|-------|------|-------------|-----------------|----------------|----------------------|----------------|
| 1 | 49m | 36m | 1 | n/a (first install) | 9 | initial baseline |
| 2 | 70m | 25m | 2 | + 6 min | 7 (att2) | GRUB sector read error → racreset soft |
| 3 | 59m | 41m | 1 | + 12 min | 9 | LINBIT linstor-common 56MB が 12 分かかる |
| 4 | 49m | 35m | 1 | + 12 min | 6 | post-reboot route 消失 → 1 回追加実行 (+ 約 6 分) |
| 5 | 76m | 29m | 2 | + ~3 min | 7 (att2) | partman 5/9 stuck → racreset soft + post-reboot route 消失 |
| 6 | 48m | 34m | 1 | ~10 min | 7 | post-reboot route 消失 + LINBIT keyring 不在の合わせ技 |
| 7 | 60m | 34m | 1 | ~26 min | 7 | createvd 1 回目 PR34 → racreset soft + createvd --realtime で回復 |
| 8 | 53m | 32m | 1 | ~8 min | 7 | Round 7 改善 22 適用 + dhcpcd 初回 probing 失敗 |
| **9** | **76m** | **54m** | **2** | **~4 min** | **7 (att2)** | **partman "No root file system" dialog 8min stuck → racreset soft + bmc-power transient error + dhcpcd IPv4LL 再現 + post-reboot route 2 回消失** |

## 次 trial への引き継ぎ

- preseed-server15.cfg の `netcfg/choose_interface select eno2` 確定 (9 trial 連続で機能)
- preseed-server15.cfg の `for disk in $(list-devices disk)` の古いパターンが原因で `/dev/sdb` (R430 vFlash SD slot) を partman が誤って候補にし、partman stuck "No root file system" を引き起こすことがある (Round 5, Round 9 で確認)。**preseed-server14.cfg の `for disk in /dev/sda` パターンに揃える候補** (Round 5 で言及されたが Round 9 でも再発、対応推奨)
- `racadm jobqueue create ... --realtime` (createvd 適用) は Round 7 改善 22 の通り安全・高速で機能
- `racadm racreset soft` 回復手順は trial-2 (GRUB), trial-5 (partman), trial-7 (createvd PR34), trial-9 (partman) で実証、trial-3, 4, 6, 8 では発動不要 (4/9 = 44% 発生率に上昇)
- **post-reboot 中の default route 消失は再現性確定** (Round 4-9 連続再発、6/6 = 100%)
- **final reboot 後の default route 消失も再現** (Round 5-9 連続、5/5 = 100%)
- **LINBIT keyring 事前配置** (Round 6 で確定) は Round 7-9 でも有効
- **dhcpcd IPv4LL probing 失敗** (Round 8 新規) は Round 9 でも再現 = 2/9 = 22%
- **bmc-power.sh cycle "Invalid System id: 1" transient error** (Round 9 新規) は手動 `bmc-power.sh on` で復旧、要追跡

## 新規 skill 改善候補 (Round 9)

### 改善 24: partman stuck 早期 trigger を 8min + SOL dialog 視認に短縮 (中優先)

- **問題** (Round 9 trial 9 s15): SKILL.md Phase 5 ステップ 4 の partman stuck trigger 条件 (15min stuck + syslog 10min silence) より前に、SOL に "No root file system is defined" dialog が表示された時点で確定的に fail と判断できる
- **修正候補**: 「**SOL に partman error dialog (例: `No root file system is defined`, `partman: ...failed`) が 5 分以上残ったら即 racreset soft 発動可**」を SKILL.md Phase 5 step 4 に追記
- **影響**: partman stuck recovery 時間を 7-10 分短縮 (Round 9 では 8min 発火で 5-7min 節約)

### 改善 25: preseed-server15.cfg の partman/early_command を `/dev/sda` 明示に統一 (低-中優先)

- **問題** (Round 9 trial 9 s15): preseed-server15.cfg は `for disk in $(list-devices disk)` のままで Round 5, Round 9 で partman stuck を発生。preseed-server14.cfg は `for disk in /dev/sda` + `[ -b "$disk" ] || continue` で安定
- **修正候補**: preseed-server15.cfg の `partman/early_command` を preseed-server14.cfg と同じ `for disk in /dev/sda` + `[ -b "$disk" ] || continue` に置換。LVM 方式への変更は不要 (現状の `partman-auto/method regular` + `atomic` レシピで十分動作している、attempt2 で 6min 完走)
- **影響**: partman stuck の発生率を 22% → ~0% に下げる見込み

### 改善 26 (新規): bmc-power.sh cycle を「Off → 直接 On」に最適化 (低優先)

- **問題** (Round 9 trial 9 s15 Phase 4 初回): server が既に Off の時 `bmc-power.sh cycle` の ForceOff API が `"Invalid System id: 1"` を返し、続く On も同じエラーを返した
- **修正候補**: `bmc-power.sh cycle` 内で先に power state を取得し、Off なら ForceOff をスキップして直接 On する。または ForceOff API エラー時の「実は Off」検出を入れる
- **影響**: bmc-mount-boot Phase が transient error で stall するのを防ぐ、recovery 自動化に有用

Trial 9 server15: success (76min, attempt 2)
