# Trial 2 / 10 — server15 (R430)

- 開始: 2026-05-12 05:31:00 JST
- 終了: 2026-05-12 06:41:00 JST
- 所要時間: 70m (wall) / 25m11s (phase合計、attempt2 のみ)
- 結果: success
- install-monitor attempt 回数: 2 (attempt1 GRUB sector read error → racreset soft → attempt2 成功)
- 失敗時の原因:
  - **attempt1: GRUB "failure reading sector 0x1e8b5 from cd0" 無限ループ** — iDRAC VirtualMedia の内部状態が前回 trial の残骸で壊れていた疑い (skill 「Phase 5 ステップ 4: iDRAC VirtualMedia 連続失敗時の回復」と同一症状)。
  - 対処: `racadm racreset soft` (約 90 秒で SSH 復帰) → VirtualMedia umount → 再 mount → boot-once VCD-DVD → 電源 ON。attempt2 は 7m03s で完走、PowerState=Off + 7 stages 観測の正規完了パターン。
- 観測された新規問題 / skill 改善候補:
  - **iDRAC VirtualMedia GRUB 読み取りエラーは "1 回目" でも起きうる** — Round 1 trial-1-s15 は一発成功だったが、Round 2 では完全リセット (RAID + state + known_hosts) 直後の attempt1 にも関わらず GRUB sector read error が発生。**Phase 4 開始時に `racreset soft` を予防的に実行する** のは効率が悪い (2-3 分追加) が、attempt1 が POST→GRUB に進んだ直後 (60 秒程度) で SOL log を即チェックして "error: failure reading sector" 検出時は **即座に racreset → 再 mount** にする早期検出ルーチンを skill に追加すると総時間が縮む。
  - **`sol-login.py` の `printf '...' > /file` も "Command may have failed" 警告を出すことがある** — 今回 `printf 'ssh-ed25519...' > /root/.ssh/authorized_keys` で警告が出たが、後続 SSH 接続は成功し authorized_keys は正しく配置されていた (鍵認証で root@10.10.10.215 にログイン成功)。**警告は false alarm** であり、後続 SSH 試行で実検証する設計が現状の skill フローと合致している。skill ドキュメントに「sol-login.py の "Command may have failed" 警告は redirect (`>`) を含むコマンドで頻出するが、authorized_keys 等は SSH キー認証成功で実検証可能」と注記すると初心者の混乱を減らせる。
  - **preseed の `netcfg/choose_interface select eno2`** は Round 1 で示された通り完璧に機能した — static IP (10.10.10.215) は eno2 に、DHCP (192.168.39.117) は eno1 に正しく分離。Phase 6 step 3 の SOL `/etc/network/interfaces` 手動編集は不要だった。
  - **`pre-pve-setup.sh` 単独では DHCP 取得タイミング失敗** — Round 1 と同じく、最初に `ssh root@<ip> dhcpcd -1 -t 30 eno1` を手動実行してから pre-pve-setup を呼ぶ必要があった。preseed install 直後の minimal Debian は `isc-dhcp-client` 不在 + dhcpcd の `--oneshot` initial timing が pre-pve-setup の内部リトライと衝突する。**改善候補**: skill Phase 7 ステップ 0 に「最初に `dhcpcd -1 -t 30 <dhcp_iface>` を実行してから pre-pve-setup を呼ぶ」と既に書かれている。今回もそれに従ったので skill としては OK。
  - **`ssh ... reboot` が systemd Bus 不在エラーを出す** — `Failed to connect to system scope bus via local transport`. `ssh ... systemctl reboot` も同様。実際にはリブートは進行する (タイムアウト後 SSH 切断で確認)。エラー出力を捨てて || true で処理する skill 例文 (`ssh ... root@<ip> reboot || true`) が正しい挙動。
  - 完全リセット直後 (RAID resetconfig + jobqueue create pwrcycle 完了) でも、iDRAC が直後に Server Configuration Profile auto-export job (約 1-2 分) を裏で動かしており、続いて `racadm raid createvd` を実行すると `LC062: Export or Import server profile operation is already running` で失敗する。**改善候補**: skill に「`resetconfig` job 完了後でも 2-3 分の auto-export job が走る場合があるので、`racadm jobqueue view` で SCP-Export ジョブを確認し、終了待ちしてから次の raid 操作に進む」と注記する。

- 主要ログ:
  - `tmp/c452be97/sol-install-trial2-s15.log` (attempt1, GRUB ループ確認用)
  - `tmp/c452be97/sol-install-trial2-s15-attempt2.log` (attempt2, 完走ログ 7 stages)
  - `tmp/c452be97/trial-2-s15.log` (trial 開始マーカ)
  - `tmp/c452be97/installer-syslog-all.log` (親セッション共通; 21:24:50 finish-install / 21:25:08 reboot 観測)
  - `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
iso-download             0m13s
preseed-generate         0m00s
iso-remaster             1m45s   (preseed が trial1 と異なるため再生成)
bmc-mount-boot           1m22s   (attempt2 用、attempt1 のリトライ時間は含まれない)
install-monitor          7m03s   (attempt2 のみ)
post-install-config      2m58s
pve-install             11m09s
cleanup                  0m41s
---
total                   25m11s
```

注: wall time は 70 分 (attempt1 失敗 + racreset 待ち時間 + 報告書作成時間を含む)。
phase合計 25m11s は attempt2 単独の所要時間で、Round 1 (36m10s) より短い (apt パッケージキャッシュが効いた + DHCP failback がスムーズだった + 14号機並行進行で APT トラフィックの待ち時間が一定)。

## 次 trial への引き継ぎ

- preseed-server15.cfg の `netcfg/choose_interface select eno2` は確定。
- Round 1 と Round 2 で異なる挙動: Round 1 は attempt1 が GRUB を通過、Round 2 は attempt1 で GRUB ループ。**完全リセット直後の attempt1 でも 50% 程度の確率で GRUB sector read error が起きる** と推定 (n=2 では結論できないが、要観察)。
- `racadm racreset soft` → 約 90 秒で recover → bmc-mount-boot 再実行 で確実に救済可能 (skill に既存記載)。

Trial 2 server15: success (70min, attempt 2)
