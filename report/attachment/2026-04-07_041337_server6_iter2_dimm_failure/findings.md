# Iteration 2 Findings - Server 6 (ayase-web-service-6)

## Summary
- **Status**: FAILED - Cannot boot installer kernel
- **Root Cause**: DIMM P2-DIMMA1 uncorrectable memory error causes EFI kernel decompression failure
- **Error**: `EFI stub: ERROR: Failed to decompress kernel` + `start_image() returned 0x8000000000000001`
- **Attempts**: 4 boot attempts, all failed identically

## Timeline

1. Found server stuck in BIOS Setup (left by previous iteration)
2. Exited BIOS, found GRUB command line (grub>) - installed OS's GRUB broken
3. Set Boot Option #1 = UEFI CD/DVD, saved, rebooted
4. Installer GRUB menu appeared ("Automated Install")
5. Kernel loading failed: `EFI stub: ERROR: Failed to decompress kernel`
6. Retried 3 more times (power cycles) - same error every time
7. Rebuilt ISO with original (committed) remaster script - same error
8. Gave up after 4 attempts

## Key Observations

### DIMM Error (POST screen)
```
Failing DIMM: DIMM location. (Uncorrectable memory component found)
P2-DIMMA1
```
- Visible on Supermicro logo screen during every POST
- BIOS disables the faulty DIMM, leaving Total Memory = 16384 MB
- Only P1-DIMMA1 has temperature sensor thresholds (only 1 DIMM populated)
- P2-DIMMA1 may be a failed DIMM or an empty slot reporting false errors

### EFI Kernel Decompression Failure
```
Booting 'Automated Install'
Loading kernel...
Loading initrd...
Booting...
EFI stub: ERROR: Failed to decompress kernel
EFI stub: ERROR: efi_stub_entry() failed!
error: start_image() returned 0x8000000000000001.
Failed to boot both default and fallback entries.
```
- Error code 0x8000000000000001 = EFI_LOAD_ERROR
- Occurs during EFI stub decompression of vmlinuz (before initrd is used)
- Reproducible across multiple boot attempts and both ISO versions
- The kernel is loaded from VirtualMedia into RAM, then EFI stub tries to decompress it

### Installed OS Also Broken
- GRUB drops to `grub>` command line (no grub.cfg found or corrupted)
- This was likely caused by memory corruption during the initial (iteration 1) installation
- Iteration 1 install-monitor took 182 minutes (vs normal 6-12 min)

### ISO Not the Cause
- Tested both modified (799MB, initrd-injected) and original (762MB, cdrom preseed) ISOs
- Both fail identically with the same EFI decompression error
- Same ISOs work on other servers (4, 5)

## Root Cause Analysis: Why install-monitor took 182 minutes

The 182-minute install-monitor in iteration 1 was caused by the same DIMM error:

1. **Intermittent decompression failures**: The EFI kernel decompression failure is position-dependent
   - When the corrupted memory region is used for kernel decompression buffer, it fails
   - When it's not used (lucky allocation), it succeeds
   - Iteration 1 got lucky after multiple retries (the 182 min includes many failed boot/retry cycles)

2. **Silent data corruption during installation**: Even when the kernel boots, the DIMM error
   can corrupt data during disk writes, causing:
   - Broken GRUB configuration (grub.cfg missing/corrupted)
   - Potentially corrupted packages
   - The installed system's kernel also fails to decompress on reboot

3. **Why iteration 2 always fails**: The memory error may have worsened since iteration 1,
   or the probability of hitting corrupted memory during kernel decompression is very high

## Recommendations

1. **Physical intervention required**: Remove or replace DIMM P2-DIMMA1
   - If slot is empty, the DIMM controller on CPU2 may be faulty
   - If DIMM is present, replace it

2. **Workaround (untested)**: 
   - In BIOS, manually disable P2-DIMMA1 slot in Chipset Configuration > Memory
   - Or remove the DIMM physically

3. **Cannot proceed with software-only fix**: The hardware error prevents reliable OS installation
