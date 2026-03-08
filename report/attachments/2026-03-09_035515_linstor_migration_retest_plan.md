# LINSTOR マルチリージョンマイグレーション再現性テスト (2回目) — テスト計画書

## Context

2026-03-09 に実施した LINSTOR マルチリージョンマイグレーションテスト (Phase 0-5) は全 Phase 成功した。
操作手順の再現性を確認するため、Phase 1-5 を同一環境で再実行する。

- **1回目レポート**: `report/2026-03-09_010540_linstor_migration_test.md`
- **スキル**: `.claude/skills/linstor-migration/SKILL.md`

### 現在の環境状態

| 項目 | 状態 |
|------|------|
| VM 200 | Region B (6号機) で稼働中 |
| pm-39c4600d | 4号機 (DR, UpToDate), 6号機 (InUse, Primary), 7号機 (UpToDate) |
| vm-200-cloudinit | 4号機, 6号機, 7号機 すべて UpToDate |
| リージョン間 | Protocol A, allow-two-primaries=no |
| リージョン内 | Protocol C, allow-two-primaries=yes |
| 5号機 | Online だがリソースなし |

Phase 0 (2+1 トポロジー構成) は既に完了済みのため、Phase 1 から再実行する。

### 再現性テストの観点

- 1回目と同じ手順で同じ結果が得られるか
- 1回目で発見した障害パターン (C3: stale パス等) が2回目でも発生するか、それとも対策により回避できるか
- ライブマイグレーションのダウンタイム・転送量が1回目と同等か

## 共通パラメータ

```
CTRL_IP=10.10.10.204
RESOURCE=pm-39c4600d
CLOUDINIT=vm-200-cloudinit
PVE_VOL=pm-39c4600d_200
VMID=200
VM_MGMT_IP=10.10.10.210
MAC0=BC:24:11:41:01:D9
MAC1=BC:24:11:5A:68:90
CHECKSUM=3ba0fc5d86eb0244bda2ed8116a01a58
```

## Phase 1-5 概要

| Phase | 内容 |
|-------|------|
| Phase 1 | リージョン内ライブマイグレーション (6↔7 双方向) |
| Phase 2 | コールドマイグレーション B→A (5号機レプリカ追加、VM移行) |
| Phase 3 | リージョン廃止 (6号機・7号機削除) |
| Phase 4 | リージョン追加 (6号機・7号機再追加、DRレプリカ設定) |
| Phase 5 | コールドマイグレーション復帰 A→B (7号機レプリカ追加、VM復帰、DRレプリカ再設定) |

## 成功基準

- 全 Phase が1回目と同じ手順で成功すること
- ラウンドトリップ (B→A→B) でデータ整合性が維持されること (md5sum 一致)
- 最終状態が1回目終了時と同一 (6号機 Primary, 7号機 Secondary, 4号機 DR)
