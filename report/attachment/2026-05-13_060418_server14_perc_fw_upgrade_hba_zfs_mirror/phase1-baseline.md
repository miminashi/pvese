# Phase 1: ベースライン採取結果 (2026-05-13 02:36-02:42 JST)

## 14号機 PERC PD 状態 (全 8 Bay)

| Bay | Size | State | Manufacturer | ProductId | Revision | NegotiatedSpeed | 備考 |
|---|---|---|---|---|---|---|---|
| 0 | 278.88 GB | Ready | SEAGATE | ST300MP0026 | KT39 | **12.0 Gb/s** | Bay 0 単独で 12Gb/s ネゴ確認 |
| 1 | 278.88 GB | **Online** | SEAGATE | ST9300653SS | N007 | 6.0 Gb/s | VD0 member |
| 2 | 277.27 GB | Ready | SEAGATE | **DKS5E K300SS** | **7F09** | 12.0 Gb/s | Hitachi OEM Seagate (10-13号機 Rev 7FA9 と類似) |
| 3 | 277.27 GB | Ready | SEAGATE | DKS5E K300SS | 7F09 | 12.0 Gb/s | 同上 |
| 4 | 277.27 GB | Ready | SEAGATE | DKS5E K300SS | 7F09 | 12.0 Gb/s | 同上 |
| 5 | 277.27 GB | Ready | SEAGATE | DKS5E K300SS | 7F09 | 12.0 Gb/s | 同上 |
| 6 | 278.88 GB | **Online** | SEAGATE | ST9300653SS | N007 | 6.0 Gb/s | VD0 member |
| 7 | 277.27 GB | Ready | SEAGATE | DKS5E K300SS | 7F09 | 12.0 Gb/s | 同上 |

**重要発見**: 全 5 本の DKS5E K300SS が **同一 Rev 7F09**、uniform 構成。10-13号機 (DKS5x-J1R2SS Rev 7FA9) と近い世代だが Rev は異なる。Phase 4 で write-block の uniform behavior を要確認。

## 14号機 VD0

| 項目 | 値 |
|---|---|
| Name | OS_RAID1 |
| Layout | Raid-1 |
| Members | Bay 1 + Bay 6 (ST9300653SS×2, 同モデル 6Gb/s) |
| Size | 278.88 GB |
| State | Online |
| OperationalState | Not applicable (BGI 不要、安定) |
| DiskCachePolicy | Disabled |

## 14号機 ホスト側

| 項目 | 値 |
|---|---|
| /dev/sda | 278.9 GB PERC H730P Mini (VD0) |
| LVM | vg0 / root 262.9 GB / swap 14.05 GB |
| FS | / on /dev/mapper/vg0-root (ext4), /boot ext4, /boot/efi vfat |
| 使用率 | 3% (5.0G/258G) |
| PVE | pve-manager 9.1.9, kernel 7.0.2-2-pve |
| Driver | megaraid_sas |
| Default Route | via 192.168.39.1 dev vmbr1 ✓ |
| smartctl | 7.4-pve1 既存 |

## 14号機 Controller

| 項目 | 値 |
|---|---|
| FirmwareVersion | **25.5.5.0005** |
| RollupStatus | Ok |
| SecurityStatus | Encryption Capable |

## 15号機 PERC PD (比較対象)

| Bay | Size | State | Manufacturer | ProductId | Revision | NegotiatedSpeed |
|---|---|---|---|---|---|---|
| 0 | 278.88 GB | Online | **WD** | WD3001BKHG | D1S2 | **6.0 Gb/s** |
| 1 | 278.88 GB | Online | SEAGATE | ST300MP0026 | KT39 | 12.0 Gb/s |
| 2 | 558.38 GB | Ready | SEAGATE | ST600MP0036 | KT39 | 12.0 Gb/s |
| 3 | 558.38 GB | Ready | HP | EG0600FBVFP | HPDC | 6.0 Gb/s |
| 4 | 558.38 GB | Ready | HP | EG0600JETKA | HPD7 | 12.0 Gb/s |
| 5 | 558.38 GB | Ready | HGST | HUC101860CSS204 | C7L0 | 12.0 Gb/s |
| 6 | 558.38 GB | Ready | TOSHIBA | AL14SXB60ENY | EE07 | 12.0 Gb/s |
| 7 | 558.38 GB | Ready | HP | EG0600JETKA | HPD4 | 12.0 Gb/s |

**重要発見 (link speed mismatch 仮説の再評価)**:
- 15号機 VD0 (Bay 0+1) = WD3001BKHG (**6.0 Gb/s**) + ST300MP0026 (12.0 Gb/s) の **混在で BGI 成功**
- → link speed mismatch だけが BGI 26% 停滞の真因ではない
- → 14号機 Bay 0 (ST300MP0026 12Gb/s) + Bay 1 (ST9300653SS 6Gb/s) も組み合わせとしては成立する可能性
- 真因はおそらく PERC FW 25.5.5.0005 の特定 disk pair (具体的に ST300MP0026 + ST9300653SS) の BGI 処理パスで起こる FW bug の可能性が高い

## 15号機 Controller

- FirmwareVersion = **25.5.9.0001** (14号機 25.5.5.0005 と差分)
- RollupStatus = Ok
- SecurityStatus = Encryption Capable

## Phase 1.2 ストレステスト結果

- 6 GiB write + 6 GiB read を 3 loop 実施 (計 ~55秒)
- Write 平均: 124 MB/s (RAID-1 上限)
- Read: 5-7 GB/s (page cache)
- dmesg I/O エラー: なし
- VD0 状態維持: Online, OperationalState=Not applicable

## 結論

Phase 1 baseline 取得完了。重要発見:
1. DKS5E K300SS は SEAGATE 製、Rev 7F09 で 5 本全て uniform
2. 14号機 Bay 0 ST300MP0026 は単独で 12.0 Gb/s リンク確認 (健全な信号)
3. 15号機 VD0 が link speed mismatch を含むため、14号機 BGI 停滞の真因は PERC FW 25.5.5 の bug の可能性が高い → Phase 6 FW 25.5.9 更新の合理性増す
4. 現 OS_RAID1 安定動作、Phase 2 以降の作業 baseline として OK
