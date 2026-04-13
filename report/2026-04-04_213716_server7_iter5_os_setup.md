# 7号機 OS セットアップ 反復5 完了レポート

**日時**: 2026-04-04 21:37 JST  
**セッション**: db5fe630  
**結果**: SUCCESS - 全8フェーズ完了

## 目的

Dell PowerEdge R320 (7号機) に対して BIOS デフォルトリセット + Debian 13 + Proxmox VE 9 の
OS セットアップを反復5として実行し、反復4からの改善点を検証する。

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | ayase-web-service-7 (Dell PowerEdge R320) |
| BMC | iDRAC7 (10.10.10.27) FW 2.65.65.65 |
| 静的IP | 10.10.10.207 (eno1) |
| OS | Debian GNU/Linux 13.4 (trixie) |
| PVE | 9.1.7 (pve-manager/9.1.7/16b139a017452f16) |
| カーネル | 6.17.13-2-pve |

## フェーズ所要時間

| Phase | 所要時間 | 備考 |
|-------|---------|------|
| iso-download | 0m14s | キャッシュ済みスキップ |
| preseed-generate | 0m11s | キャッシュ済みスキップ |
| iso-remaster | 0m24s | preseed未変更スキップ |
| bmc-mount-boot | 1m01s | iDRAC VirtualMedia + boot-once |
| install-monitor | 10m31s | SOL監視（再インストール1回含む） |
| post-install-config | 4m59s | SOLログイン + SSH鍵 + 静的IP |
| pve-install | 31m10s | pre-pve-setup + PVE + LINSTOR |
| cleanup | 1m13s | Bridge + IPoIB設定 |
| **合計** | **49m43s** | |

## 新発見: BIOSデフォルトロードでBoot ModeがLegacyに戻る

### 問題

F3 (Load Default Settings) を実行すると Dell R320 の Boot Mode が UEFI → BIOS (Legacy) に変更される。
これによりUEFIモードでインストールされたGPTパーティションがブートできなくなる。

反復5では以下の問題シーケンスが発生:
1. BIOSデフォルトロード後にサーバを再起動
2. Debian preseed インストールがLegacyモードで実行 → 完了
3. 再起動後 "No boot device available. Current boot mode is set to BIOS." と表示

### 根本原因

Dell R320 の BIOS デフォルト設定は Boot Mode = BIOS (Legacy)。
F3 でデフォルトロードするとこの値も既存のUEFI設定から変更される。

### 修正手順（当セッションで実施）

```sh
# UEFIモードに戻す
ssh -F ssh/config idrac7 "racadm set BIOS.BiosBootSettings.BootMode Uefi"
ssh -F ssh/config idrac7 "racadm jobqueue create BIOS.Setup.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA"
# 電源サイクルしてジョブ完了を待つ (~6分)
ssh -F ssh/config idrac7 "racadm jobqueue view -i JID_xxx"
# Status=Completed 確認後、再インストール実行
```

再インストールはLegacyインストール済み状態から行ったが問題なく完了した。

### 今後の手順への追加

**BIOSリセット後の必須確認手順:**
```sh
# F3デフォルトロード + 保存 + 再起動後
ssh -F ssh/config idrac7 "racadm get BIOS.BiosBootSettings.BootMode"
# BootMode=Bios (Legacy) なら必ず修正
ssh -F ssh/config idrac7 "racadm set BIOS.BiosBootSettings.BootMode Uefi"
ssh -F ssh/config idrac7 "racadm jobqueue create BIOS.Setup.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA"
# 電源サイクル + ジョブ完了確認後にOS再インストール
```

## その他の知見

### バックグラウンド実行問題への対策

長時間のSSHコマンドは Claude Code のツール実行がバックグラウンドに回ることがある。
回避策: スクリプトをサーバにscpしてから `ssh root@ip sh /tmp/script.sh` で実行する。

### ifupdown2インストール後のデフォルトルート変更

proxmox-ve インストール後に ifupdown2 が `/etc/network/interfaces` を再適用し、
default via 10.10.10.1 が復活する。
**対策**: post-rebootスクリプト完了後に必ず `pre-pve-setup.sh` を再実行すること。

## 最終状態

| 項目 | 値 |
|------|-----|
| OS | Debian 13.4 (trixie) |
| PVE | pve-manager/9.1.7/16b139a017452f16 |
| カーネル | 6.17.13-2-pve |
| vmbr0 | 10.10.10.207/8 (eno1) |
| vmbr1 | 192.168.39.207/24 DHCP (eno2) |
| ibp10s0 | 192.168.101.7/24 (IPoIB connected mode MTU 65520 永続化) |
| DRBD | 9.3.1-1, 6.17.13-2-pve: installed |
| linstor-satellite | enabled |
| pvedaemon/pveproxy/pve-cluster | active |

## 改善すべき点（次回反復に向けて）

1. **BIOSリセット後のBootMode確認**: F3後に必ず `racadm get BIOS.BiosBootSettings.BootMode` を確認
2. **手順書への記載**: os-setup スキルの iDRAC セクションに「BIOS F3後はBootMode確認必須」を追記
3. **os-setup スキル Phase 4 前提チェック**: iDRAC の場合 BootMode=Uefi を確認するステップ追加
