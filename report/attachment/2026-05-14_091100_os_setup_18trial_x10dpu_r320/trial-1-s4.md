# Trial 1 server4 レポート

- **結果**: success
- **開始時刻**: 2026-05-14 09:13:37 JST
- **完了時刻**: 2026-05-14 10:10:40 JST
- **所要時間 (wall)**: 57分03秒
- **attempt 数**: 0 (Phase 4-8 の major リトライなし)

## 発動したリカバリ
- racreset soft: 0 回 (server4 は Supermicro なので適用外)
- POST 92 リカバリ (ForceOff→20s→PowerOn→150s): 0 回
- install-monitor reconnect: 0 回 (exit 0 一発)
- ssh-wait 延長: あり (Phase 6 の初回 ssh-wait 180s タイムアウト - 別途 pexpect で対処)
- pre-pve-setup 再実行: なし (Supermicro は不要。デフォルトルートは保持されていた)

## 観察した問題

### 既知問題
- POST code API が stale 値 (0x01) を返し続ける - SOL と KVM スクリーンショットで真状態を判断

### 新規問題 (要注意)
1. **`find-boot-entry "ATEN Virtual CDROM"` が失敗** - このファームウェア (BIOS 4.0) の Redfish BootOptions API が空。`bmc-power.sh boot-next` (UefiBootNext 方式) が使えない。代わりに `boot-override Cd UEFI` (単純 Redfish boot override) を使用して正常にブート可能
2. **SOL 経由の `echo ... | base64 -d > /root/.ssh/authorized_keys` がサイレント失敗** - SKILL.md の SOL pipe 問題は Supermicro (ttyS1/COM2) でも再現。pexpect によるパスワード SSH で鍵配置を行い回避
3. **`ssh-wait.sh` に raw IP (`10.10.10.204`) を渡すと key auth 失敗** - `ssh/config` の `Host pve4` エントリは IP にマッチしない (`IdentitiesOnly yes` + `IdentityFile` が適用されない)。`pve4` エイリアスを使う必要がある。`ssh-wait.sh` には IP ではなく alias を渡すこと

## 最終検証 (success)
- pveversion 出力: `pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)`
- ip route show default: `default via 192.168.39.1 dev vmbr1`
- vmbr0: `10.10.10.204/8 UP`
- vmbr1: `192.168.39.187/24 UP` (DHCP)
- Web UI: `https://10.10.10.204:8006` 接続可 (HTML応答確認)
- SSH: `pve4` alias で key auth OK

## 副次的観察
- Debian 13.4 (trixie) がインストールされた (カーネル: 6.12.86+deb13-amd64)
- PVE kernel 7.0.2-2-pve インストール後の reboot で POST 92 ハングなし (Phase 7 reboot は 70s で SSH 接続)
- Phase 8 最終 reboot も POST 92 ハングなし (即時 SSH 接続)
- LINSTOR satellite/proxy インストール済み (`linstor-satellite.service` 有効化)
- `pve-setup-remote.sh --phase post-reboot` 実行中の default route 消失なし (Supermicro では問題なし)

## ログ参照
- `tmp/e28df8d0/trial-1-s4.log`
- `tmp/e28df8d0/sol-install-s4.log` (321KB)
- `tmp/e28df8d0/installer-syslog-s4.log` (321KB)

## Phase 別所要時間
| Phase | 名称 | 所要時間 |
|-------|------|---------|
| 1 | iso-download | 0m23s (既存ISO sha256検証のみ) |
| 2 | preseed-generate | 0m30s |
| 3 | iso-remaster | 1m54s (preseed変更あり、リマスター実行) |
| 4 | bmc-mount-boot | 15m19s (BootOptions列挙パワーサイクル + boot-override Cd UEFI 設定含む) |
| 5 | install-monitor | 8m05s (Debian インストール完了) |
| 6 | post-install-config | 17m04s (SOL設定 + pexpect SSH key配置 + machine-id検証) |
| 7 | pve-install | 8m38s (pre-reboot + reboot + post-reboot --linstor + final reboot) |
| 8 | cleanup | 4m30s (bridge設定 + 最終検証含む) |
| - | **合計** | **56m23s (phase.sh計測) / 57m03s (wall clock)** |
