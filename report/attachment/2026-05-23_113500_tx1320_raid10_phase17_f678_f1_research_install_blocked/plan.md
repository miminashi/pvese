# Phase 17 計画: TX1320 RAID10 OS install 完遂 (F6/F7/F8 整備 + 再試行 → F2 PXE pivot)

## Context (なぜこの作業をするか)

Phase 16 (2026-05-23 replicated-pearl) で、 Phase 15 patch を `commit 0624539b` に統合 + PSU cold reset + deploy-careful.sh (105s pad) で **cdrom-detect 突破 + apt + partman フェーズ到達** に成功した。 ただし最終目標 (OS install 完遂 + SSH login) は未達成。 残る障害は **iRMC FW 9.08F の USB redirector 累積的劣化** (30 min install 中に SOL session 347 reconnect) に絞り込み済。

Phase 17 の目的:
1. Phase 16 で散在した工事用具 (orchestrate.sh + 依存 10 ファイル) を main commit にまとめて作業基盤を綺麗にする (F6)
2. deploy-careful.sh の 105s pad を orchestrate.sh に統合して **再現性のある 1-shot deploy** を確立 (F8)
3. patch marker を SOL で観察可能にして **patch 動作の直接立証** を可能にする (F7)
4. 再 deploy で install 完遂を試行
5. 完遂しない場合 → **F2 PXE pivot** を試す (F1 FW update はユーザ承認後、 BMC ブリックリスク回避のため後回し)

最終目標: **OS インストール完了 (preseed 完走 + RAID10 + SSH login)**。

---

## Phase 17 sequence (ユーザ承認済)

ユーザ判断 (2026-05-23):
- **sequence**: F6+F7+F8 整備 → deploy → 不調なら F2
- **F6 粒度**: Option B (5 commits 分割)
- **F1 範囲**: リサーチのみ (本セッションで FW flash しない)

| # | サブタスク | 工数 | リスク | 効果 |
|---|-----------|------|--------|------|
| **17-1** | **F6**: orchestrate.sh + 依存 10 ファイルを **5 commit (Option B) で main 統合** | 30-45 min | 低 | 作業基盤確立、 git bisect 可能化 |
| **17-2** | **F8**: deploy-careful.sh の 105s pad を `tx1320-raid10-orchestrate.sh` deploy() に統合 (3 環境変数化) | 15-20 min | 低 | 再現性確保 |
| **17-3** | **F7**: patch marker `echo "..." > /dev/console` 1 行追加 + build sanity | 10 min | 低 | SOL 観察性向上 |
| **17-4** | iRMC state 確認 → 必要なら PSU cold reset 依頼 → deploy + 30 min SOL monitor | 40 min | 中 | install 完遂試行 |
| **17-5** | 17-4 完遂達成 → SSH 確認 + 完了レポート | 15 min | - | 最終目標達成 |
| **17-6** | 17-4 未達 → **F2 PXE pivot** 検討開始 (playground 上に dnsmasq + TFTP 立上) | 90-180 min | 中 | install 完遂の代替経路 |
| **17-7** | 17-4 / 17-6 完了後 (or 不要時) → **F1 FW update リサーチのみ** (Fujitsu support 経路 + update 手順調査、 **本セッションで FW flash しない**、 結果はレポート化のみ) | 30-45 min | 低 (read-only) | 次セッション以降の判断材料化 |

**所要時間目安**: 17-1〜17-5 で完了すれば 2-3 時間。 17-6 まで進めば +2 時間。 17-7 リサーチで +30 min。 BMC ブリックリスクのある FW flash は今回実施しない。

---

(以下、 元 plan ファイルから 17-1 〜 17-7 詳細セクション、 検証方法、 制約・注意事項。 詳細は本セッションの `.claude/plans/report-2026-05-23-052353-tx1320-raid10-wise-book.md` を参照)
