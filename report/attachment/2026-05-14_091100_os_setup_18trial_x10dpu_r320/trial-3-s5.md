# Trial 3 server5 レポート

- **結果**: success
- **開始時刻**: 2026-05-15 00:11:41 JST
- **完了時刻**: 2026-05-15 00:44:49 JST
- **所要時間 (wall)**: 33 分 08 秒
- **attempt 数**: 1 (リトライなし)
- **machine-id mtime check**: install-monitor.start +274s で fresh install 確定

## preseed workaround の必要性

`generate-preseed.sh` の 4 件リグレッションをすべて Edit で workaround (通算 **8 trial 連続再現**):
- `netcfg/choose_interface select eno2np1` → `select auto`
- `apt-setup/use_mirror boolean false` → `true`
- `apt-setup/no_mirror boolean true` → `false`
- `apt-setup/cdrom/set-next boolean false` → `true`

## 発動した既知 workaround

1. **問題 1 find-boot-entry 失敗** → `boot-override Cd UEFI` + cycle
2. **問題 4 予防** → post-install で `boot-override Hdd UEFI`
3. **問題 5 Final reboot SSH refused** → 90 秒待ちで復帰
4. **POST stale 0x01** → 60s stable で stale 判定し進行
5. **LINBIT keyring 事前配置** + **build-essential 事前 install** → どちらも未発症 (Round 2 s14 対策有効)

## 新規観察

- **install-monitor exit 4 (false-positive)**: SOL stages=0 で PowerState=Off 検出 → exit 4。SOL log は 3.5KB と極端に少なく、ttyS1 への installer 出力が出ていない可能性。一方 installer-syslog (UDP 5514) は 303KB で `finish-install ... 99reboot` 49 件完了確認できたため、手動で install-monitor を done マーク。sol-monitor.py の stage detection 見直しが望ましい

## 最終検証 (success)

- `pveversion`: pve-manager/9.1.11/8eac2c86f015bdda (kernel 7.0.2-2-pve)
- vmbr0 (10.10.10.205/8) + vmbr1 (192.168.39.139/24) UP
- `default via 192.168.39.1 dev vmbr1`
- Web UI HTTP 200
- machine-id mtime > install-monitor.start (+274s)

## ログ参照

- SOL log: `tmp/e28df8d0/sol-install-s5*.log`
- installer syslog: `tmp/e28df8d0/installer-syslog-s5*.log`
- preseed (workaround 適用済): `preseed/preseed-generated-s5.cfg`
- state: `state/os-setup/server5/` (全 8 phase done)
- (subagent が独自に `report/2026-05-15_004504_trial-3-s5_round3/` も作成、本ファイルと等価)
