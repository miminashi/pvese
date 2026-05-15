# Trial 1 / 10 — server15 (R430)

- 開始: 2026-05-12 04:38:22 JST
- 終了: 2026-05-12 05:27:15 JST
- 所要時間: 48m53s (wall) / 36m10s (phase合計)
- 結果: success
- install-monitor attempt 回数: 1 (一発成功)
- 失敗時の原因: なし
- 観測された新規問題 / skill 改善候補:
  - **preseed の `netcfg/choose_interface auto`** が link-up している全 NIC (eno1, eno2) のうち先頭 NIC を選択するため、static IP (10.10.10.215) が eno1 に割り当てられる。本来 mgmt 配線は eno2 のため、`No route to host` で SSH 不到達となる。OS 起動後に SOL で `/etc/network/interfaces` を `eno2=static, eno1=manual` に書き換えてから ifup する必要があった。skill フローでは Phase 6 ステップ 3 の SOL 経由設定で対応すべきだが、現状の skill コマンド例は authorized_keys 配置のみ書かれており、interfaces 修正は明示されていない。**改善候補**: Phase 6 で interfaces を明示的に書き換える手順を skill / preseed (`netcfg/choose_interface select eno2`) どちらかで強化する。
  - **`pre-pve-setup.sh` の DHCP 取得が一発で動かない**: Debian 13 minimal install は `isc-dhcp-client` 不在 + DHCP 30s timeout で失敗。先に `dhcpcd -1 -t 30 eno1` を手動で叩いて lease を取らせる必要があった。スクリプト側で dhcpcd フォールバックを既に持っているがタイミング依存。**改善候補**: pre-pve-setup の Step 3 で最初に `dhcpcd` を試すよう順序入れ替え、または skill 手順で明示的に「DHCP 失敗時は `dhcpcd -1 -t 30` を先に流す」と書く。
  - **SOL 経由 `cat > /file << EOF` heredoc が機能しない**: `sol-login.py` が行単位で送信するため heredoc が複数の独立コマンドに分解される。`printf '...\n...\n' > /file` を使う必要がある。**改善候補**: skill ドキュメントに「heredoc 使用禁止、printf を使う」と追記。
  - **`sol-login.py` がコマンドの stdout を捕捉しない**: 実行ログには `[N/M] cmd` だけが残り、`ip addr` 等の出力を確認できない。状態確認には syslog 経由か `> /tmp/file` で残してから後で SSH で読む必要がある。**改善候補**: `sol-login.py` に `--capture-output PATH` を追加する。
  - 15号機の iDRAC FW 2.85 は時刻同期が正しく、preseed の `clock-setup/ntp false` でも apt GPG 検証が通った。14号機 (FW 2.63) で発生した RTC 2001 年問題は再現せず。
- 主要ログ:
  - `tmp/c452be97/sol-install-trial1-s15.log` (SOL 監視ログ、9 stages 観測)
  - `tmp/c452be97/trial-1-s15.log` (trial 開始マーカ)
  - `tmp/c452be97/installer-syslog-all.log` (親セッション共通)
  - `log/oplog.log` (pve-lock 経由の状態変更操作ログ)

## Phase 別所要時間 (`./scripts/os-setup-phase.sh times --config config/server15.yml`)

```
iso-download             0m21s
preseed-generate         0m04s
iso-remaster             1m47s
bmc-mount-boot           2m28s
install-monitor          7m51s
post-install-config     10m32s
pve-install             12m23s
cleanup                  0m44s
---
total                   36m10s
```
