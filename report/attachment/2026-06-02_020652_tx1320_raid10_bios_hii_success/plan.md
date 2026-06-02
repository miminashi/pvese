# TX1320 M3 — BIOS RAID (AVAGO HII KVM) 経由の RAID10 構築 再調査・実機検証

## Context（なぜやるか）

- コントローラ **PRAID EP400i (LSI MegaRAID SAS3008)** は RAID10 を確実にサポート（Web 調査確定 / RAID5/6 が作れる以上 RAID10 も可能）。
- これまで TX1320 で RAID10 構築に成功したのは **storcli（OS install 中）経路のみ**。BIOS RAID (AVAGO HII KVM) 経路は **2026-05-17 (a-goofy-graham) に「Select RAID Level 到達不可 = dead-end」と判定**されている。
- しかしこの dead-end 判定は **偽陰性の可能性が高い**:
  1. FW **9.08F** + 旧ツール時代の結論（2026-06-01 ハードニング前）。
  2. **🚨 スキル内部に矛盾がある**: dead-end は「Select RAID Level (y=128) 行に到達不可」と断定するが、SKILL.md line 445（2026-06-01 jiggly12、dead-end より後）は「`Select RAID Level` から ArrowDown×2 がちょうど Select Drives」と**カーソルが Select RAID Level 行に乗れている前提**で navigation を記述している。つまり後の作業で行は到達できていた可能性が高く、dead-end の「行スキップ」は当時の検出不良の疑いが濃い。
  3. **行スキップの真因はカーソル検出の誤り**: レポート自身が「form 内 cursor 位置検出が `[RAID0]` 明色 cluster 誤検出で確立できず」と認める（line 331）。y=128 への到達判定の土台が不安定だった。現在は「画面の文字・反転背景・右ヘルプ全文をサブエージェントが読む」方式で確実に行を同定できる。
  4. **🚨 ドライブ未選択のまま RAID Level を試した（RAID10 出現の前提を欠く）** — Web 調査が示す MegaRAID 標準手順「先に 4 ドライブ選択 → 後で RAID Level を開くと RAID10 が出現」を一度も試していない。RAID10 がドロップダウンに出ない/活性化しないのは drive-count 依存の正常挙動の可能性。
  5. **ドロップダウンを開いた後のキー応答**は別問題で、2026-06-01 jiggly12 発見の modal フォーカス喪失バグ（ダイアログ/ポップアップを開くと canvas がキーボードフォーカスを失う → `mouse 512 384` で再確立）が該当する。※ これは popup/dialog 限定で「メニュー行への到達」には影響しない（理由 2/3 と混同しない）。
  6. マウスクリック不達の結論も旧 `click` 実装由来。新 `server.py` の `mouse` 実クリックは動作実績あり。
- **目的**: ハードニング済みツール + MegaRAID 標準手順 + per-key サブエージェント画像分析で、BIOS HII から RAID10 を作れるか実機で再検証し、作れれば自動化手順を確立してスキルに反映する。

（以下、承認時のプラン全文。Phase 0〜4 / 完了条件 / 検証 / リスクは本文記載のとおり。決定木 H1（行到達可否確定）→ H2（ドロップダウン逐語確認・RAID10 選択 or RAID1+span）→ H3（Profile-Based 経路）の順で進める設計。実機では H1 で「フォームがカーソル Select RAID Level 行に乗って開く + ドロップダウンに RAID10 在り」が即座に確認され、H2 の RAID10 直接選択で成立した。）
