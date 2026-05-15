# Trial 3 / 10 — server15 (R430)

- 開始: 2026-05-12 06:44:05 JST
- 終了: 2026-05-12 07:42:40 JST
- 所要時間: 58m35s (wall) / 40m37s (phase合計)
- 結果: success
- install-monitor attempt 回数: 1 (一発成功)
- 失敗時の原因: なし
- 観測された新規問題 / skill 改善候補:
  - **packages.linbit.com からの linstor-common (56.6 MB) ダウンロードが遅い** — 約 150 KB/sec で、一度 timeout してから再試行 (`Ign:13` → 再 `Get:13`) し、計 12-13 分かかった。Round 1/2 と比較して post-reboot 全体時間が大幅延伸 (Round 1: 11m, Round 2: 13m, Round 3: 23m36s)。**改善候補**: skill に「LINBIT 経由の `linstor-common` (56 MB) は転送に 5-15 分かかる場合がある。apt が止まっているように見えても `/var/cache/apt/archives/partial/` のファイルサイズが増えていれば正常」と注記する。apt の `-o Acquire::Retries=3 -o Acquire::http::Timeout=60` も検討余地あり
  - **trial-1/trial-2 で実証された改善 6-9 は今回も有効**:
    - 改善 6 (LINBIT GPG 事前配置): trial-3 で local 取得 + dearmor + scp 方式が機能 (`https://packages.linbit.com/...` が GPG 検証成功)
    - 改善 7 (build-essential): `apt install -y build-essential` を `pve-setup-remote.sh --linstor` の前に流すことで drbd-dkms ビルドが正常完了 (Building module(s).....done.)
    - 改善 8 (SCP Export 待ち): 今回 `resetconfig` 後に SCP Export job は **発生せず** (`Configure: RAID Status=Completed` のみで Export job 自体が出現せず)。Round 2 と挙動差。skill 既存記載通り「Export job があれば待つ、なければ進む」で問題なし
    - 改善 9 (sol-login printf > /file 警告): `chmod 700 /root/.ssh` と `chmod 600 /root/.ssh/authorized_keys` で "Command may have failed" が出たが authorized_keys 配置 + SSH key auth は成功。skill 注記通り誤検知扱いで正解
  - **eno1 が default DOWN** (Round 1/2 と同様) — preseed `netcfg/choose_interface select eno2` の副作用で eno1 が `iface eno1 inet manual` 配線にならず無設定。SOL コマンドで `ip link set eno1 up` を明示実行する必要があった (Round 2 も同様、skill には未記載)。**改善候補**: skill Phase 6 step 3 の SOL コマンドファイルに `ip link set eno1 up` を加える、または preseed late_command で `printf 'auto eno1\niface eno1 inet manual\n' >> /etc/network/interfaces`
  - **完全リセット直後の install attempt 1 で GRUB sector read error なし** — Round 2 (attempt 1 で発生) と異なる挙動。3 trial 中 1 回発生 (33%) の reproducibility。skill に既存記載の racreset soft 回復手順が trial-2 で実証済みなので対応は十分

- 主要ログ:
  - `tmp/c452be97/sol-install-trial3-s15.log` (SOL 監視ログ、9 stages 観測、stage 5/9 → 7/9 → PowerState Off)
  - `tmp/c452be97/trial-3-s15.log` (trial 開始マーカ)
  - `tmp/c452be97/installer-syslog-all.log` (親セッション共通)
  - `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
iso-download             0m14s
preseed-generate         0m03s
iso-remaster             0m09s   (preseed unchanged, 再生成スキップ)
bmc-mount-boot           1m53s
install-monitor          7m25s
post-install-config      6m06s
pve-install             23m36s   (LINBIT linstor-common 56MB 遅延ダウンロード起因)
cleanup                  1m11s
---
total                   40m37s
```

注: wall time は 58m35s。phase合計 40m37s より長いのは Phase A (RAID resetconfig + createvd, 約 12 分) + 各 phase 間の人手部分 (Phase A → B 切替時の確認時間等) を含むため。

## 次 trial への引き継ぎ

- preseed-server15.cfg の `netcfg/choose_interface select eno2` 確定 (3 trial 連続で機能)
- `racadm racreset soft` 回復手順は trial-2 で実証、trial-3 では発動不要
- LINBIT 経由 `linstor-common` (56 MB) のダウンロードは時間依存性高い (5-15 分幅)。post-reboot 全体時間に影響する主要因
- `dhcpcd -1 -t 30 eno1` 事前実行は引き続き必須 (Debian 13 minimal の DHCP timing 問題)

Trial 3 server15: success (58min, attempt 1)
