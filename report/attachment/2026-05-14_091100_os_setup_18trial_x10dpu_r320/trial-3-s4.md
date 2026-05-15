# Trial 3 server4 レポート

- **結果**: success
- **開始時刻**: 2026-05-14 23:11:21 JST
- **完了時刻**: 2026-05-15 00:07:55 JST
- **所要時間 (wall)**: 56m25s
- **attempt 数**: 1 (再 install 不要)

## preseed workaround の必要性

**Round 1+2 と同じ `generate-preseed.sh` リグレッションが 100% 再現**:
- L34 `choose_interface eno2np1 → auto`
- L56-57 `use_mirror false/no_mirror true → true/false`
- L59 `cdrom/set-next false → true`

→ 7 trial 連続 100% 再現確認 (server4 R2, R3 / server5 R1, R2 / server6 R1, R2 / server4 R3)

## 発動したリカバリ (Round 1+2 既知)

1. **find-boot-entry 失敗** ✓ 再現 → `boot-override Cd UEFI` で代替
2. **boot-override-reset 後 iPXE** 予防適用 → `boot-override Hdd UEFI` で先回り
3. **ssh-wait alias 必須** ✓ 再現 → IP 指定だと ssh/config の Host pve4 が効かず認証失敗、`ssh-wait.sh pve4` で解決
4. **Final reboot 後 SSH 一時 refused** ✓ 再現 → 90 秒後接続成功
5. **post-reboot 中の default route 消失** ✓ 再現 → `pre-pve-setup.sh` 再実行で復旧
6. **LINBIT GPG キー silent failure** ✓ 再現 → Ubuntu キーサーバから dearmor 済 keyring を `scp /usr/share/keyrings/`
7. **DRBD DKMS build-essential 必須** → 事前に apt install

## 観察した問題

### 既知 (Round 1+2 で既出)
- 上記リカバリ項目すべて

### 新規 (Round 3 で発見)
- **Debian 13 minimal は `isc-dhcp-client` 不在で eno1np0 が boot 直後 DOWN**: Phase 7 初回 `pre-pve-setup.sh` が DNS 解決失敗 → `dhcpcd -1 -t 30 eno1np0` 手動投入で復旧

## 最終検証 (全 success 基準クリア)

- `pveversion` = `pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)`
- vmbr0 (10.10.10.204/8) UP / vmbr1 (192.168.39.189/24) UP
- `default via 192.168.39.1 dev vmbr1`
- Web UI HTTP 200
- machine-id mtime (23:21:55) > install-monitor.start (23:18:00) — **fresh install 確定**

## ログ参照

- 試行ログ: `tmp/e28df8d0/trial-3-s4.log`
- SOL: `tmp/e28df8d0/sol-install-s4.log` (Round 3 分は subagent 作成の別添付 `report/attachment/2026-05-15_000842_trial-3-s4_round3/` にも存在)
- Installer syslog: `tmp/e28df8d0/installer-syslog-s4.log`
- (補足: subagent が独自に `report/2026-05-15_000842_trial-3-s4_round3/` も作成、内容は本ファイルと等価)

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 12s |
| preseed-generate | 36s (workaround edit 含む) |
| iso-remaster | 17s (skip、preseed hash 一致) |
| bmc-mount-boot | 5m30s |
| install-monitor | 8m06s |
| post-install-config | 24m57s |
| pve-install | 16m16s |
| cleanup | 31s |
| **total** | **56m25s** |
