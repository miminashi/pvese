# Trial 6 / 10 — server15 (R430)

- 開始: 2026-05-12 10:18 JST (powerdown 直後の最初の RAID resetconfig)
- 終了: 2026-05-12 11:06 JST
- 所要時間: 約48m (wall) / 34m32s (phase合計)
- 結果: success
- install-monitor attempt 回数: 1 (一発成功)
- 失敗時の原因: なし

- 観測された問題 / 既知事象の再現:
  - **post-reboot 中の default route 消失 (Round 4 改善 15) は再現** — `proxmox-ve` インストール完了後、最初の `apt-get update` で enterprise.proxmox.com に 401 Unauthorized + LINBIT keyring 不在で `pve-setup-remote.sh --phase post-reboot` 初回が exit 100 (Round 4-5 と同じ default route 消失パターン + LINBIT keyring 未配置の合わせ技)。
  - **対処** (skill 通り):
    1. enterprise repo (`pve-enterprise.sources`) を削除
    2. LINBIT keyring を ローカル → ubuntu keyserver 経由で取得 → `/usr/share/keyrings/linbit-keyring.gpg` に配置
    3. `pre-pve-setup.sh` を再実行 (default route 復旧 + apt sources 再生成 + LINBIT 有効化)
    4. `pve-setup-remote.sh --phase post-reboot --linstor` を再実行 → 成功 (drbd-dkms ビルドも一発成功、build-essential 事前 install 済)
  - **改善 16 (partman 5/9 stuck) は発動なし** — 今回は LOADING_COMPONENTS から FINISH まで stuck なく進行 (Round 3-5 でも 1 trial しか発動していない、稀な事象)
  - **改善 17 (pve-bridge-setup.sh 必須) は問題なく実行** — final reboot → route fix → `pve-bridge-setup.sh --static-iface eno2 --static-ip 10.10.10.215/8 --dhcp-iface eno1` で vmbr0/vmbr1 作成。Web UI 200 / vmbr0 UP / default route via vmbr1 確認済
  - **改善 18 (final reboot 後の route 消失)** — final reboot 後 default route 消失 (Round 5 と同じ)。`pre-pve-setup.sh` 再実行で確実に救済。skill 通り
  - **PowerState API 30s timeout が install-monitor 中に頻発** (Round 4 と同じ): BMC が POST/boot 移行期に Redfish API を一時的にブロック。sol-monitor.py は None を受けても継続実行する設計で、Stage 観測 + EOF + 30s 後 PowerState=Off で完了判定。skill 既存挙動と一致。改善不要
  - **完全リセット直後の `racadm raid resetconfig` 後の SCP Export job** — 今回も発生 (`JID_785674319664`)。createvd 前に Completed 確認、skill 通り
  - **RAID resetconfig → createvd の所要時間**: resetconfig job 約 4 分 (Running 34%→100%、SCP Export 自動付随)、createvd job 約 4 分 (Running 34%→100%)。Total ~10 分

- 新発見 / skill 改善候補:
  - **post-reboot 1 回目の失敗パターンが 2 つ複合**: 今回は (a) enterprise repo 401 (b) LINBIT keyring 不在 が同時に発生。Round 4-5 では (a) のみ観測。`pve-setup-remote.sh` の最初の `apt-get update` の前に enterprise repo を確実に削除する処理は既に skill `--Removing enterprise repositories--` に入っているが、その**直後の `apt-get update`** で LINBIT GPG が 404 のまま走るので exit 100 になる。**改善候補 19**: SKILL.md Phase 7 ステップ 4 の前段で「`--linstor` を使う場合、`pve-setup-remote.sh` 実行前にローカルから LINBIT keyring を取得して配置する」を **必須ステップ化** (現在は note 扱い)。今回 Round 6 で確実に発動 → keyring 配置は事前必須と確定。

- 主要ログ:
  - `tmp/t6s15-01/sol-install-trial6-s15.log` (SOL 監視ログ、7 stages 観測、PowerState=Off + Power down 検出で正規完了)
  - `tmp/t6s15-01/sol-commands-s15-t6.txt` (post-install-config SOL コマンド)
  - `tmp/t6s15-01/linbit-keyring.gpg` (LINBIT keyring、後続 trial で再利用可)
  - `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
iso-download             0m00s   (キャッシュ再利用、Phase 完了マークのみ)
preseed-generate         0m00s   (静的 preseed-server15.cfg 使用)
iso-remaster             0m00s   (preseed hash 一致 → リマスタースキップ)
bmc-mount-boot           1m22s
install-monitor          7m32s
post-install-config      5m59s
pve-install             17m46s   (post-reboot を 2 回走らせた合計 + LINSTOR + DRBD DKMS)
cleanup                  1m53s   (bridge setup 含む)
---
total                   34m32s
```

注: wall time は約 48 分 (Phase A の RAID resetconfig + createvd + Export 全体 ~10 分を含む)。
phase合計 34m32s は OS install 開始以降のフェーズ所要時間。

## 検証コマンド結果

| 検証項目 | 結果 |
|---------|------|
| `pveversion` | `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)` |
| `ip -brief addr show vmbr0` | `vmbr0 UP 10.10.10.215/8` |
| `ip route` default | `default via 192.168.39.1 dev vmbr1` |
| `curl -sk https://10.10.10.215:8006` | `200 OK` |
| `racadm raid get vdisks` | `Disk.Virtual.0 State=Online Layout=Raid-1 (BGI in progress)` |

## Round 1-6 比較

| trial | wall | phase total | install attempt | RAID reset job | install-monitor stage | 主な遅延要因 |
|-------|------|-------------|-----------------|----------------|----------------------|----------------|
| 1 | 49m | 36m | 1 | n/a (first install) | 9 | initial baseline |
| 2 | 70m | 25m | 2 | + 6 min | 7 (att2) | GRUB sector read error → racreset soft |
| 3 | 59m | 41m | 1 | + 12 min | 9 | LINBIT linstor-common 56MB が 12 分かかる |
| 4 | 49m | 35m | 1 | + 12 min | 6 | post-reboot route 消失 → 1 回追加実行 (+ 約 6 分) |
| 5 | 76m | 29m | 2 | + ~3 min | 7 (att2) | partman 5/9 stuck → racreset soft + post-reboot route 消失 |
| 6 | 48m | 34m | 1 | ~10 min | 7 | post-reboot route 消失 + LINBIT keyring 不在の合わせ技 (1 回追加実行) |

## 次 trial への引き継ぎ

- preseed-server15.cfg の `netcfg/choose_interface select eno2` 確定 (6 trial 連続で機能)
- `racadm racreset soft` 回復手順は trial-2 (GRUB), trial-5 (partman) で実証、trial-3, 4, 6 では発動不要 (2/6 = 33% 発生率)
- **post-reboot 中の default route 消失は再現性確定** (Round 4, 5, 6 連続再発、3/3 = 100%)。`pre-pve-setup.sh` 再実行で確実救済
- **LINBIT keyring は事前配置が必須** (Round 6 で確定)。`tmp/t6s15-01/linbit-keyring.gpg` は次 trial で再利用可
- `dhcpcd -1 -t 30 eno1` 事前実行は引き続き必須 (Debian 13 minimal の DHCP timing 問題)。今回 1 回目は dhcpcd 成功、2-3 回目は timeout → dhclient fallback
- LINBIT linstor-common (56.6MB) は今回 13 秒で完走 (9.3 MB/s、帯域良好)
- `pve-bridge-setup.sh` は cleanup ステップで実行、Phase 8 完了に必要 (Round 5 で改善 17 として skill 強化済)
- final reboot 後の default route 消失も再現 (Round 5 と同じ)、`pre-pve-setup.sh` 再実行で救済

## 新規 skill 改善候補 (Round 6.5)

### 改善 19: LINBIT keyring 事前配置を必須ステップ化
- **問題** (s15 trial 6): `pve-setup-remote.sh --phase post-reboot --linstor` の初回実行で `Failed to parse keyring "/usr/share/keyrings/linbit-keyring.gpg": No such file or directory` で apt-get update が失敗、`Unable to locate package drbd-dkms` まで連鎖 → exit 100
- **修正**: SKILL.md Phase 7 の post-reboot 直前に「**`--linstor` を使う場合、必ず先に ubuntu keyserver から LINBIT keyring を取得 → `/usr/share/keyrings/linbit-keyring.gpg` に配置すること**」を必須ステップ化。現在は「LINBIT GPG キーが 404 になる場合の対処」として note 扱いだが、今回は keyring が初回から存在せず必ず失敗するパターンなので、最初から事前配置する手順にする
- **コマンド**:
  ```sh
  curl "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4E5385546726D13CB649872CFC05A31DB826FE48" -o tmp/<sid>/linbit-key.asc
  gpg --batch --yes --dearmor -o tmp/<sid>/linbit-keyring.gpg tmp/<sid>/linbit-key.asc
  scp -F ssh/config tmp/<sid>/linbit-keyring.gpg root@<static_ip>:/usr/share/keyrings/linbit-keyring.gpg
  ssh -F ssh/config root@<static_ip> chmod a+r /usr/share/keyrings/linbit-keyring.gpg
  ```

### 改善 20: enterprise repo 削除を post-reboot 直前にも実行 (冪等性確認)
- **問題** (s15 trial 6): 初回 `pre-pve-setup.sh` 実行後、`pve-setup-remote.sh --phase pre-reboot` 内で proxmox-ve リポジトリが追加されるが、その中に `pve-enterprise.sources` も含まれる。post-reboot の `apt-get update` で 401 Unauthorized が出るのは、これが残っているため。
- **状態**: skill 既存「`--Removing enterprise repositories--`」は post-reboot 内に存在。確認のみ
- **修正**: skill には既に書かれているので動作確認のみ。今回は (a) enterprise repo 残り + (b) LINBIT keyring 不在 の両方が同時発生したため、(b) を改善 19 で事前必須化すれば、(a) は post-reboot 内で削除されるため一発で通る

Trial 6 server15: success (48min, attempt 1)
