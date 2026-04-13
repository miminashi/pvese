# Phase 3: BIOS/ファームウェア設定 トレーニングレポート

- **実施日時**: 2026年4月4日 03:06 〜 03:11 JST
- **対象**: Phase 3 (Iteration 22-30)

## 添付ファイル

- [実装プラン](attachment/2026-04-04_023058_phase1_monitoring_baseline/plan.md)

## 前提・目的

- 背景: リージョン A+B 全体操作トレーニングの Phase 3
- 目的: BIOS/iDRAC/PERC RAID 設定の現状を記録し、サーバ間の不整合を特定する
- 前提条件: Phase 2 完了、全6ノード稼働中

## 環境情報

| 項目 | Region A (4-6号機) | Region B (7-9号機) |
|------|-------------------|-------------------|
| ハードウェア | Supermicro X11DPU | Dell PowerEdge R320 |
| BIOS | AMI Aptio UEFI | Dell BIOS 2.3.3 |
| RAID | なし (NVMe 直接) | PERC H710 Mini |
| iDRAC FW | - | 2.65.65.65 |

## イテレーション結果

### Iteration 22-24: Supermicro BIOS 設定確認

KVM スクリーンショットで OS 稼働を確認後、SSH 経由で EFI ブートエントリとカーネルコマンドラインを確認。

**EFI Boot Order 比較**:

| 項目 | 4号機 | 5号機 | 6号機 |
|------|-------|-------|-------|
| BootCurrent | Boot0004 (debian) | Boot0004 (debian) | Boot0000 (debian) |
| ATEN Virtual CDROM | あり (Boot0006) | あり (Boot0006) | **なし** |
| PXE エントリ数 | 1 (統合) | 1 (統合) | **16 (個別NIC)** |
| EFI Shell | あり | あり | あり |

**カーネルコマンドライン** (全台共通):
```
console=tty0 console=ttyS1,115200n8 quiet
```

**カーネルバージョン差異**:
- 4/5号機: `6.17.13-1-pve`
- 6号機: `6.17.13-2-pve` (より新しいインストール)

**6号機固有の問題**:
- ATEN Virtual CDROM が EFI ブートリストに存在しない → VirtualMedia ブートには BIOS Boot Tab から直接設定が必要 (既知、os-setup スキルに記載済み)
- PXE エントリ 16個 → debian エントリ喪失時にネットワークブートのフォールバックループリスク

### Iteration 25-27: iDRAC 設定確認

| 項目 | 7号機 | 8号機 | 9号機 |
|------|-------|-------|-------|
| FW | 2.65.65.65 | 2.65.65.65 | 2.65.65.65 |
| BIOS | 2.3.3 | 2.3.3 | 2.3.3 |
| Service Tag | 9QYZF42 | 9QYZF42 | 9QYZF42 |
| IPMI LAN | Enabled | Enabled | Enabled |
| BootSeq 1st | **NIC** | **Optical** | **Optical** |

**BootSeq 不整合**: 7号機のみ NIC が先頭。OS インストール後は HardDisk を先頭にすべき。

### Iteration 28-30: PERC RAID ステータス

**VD 状態**:

| VD | 7号機 | 8号機 | 9号機 |
|----|-------|-------|-------|
| system (RAID-1) | Online, 278GB | Online, 837GB | Online, 837GB (**BGI 94%**) |
| data0 (RAID-0) | Online, 837GB | Online, 837GB | Online, 837GB |
| data1-3 (RAID-0) | Online | Online | Online |
| data4-5 (RAID-0) | Online | - | - |
| 合計 VD 数 | **7** | **5** | **5** |

**PD 状態**: 全台 8 PD、Failed/Blocked なし。8/9号機 Bay 0-1 は Ready (未使用 273GB)。

## 再現性評価

| 操作 | Iter 22 | Iter 23 | Iter 24 | 結果 |
|------|---------|---------|---------|------|
| KVM + efibootmgr | 成功 | 成功 | 成功 | 再現性確認済み |
| iDRAC racadm | 成功 x3 | 成功 x3 | 成功 x3 | 再現性確認済み |
| PERC RAID | 成功 x3 | 成功 x3 | 成功 x3 | 再現性確認済み |

## 発見した問題と改善

| # | 問題 | 影響 | 対策 | 反映先 |
|---|------|------|------|--------|
| 1 | 6号機 ATEN Virtual CDROM なし | VirtualMedia ブートに BIOS 操作必要 | 既知、os-setup スキルに記載済み | - |
| 2 | 7号機 BootSeq NIC 優先 | OS 再インストール時に意図せぬ PXE ブート | OS インストール後に修正推奨 | - |
| 3 | 9号機 VD0 BGI 94% | 自動完了。パフォーマンス影響小 | 監視のみ | - |
| 4 | カーネル版差異 (6号機 -2-pve) | 機能影響なし | 統一するなら apt upgrade | - |

## スキル/ドキュメント変更

なし (既存スキルの記載で対応済み)

## 参考

- [Phase 2 レポート](2026-04-04_030613_phase2_power_management.md)
