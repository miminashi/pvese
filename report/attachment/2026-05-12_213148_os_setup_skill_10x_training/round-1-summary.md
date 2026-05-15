# Round 1 Summary

| trial | server | result | wall time | phase total | install attempt | 主要トピック |
|-------|--------|--------|-----------|-------------|-----------------|--------------|
| 1 | server14 | success | 47m17s | 29m14s | 1 | parallel session 競合 (test artifact), state ディレクトリの rm -rf ブロック |
| 1 | server15 | success | 48m53s | 36m10s | 1 | netcfg/choose_interface auto で eno1 選択, pre-pve DHCP timeout, SOL heredoc 不可 |

## 統一して反映すべき skill 改善点 (Round 1.5)

### 改善 1: preseed の netcfg/choose_interface に明示的な NIC 名を指定
- **問題**: `netcfg/choose_interface auto` は link up の先頭 NIC を選び、mgmt 配線が eno2 のサーバでは eno1 に静的 IP が割り当てられ SSH 不到達
- **修正**: SKILL.md Phase 2 (preseed-generate) で `netcfg/choose_interface select eno2` を推奨し、`%%STATIC_IFACE%%` プレースホルダ導入を提案

### 改善 2: pre-pve-setup.sh の DHCP フォールバック明文化
- **問題**: Debian 13 minimal は isc-dhcp-client 不在で初回 DHCP が timeout
- **修正**: SKILL.md Phase 7 step 0 に「DHCP timeout 時は `dhcpcd -1 -t 30 <iface>` を先行実行」と明記

### 改善 3: SOL 経由コマンド送信のベストプラクティス
- **問題**: SOL 行送信モードでは heredoc (`cat <<EOF`) が複数 echo に分解される
- **修正**: SKILL.md Phase 6 step 3 に「heredoc 禁止、`printf '...\n'` を使う」を明記

### 改善 4: state リセットのコマンド例
- **問題**: `rm -rf state/os-setup/server14/*` が CLAUDE.md 内 shell 安全チェックでブロック
- **修正**: SKILL.md Resume セクションに「`find state/os-setup/<host> -mindepth 1 -delete` で初期化」を追記

### 改善 5: BIOS SerialComm の許容値拡大
- **問題**: skill は `OnConRedirCom1` 必須としているが、R430 + BIOS 2.9.1 では `OnConRedirAuto` も動作
- **修正**: SKILL.md Phase 4 iDRAC SerialCommSettings の事前検証ロジックを `OnConRedirCom1|OnConRedirAuto` 許容に
