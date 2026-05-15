# Trial 2 server5 レポート

- **結果**: success
- **開始時刻**: 2026-05-14 17:13:00 JST
- **完了時刻**: 2026-05-14 17:54:12 JST
- **所要時間 (wall)**: 約 41 分 12 秒
- **attempt 数**: 1
- **preseed workaround の必要性**: あり (Round 1/Round 2 server4 と同じ 4 件のリグレッションが再発)
- **発動したリカバリ**: なし (1 回で installer 完走)

## 観察した問題

### 既知 (Round 1 + Round 2 server4 で既出)
- **Degradation 1 (`generate-preseed.sh`)**: server5 でも 100% 再現。`netcfg/choose_interface select eno2np1` / `apt-setup/use_mirror=false` / `no_mirror=true` / `cdrom/set-next=false` を 4 件手動修正で対応。3 台 (s4/s5/s6) 連続再発 + Round 2 でも s4/s5 で再発 = 確定リグレッション
- **Problem 1 (`find-boot-entry "ATEN Virtual CDROM"` 失敗)**: BIOS 4.0 で再発。workaround `bmc-power.sh boot-override Cd UEFI` で正常動作
- **Problem 3 (`ssh-wait.sh` raw IP で失敗)**: 再発 2 回 (Phase 6 と Phase 7 final reboot 後)。`ssh-wait.sh 10.10.10.205` は `Permission denied` で全 attempt 失敗するが、`ssh -F ssh/config pve5` (同じ IP) は即座に通る。alias 経由は問題なし
- **Problem 4 (boot-override-reset 後 iPXE)**: workaround `bmc-power.sh boot-override Hdd UEFI` で disk boot 成功
- **Problem 5 (final reboot 後 SSH 一時 connection refused)**: 105 秒で復帰 (90 秒 + α、想定範囲内)

### Round 2 server4 で発見 → server5 では未発生
- 既存 socat orphan: 開始前確認、本 trial では存在せず (clean)

### 新規 / 既知の補足
- **sol-monitor exit 4 (FALSE POSITIVE 検出ロジック)**: SOL log は keepalive のみで stage 検出 0。一方 installer-syslog (UDP 5514) には 3301 行・finish-install 完走・grub-installer 成功・OS reboot トリガまで完全記録あり。サイドチャネル (syslog) で install 成功確認 → 手動で install-monitor を done マーク。SKILL.md の exit 4 ガイダンス (`force-off → bmc-mount-boot 再実行`) より、syslog による補助検証を優先した。Supermicro X11DPU + ttyS1 で SOL に installer 出力が流れない既知傾向と思われる。Phase 6 step 5 の machine-id mtime 検証 (+264 秒) で真の新規インストールを確定

## 最終検証 (success)

- `ssh -F ssh/config pve5 pveversion` → `pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)` ✓
- vmbr0 UP, `10.10.10.205/8` ✓
- vmbr1 UP, `192.168.39.138/24` ✓
- default via `192.168.39.1 dev vmbr1` ✓
- Web UI https://10.10.10.205:8006 → HTTP 200 ✓
- `/etc/machine-id` mtime fresh (+264s) ✓
- LINSTOR/DRBD パッケージ完了、satellite enabled ✓

## ログ参照

- セッション tmp: `tmp/e28df8d0/`
- SOL log: `tmp/e28df8d0/sol-install-s5-r2.log` (84 lines, keepalive のみ)
- Installer syslog: `tmp/e28df8d0/installer-syslog-s5-r2.log` (3301 lines)
- Phase 6 boot screenshot: `tmp/e28df8d0/r2-postboot-1.png`

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 0m21s (cached) |
| preseed-generate | 0m26s (含む workaround edit) |
| iso-remaster | 0m18s (preseed hash match → skip remaster) |
| bmc-mount-boot | 5m37s |
| install-monitor | 9m10s |
| post-install-config | 7m00s |
| pve-install | 16m59s (LINSTOR 含む) |
| cleanup | 0m46s |
| **total** | **40m37s** |
