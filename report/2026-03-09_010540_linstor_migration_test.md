# LINSTOR マルチリージョンマイグレーション実運用テスト

- **実施日時**: 2026年3月9日 08:00 - 10:05 JST
- **Issue**: #34

## 前提・目的

LINSTOR/DRBD マルチリージョン構成で、実運用シナリオ (ライブマイグレーション、コールドマイグレーション、リージョン廃止・追加) を検証する。

- 背景: 4ノード LINSTOR クラスタ (place-count=2) でリージョン間 DR 同期 + マイグレーションが必要
- 目的: 2+1 トポロジー (リージョン内 Protocol C + リージョン間 Protocol A DR) の構成と全マイグレーションシナリオの検証
- 前提条件: 4ノード LINSTOR クラスタが稼働中、マルチリージョンスクリプト (`scripts/linstor-multiregion-*.sh`) が利用可能

### 参照レポート

- [2026-03-02 LINSTOR 4ノードマルチリージョンベンチマーク](2026-03-02_001504_linstor_4node_multiregion_benchmark.md)

## 環境情報

| 項目 | 値 |
|------|-----|
| Region A (pvese-cluster1) | 4号機 (10.10.10.204, controller) + 5号機 (10.10.10.205) |
| Region B (pvese-cluster2) | 6号機 (10.10.10.206) + 7号機 (10.10.10.207) |
| LINSTOR コントローラ | 4号機 (10.10.10.204:3370) |
| DRBD | 9.3.0 |
| LINSTOR | 1.33.1 |
| PVE | 9.1.6 |
| カーネル | 6.17.13-1-pve |
| テスト VM | VM 200 (bench-vm), 4GiB RAM, 4 cores, 32GiB DRBD disk, kvm64 CPU |
| VM 管理 IP | 10.10.10.210/8 |
| テストデータ | 512 MiB urandom (md5sum: 3ba0fc5d86eb0244bda2ed8116a01a58) |

### ハードウェア差異

| ノード | マザーボード | CPU |
|--------|------------|-----|
| 4号機, 5号機, 6号機 | Supermicro X11DPU | Xeon (Skylake/Cascade Lake 世代) |
| 7号機 | DELL PowerEdge R320 | Xeon E5-2400 (Sandy Bridge 世代) |

## テスト結果サマリ

| Phase | テスト | 結果 | 備考 |
|-------|--------|------|------|
| Phase 0 | 2+1 トポロジー構成 | **成功** | RG replicas-on-same, VM 作成, DR レプリカ追加 |
| Phase 1 | リージョン内ライブマイグレーション | **成功** | 双方向, ゼロダウンタイム |
| Phase 2 | コールドマイグレーション B→A | **成功** | VM config 再作成方式 (vzdump 不要) |
| Phase 3 | リージョン廃止 (B 削除) | **成功** | linstor-multiregion-node.sh remove |
| Phase 4 | リージョン追加 (B 再追加) | **成功** | パス再作成が必要 |
| Phase 5 | コールドマイグレーション A→B (復帰) | **成功** | ラウンドトリップでデータ整合性維持 |

## Phase 0: 2+1 トポロジー構成

### 実施内容

1. RG に `replicas-on-same site` を設定 (auto-place がリージョン内に配置)
2. `auto-block-size=512` を設定 (minIoSize 不一致対策)
3. VM 200 を Region B (6号機) に作成 (cloud-init, デュアル NIC, Ed25519 SSH)
4. Region A (4号機) に DR レプリカを追加
5. cross-region パスを作成 (PrefNic=ib0 バイパス)
6. Protocol A を inter-region 接続に設定

### 発見事項

- `replicas-on-same "Aux/site"` は二重プレフィックスになる → `--replicas-on-same site` を使用
- PrefNic=ib0 のノードは DRBD を IB アドレスにバインド → `node-connection path create` で `default` インターフェースを指定して回避
- 32GiB フルシンク: 1GbE 経由で約6分

### 再現手順

```sh
ssh root@10.10.10.204 "linstor resource-group modify pve-rg --replicas-on-same site"
ssh root@10.10.10.204 "linstor resource-group set-property pve-rg Linstor/Drbd/auto-block-size 512"

ssh root@10.10.10.204 "linstor resource create ayase-web-service-4 pm-39c4600d"

ssh root@10.10.10.204 "linstor node-connection path create ayase-web-service-4 ayase-web-service-6 cross-region default default"
ssh root@10.10.10.204 "linstor node-connection path create ayase-web-service-4 ayase-web-service-7 cross-region default default"

./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
```

## Phase 1: リージョン内ライブマイグレーション

### 実施内容

VM 200 を Region B 内で双方向にライブマイグレーション。

### 結果

| テスト | 結果 | ダウンタイム | 転送量 | 時間 |
|--------|------|------------|--------|------|
| 6号機 → 7号機 (kvm64) | 成功 | 73ms | 911 MiB | 18秒 |
| 7号機 → 6号機 (kvm64) | 成功 | 33ms | 349 MiB | 11秒 |
| 6号機 → 7号機 (host CPU) | **失敗** | - | - | - |

- uptime が連続 (VM リブートなし)
- データ整合性 OK (md5sum 一致)
- DRBD Primary ロールが移行先に正常遷移
- DR レプリカ (4号機) は UpToDate を維持

### 失敗: host CPU タイプ

CPU タイプ `host` で 6号機 → 7号機マイグレーションを試みたところ失敗:
```
kvm: Putting registers after init: Failed to set special registers: Invalid argument
```

原因: 6号機 (Xeon Skylake) と 7号機 (Xeon Sandy Bridge) の CPU 世代が異なる。`kvm64` に変更して成功。

### 再現手順

```sh
ssh root@10.10.10.206 "qm set 200 --cpu kvm64"
./pve-lock.sh run ./oplog.sh ssh root@10.10.10.206 "qm migrate 200 ayase-web-service-7 --online"
./pve-lock.sh run ./oplog.sh ssh root@10.10.10.207 "qm migrate 200 ayase-web-service-6 --online"
```

## Phase 2: コールドマイグレーション (Region B → A)

### 実施内容

リージョン廃止シナリオとして VM 200 を Region B から Region A に移行。

### 手順

1. Region A に2レプリカ確保 (4号機 DR + 5号機新規)
2. 5号機用 cross-region パス作成 (5↔6, 5↔7)
3. VM 停止
4. Region B レプリカ削除 (6号機, 7号機)
5. Region B の VM config 削除: `rm /etc/pve/qemu-server/200.conf`
6. Region A で VM 再作成: `qm create 200` + `qm set --scsi0 linstor-storage:pm-39c4600d_200`
7. VM 起動 + データ整合性検証

### 核心的発見

**`qm set --scsi0 linstor-storage:<resource_name>` は PVE クロスクラスタで動作する。**

- LINSTOR リソースが移行先ノードに UpToDate で存在していれば、`qm set` で直接アタッチ可能
- vzdump/qmrestore は不要
- リソース名の形式: `pm-39c4600d_200` (LINSTOR リソース名 + `_` + VMID)

### 再現手順

```sh
./pve-lock.sh run ./oplog.sh ssh root@10.10.10.206 "qm stop 200"
ssh root@10.10.10.204 "linstor resource delete ayase-web-service-6 pm-39c4600d"
ssh root@10.10.10.204 "linstor resource delete ayase-web-service-7 pm-39c4600d"
ssh root@10.10.10.206 "rm /etc/pve/qemu-server/200.conf"
ssh root@10.10.10.204 "qm create 200 --name bench-vm --memory 4096 --cores 4 --cpu kvm64 --net0 virtio=BC:24:11:41:01:D9,bridge=vmbr1 --net1 virtio=BC:24:11:5A:68:90,bridge=vmbr0 --ostype l26 --scsihw virtio-scsi-single"
ssh root@10.10.10.204 "qm set 200 --scsi0 linstor-storage:pm-39c4600d_200,discard=on,iothread=1,size=32G"
ssh root@10.10.10.204 "qm set 200 --boot order=scsi0"
./pve-lock.sh run ./oplog.sh ssh root@10.10.10.204 "qm start 200"
ssh debian@10.10.10.210 "md5sum -c /home/debian/checksums.txt"  # OK
```

## Phase 3: リージョン廃止 (Region B ノード削除)

### 実施内容

Phase 2 で VM 移行完了後、Region B を LINSTOR から完全に除去。

```sh
./pve-lock.sh run ./oplog.sh ./scripts/linstor-multiregion-node.sh remove ayase-web-service-7 config/linstor.yml
./pve-lock.sh run ./oplog.sh ./scripts/linstor-multiregion-node.sh remove ayase-web-service-6 config/linstor.yml
```

結果: 両ノード正常削除。Region A の VM は影響なく稼働継続。

## Phase 4: リージョン追加 (Region B 再追加)

### 実施内容

廃止した Region B を再び LINSTOR に追加し、DR レプリカを設定。

### 発見事項

- node remove/re-add 後、既存の cross-region パスは **stale になる** (ノード UUID 変更のため)
- `Network interface 'default' of node 'X' does not exist!` エラーが発生
- 解決: パスを delete + recreate
- DRBD config (`.res` ファイル) も古い UUID/アドレスを参照 → パス再作成で自動再生成

### 再現手順

```sh
ssh root@10.10.10.204 "linstor node create ayase-web-service-6 10.10.10.206 --node-type Satellite"
ssh root@10.10.10.204 "linstor storage-pool create lvm ayase-web-service-6 striped-pool linstor_vg"
ssh root@10.10.10.204 "linstor node set-property ayase-web-service-6 Aux/site region-b"
ssh root@10.10.10.204 "linstor node set-property ayase-web-service-6 DrbdOptions/AutoEvictAllowEviction false"

ssh root@10.10.10.204 "linstor node-connection path delete ayase-web-service-4 ayase-web-service-6 cross-region"
ssh root@10.10.10.204 "linstor node-connection path create ayase-web-service-4 ayase-web-service-6 cross-region default default"

ssh root@10.10.10.204 "linstor resource create ayase-web-service-6 pm-39c4600d"
./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
```

## Phase 5: コールドマイグレーション復帰 (Region A → B)

### 実施内容

Phase 2 の逆方向。VM 200 を Region A から Region B に戻し、ラウンドトリップのデータ整合性を検証。

### 結果

- VM が Region B で正常起動
- データ整合性 OK: `3ba0fc5d86eb0244bda2ed8116a01a58` (ラウンドトリップ B→A→B で一致)
- DR レプリカ (4号機) の Protocol A 同期完了 (32GiB, ~6分)

### 最終状態

```
Region B (Primary):
  ayase-web-service-6: pm-39c4600d InUse UpToDate
  ayase-web-service-7: pm-39c4600d Unused UpToDate
  (Protocol C, allow-two-primaries=yes)

Region A (DR):
  ayase-web-service-4: pm-39c4600d Unused UpToDate
  (Protocol A, allow-two-primaries=no)
```

## 障害パターンまとめ

### ライブマイグレーション

| ID | 障害 | 発生 | 対策 |
|----|------|------|------|
| M1 | host CPU で異種ハードウェア間マイグレーション失敗 | Phase 1 | kvm64 に変更 |
| M2 | vendor snippet 未配置 | Phase 1 | 移行先ノードに snippet コピー |

### コールドマイグレーション

| ID | 障害 | 発生 | 対策 |
|----|------|------|------|
| C1 | PrefNic=ib0 で cross-region DRBD 接続不能 | Phase 0 | node-connection path (default interface) |
| C2 | replicas-on-same 二重プレフィックス | Phase 0 | "site" を使用 (Aux/なし) |
| C3 | node remove/re-add 後の stale パス | Phase 4 | パス delete + recreate |

## 成果物

| ファイル | 内容 |
|---------|------|
| `.claude/skills/linstor-migration/SKILL.md` | マイグレーションスキル (新規) |
| `config/linstor.yml` | migration セクション追加 |
| `memory/linstor.md` | 2+1 トポロジー、マイグレーション手順メモ追記 |
| 本レポート | テスト結果 |

## 結論

LINSTOR/DRBD マルチリージョン環境で以下の全シナリオが正常に動作することを確認:

1. **リージョン内ライブマイグレーション**: ゼロダウンタイム (33-73ms), 双方向で成功
2. **リージョン間コールドマイグレーション**: LINSTOR リソースの直接アタッチ方式で vzdump 不要
3. **リージョン廃止・追加**: スクリプト化済みの手順で正常動作 (ただし re-add 後のパス再作成が必要)
4. **データ整合性**: ラウンドトリップ (B→A→B) で完全一致

主な注意点:
- 異種ハードウェア間のライブマイグレーションには `kvm64` CPU タイプが必須
- PrefNic=ib0 環境では cross-region パスを `default` インターフェースで作成
- ノード re-add 後はパスの delete + recreate が必要
