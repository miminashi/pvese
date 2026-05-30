# TX1320 SMB silent failure: N2 仮説検証 (別 ISO で attach 試行)

## Context

前セッション (`report/2026-05-20_144338_tx1320_raid10_smb_n1_disproof.md`、 virtual-wolf) で N1 仮説 (setpathinfo の chmod EPERM 起因) を Samba debug log で反証。 setpathinfo / smb_posix_open / smbXsrv_open_create はすべて NT_STATUS_OK で成功するが、 iRMC は USB device を生成せず ~320ms 後に close → 60s 沈黙 → retry を継続する状態。 真因は smb_posix_open response 後の iRMC 内部処理にあると確定。

本セッションでは **N2 仮説 = 「iRMC は AIO read で取得した ISO 先頭の何かが想定と違って abort」** を検証する。 最小実装として、 動作未確認だが書き込み権限不要な純正 Debian ISO (`debian-13.3.0-amd64-netinst.iso`) を VirtualMedia source に切り替え、 同じ trigger sequence (DisconnectCD → config → ConnectCD) で Members.count >= 1 となるかを確認する。

期待される分岐:
- **attach 成立** → N2 確定。 元 ISO (`debian-training-tx1320-raid10.iso`) の内容が iRMC 想定と何か違う (例: ISO9660 header、 Boot Catalog、 El Torito、 size 偶奇)。 install 完走への現実的経路が見える
- **attach 不成立** → N2 反証。 ISO 内容ではなく iRMC 側固有の問題に絞り込み、 次セッションで N4 (smb.conf 無改変 + tcpdump 並行 + AIO read 後 packet 完全捕捉) と N3 (Licenses dump) へ進む

Samba debug log は前セッション教訓「仮説検証時は証拠ポイントを Samba log で個別に grep して NT_STATUS まで確認」を踏まえ、 最初から `log level = 10` で取得する (force user は **設定しない**、 前セッションで判明した AIO read 抑制副作用を避けるため)。

## Approach

1 sudo session = 1 phase に分解。 smb.conf 改変は `[global] log level = 10` 1 行追加のみで [public] には触らない。 ISO 切替は `irmc-virtualmedia.sh config` の引数指定で完結 (ファイル実体は触らない)。

### Phase 0: Pre-flight (read-only、 sudo 不要)

- tmp/<sid>/ 作成、 ping baseline 10 packets、 BMC PowerState、 VirtualMedia status、 ISO 存在確認、 smb.conf backup、 smbclient -L baseline

### Phase 1: BMC give-up state 解除 (sudo 不要)

`POST /redfish/v1/Managers/iRMC/Actions/Manager.Reset {"ResetType":"GracefulRestart"}` → 30s sleep → 5s 間隔で bmc-power.sh status を rc=0 まで polling (最大 40 iter)。

### Phase 2: N2 trigger + 120s polling (sudo 1 回)

`! sudo sh tmp/<sid>/phase2-n2.sh`:
1. smb.conf に log level=10 を適用
2. Samba log truncate
3. smbcontrol reload-config + close-share
4. iRMC DisconnectCD
5. 10s 待機
6. irmc-virtualmedia.sh config で debian-13.3.0-amd64-netinst.iso に切り替え
7. iRMC ConnectCD

`tmp/<sid>/phase2-poll.sh` で Members.count を 5s 間隔 24 回。

### Phase 3: 結果分岐

- Branch A (Members>=1): N2 確定
- Branch B (24 iter で 0): N2 反証 → Samba log で iRMC が送る trans2 シーケンスを精査

### Phase 4: skipped

### Phase 5: Cleanup (sudo 1 回)

DisconnectCD → smb.conf 復元 → smbcontrol reload → 元 ISO config 復元。 diff exit 0 で確認。

### Phase 6: レポート + Issue #69 update

## Verification

ping 0% loss、 ConnectCD HTTP 204、 polling 24 iter 完走、 Phase 5 diff exit 0。

## Critical files

### 読み取りのみ
- `report/2026-05-20_144338_tx1320_raid10_smb_n1_disproof.md`
- `scripts/irmc-virtualmedia.sh` / `scripts/bmc-power.sh`
- `/var/samba/public/debian-13.3.0-amd64-netinst.iso` (N2 検証用)

### 一時改変 → Phase 5 で完全復元
- `/etc/samba/smb.conf`、 `/var/log/samba/log.*`

## Risks
1. ISO 切替の config は ConnectCD を含まない (別途 POST 必要)
2. smb.conf [public] には触らない (force user 副作用回避)
3. iRMC give-up state は Phase 1 で先に解除
4. install 完走しない (検証のみ)
