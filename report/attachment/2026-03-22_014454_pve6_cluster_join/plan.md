# 6号機を pvese-cluster1 (4+5号機) に参加させる

## Context

現在 4+5号機が pvese-cluster1、6号機が pvese-cluster2 (1台のみ、Quorum blocked) という状態。
6号機を pvese-cluster1 に参加させ、Region A を 3ノード PVE クラスタ (4+5+6) にする。
ユーザーは OS/ディスク初期化 OK と明言。

**方針**: OS 再インストールは不要。PVE クラスタ設定をリセットして `pvecm add` で参加する。
LINSTOR satellite と striped-pool (linstor_vg) は既存のものを再利用。

## Phase 0: 事前確認 (読み取り専用)

```sh
ssh -F ssh/config pve6 pvecm status          # pvese-cluster2, 1ノード, NOT quorate 確認
ssh -F ssh/config pve4 pvecm status          # pvese-cluster1, 2ノード (4+5), quorate 確認
ssh -F ssh/config pve4 linstor node list     # node6 が SATELLITE/ONLINE か確認
ssh -F ssh/config pve4 linstor resource list -n ayase-web-service-6  # リソース有無
ssh -F ssh/config pve6 vgs linstor_vg        # VG 存在確認
ssh -F ssh/config pve6 lvs linstor_vg        # stale LV がないか
ssh -F ssh/config pve6 qm list              # VM なし確認
ssh -F ssh/config pve6 ip link show type bridge  # vmbr0/vmbr1 存在確認
```

## Phase 1: LINSTOR ノード削除 (クリーン再登録のため)

6号機の LINSTOR satellite をいったん削除する。linstor_vg と物理ディスクはそのまま残す。

```sh
ssh -F ssh/config pve6 systemctl stop linstor-satellite
ssh -F ssh/config pve4 linstor storage-pool delete ayase-web-service-6 striped-pool  # (あれば)
ssh -F ssh/config pve4 linstor node delete ayase-web-service-6
```

## Phase 2: PVE クラスタ設定リセット (6号機)

6号機の pvese-cluster2 設定を完全に除去し、スタンドアロン PVE ノードにする。

```sh
# PVE/corosync サービス停止
ssh -F ssh/config pve6 systemctl stop pvedaemon pveproxy pvestatd pve-cluster corosync

# 古いクラスタ設定を削除
ssh -F ssh/config pve6 pmxcfs -l   # ローカルモードで pmxcfs を起動
ssh -F ssh/config pve6 rm -f /etc/pve/corosync.conf
ssh -F ssh/config pve6 rm -rf /etc/corosync/*
ssh -F ssh/config pve6 rm -f /var/lib/corosync/*
ssh -F ssh/config pve6 killall pmxcfs   # ローカルモード停止

# pve-cluster を通常モードで再起動
ssh -F ssh/config pve6 systemctl start pve-cluster
```

## Phase 3: pvese-cluster1 に参加

```sh
# 6号機から pvese-cluster1 (node4) に参加
ssh -F ssh/config pve6 pvecm add 10.10.10.204 --force --use_ssh
```

参加後の確認:
```sh
ssh -F ssh/config pve4 pvecm status   # 3ノード, quorate
ssh -F ssh/config pve4 pvecm nodes    # node 4, 5, 6 全て表示
```

**注意**: 2ノード→3ノードで `two_node: 1` 設定が自動的に削除されるはず。`/etc/pve/corosync.conf` を確認。

## Phase 4: ネットワークブリッジ確認

vmbr0 (管理用, eno2np1, 10.10.10.206/8) と vmbr1 (VM用, eno1np0, DHCP) が残っているか確認。
なければ `/etc/network/interfaces` を修正して `ifreload -a`。

## Phase 5: LINSTOR satellite 再登録

```sh
# satellite 起動
ssh -F ssh/config pve6 systemctl start linstor-satellite
ssh -F ssh/config pve6 systemctl enable linstor-satellite

# ノード登録
ssh -F ssh/config pve4 linstor node create ayase-web-service-6 10.10.10.206 --node-type Satellite

# IB インターフェース登録 (IB IP: 192.168.100.3)
ssh -F ssh/config pve4 linstor node interface create ayase-web-service-6 ib0 192.168.100.3
ssh -F ssh/config pve4 linstor node set-property ayase-web-service-6 PrefNic ib0

# ストレージプール再作成 (既存 linstor_vg を使用)
ssh -F ssh/config pve4 linstor storage-pool create lvm ayase-web-service-6 striped-pool linstor_vg

# LvcreateOptions 設定 (-i4 -I64、scp+ssh パターン必要)
# Aux/site プロパティ設定
ssh -F ssh/config pve4 linstor node set-property ayase-web-service-6 Aux/site region-a

# cross-region パス (Region B ノードとの接続)
ssh -F ssh/config pve4 linstor node-connection path create ayase-web-service-6 ayase-web-service-7 cross-region default default
ssh -F ssh/config pve4 linstor node-connection path create ayase-web-service-6 ayase-web-service-8 cross-region default default
ssh -F ssh/config pve4 linstor node-connection path create ayase-web-service-6 ayase-web-service-9 cross-region default default
```

## Phase 6: IPoIB 確認

6号機の IPoIB (192.168.100.3/24) が動作しているか確認。

```sh
ssh -F ssh/config pve6 ip addr show type ipoib
```

未設定の場合: `scripts/ib-setup-remote.sh` を scp して実行。

## Phase 7: PVE ストレージ確認

pvese-cluster1 に参加したことで `/etc/pve/storage.cfg` が共有される。
`linstor-storage` が node6 で利用可能か確認:

```sh
ssh -F ssh/config pve6 pvesm status
ssh -F ssh/config pve6 dpkg -l linstor-proxmox   # プラグイン存在確認
```

## Phase 8: 最終検証

```sh
ssh -F ssh/config pve4 pvecm status              # 3ノード quorate
ssh -F ssh/config pve4 linstor node list          # 6ノード全 Online
ssh -F ssh/config pve4 linstor storage-pool list  # node6 に striped-pool
ssh -F ssh/config pve6 pvesm status              # linstor-storage active
```

## Phase 9: レポート作成

REPORT.md フォーマットに従いレポートを `report/` に作成。

## 修正対象ファイル

なし (設定変更・コマンド実行のみ、スクリプト修正不要)

## リスクと対策

| リスク | 対策 |
|-------|------|
| pvecm add 失敗 | OS 再インストール (os-setup スキル) にフォールバック |
| stale DRBD メタデータ | `wipefs -af` + linstor_vg 再作成 |
| corosync split-brain | Phase 2 で旧クラスタ設定を完全除去してから join |
| LINSTOR コントローラ (node4) への影響 | LINSTOR 操作は追加のみ (node create, sp create)。既存リソースに変更なし |

