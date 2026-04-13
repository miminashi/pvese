# server7 OS Setup 完了レポート

**日時**: 2026-04-04  
**対象**: ayase-web-service-7 (10.10.10.207, iDRAC 10.10.10.27)  
**作業**: Debian 13 + PVE 9.1.7 + DRBD/LINSTOR インストール (os-setup 全8フェーズ)

---

## 結果サマリー

| 項目 | 値 |
|------|-----|
| OS | Debian 13.3 (Trixie) |
| PVE | 9.1.7 (pve-manager) |
| カーネル | 6.17.13-2-pve |
| DRBD | 9.3.1-1 (dkms installed) |
| LINSTOR | satellite 1.33.1, client 1.27.1 |
| ネットワーク | vmbr0 (eno1, 10.10.10.207/8), vmbr1 (eno2, DHCP 192.168.39.209/24) |
| デフォルトルート | 192.168.39.1 (vmbr1 経由) |

---

## フェーズ別所要時間

| フェーズ | 状態 | 所要時間 |
|---------|------|---------|
| iso-download | done | - (既存) |
| preseed-generate | done | - (既存) |
| iso-remaster | done | 1m49s |
| bmc-mount-boot | done | 0m43s |
| install-monitor | done | 43m54s |
| post-install-config | done | 1m32s |
| pve-install | done | 36m01s |
| cleanup | done | 11m08s |

---

## 主要な問題と解決策

### 1. SSH 認証失敗 (VNC type コマンドの大文字化バグ)

**問題**: `idrac-kvm-interact.py` の `type` コマンドが混在ケース文字列をランダムに大文字化する。
`chpasswd` コマンドで設定したパスワードが文字化けし、SSH パスワード認証が失敗した。

**解決策**: パスワード認証を放棄し、SSH 公開鍵認証に切り替えた。
ローカルマシンで `python3 -m http.server 9876` を起動し、サーバ側で
`busybox wget -O /root/.ssh/authorized_keys http://10.1.6.1:9876/authorized_keys` で鍵を取得。

**教訓**:
- VNC `type` コマンドは全小文字文字列にのみ使用すること
- 混在ケース文字列は `sendkeys` で1キーずつ送信するか、ファイル転送方式を使うこと
- base64 エンコード経由の書き込みが最も安全 (`echo <b64> | base64 -d > file`)

### 2. busybox wget の活用

**問題**: preseed が CD-only (`apt-setup/use_mirror boolean false`) だったため、
`pkgsel/include` で指定した wget, curl が未インストールだった。

**解決策**: `busybox wget` はベース Debian インストールに含まれており、HTTP ダウンロードに使用できる。

### 3. LINBIT GPG キー取得失敗

**問題**: `pve-setup-remote.sh` が `https://packages.linbit.com/package-signing-pubkey.gpg` (404)
および `keyserver.ubuntu.com` (タイムアウト) からのキー取得に失敗した。

**解決策**: ローカルマシンで Ubuntu キーサーバからキーを取得して SCP で配置:
```sh
curl "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4E5385546726D13CB649872CFC05A31DB826FE48" -o tmp/db5fe630/linbit-key.asc
gpg --batch --yes --dearmor -o tmp/db5fe630/linbit-keyring.gpg tmp/db5fe630/linbit-key.asc
scp -F ssh/config tmp/db5fe630/linbit-keyring.gpg root@10.10.10.207:/usr/share/keyrings/linbit-keyring.gpg
```

**教訓**: LINBIT キーの URL は変わりやすい。ローカル取得 + SCP が最も確実。

### 4. デフォルトゲートウェイ設定

**問題**: 最初の interfaces ファイルに `gateway 10.10.10.1` を設定したため、
10.0.0.0/8 (インターネット不可) 経由になってしまった。

**解決策**: vmbr0 からゲートウェイを削除し、vmbr1 (DHCP) が自動的に 192.168.39.1 をデフォルトルートとして取得するよう修正。

**正しい interfaces 設定**:
```
auto vmbr0
iface vmbr0 inet static
    address 10.10.10.207/8
    bridge-ports eno1    # gateway なし
    bridge-stp off
    bridge-fd 0

auto vmbr1
iface vmbr1 inet dhcp    # DHCP がデフォルトルートを提供
    bridge-ports eno2
    bridge-stp off
    bridge-fd 0
```

### 5. GRUB ブート失敗 (前セッションから継続)

**問題**: 前セッションで GRUB が `unknown filesystem` エラーで起動できなかった。
BIOS Legacy モードで GPT パーティション + EFI が作成されていた。

**解決策 (前セッション)**: BIOS を UEFI モードに変更後、OS を再インストール。

---

## 最終状態確認

```
PVE: pve-manager/9.1.7/16b139a017452f16 (running kernel: 6.17.13-2-pve)
DRBD: drbd/9.3.1-1, 6.17.13-2-pve, x86_64: installed
linstor-satellite: active (running)
vmbr0: 10.10.10.207/8 (UP)
vmbr1: 192.168.39.209/24 (UP, DHCP)
default via 192.168.39.1 dev vmbr1
```

---

## 次のステップ

- server7 を Region B LINSTOR クラスタ (server7 + server8 + server9) に追加
- IPoIB セットアップ
- LINSTOR satellite として既存クラスタに参加
