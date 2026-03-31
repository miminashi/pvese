# 7-9号機 RAID再構成 + OS再セットアップ

## Context

ユーザが7-9号機の物理ディスク構成を変更した。既存のVDを削除し、新しい物理ディスクに合わせてRAIDを再構成し、Debian + PVE を再インストールする。

### 現在の物理ディスク構成

| Bay | 7号機 | 8号機 | 9号機 |
|-----|-------|-------|-------|
| 0 | 278.88 GB | 558.38 GB | 558.38 GB |
| 1 | 278.88 GB | 558.38 GB | 558.38 GB |
| 2 | 837.75 GB | 837.75 GB | 837.75 GB |
| 3 | 837.75 GB | 837.75 GB | 837.75 GB |
| 4 | 837.75 GB | 837.75 GB | 837.75 GB |
| 5 | 837.75 GB | 837.75 GB | 837.75 GB |
| 6 | 837.75 GB | 837.75 GB | 837.75 GB |
| 7 | 837.75 GB | - | - |

### 現在の VD (削除対象)

- 7号機: VD0 (RAID-1, 278GB) + VD1-6 (6x RAID-0, 837GB) = 7 VDs
- 8号機: VD0 (RAID-1, 558GB) + VD1-5 (5x RAID-0, 837GB) = 6 VDs
- 9号機: VD0 (RAID-1, 558GB) + VD1-5 (5x RAID-0, 837GB) = 6 VDs

## 手順

### Step 1: RAID 再構成 (perc-raid スキル)

各サーバで既存VDをすべて削除し、新しいVDを作成する。

**8号機・9号機の物理ディスク構成は racadm の情報が実際と異なる可能性あり。**
作業開始後に perc-raid スキルで PERC BIOS 画面に入り、実際のディスク構成を VNC スクリーンショットで確認してから VD を作成する。

**VD構成 (新規作成):**
- 7号機: VD0 = RAID-1 (Bay 0-1, 278GB, name=system) + 残りBay各1台ずつ RAID-0 (name=data0,data1,...)
- 8号機: 実際のディスク構成を確認後に決定
- 9号機: 実際のディスク構成を確認後に決定

手順:
1. perc-raid スキルで PERC BIOS に入り物理ディスク構成を確認
2. 全 VD 削除 (`racadm raid deletevd`)
3. 新 VD 作成 (`racadm raid createvd`)
4. ジョブキュー作成 + パワーサイクル
5. 完了確認

### Step 2: 設定ファイル更新

- `config/linstor.yml` の storage_disks と lvcreate_options を更新
- `config/server7.yml`: TBD コメント削除

### Step 3: OS 再セットアップ (os-setup スキル)

3台を順次 os-setup スキルで Debian 13 + PVE 9 をインストール

### Step 4: 検証

- SSH 接続確認
- ディスク構成確認 (`lsblk`)
- PVE Web UI アクセス確認

### Step 5: レポート作成
