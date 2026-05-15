# Trial 5 / 10 — server15 (R430)

- 開始: 2026-05-12 08:58:13 JST
- 終了: 2026-05-12 10:14:38 JST
- 所要時間: 76m25s (wall) / 29m26s (phase合計、attempt2 のみ)
- 結果: success
- install-monitor attempt 回数: 2 (attempt1 partman stuck → racreset soft → attempt2 成功)
- 失敗時の原因:
  - **attempt1: partman 15min stuck on stage 5/9** — sol-monitor で 5 stages 観測後、stages=5 のまま 15 分以上停滞。installer-syslog の最終行が `partman: No matching physical volumes found` (00:26:19) で 12 分以上沈黙。KVM screenshot は capconsole で黒画面 (VNC 拒否、IDLE 状態)。SOL 末尾は byobu/screen のステータスバー (1*installer (red)) が毎分更新だけ。
  - 対処: skill Phase 5 ステップ 4 の早期 trigger「partman stage 5/9 15分停滞 + syslog 10+min 沈黙」に従い `racadm racreset soft` (約 90 秒で SSH 復帰) → VirtualMedia umount → 再 mount + verify → boot-once VCD-DVD → 電源 ON。
  - attempt2 は 7m09s で完走、PowerState=Off + 7 stages 観測 (LOADING_COMPONENTS, DETECTING_NETWORK, CONFIGURING_APT, INSTALLING_SOFTWARE, INSTALLING_GRUB ...) の正規完了パターン。

- 観測された新規問題 / skill 改善候補:
  - **「partman 5/9 stuck + syslog silence」は完全リセット直後でも発生する** (Round 4 trial-4 は一発成功だった条件と完全同条件で再現)。Trial 1 (success att1), Trial 2 (GRUB sector read), Trial 3 (success att1), Trial 4 (success att1), Trial 5 (partman stuck att1) → 5 trial 中 attempt1 失敗が 2/5 (40%) になった。失敗パターンは Round 2 (GRUB sector read) と異なる新パターン。
  - **Phase 5 早期 trigger ルールは機能した** — skill 記載の partman stuck 判定基準 (stage 5/9 15分 + installer-syslog 10+min 沈黙) に従い 15.2 min で racreset soft → attempt2 一発成功。Round 2 の GRUB sector read より検出が遅いので skill にしっかり書いておく必要あり。**改善候補 16**: SKILL.md Phase 5 step 4 「partman stage 5/9 stuck の早期トリガ条件は trial 5 で n=1 実証された (Round 1-4 で不検出だった)」と注記し、`partman: No matching physical volumes found` を SOL 上で 10 分以上見たらアクション起動の候補とする。
  - **Round 4 改善 15 (post-reboot 中 default route 消失) は本 trial でも再現** — `pve-setup-remote.sh --phase post-reboot` の `apt install proxmox-ve` の途中で `ifupdown2` 再初期化により default via 192.168.39.1 が消失し、続く `apt install` の途中で `Temporary failure resolving 'packages.linbit.com'` 等の DNS 解決失敗 → exit 100。`pre-pve-setup.sh` を再実行してルート修復 → `pve-setup-remote.sh --phase post-reboot` を再実行で成功。Round 4 改善 15 の skill 注記がそのまま機能した (今回 trial 4 と同じ挙動)。再現性確定 (Round 4, 5 連続)。
  - **VLAN なし R430 はインストール後 vmbr0/vmbr1 を別途作成する必要がある** — `pve-setup-remote.sh` は vmbr0/vmbr1 を作成しない (静的 iface はそのまま `eno2` static)。Phase 7/8 完了後の検証で `vmbr0` が存在せず Web UI 200 確認のため `pve-bridge-setup.sh --static-iface eno2 --static-ip 10.10.10.215/8 --dhcp-iface eno1` を別途実行。**改善候補 17**: SKILL.md Phase 7 ステップ 4 の後に「PVE インストール完了後、`pve-bridge-setup.sh` を実行して vmbr0/vmbr1 を作成する。Trial 4 までは Web UI 確認時に明示的に意識されていなかったが、PVE Web UI で VM を立てる前に必須」と Phase 8 / Phase 9 として追記。
  - **改善 10-14 (Round 2.5/3.5)、改善 15 (Round 4.5) は本 trial で全部実証**:
    - 改善 10 (partman 5/9 stuck 早期判定): **trial 5 で初発動 + 救済成功** — 15 min/10 min ルール通り
    - 改善 11 (DETECTING timeout): 発動なし (boot 後 sleep 120 → sol-login 即成功)
    - 改善 12 (eno1 DHCP iface): SOL コマンドリストに `ip link set eno1 up` + `printf 'auto eno1\niface eno1 inet manual\n'` を含めて勿論動作
    - 改善 13 (iDRAC SSH 復旧確認): racreset soft 後 7×15=105 秒で SSH 復帰、wait-idrac スクリプトで確認
    - 改善 14 (LINBIT linstor-common ダウンロード時間): 117 MB を 29 秒 (~4 MB/s) — 帯域良好
    - 改善 15 (post-reboot default route 消失): 再現 + skill 通り回復成功
  - **完全リセット直後の `racadm raid resetconfig` 後の SCP Export job** — 今回も発生 (`JID_785622467226 Status=Running pct=10`)。skill の警告通り createvd を打つ前に終了を確認し待機 (実際にはわずか数秒で消えた)。

- 主要ログ:
  - `tmp/c452be97/sol-install-trial5-s15.log` (attempt1, partman stuck ログ、15min stage 5/9 沈黙)
  - `tmp/c452be97/sol-install-trial5-s15-att2.log` (attempt2, 7 stages 観測の完走ログ)
  - `tmp/c452be97/trial-5-s15.log` (trial 開始マーカ)
  - `tmp/c452be97/installer-syslog-all.log` (親セッション共通)
  - `tmp/c452be97/sol-commands-s15-t5.txt` (post-install-config SOL コマンド)
  - `tmp/c452be97/t5-check1.png`, `t5-check2.png` (partman stuck 時の KVM screenshot, 両方とも capconsole 黒画面)
  - `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
iso-download             0m14s
preseed-generate         0m12s
iso-remaster             0m03s   (preseed unchanged, 再生成スキップ)
bmc-mount-boot           2m00s   (attempt2 用、attempt1 のリトライ時間は含まれない)
install-monitor          7m09s   (attempt2 のみ)
post-install-config      6m23s
pve-install             13m15s   (post-reboot を 2 回走らせた合計 + LINSTOR 29s download)
cleanup                  0m10s
---
total                   29m26s
```

注: wall time は 76m25s (attempt1 失敗 + racreset 待ち + RAID resetconfig + createvd を含む)。
phase合計 29m26s は attempt2 単独 + 後続フェーズの所要時間。

## Round 1-5 比較

| trial | wall | phase total | install attempt | RAID reset job | install-monitor stage | 主な遅延要因 |
|-------|------|-------------|-----------------|----------------|----------------------|----------------|
| 1 | 49m | 36m | 1 | n/a (first install) | 9 | initial baseline |
| 2 | 70m | 25m | 2 | + 6 min | 7 (att2) | GRUB sector read error → racreset soft |
| 3 | 59m | 41m | 1 | + 12 min | 9 | LINBIT linstor-common 56MB が 12 分かかる |
| 4 | 49m | 35m | 1 | + 12 min | 6 | post-reboot route 消失 → 1 回追加実行 (+ 約 6 分) |
| 5 | 76m | 29m | 2 | + ~3 min | 7 (att2) | **partman 5/9 stuck → racreset soft (新パターン)** + post-reboot route 消失 (Round 4 と同じ) |

## 次 trial への引き継ぎ

- preseed-server15.cfg の `netcfg/choose_interface select eno2` 確定 (5 trial 連続で機能)
- `racadm racreset soft` 回復手順は trial-2 (GRUB sector read) と trial-5 (partman stuck) の **2 種類の attempt1 失敗パターン**で実証
- attempt1 失敗発生率は **2/5 = 40%** (GRUB 1/5, partman 1/5)。原因不明だが「完全リセット直後」「iDRAC VirtualMedia の内部状態が前回の残骸で壊れる」仮説のいずれかと推定
- post-reboot 中の default route 消失は **再現性確定** (Round 4, 5 連続)。`pre-pve-setup.sh` 再実行で確実救済
- `dhcpcd -1 -t 30 eno1` 事前実行は引き続き必須 (Debian 13 minimal の DHCP timing)
- LINBIT linstor-common (56.6 MB) は今回 29 秒で完走 (帯域良好時間帯)
- **新発見**: PVE インストール完了直後は vmbr0/vmbr1 が存在しないため、`pve-bridge-setup.sh` を別途実行する必要がある (Web UI 200 + ネットワーク疎通には必須)。trial 1-4 では検証スコープに入っていなかった可能性

## 新規 skill 改善候補 (Round 5.5)

### 改善 16: partman 5/9 stuck 早期 trigger の n=1 実証記録
- **問題**: Round 2 (n=1) で skill に書かれていた「partman 5/9 stuck 15分 + syslog 沈黙 10min → racreset soft」の早期 trigger ルールが、trial 5 で初めて実用された。Round 1, 3, 4 では発動せず、trial 5 で初発動。完全リセット直後の attempt1 でも partman が dialog 表示状態 (preseed auto-confirm 期待) で SOL 表示は frozen に見えるパターンがある
- **修正**: SKILL.md Phase 5 step 4 「partman 5/9 stuck の判定」セクションに「partman で SOL screen が `(1*installer)` red highlight の byobu ステータスバー (タイマー更新のみ) で stuck + installer-syslog 最終行が `partman: No matching physical volumes found` から 10 分以上沈黙 → racreset soft 即発動」を具体例として追記。今回の SOL 末尾パターンは「`partman: No matching physical volumes found` 後の沈黙」(skill 既存記載と一致するが、screen の表示パターン (byobu の clock 更新だけ) を明示すると判定がしやすい)

### 改善 17: PVE インストール後の vmbr0/vmbr1 設定を Phase 8 化
- **問題**: `pve-setup-remote.sh` 単独では vmbr0/vmbr1 を作らない。`/etc/network/interfaces` は preseed install 時の `eno2 inet static` のままで、PVE Web UI からは VM 立てられない (NIC bridge がない)
- **修正**: SKILL.md に Phase 8b (または Phase 9) として「`pve-bridge-setup.sh --static-iface <iface> --static-ip <ip/mask> --dhcp-iface <iface>` を実行して vmbr0/vmbr1 を作成する」と明記。trial 1-4 の検証では vmbr0 = static_iface 互換だったか、Web UI 200 が `eno2` 直で通っていたかは要確認 (Round 1-4 のレポートに `vmbr0` 検証コマンドが含まれているか）

Trial 5 server15: success (76min, attempt 2)
