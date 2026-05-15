# server14 trial 2 (2026-05-15)

- **結果**: ❌ failure
- **wall**: ~25 分 (08:32 mount → 08:57 abort)
- **attempts**: 1 (partman dialog stuck 19+ 分、installer hang)
- **主要事象**:
  - 修正済み preseed (use_mirror=false / no_mirror=true) で ISO 再 remaster → mount → boot
  - sol-monitor 起動、SOL に POST → kernel → installer 順調
  - installer-syslog (parent's socat 経由) で partman が **2 つの disk** を発見:
    - `/dev/sda` — RAID-1 VD (Bay 1+6)、preseed target、新規パーティション化済 (`/dev/sda3` PV ayase-web-service-14-vg)
    - `/dev/sdb` — Bay 0 Non-Raid passthrough、trial 1 install 時の **既存** LVM (`/dev/sdb3 PV ayase-web-service-14-vg`、276.96 GiB) を発見
  - **二重 LVM (同名 VG)** → partman が解決できず interactive dialog で停止
  - byobu status bar 23:37 → 23:56 (19 分) で全進行なし、SOL は alive
  - **kill + force off**

## 修正の動作確認 (リグレッション検出)

- preseed-server14.cfg を CD-only 化 (use_mirror false, no_mirror true) — trial 1 で発見した regression を fix
- LVM Bay 1+6 構成: VD0 作成成功
- **新規 regression 発見**: PERC 控制器が **HBA mode 残留設定** で Bay 0 を Non-Raid passthrough exposure すると、preseed の `partman-auto/disk /dev/sda` の disk 順序が非決定的になり、partman が 2 つの同名 VG を発見してハングする
- build-essential / sol-monitor 新フラグ動作確認: install-monitor 完了に至らず未検証

## 前回 20 trial training との挙動差分

前回 training (5/12) では Bay 0 が Foreign / Ready 状態だったため partman に exposure されず問題なし。今回 PERC HBA→RAID 切替後も Bay 0 は **Non-Raid** のまま残留 (resetconfig は試みず、Bay 1+6 のみ converttoraid + createvd を実行)。

## 詳細ログ抜粋

```
<13>May 14 23:36:30 partman:   PV /dev/sdb3   VG ayase-web-service-14-vg   lvm2 [276.96 GiB / 0    free]
<13>May 14 23:36:30 partman:   Total: 1 [276.96 GiB] / in use: 1 [276.96 GiB] / in no VG: 0 [0   ]
<13>May 14 23:36:30 partman:   Found volume group "ayase-web-service-14-vg" using metadata type lvm2
<13>May 14 23:36:30 partman-lvm:   2 logical volume(s) in volume group "ayase-web-service-14-vg" now active
<13>May 14 23:36:34 partman: Cannot initialize conversion from codepage 850 to ANSI_X3.4-1968: Invalid argument
... (沈黙、19 分の byobu status bar 進行のみ、dialog stuck)
```

## 対応プラン (trial 3)

Bay 0 (Non-Raid passthrough) の partition table を消去してから再インストール:
- `racadm raid converttoraid:Disk.Bay.0...` で Bay 0 を RAID-eligible に変換
- もしくは Linux rescue で `wipefs -a /dev/sdb` で metadata 消去
- もしくは preseed `partman-auto/disk` を `/dev/disk/by-id/scsi-VD0` のような stable path に変更
- 最も簡単: Bay 0 を `converttoraid` で controller 視点から非 passthrough 化
