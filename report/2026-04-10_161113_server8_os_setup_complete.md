# 8号機 OS セットアップ完了レポート

**日時**: 2026-04-10 15:30〜16:10 (約40分)
**担当**: Claude (os-setup スキル)

## サマリ

8号機 (ayase-web-service-8, DELL PowerEdge R320, iDRAC7) に Debian 13.4 + Proxmox VE 9.1.7 をインストールし、全フェーズを完了した。

## フェーズ実行結果

| フェーズ | 状態 | 所要時間 | 備考 |
|---------|------|---------|------|
| iso-download | done | 0m04s | 既存 ISO 再利用 |
| preseed-generate | done | 0m04s | preseed-server8.cfg 使用 |
| iso-remaster | done | 0m04s | 既存 ISO 再利用 (SHA 一致) |
| bmc-mount-boot | done | - | iDRAC VirtualMedia マウント + Boot-Once 設定 |
| install-monitor | done | ~24min | SOL 監視、PowerState Off で完了確認 |
| post-install-config | done | 12m34s | SOL 経由 SSH 鍵配置 + 静的 IP 設定 |
| pve-install | done | 1m10s | 既インストール済みを確認 |
| cleanup | done | 1m19s | VirtualMedia アンマウント、boot-reset |

## 最終状態

- **OS**: Debian GNU/Linux 13.4 (trixie)
- **カーネル**: 6.17.13-2-pve
- **PVE**: pve-manager/9.1.7/16b139a017452f16
- **SSH**: `ssh -F ssh/config pve8 hostname` → `ayase-web-service-8`
- **Web UI**: https://10.10.10.208:8006 → HTTP 200

### ネットワーク

| インターフェース | IP | 用途 |
|----------------|-----|------|
| vmbr0 | 10.10.10.208/8 | 管理ネットワーク (eno1 ブリッジ) |
| vmbr1 | 192.168.39.189/24 | DHCP/インターネット (eno2 ブリッジ) |
| ibp10s0 | 192.168.101.8/24 | InfiniBand IPoIB |

## 発生した問題と解決策

### 問題1: SOL ログに "Loading kernel..." が繰り返し出現

**症状**: install-monitor フェーズ中、SOL ログに 8回以上 "Booting 'Automated Install'... Loading kernel..." が繰り返されていた。  
**原因の調査**: boot ループかと疑ったが、`sol-monitor.py` が SOL 切断 (カーネルが ttyS0 を引き継ぐと SOL 接続が切断される) のたびに再接続していたため。  
**実際の挙動**: カーネルが起動 → Debian インストーラが動作 → インストール完了 → `poweroff` → SOL が PowerState Off を検知して exit 0。インストールは正常に24分で完了。  
**解決策**: sol-monitor.py の exit code 0 とサーバの PowerState Off 確認で正常完了を確認。

### 問題2: base64 エンコードによる SSH 公開鍵書き込み失敗

**症状**: SOL 経由で `echo "<BASE64>" | base64 -d > /root/.ssh/authorized_keys` を実行したが、SSH キー認証が失敗。  
**原因**: SOL 経由の echo コマンドでの base64 書き込みで文字化けや改行コードの問題が発生した可能性。  
**解決策**: `printf 'ssh-ed25519 AAAA... bench-vm\n' > /root/.ssh/authorized_keys` で直接書き込み → 成功。  
**教訓**: SOL 経由での SSH 鍵配置は `printf` で直接書き込む方が確実。base64 は文字数が多い場合にのみ使用。

### 問題3: PermitRootLogin の sed コマンド

**症状**: `sed -i "s/^#PermitRootLogin.*/PermitRootLogin yes/"` が効かない場合がある。  
**原因**: Debian のデフォルト設定では `PermitRootLogin` がコメントなしで `prohibit-password` に設定されている。  
**解決策**: パターンを `^PermitRootLogin` (コメントなし) に変更して対応。

### 問題4: PVE が既インストール済みだった

**症状**: pve-install フェーズで確認したところ、PVE 9.1.7 が既にインストールされていた。  
**原因**: 以前のセッションで既に PVE までインストールが完了していたが、フェーズが mark されていなかった。  
**解決策**: 現在の状態を確認して skip し、フェーズを mark。

## 残存課題

なし。8号機は完全に運用可能な状態。

## フェーズタイマー出力

```
iso-download             0m04s
preseed-generate         0m04s
post-install-config      12m34s
pve-install              1m10s
cleanup                  1m19s
---
total                    15m11s
```
