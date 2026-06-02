# TX1320 iPXE-CD + BIOS HII Clear 10-run runlog (session r10hiicd, 2026-06-02)

Report dir: report/attachment/2026-06-02_122133_tx1320_ipxe_cd_hii_clear_10run/

Pipeline (pre-flight verified):
- BMC 10.254.254.9 reachable (~94-183ms, 0% loss), iRMC FW healthy, PowerState=Off at start
- iPXE-CD ISO: 10.1.6.6:/var/samba/public/ipxe-tx1320.iso (NFS, basename `ipxe-tx1320.iso`)
- HTTP docroot /var/www/html: preseed/training-tx1320.cfg (storcli RAID10 + eno1 + /dev/sda), firmware/{storcli64.bin,setup-raid10-storcli.sh,phonehome-setup.sh}
- ipxe.efi cmdline = interface=auto (NOT eno1) → #15 netcfg stuck risk ~30%, workaround ForceOff→retry
- iPXE boot script preseed/url = http://10.1.6.6/preseed/training-tx1320.cfg

env for bmc-power.sh: BMC_SCHEME=https / BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" / POWER_ON_RESET_TYPE=On / BMC_PATCH_REQUIRES_ETAG=1 / BMC_BOOT_OVERRIDE_NO_DISABLED=1

| run | RAID Clear (HII) | Clear 所要 | deploy 再試行 | install 所要 | 完了判定 | SSH 到達(eno2 IP) | RAID10 | 失敗モード/備考 |
|-----|------------------|-----------|--------------|-------------|---------|------------------|--------|----------------|
| 01  | OK (commit recipe 1st try) | ~7min(KVM warmup込) | 0 | ~9min(preseed03:37→poweroff~03:50) | OK(poweroff+phonehome) | 10.254.254.4 OK | Optl 1.635TB | #15なし。/dev/sda確定。`setup-raid10-storcli.sh tee:not found`(L59/74,非致命) |
| 02  | OK (streamlined 4-file, sig一致) | ~4min | 0 | ~9min(preseed04:06→phonehome04:14) | OK(poweroff+phonehome) | 10.254.254.5 OK | Optl 1.635TB | #15なし。streamline版検証OK(2回目再現) |
| 03  | OK (統合1ファイル, 5チェックポイント全一致) | ~1.5min | 0 | ~8min(preseed04:30→phonehome04:38) | OK(poweroff) | 10.254.254.6 OK | Optl 1.635TB | #15なし。統合1ファイルClear検証OK(3回目再現,決定論確定) |
| 04  | OK (統合1ファイル, 全一致) | ~1.5min | 0 | ~8min(preseed04:53→phonehome05:01) | OK(poweroff) | 10.254.254.7 OK | Optl 1.635TB | #15なし。4回目再現 |
| 05  | OK (統合1ファイル, 全一致) | ~1.5min | 0 | ~8min(preseed05:16→phonehome05:25) | OK(poweroff) | 10.254.254.8 OK | Optl 1.635TB | #15なし。5回目再現 |
| 06  | OK (統合1ファイル, 全一致) | ~1.5min | 0 | ~8min(preseed05:39→phonehome05:48) | OK(poweroff) | 10.254.254.10 OK | Optl 1.635TB | #15なし。6回目再現 |
| 07  | OK (統合1ファイル, 全一致) | ~1.5min | 0 | ~8min(preseed06:02→poweroff) | OK(poweroff) | 10.254.254.11 OK | Optl 1.635TB | #15なし。7回目再現 |
| 08  | OK (統合1ファイル, 全一致) | ~1.5min | 0 | ~10min(poweroff基準) | OK(poweroff) | 10.254.254.12 OK | Optl 1.635TB | #15なし。8回目再現 |
| 09  | OK (統合1ファイル, 全一致, KVM再起動1回) | ~1.5min(再起動別) | 0 | ~10min(poweroff基準) | OK(poweroff) | 10.254.254.13 OK | Optl 1.635TB | #15なし。9回目再現。初回KVMがidle-timeout(cp遅延)→relaunchで成功 |
| 10  | OK (統合1ファイル, 全一致) | ~1.5min | 0 | ~10min(poweroff基準) | OK(poweroff) | 10.254.254.14 OK | Optl 1.635TB | #15なし。10回目再現。**10/10完遂** |
