# ZFS raidz1 ベンチマーク再実施 — ARC無効化 + 64GiB + IPoIB

## Context

前回の ZFS raidz1 ベンチマーク (2026-03-30_025702) では、ZFS ARC キャッシュがテストファイル (1GiB/4GiB) を完全にキャッシュし、読み込み性能が LVM 比で 12〜37 倍という異常値を示した。レポート自身が「より公平な比較のためには ARC 無効化 + 大容量テストファイル + ARC ヒット率計測が必要」と結論していた。また、前回は IPoIB が未設定のため GbE のみだったが、現在は IB が 3 台とも設定済み (192.168.101.7/8/9)。

**目的**: ARC キャッシュの影響を排除した HDD 生性能を計測し、GbE と IPoIB の両方で比較する。

## 変更点 (前回比)

1. ARC 最小化: `zfs_arc_max=67108864` (64 MiB) — 前回は 4 GiB
2. テストファイルサイズ: 64 GiB — 前回は 1 GiB (ランダム) / 4 GiB (シーケンシャル)
3. VM ディスクサイズ: 80 GiB — 前回は 32 GiB
4. IPoIB + GbE 両方でテスト — 前回は GbE のみ
5. DRBD レプリカ: 7号機 ↔ 8号機 — 前回は 7号機 ↔ 9号機

## 実施フェーズ

1. Phase 0: 現状確認
2. Phase 1: ARC 最小化 (3台で zfs_arc_max=64MiB)
3. Phase 2: VM 100 再作成 (80G ディスク、64GiB テストファイル事前作成)
4. Phase 4: fio ベンチマーク — IPoIB (PrefNic=ibp10s0) 7テスト x 3回
5. Phase 5: fio ベンチマーク — GbE (PrefNic unset) 7テスト x 3回
6. Phase 6: ARC 復元 + PrefNic 復元
7. Phase 7: 結果集計・レポート作成
