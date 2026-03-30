# LVM によるノード内ディスク冗長化の選択肢調査

- **実施日時**: 2026年3月30日 01:28 (JST)

## 前提・目的

### 背景

LINSTOR/DRBD はノード間レプリケーションによる縮退運転をサポートするが、1ノード内のディスク冗長性は組み込みでサポートしていない。ノード内の単一ディスク障害に対する保護には、LINSTOR の下層で別途冗長化を行う必要がある。

本レポートでは、LVM を中心としたノード内ディスク冗長化のとりうる全選択肢を整理し、各方式の特性・制約・LINSTOR との統合方法を比較する。

### 参照した過去のレポート

- [LINSTOR LVM-RAID1 ベンチマーク](2026-03-29_090042_linstor_lvm_raid1_benchmark.md) — LVM RAID1 性能計測
- [LINSTOR LVM-RAID1 セットアップ](2026-03-29_062142_linstor_lvm_raid1_setup_progress.md) — LVM RAID1 構築手順
- [LINSTOR Software RAID1 実験](2026-03-22_220051_linstor_software_raid1_experiment.md) — mdadm RAID1 vs LVM RAID1 vs HW RAID5 比較
- [LVM RAID10 ディスク障害実験](2026-02-27_203200_linstor_lvm_raid10_disk_failure_experiment.md) — LVM RAID10 カーネルバグ発見
- [LVM RAID 運用懸念事項](2026-02-28_010338_linstor_lvm_raid_operational_concerns.md) — DRBD から LVM RAID 劣化が不可視な問題
- [PERC H710 RAID5 write hole 調査](2026-03-30_003000_perc_h710_raid5_write_hole.md) — HW RAID5 の write hole 問題
- [LINSTOR RAID5 resilience 実験](2026-03-22_120534_linstor_raid5_resilience_experiment.md) — PERC RAID5 による冗長化テスト

### 前提条件

- 各ノード 4 台の HDD (PERC H710 で個別 RAID0 VD = JBOD エミュレーション)
- LINSTOR が LVM ストレージプールを使用 (VG: `linstor_vg`)
- カーネル: 6.17.13-2-pve
- ディスク容量: 各約 838 GiB (7-9号機)

## 環境情報

| リージョン | ノード | サーバ | ディスク | RAID コントローラ |
|-----------|--------|--------|---------|-----------------|
| Region A | pve4, pve5, pve6 | Supermicro X11DPU | 4x HDD/ノード | PERC H710 |
| Region B | pve7, pve8, pve9 | Dell PowerEdge R320 | 4x HDD/ノード | PERC H710 Mini |

## 調査結果

選択肢は大きく 4 つのカテゴリに分類される:

1. **LVM 組み込み RAID** (dm-raid) — LINSTOR と最も統合しやすい
2. **mdadm + LVM** — 下層で mdadm、上層で通常の LVM
3. **ZFS + LINSTOR ZFS プロバイダ** — LVM を使わない別アプローチ
4. **ハードウェア RAID (PERC H710)** — ソフトウェア不要だが制約大

---

### カテゴリ 1: LVM 組み込み RAID (dm-raid)

LINSTOR は `StorDriver/LvcreateOptions` パラメータを `lvcreate` にそのまま渡す。また `StorDriver/LvcreateType` として `raid0`, `raid1`, `raid4`, `raid5`, `raid6`, `raid10` を指定可能。LVM RAID の各 LV が個別に冗長化される。

#### 1-A. LVM RAID1 (`--type raid1 -m 1`)

| 項目 | 値 |
|------|-----|
| 最小ディスク数 | 2 |
| 4ディスク時の容量 | 約 1.63 TiB (2ディスク分。残り2台は別ミラーペア or 未使用) |
| 障害耐性 | ミラーペアあたり 1 ディスク |
| Hot rebuild | **可能** (本プロジェクトで検証済み) |
| Write hole | なし (パリティ不使用) |
| LINSTOR 統合 | `LvcreateOptions: '--type raid1 -m 1'` で自動作成 |
| 本プロジェクトでの状態 | **検証済み・推奨** |

**構成パターン** (4ディスクの場合):
- **パターン A**: VG に 4 PV を入れ、`-m 1` で各 LV が 2-way ミラー。LVM が自動的に異なる PV にミラーレッグを配置
- **パターン B**: 2+2 で 2 つの VG に分け、それぞれ RAID1。LINSTOR からは 2 プール

**既知の問題**:
- DRBD から LVM RAID の劣化状態が見えない。`lvs -o lv_attr` の `p` (partial) フラグを別途監視する必要がある
- 4ディスク全体で 1 つの VG にした場合、LVM はミラーレッグを同じ PV に置かないよう自動配置するが、ディスクが 2 台以下に減ると LV 作成不可になる

#### 1-B. LVM RAID10 (`--type raid10`)

| 項目 | 値 |
|------|-----|
| 最小ディスク数 | 4 |
| 4ディスク時の容量 | 約 1.63 TiB |
| 障害耐性 | ミラーペアあたり 1 ディスク |
| Hot rebuild | **不可** (カーネルバグ) |
| Write hole | なし |
| LINSTOR 統合 | `LvcreateOptions: '--type raid10 -i2 -m1'` |
| 本プロジェクトでの状態 | **使用不可** (カーネルバグ) |

**カーネルバグ**: `raid10.c:3454` で hot rebuild 時にカーネルクラッシュ (6.17.9-1-pve で確認)。LKML で 2025年末〜2026年初にパッチが投稿されているが、6.17.13-2-pve での修正は**未確認**。Cold rebuild (リブート後) は動作する。

**容量は RAID1 と同等** (50%) のため、バグが修正されても RAID1 に対する明確な優位性がない。

#### 1-C. LVM RAID5 (`--type raid5`)

| 項目 | 値 |
|------|-----|
| 最小ディスク数 | 3 |
| 4ディスク時の容量 | **約 2.45 TiB (75%)** — 最高の容量効率 |
| 障害耐性 | 1 ディスク |
| Hot rebuild | 可能 (dm-raid レベル) |
| Write hole | **あり** (dm-raid にはデフォルトでジャーナルなし) |
| LINSTOR 統合 | `LvcreateOptions: '--type raid5 -i3 -I64'` |
| 本プロジェクトでの状態 | **未テスト** (dm-raid レベル) |

**Write hole 問題**: 予期しない電源断時にパリティとデータの不整合が発生する可能性がある。dm-raid (LVM RAID5) にはデフォルトでジャーナルデバイスやビットマップがない。ただし DRBD のノード間レプリケーションにより、write hole でデータが破損しても他ノードのレプリカから回復可能であるため、リスクは軽減される。

**PERC H710 の HW RAID5 との違い**: HW RAID5 は BBU (Battery Backup Unit) で write hole を軽減するが、BBU 劣化時の保護は不十分 (report `2026-03-30_003000`)。dm-raid RAID5 は BBU に依存しないが、ジャーナルなしでは write hole リスクが残る。

#### 1-D. LVM RAID6 (`--type raid6`)

| 項目 | 値 |
|------|-----|
| 最小ディスク数 | **5** (3 データ + 2 パリティ) |
| 4ディスク時 | **使用不可** |
| 本プロジェクトでの状態 | 対象外 |

LVM RAID6 は最小 5 PV を要求するため、4 ディスク/ノード環境では使用できない。

---

### カテゴリ 2: mdadm + LVM

mdadm でアレイを構成し、その上に通常の VG/LVM を構築する。LINSTOR からは単一ブロックデバイス上の通常の VG に見えるため、`LvcreateOptions` に RAID 関連の指定は不要。

#### 2-A. mdadm RAID1

| 項目 | 値 |
|------|-----|
| 4ディスク時の容量 | 838 GiB (2台ミラー + 2台スペア) または 1.63 TiB (2組のミラー) |
| 障害耐性 | 1 ディスク (スペアあり時は自動 rebuild) |
| Hot rebuild | **可能** (本プロジェクトで検証済み、約 85 分/838 GiB) |
| Write hole | なし |
| LINSTOR 統合 | 透過的 (VG が `/dev/md0` 上に存在) |
| 本プロジェクトでの状態 | **検証済み** |

**構成パターン**:
- **2台ミラー + 2台ホットスペア**: 障害時に自動で spare が activate される。ただし容量は 1 台分
- **2組のミラー (md0 + md1)**: 2 つの PV で 1 つの VG。容量 1.63 TiB

#### 2-B. mdadm RAID5 (+ PPL)

| 項目 | 値 |
|------|-----|
| 4ディスク時の容量 | **約 2.45 TiB (75%)** |
| 障害耐性 | 1 ディスク |
| Hot rebuild | 可能 |
| Write hole | PPL (Partial Parity Log) で**ほぼ解消** (約 3-5% の書き込み性能低下) |
| LINSTOR 統合 | 透過的 |
| 本プロジェクトでの状態 | **未テスト** |

```sh
# PPL 付きで作成
mdadm --create /dev/md0 --level=5 --raid-devices=4 \
  --consistency-policy=ppl /dev/sd{b,c,d,e}
```

**LVM RAID5 との違い**: mdadm は PPL (Partial Parity Log) をサポートし、write hole をほぼ解消できる。dm-raid (LVM RAID5) には同等の機能がない。

#### 2-C. mdadm RAID10

| 項目 | 値 |
|------|-----|
| 4ディスク時の容量 | 約 1.63 TiB |
| 障害耐性 | ミラーペアあたり 1 ディスク |
| Hot rebuild | 可能 |
| Write hole | なし |
| LINSTOR 統合 | 透過的 |
| 本プロジェクトでの状態 | **未テスト** (mdadm レベル) |

LVM RAID10 のカーネルバグ (raid10.c) とは別の実装 (md/raid10.c vs dm-raid/raid10)。mdadm 版は安定性の実績が長い。

#### 2-D. mdadm RAID6

| 項目 | 値 |
|------|-----|
| 4ディスク時の容量 | 838 GiB (50%) — mdadm は 4 台で RAID6 を構成可能 |
| 障害耐性 | **2 ディスク** (最高) |
| Hot rebuild | 可能 |
| Write hole | あり (PPL は RAID5 のみ。bitmap で部分的に軽減) |
| LINSTOR 統合 | 透過的 |
| 本プロジェクトでの状態 | **未テスト** |

LVM RAID6 と異なり、mdadm は **4 台で RAID6 を構成可能** (2 データ + 2 パリティ)。容量効率は RAID1 と同じ 50% だが、任意の 2 台障害に耐える点が優位。

**mdadm 共通の運用負荷**:
- `mdadm.conf` の管理と `update-initramfs` の実行が必要
- `/proc/mdstat` の監視
- OS 再インストール時にアレイの再構成が必要

---

### カテゴリ 3: ZFS + LINSTOR ZFS プロバイダ

LINSTOR は LVM だけでなく **ZFS/ZFS_THIN ストレージプロバイダ**をネイティブサポートしている。LVM を使わず、ZFS プール上に直接 LINSTOR ストレージプールを構成できる。

#### 3-A. ZFS mirror (2x2 vdev)

| 項目 | 値 |
|------|-----|
| 4ディスク時の容量 | 約 1.63 TiB |
| 障害耐性 | vdev あたり 1 ディスク |
| Hot rebuild (resilver) | **可能** |
| Write hole | **なし** (ZFS は COW 設計) |
| チェックサム | **あり** (サイレント破損検出) |
| LINSTOR 統合 | ネイティブ (`linstor sp create zfs <node> <pool> <zpool>`) |
| 本プロジェクトでの状態 | **未テスト** |

```sh
# 2x2 ミラー vdev で ZFS プール作成
zpool create linstor_zpool mirror sdb sdc mirror sdd sde

# LINSTOR ストレージプール (thick)
linstor storage-pool create zfs <node> zfs-pool linstor_zpool
# LINSTOR ストレージプール (thin)
linstor storage-pool create zfsthin <node> zfs-thin-pool linstor_zpool
```

#### 3-B. ZFS raidz1 (RAID5 相当)

| 項目 | 値 |
|------|-----|
| 4ディスク時の容量 | **約 2.45 TiB (75%)** |
| 障害耐性 | 1 ディスク |
| Hot rebuild (resilver) | 可能 |
| Write hole | **なし** (COW) |
| チェックサム | あり |
| LINSTOR 統合 | ネイティブ |
| 本プロジェクトでの状態 | **未テスト** |

```sh
zpool create linstor_zpool raidz1 sdb sdc sdd sde
```

#### 3-C. ZFS raidz2 (RAID6 相当)

| 項目 | 値 |
|------|-----|
| 4ディスク時の容量 | 約 1.63 TiB (50%) |
| 障害耐性 | **2 ディスク** |
| Hot rebuild (resilver) | 可能 |
| Write hole | なし (COW) |
| チェックサム | あり |
| LINSTOR 統合 | ネイティブ |
| 本プロジェクトでの状態 | **未テスト** |

```sh
zpool create linstor_zpool raidz2 sdb sdc sdd sde
```

**ZFS 共通の特長**:
- **Write hole が存在しない**: COW (Copy-on-Write) 設計により、書き込み途中の電源断でもデータ不整合が発生しない。mdadm RAID5/6 や HW RAID5 の最大の弱点を根本的に解決
- **チェックサム**: 全データブロックにチェックサムを付与し、サイレントデータ破損 (bit rot) を検出・自動修復
- **LINSTOR ネイティブ対応**: `zfs` / `zfsthin` プロバイダで追加の管理レイヤなしに統合
- **PVE との親和性**: PVE は ZFS をネイティブサポートしており、`zfs-dkms` パッケージで利用可能

**ZFS の制約**:
- メモリ使用量: ARC キャッシュがデフォルトで RAM の 50% を使用 (チューニング可能。R320 の 48 GiB RAM なら実用範囲)
- ライセンス: CDDL (GPL 非互換) — Linux カーネルに直接マージされていないが、機能的に問題なし
- raidz の拡張制約: 作成後にディスクを追加できない (vdev 単位での交換のみ)
- LVM との二重レイヤは不要 (LINSTOR が ZFS を直接使用)

---

### カテゴリ 4: ハードウェア RAID (PERC H710)

ソフトウェア RAID を使わず、PERC H710 コントローラで RAID を構成する方式。

| 構成 | 容量 | 障害耐性 | 本プロジェクトでの状態 |
|------|------|---------|---------------------|
| HW RAID1 | 838 GiB (50%) | 1/ペア | 未テスト (RAID レベル) |
| HW RAID5 | 1.63 TiB (75%) | 1 ディスク | **テスト済み・非推奨** |
| HW RAID6 | 838 GiB (50%) | 2 ディスク | 未テスト |
| HW RAID10 | 1.63 TiB (50%) | 1/ペア | 未テスト |

**致命的な制約**:
- **全ディスク操作にリブートが必要**: VD の作成・削除・リビルドは racadm + jobqueue + 電源サイクルで実行。ホットスワップ不可
- **Write hole**: BBU (Battery Backup Unit) で軽減するが、BBU 劣化時は保護不十分 (report `2026-03-30_003000`)
- **racadm ジョブ失敗**: 頻繁に発生 (STOR023 stale config 等)
- **OS 破壊リスク**: VD クリア時に OS ディスクを巻き込む可能性あり

**結論**: 本プロジェクトの過去レポートで**PERC RAID5 は非推奨**と結論済み。個別 RAID0 (JBOD エミュレーション) + ソフトウェア冗長化が推奨方針。

---

## 全選択肢の比較

### 容量効率

| 方式 | 4ディスク時の容量 | 効率 |
|------|-----------------|------|
| LVM RAID5 / mdadm RAID5 / ZFS raidz1 | 2.45 TiB | **75%** |
| LVM RAID1 (4PV, 1VG) / LVM RAID10 / mdadm RAID10 / ZFS mirror (2x2) | 1.63 TiB | 50% |
| mdadm RAID6 / ZFS raidz2 | 1.63 TiB | 50% |
| mdadm RAID1 (2台+2スペア) / LVM RAID1 (2PV) | 838 GiB | 25% |

### 障害耐性

| 方式 | 耐障害ディスク数 | 備考 |
|------|----------------|------|
| mdadm RAID6 / ZFS raidz2 | **2 台** | 最高の耐障害性 |
| RAID1 / RAID10 系全般 | 1 台/ペア | ペアの両方が壊れると損失 |
| RAID5 / raidz1 系全般 | 1 台 | rebuild 中の 2 台目障害で損失 |

### LINSTOR 統合度

| レベル | 方式 | 説明 |
|--------|------|------|
| **最高** | LVM RAID1/5/10 | `LvcreateOptions` で LINSTOR が直接 RAID LV を作成 |
| **高** | ZFS mirror/raidz | LINSTOR ZFS プロバイダでネイティブ統合 |
| **透過的** | mdadm + LVM | LINSTOR は通常の VG として認識。mdadm は別管理 |
| **透過的** | HW RAID + LVM | LINSTOR は通常の VG として認識。PERC は別管理 |

### Write hole リスク

| 方式 | Write hole | 対策 |
|------|-----------|------|
| ZFS raidz1/2 | **なし** | COW 設計で根本的に解決 |
| RAID1 / RAID10 系全般 | **なし** | パリティ不使用のため該当しない |
| mdadm RAID5 + PPL | **ほぼなし** | PPL (Partial Parity Log) で保護。3-5% 性能低下 |
| LVM RAID5 | **あり** | dm-raid にジャーナル機能なし。DRBD レプリカで軽減 |
| HW RAID5/6 | **BBU 依存** | BBU 劣化時は保護不十分 |

### 総合比較

| 方式 | 容量効率 | 障害耐性 | Write hole | Hot rebuild | LINSTOR統合 | 運用負荷 | 状態 |
|------|:-------:|:-------:|:----------:|:----------:|:----------:|:-------:|:----:|
| **LVM RAID1** | 50% | 1/ペア | なし | 可 | 最高 | 低 | 検証済み |
| **LVM RAID5** | **75%** | 1台 | あり | 可 | 最高 | 低 | 未テスト |
| LVM RAID10 | 50% | 1/ペア | なし | 不可 | 最高 | — | バグで不可 |
| mdadm RAID1 | 25-50% | 1台 | なし | 可 | 透過的 | 中 | 検証済み |
| **mdadm RAID5+PPL** | **75%** | 1台 | ほぼなし | 可 | 透過的 | 中 | 未テスト |
| mdadm RAID10 | 50% | 1/ペア | なし | 可 | 透過的 | 中 | 未テスト |
| mdadm RAID6 | 50% | **2台** | あり | 可 | 透過的 | 中 | 未テスト |
| **ZFS mirror (2x2)** | 50% | 1/vdev | **なし** | 可 | 高 | 低-中 | 未テスト |
| **ZFS raidz1** | **75%** | 1台 | **なし** | 可 | 高 | 低-中 | 未テスト |
| ZFS raidz2 | 50% | **2台** | **なし** | 可 | 高 | 低-中 | 未テスト |
| HW RAID5 | 75% | 1台 | BBU依存 | 不可(要再起動) | 透過的 | 高 | 非推奨 |

## 結論

### 検証済みで実用的な選択肢

**LVM RAID1** (`--type raid1 -m 1`) が現時点で唯一の検証済み・実用的な選択肢。LINSTOR との統合が最もシンプルで、hot rebuild も動作確認済み。容量効率 50% が許容できるなら最も安全な選択。

### 未テストだが有望な選択肢

容量効率やデータ保全性を重視する場合、以下の 3 つが有力候補:

1. **ZFS raidz1 + LINSTOR ZFS プロバイダ** — 容量効率 75%、write hole なし (COW)、チェックサムによるサイレント破損検出、LINSTOR ネイティブ統合。LVM を使わない根本的に異なるアプローチだが、アーキテクチャ的に最もクリーン。

2. **mdadm RAID5 + PPL** — 容量効率 75%、PPL で write hole をほぼ解消。LINSTOR からは透過的だが mdadm の追加管理が必要。

3. **ZFS mirror (2x2)** — 容量効率 50% (RAID1 と同等) だが、write hole なし + チェックサムの恩恵がある。性能面では raidz1 より優位 (ランダム書き込み)。

### 選択の指針

| 優先事項 | 推奨方式 |
|---------|---------|
| 安全性・実績重視 | LVM RAID1 (検証済み) |
| 容量効率 + データ保全性 | ZFS raidz1 (未テスト・要検証) |
| 容量効率 + LVM 維持 | mdadm RAID5 + PPL (未テスト・要検証) |
| 最大障害耐性 | ZFS raidz2 または mdadm RAID6 (未テスト) |
