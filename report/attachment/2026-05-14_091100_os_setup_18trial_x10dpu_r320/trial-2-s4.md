# Trial 2 server4 レポート

- **結果**: success
- **開始時刻**: 2026-05-14 16:41:11 JST
- **完了時刻**: 2026-05-14 17:10:44 JST
- **所要時間 (wall)**: 約 29 分 33 秒
- **attempt 数**: 1

## preseed workaround の必要性: **あり** (Round 1 デグレ確実に再現)

`generate-preseed.sh config/server4.yml preseed/preseed-generated-s4.cfg` が出力したファイルには Round 1 と同じ 4 件の壊れた設定:

| 行 | 出力された値 (壊れ) | 修正後 |
|----|-------------------|--------|
| 34 | `netcfg/choose_interface select eno2np1` | `select auto` |
| 56 | `apt-setup/use_mirror boolean false` | `boolean true` |
| 57 | `apt-setup/no_mirror boolean true` | `boolean false` |
| 59 | `apt-setup/cdrom/set-next boolean false` | `boolean true` |

→ **3/3 サーバで generate-preseed.sh デグレが 100% 再現**。`scripts/generate-preseed.sh` 修正の別 issue 化が必須

## 発動したリカバリ

なし (POST 92 等のリカバリ未発動)

## 観察した問題

### 既知 (Round 1 で既出)

- **`generate-preseed.sh` デグレ**: 上述 4 項目をハードコードで壊れた値 → 手動修正で workaround
- **`find-boot-entry "ATEN Virtual CDROM"` が空配列で失敗** (Supermicro BIOS 4.0): 3 回リトライ後 timeout → `boot-override Cd UEFI` で代替成功
- **Phase 6 後 boot-override Hdd UEFI 予防策**: 実施 (実害なし、保険)

### 新規 (Round 1 で見えなかった事象)

- **既存 socat (UDP 5514) の残骸が居座る**: PPID=1 の orphan socat が syslog-receiver port を占拠していたため kill してから fresh 起動。並列セッション/前回中断由来の orphan 検出が今後必要。Phase 5 でぶつかると hang する可能性 → SKILL.md の "並列実行時" 注意の単独実行版を追記推奨
- **Phase 4 後の POST code stale `0x00`**: 既知 stale 値、SKILL.md の "stale 45s で proceed" ルールが機能 (問題なし)
- **preseed late_command の SSH 鍵配置が一発動作**: SOL 経由 SSH 鍵配置すら不要 (Round 1 同様)

## POST 92 ハングの有無

なし (Round 1 でも未発火、Round 2 でも未発火)

## 最終検証 (success)

```
pveversion: pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)
ip route: default via 192.168.39.1 dev vmbr1
vmbr0: UP 10.10.10.204/8
vmbr1: UP 192.168.39.188/24
Web UI: HTTP=200
```

OS: Debian GNU/Linux 13 (trixie) + PVE 9.1.11 / kernel 7.0.2-2-pve

## ログ参照

- SOL install log: `tmp/e28df8d0/sol-install-s4.log`
- Installer syslog: `tmp/e28df8d0/installer-syslog-s4.log` (3292 行)
- oplog: `log/oplog.log`
- phase state: `state/os-setup/server4/`

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 0m19s (キャッシュヒット) |
| preseed-generate | 0m35s (Edit 手動修正含む) |
| iso-remaster | 1m43s (preseed sha256 差分で再リマスター) |
| bmc-mount-boot | 4m00s |
| install-monitor | 7m34s |
| post-install-config | 2m58s (preseed late_command で鍵配置済) |
| pve-install | 10m38s (LINSTOR 含む) |
| cleanup | 0m54s |
| **total** | **28m41s** |

## 補足

- `state/os-setup/server4/` は全 8 phase done
- generate-preseed.sh デグレが 100% 再現 → 恒久バグ、別 issue 化推奨
- 古い orphan socat の検出は SKILL.md 単独実行手順に追加推奨
