# Server 6 (ayase-web-service-6) Diagnosis

## Status: BLOCKED - Hardware Failure

Server 6 cannot reliably boot any OS kernel due to a memory hardware error.

## Problem

Every boot attempt fails with:
```
EFI stub: ERROR: Failed to decompress kernel
EFI stub: ERROR: efi_stub_entry() failed!
error: start_image() returned 0x8000000000000001.
```

The error occurs before the kernel even starts executing. The EFI stub (embedded in vmlinuz)
cannot decompress the kernel image because the decompression buffer in RAM is corrupted.

## Root Cause

**DIMM P2-DIMMA1 has an uncorrectable memory error.**

POST shows: `Failing DIMM: DIMM location. (Uncorrectable memory component found) P2-DIMMA1`

The BIOS disables the faulty DIMM, reducing total memory to 16384 MB (1x 16GB DIMM on P1-DIMMA1).
However, the memory controller on CPU2 may still have issues that affect memory access patterns,
or the DIMM is partially disabled but still mapped in certain regions.

## Evidence

| Observation | Implication |
|-------------|-------------|
| POST shows P2-DIMMA1 uncorrectable error | Hardware memory fault |
| Total Memory = 16384 MB (only P1-DIMMA1) | BIOS disabled faulty DIMM |
| `Failed to decompress kernel` on every boot | Memory corruption in decompression buffer |
| Same ISOs work on servers 4 and 5 | Not an ISO/software issue |
| 4 consecutive boot attempts all fail | Not an intermittent/transient issue |
| Iteration 1 install-monitor took 182 min (vs 6-12 min normal) | Previous install plagued by same issue |
| Installed OS GRUB is broken (drops to grub> prompt) | Filesystem corruption during prior install |

## Iteration History

- **Iteration 1**: Completed but took 2+ hours. install-monitor phase took 182 minutes.
  The installation somehow succeeded (lucky memory allocation) but produced a corrupted system.
- **Iteration 2**: Cannot complete. Boot fails deterministically with kernel decompression error.

## Required Action (Physical)

One of the following physical interventions is needed:

1. **Remove DIMM P2-DIMMA1** if physically present
2. **Replace DIMM P2-DIMMA1** with a known-good module
3. **If no DIMM is installed**, the memory controller on CPU2 may be faulty
   - Try reseating CPU2
   - If CPU2 memory controller is bad, consider removing CPU2 entirely
     (server would run single-socket)

## BIOS Workaround (Untested)

If physical access is not immediately available, try:
- BIOS > Advanced > Chipset Configuration > North Bridge > Memory Configuration
- Look for per-DIMM or per-channel disable options
- Disable P2-DIMMA1 channel entirely

## What NOT to Do

- Do NOT attempt further OS installations - they will either fail or produce corrupted systems
- Do NOT use BIOS F3 (Load Optimized Defaults) - this resets all settings
- Do NOT run BMC factory reset - this wipes BMC credentials and network config

## Server Config Reference

| Parameter | Value |
|-----------|-------|
| BMC IP | 10.10.10.26 |
| Static IP | 10.10.10.206 |
| SSH alias | pve6 |
| Config | config/server6.yml |
| Issue | #41 (DIMM P2-DIMMA1 error) |
