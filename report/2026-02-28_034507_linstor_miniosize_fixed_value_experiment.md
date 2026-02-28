# LINSTOR minIoSize 固定指定 (auto-block-size) による不一致回避実験

- **実施日時**: 2026年2月28日 03:00-03:45
- **関連 Issue**: #26 (minIoSize 不一致問題の発見), #28 (本実験)
- **関連レポート**: [2026-02-27 LINSTOR LVM RAID10 ディスク障害実験](2026-02-27_203200_linstor_lvm_raid10_disk_failure_experiment.md)

## 前提・目的

### 背景

2026-02-27 の LINSTOR LVM RAID10 ディスク障害実験で、physical block size が異なるディスクを持つノード間で `StorDriver/internal/minIoSize` が不一致になり、ノード rejoin 時にリソース作成が失敗する問題が発見された。

従来の回避策は「VG 作成時に 512B physical block size の PV を先頭に配置する」だったが、LINSTOR 1.33.0 で追加された `Linstor/Drbd/auto-block-size` プロパティにより、DRBD の block-size を事前に固定指定し、minIoSize の不一致を無視できる可能性がある。

### 目的

1. `Linstor/Drbd/auto-block-size` プロパティの存在と動作を確認
2. minIoSize 不一致環境 (512 vs 4096) でリソース作成が可能になるか実証
3. VG PV 順序に依存しない回避策を確立

## 環境情報

| 項目 | 4号機 | 5号機 |
|------|-------|-------|
| ホスト名 | ayase-web-service-4 | ayase-web-service-5 |
| IP | 10.10.10.204 | 10.10.10.205 |
| 役割 | COMBINED (Controller+Satellite) | SATELLITE |
| sda block size | 512B | 4096B |
| sdb block size | 512B | 512B |
| sdc block size | 4096B | 4096B |
| sdd block size | 512B | 4096B |

- LINSTOR 1.33.1, DRBD 9.3.0
- VG: `linstor_vg` (4x SATA HDD, LVM striped `-i4 -I64`)
- Resource group: `pve-rg` (place-count=2, protocol C, quorum=off)
- DRBD transport: TCP over IPoIB

## 調査結果

### auto-block-size プロパティ

| レベル | 設定可否 | 備考 |
|--------|---------|------|
| resource-group | OK | `linstor resource-group set-property <rg> Linstor/Drbd/auto-block-size <value>` |
| controller | OK | `linstor controller set-property Linstor/Drbd/auto-block-size <value>` |
| storage-pool | NG | "The key is not whitelisted" エラー |

### auto-min-io プロパティ

CHANGELOG に言及されていた `auto-min-io` は、LINSTOR 1.33.1 ではプロパティとして設定不可 ("not whitelisted")。

### auto-block-size の効果

resource-group に `Linstor/Drbd/auto-block-size 512` を設定すると、DRBD リソース設定ファイル (`/var/lib/linstor.d/*.res`) に以下が追加される:

```
disk
{
    block-size 512;
    discard-zeroes-if-aligned no;
}
```

これにより DRBD は underlying device の physical block size に関わらず 512B block size を使用する。

## 実験手順と結果

### 実験 1: auto-block-size あり + minIoSize 不一致で手動 resource create

**手順**:

1. resource-group に `auto-block-size=512` を設定:
   ```sh
   linstor resource-group set-property pve-rg Linstor/Drbd/auto-block-size 512
   ```

2. 5号機を LINSTOR から離脱 (depart):
   ```sh
   linstor resource-group modify pve-rg --place-count 1
   linstor resource delete ayase-web-service-5 pm-c0401219
   linstor resource delete ayase-web-service-5 vm-100-cloudinit
   linstor storage-pool delete ayase-web-service-5 striped-pool
   linstor node delete ayase-web-service-5
   ```

3. 5号機の VG を 4096B PV (sda) 先頭で再作成:
   ```sh
   vgremove -f linstor_vg
   wipefs -af /dev/sda /dev/sdb /dev/sdc /dev/sdd
   pvcreate /dev/sda /dev/sdb /dev/sdc /dev/sdd
   vgcreate linstor_vg /dev/sda /dev/sdb /dev/sdc /dev/sdd
   ```

4. 5号機を LINSTOR に rejoin:
   ```sh
   linstor node create ayase-web-service-5 10.10.10.205 --node-type Satellite
   linstor node interface create ayase-web-service-5 ib0 192.168.100.2
   linstor node set-property ayase-web-service-5 PrefNic ib0
   linstor storage-pool create lvm ayase-web-service-5 striped-pool linstor_vg
   linstor storage-pool set-property ayase-web-service-5 striped-pool StorDriver/LvcreateOptions -- '-i4 -I64'
   ```

5. minIoSize 不一致を確認:
   - 4号機: `StorDriver/internal/minIoSize = 512`
   - 5号機: `StorDriver/internal/minIoSize = 4096`

6. 手動 resource create:
   ```sh
   linstor resource create ayase-web-service-5 pm-c0401219
   linstor resource create ayase-web-service-5 vm-100-cloudinit
   ```

**結果**: **成功**。minIoSize が 512 vs 4096 で不一致にもかかわらず、リソースが正常に作成され DRBD フル同期が開始された。

### 実験 2: auto-block-size なし + minIoSize 不一致で手動 resource create (対照実験)

**手順**:

1. 5号機のリソースを削除

2. auto-block-size を resource-group から削除:
   ```sh
   linstor resource-group set-property pve-rg Linstor/Drbd/auto-block-size
   ```

3. 手動 resource create:
   ```sh
   linstor resource create ayase-web-service-5 pm-c0401219
   ```

**結果**: **失敗**。

```
ERROR: Cannot create resource "pm-c0401219" on node "ayase-web-service-5",
       storage pool has an incompatible minimum I/O size
```

### 実験 3: auto-block-size あり + minIoSize 不一致で auto-place (place-count=2)

**手順**:

1. auto-block-size=512 を再設定
2. `linstor resource-group modify pve-rg --place-count 2`

**結果**: **失敗** (auto-place のみ)。「Not enough available nodes」エラー。
auto-place は minIoSize 不一致のノードを配置候補から除外する。

### まとめ

| 操作 | auto-block-size あり | auto-block-size なし |
|------|:---:|:---:|
| 手動 `resource create` | OK | NG (incompatible minIoSize) |
| 自動 `resource-group modify --place-count 2` | NG (auto-place 除外) | NG |

## 結論

1. **`Linstor/Drbd/auto-block-size 512`** は DRBD レベルの block-size 不一致を解決し、**手動 `resource create`** で minIoSize 不一致環境でもリソース作成を可能にする

2. **auto-place** (`--place-count` 変更による自動配置) は auto-block-size の設定に関わらず minIoSize 不一致ノードを除外する。rejoin 時は `resource create` コマンドでノードを明示的に指定する必要がある

3. **推奨構成**: 以下の2つを併用する
   - **VG PV 順序調整** (512B PV 先頭): auto-place でもリソース作成を可能にする主回避策
   - **`auto-block-size=512`**: VG PV 順序を誤った場合のセーフティネットとして常時設定。手動 `resource create` でのフォールバックを可能にする

4. **rejoin 手順の改善**: auto-place が失敗した場合、手動 `resource create` にフォールバックする手順を追加

## 環境の最終状態

- auto-block-size=512: resource-group `pve-rg` に設定済み (永続)
- 5号機 VG: sda (4096B) 先頭のまま (minIoSize=4096)
- 4号機 VG: minIoSize=512
- 全リソース: UpToDate/UpToDate (手動 resource create + フル同期完了)
