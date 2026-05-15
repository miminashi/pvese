# Round 2 Summary

| trial | server | result | wall time | phase total | install attempt | 主要トピック |
|-------|--------|--------|-----------|-------------|-----------------|--------------|
| 2 | server14 | success | 53m08s | 36m31s | 1 | LINBIT GPG empty file (404→fallback不発火), DRBD DKMS需 build-essential |
| 2 | server15 | success | 70min | 25m11s | 2 | GRUB sector read fail on attempt 1 → racadm racreset soft で回復 (skill 通り) |

## Round 1.5 改善の検証

| 改善 | 結果 |
|------|------|
| netcfg/choose_interface select eno2 | ✓ s15 で完全機能 (SOL /etc/network/interfaces 編集不要) |
| dhcpcd フォールバック | ✓ s14 でも s15 でも問題なし (skill ガイド十分) |
| SOL heredoc 禁止 / printf | ✓ s15 で printf 動作確認 |
| find ... -mindepth 1 -delete | ✓ 両 trial で動作 |
| racadm racreset soft 回復 (Phase 5) | ✓ **s15 trial 2 で実証** (GRUB ループ → racreset → attempt 2 成功) |

## 新規 skill 改善候補 (Round 2.5)

### 改善 6: LINBIT GPG 鍵の empty-file detect
- **問題**: `pve-setup-remote.sh --linstor` の wget が `packages.linbit.com/package-signing-pubkey.gpg` から **404** を取得し空ファイルを残す。在来の `wget` exit code 0 + empty file という silent failure
- **修正**: SKILL.md Phase 7 step 4 で「`--linstor` 使用時は wget 後にファイルサイズが 0 なら ubuntu キーサーバから手動取得 + dearmor で配置する手順」を追記

### 改善 7: DRBD DKMS は build-essential 必須
- **問題**: `pve-setup-remote.sh --linstor` は `gcc` を入れるが `build-essential`/`libc6-dev` は入れず DRBD DKMS ビルドが `stdio.h: No such file` で失敗 → drbd-dkms iF 状態
- **修正**: SKILL.md Phase 7 step 4 で「`--linstor` 前に `apt install -y build-essential` を流す」を追記、または `pve-setup-remote.sh` の依存パッケージリストに `build-essential` を追加 (今回は skill 側にメモ)

### 改善 8: racadm resetconfig は SCP Export 後行ジョブ
- **問題**: `racadm raid resetconfig` 後に `racadm jobqueue view` で `Export: Server Configuration Profile` の自動 job が残り、次の `racadm raid createvd` が `LC062` で失敗することがある
- **修正**: SKILL.md Phase 4 / R430 RAID 整備セクションで「resetconfig → jobqueue create → **resetconfig job が完了 + SCP Export job も完了するまで待つ**」を追記

### 改善 9: sol-login.py の `printf > file` 警告は誤検知
- **問題**: SOL に対して `printf '...' > /tmp/file` を流すと `sol-login.py` が「Command may have failed」を WARN するが redirect 自体は成功
- **修正**: SKILL.md Phase 6 step 3 の SOL コマンド送信ベストプラクティスに「printf > /file は WARN が出ても無視 (実体は成功) — SSH key-auth で間接的に検証」を追記
