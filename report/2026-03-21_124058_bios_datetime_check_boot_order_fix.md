# BIOS System Date/Time 確認 + ブートオーダー修正

- **実施日時**: 2026年3月21日 11:44 - 12:40 (JST)

## 前提・目的

4-6号機の BIOS System Date/Time が現在時刻とずれている可能性があるため、BIOS Setup に入って確認する。ずれがあれば修正する。

- 対象: 4号機 (10.10.10.24), 5号機 (10.10.10.25), 6号機 (10.10.10.26)
- 方法: bios-setup スキル (KVM スクリーンショット + キーストローク)
- pve-lock 使用 (電源操作を伴う)

## 環境情報

- 4-6号機: Supermicro X11DPU, AMI Aptio UEFI BIOS V4.0 (Build Date 08/11/2023)
- OS: Debian 13.3 (Trixie) + Proxmox VE 9.1.6
- BIOS 時刻表示: UTC

## 結果

### BIOS System Date/Time の確認

3台とも BIOS の System Date/Time は UTC で正確に動作しており、修正は不要だった。

| サーバ | BIOS System Date | BIOS System Time (UTC) | 確認時刻 (UTC) | 差分 |
|--------|------------------|------------------------|---------------|------|
| 4号機 | Sat 03/21/2026 | 02:47:00 | 02:47:03 | ~3秒 |
| 5号機 | Sat 03/21/2026 | 02:53:05 | 02:53:05 | ~0秒 |
| 6号機 | Sat 03/21/2026 | 02:55:56 | 02:55:56 | ~0秒 |

### ブートオーダー問題の発見と修正

BIOS 確認後に "Exit Without Saving" で終了したところ、3台とも OS が起動せず "Reboot and Select proper Boot device" で停止した。

**原因**: ブートオーダーの設定が不適切だった。

| Boot Option | 変更前 | 変更後 |
|-------------|--------|--------|
| #1 | CD/DVD | **UEFI Hard Disk:debian** |
| #4 | Network:IBA 40-10G | (変更なし) |
| #6 | Hard Disk (Legacy) | (変更なし) |
| #11 | UEFI Hard Disk:debian | CD/DVD (繰り上げ) |

元のブートオーダーでは Boot Option #1 が CD/DVD、UEFI Hard Disk:debian は #11 だった。ブートプロセスは #1 (CD/DVD) → #2 (UEFI USB CD/DVD) → ... → #4 (PXE) → ... → #11 (UEFI Hard Disk:debian) の順に試行するが、PXE タイムアウト後に全ブートオプションの試行が完了する前に停止していた可能性がある。

**修正**: 3台とも Boot Option #1 を "UEFI Hard Disk:debian" に変更し、Save & Exit で保存。これにより:
- OS ブートが最初に試行されるため、起動時間が大幅に短縮
- PXE タイムアウト待ちが不要に

### OS 起動確認

| サーバ | SSH 接続 | OS 時刻 (UTC) |
|--------|---------|---------------|
| 4号機 | OK | Sat Mar 21 03:32:58 AM UTC 2026 |
| 5号機 | OK | Sat Mar 21 03:40:30 AM UTC 2026 |
| 6号機 | OK | Sat Mar 21 03:40:36 AM UTC 2026 |

## 再現方法

### BIOS Setup 進入

```sh
# Power off → 15秒待機 → Power on
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H <BMC_IP> -U claude -P Claude123 power off
sleep 15
./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H <BMC_IP> -U claude -P Claude123 power on

# 1秒後に KVM 接続、80回の Delete を1秒間隔で送信
# (スクリプトファイルに書いて実行)
```

### ブートオーダー変更

1. Main タブから ArrowRight x5 で Boot タブに移動
2. ArrowDown x2 で Boot Option #1 に移動
3. Enter で選択ダイアログを開く
4. ArrowDown x10 で "UEFI Hard Disk:debian" を選択
5. Enter で確定
6. F4 → Enter で Save & Exit

## 備考

- 4号機の CPLD Version は 03.B0.06、6号機は 03.B0.09 (5号機は 03.B0.06)
- 6号機のメモリは 16384 MB (4,5号機は 32768 MB)
- ブートオーダーの問題は以前から存在していたが、OS が動作中は再起動しない限り顕在化しなかった
- 今回の BIOS 進入で初めて問題が発覚した
