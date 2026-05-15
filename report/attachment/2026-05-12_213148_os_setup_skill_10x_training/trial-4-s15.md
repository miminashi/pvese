# Trial 4 / 10 — server15 (R430)

- 開始: 2026-05-12 08:06:49 JST
- 終了: 2026-05-12 08:55:49 JST
- 所要時間: 49m00s (wall) / 35m12s (phase合計)
- 結果: success
- install-monitor attempt 回数: 1 (一発成功)
- 失敗時の原因: なし

- 観測された新規問題 / skill 改善候補:
  - **pve-setup-remote post-reboot 中の reboot で default route が消失** (Round 3 までと挙動同等だが今回より顕著に観測): pve-setup-remote の post-reboot phase 中に proxmox-ve install → grub 再生成 → /etc/network/if-up.d/z-fix-default-route hook 配置の直後に LINBIT repository 設定が走るが、その直前で何らかの operation (おそらく `ifupdown2` re-init 由来) によって default via 192.168.39.1 が消失し、`Temporary failure resolving 'packages.linbit.com'` が連鎖して `Unable to locate package drbd-dkms` まで進む。結果として **post-reboot を 2 回 (route fix → 再実行) 走らせる必要があり**、追加で 1 回ぶんの apt-update + LINBIT 取得時間が掛かる。
    - 1 回目 post-reboot: proxmox-ve install 完了 (デフォルト route 消失) → LINBIT install fail (exit 100)
    - 2 回目 pre-pve-setup: route 復旧
    - 3 回目 post-reboot: LINBIT install 成功 (drbd-dkms 含む、5-6 分)
  - **改善候補 15**: SKILL.md Phase 7 ステップ 4 に「pve-setup-remote post-reboot は internal で複数回の apt operation を走らせるため、その間に default route が消失することがある。`Temporary failure resolving` / `Unable to locate package` を観測したら `pre-pve-setup.sh` を 1 回挟んで再実行する」と明記する。もしくは pve-setup-remote.sh の途中で route check + 自動再設定を入れる
  - **Round 2.5 改善 6-9 + Round 3.5 改善 10-14 はすべて機能**:
    - 改善 6 (LINBIT GPG 事前配置): trial-3 の keyring 再利用、`https://packages.linbit.com/...` が GPG 検証成功
    - 改善 7 (build-essential 事前 install): DRBD DKMS build 一発成功 (`Building module(s).......... done.`)
    - 改善 8 (SCP Export job 完了待ち): 今回も Export job は **resetconfig 完了後に Completed 状態で出現** したのでスキップ可。skill 既存記載通り
    - 改善 9 (sol-login printf > file 警告): `chmod 700 /root/.ssh` / `chmod 600 authorized_keys` で警告が出たが SSH key auth 成功 (誤検知確定)
    - 改善 10 (partman 5/9 stuck 早期判定): 今回 partman は stuck せず一発で stage 5/9 → 進行 (発動なし)
    - 改善 11 (DETECTING timeout): 今回は sleep 180s 後の sol-login で一発成功、DETECTING fail なし
    - 改善 12 (eno1 DHCP iface): SOL コマンドリストに `ip link set eno1 up` + `printf 'auto eno1\niface eno1 inet manual\n'` を含めて prevent (Round 3 で既に skill に書かれている)。今回も適用、`pre-pve-setup.sh` の dhclient fallback で 30s timeout → dhclient で取得成功
    - 改善 14 (LINBIT linstor-common ダウンロード時間): 今回は ~10 MB/sec で 6 秒で完走 (apt キャッシュ + ネット帯域良好)
  - **完全リセット直後の install attempt 1 で GRUB sector read error なし** — Round 1, 3, 4 (= 4 trial 中 3 回) で発生せず、Round 2 のみで発生 (25%)。`racreset soft` 回復手順は trial-2 で実証済みで継続有効
  - **sol-monitor で観測された stage は 6/9** (LOADING_COMPONENTS, DETECTING_NETWORK, CONFIGURING_APT, INSTALLING_BASE_SYSTEM, GRUB_INSTALL, FINISH_INSTALL 系の停止点で計測 — trial 1-3 は 7-9 stages 観測されていた)。但し PowerState=Off + "Power down" 検出 + stages_seen=5 で正規完了判定はクリア (sol-monitor.py の False positive ガードは通過)。実 install 検証 (`/etc/machine-id` mtime 比較) も通過。
  - **PowerState check failed: timeout after 30 seconds** が install-monitor 中に頻発 (Cycle 0-5 で 6 回)。BMC が POST / OS boot 移行期に Redfish API を一時的にブロックする挙動。`sol-monitor.py` 側は None 受け取り後の継続実装が正しく動作 (stage 観測 + SOL EOF + 30s 後 PowerState=Off で完了判定)。skill 既存挙動と一致。改善要らず

- 主要ログ:
  - `tmp/c452be97/sol-install-trial4-s15.log` (SOL 監視ログ、6 stages 観測、PowerState=Off + Power down 検出で正規完了)
  - `tmp/c452be97/trial-4-s15.log` (trial 開始マーカ)
  - `tmp/c452be97/installer-syslog-all.log` (親セッション共通)
  - `tmp/c452be97/sol-commands-s15-t4.txt` (post-install-config SOL コマンド)
  - `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
iso-download             0m10s
preseed-generate         0m04s
iso-remaster             0m05s   (preseed unchanged, 再生成スキップ)
bmc-mount-boot           2m13s
install-monitor          8m20s
post-install-config      6m02s
pve-install             17m28s   (post-reboot を 2 回走らせた合計)
cleanup                  0m50s
---
total                   35m12s
```

注: wall time は 49m00s。phase合計 35m12s より長いのは Phase A (RAID resetconfig + createvd, 約 12 分) を含むため。

## 次 trial への引き継ぎ

- preseed-server15.cfg の `netcfg/choose_interface select eno2` 確定 (4 trial 連続で機能)
- `racadm racreset soft` 回復手順は trial-2 で実証、trial-3, 4 では発動不要 (1/4 = 25% 発生率)
- `dhcpcd -1 -t 30 eno1` 事前実行は引き続き必須 (Debian 13 minimal の DHCP timing 問題)
- **post-reboot 中の default route 消失は再現性あり** (今回確実に観測)。改善 15 の skill 追記候補が次 trial で実証されるかは未確認
- LINBIT linstor-common (56.6MB) は今回 6 秒で完走 (時間帯依存、深夜帯+空いてる時間帯で帯域良好)
- 改善 10-14 (Round 3.5) は今回発動なし or 機能維持を確認

## Round 1-4 比較

| trial | wall | phase total | install attempt | RAID reset job | install-monitor stage | 主な遅延要因 |
|-------|------|-------------|-----------------|----------------|----------------------|----------------|
| 1 | 49m | 36m | 1 | n/a (first install) | 9 | initial baseline |
| 2 | 70m | 25m | 2 | + 6 min | 7 (att2) | GRUB sector read error → racreset soft |
| 3 | 59m | 41m | 1 | + 12 min | 9 | LINBIT linstor-common 56MB が 12 分かかる |
| 4 | 49m | 35m | 1 | + 12 min | 6 | post-reboot route 消失 → 1 回追加実行 (+ 約 6 分) |

Trial 4 server15: success (49min, attempt 1)
