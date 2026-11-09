# Lab NVMe dropout, 2026-11-08

**Status:** recovered after a reboot. Root cause unknown.

Lab's only NVMe disappeared from the system while a training run was active. The root filesystem went into emergency read-only and writes were lost. The drive came back after a reboot, and SMART shows no media errors, so this looks like the drive or its link dropping out rather than worn or damaged flash. It could happen again.

## Hardware

- **Drive:** Crucial P3 2 TB (`CT2000P3PSSD8`), firmware `P9CR40A`, at PCI `01:00.0`
- **Role:** the only disk. Root (LVM) and `/data` are both on it, with no backups.

## Timeline (CST)

| Time | Event |
|---|---|
| 09:10:49 | Boot that later failed |
| 19:37-19:41 | About 8 GB copied to lab over rsync during training, with no problem |
| 19:41 | Beekeeper run `franka-kitchen-vla2-31` starts on the 3090 |
| 20:50:45 | rsync of 11 GB begins. This is also the last entry saved in that boot's journal |
| 20:52:23 | rsync reports success |
| About 20:52:50 | Beekeeper API calls begin to hang, then return 500 after about 120 s |
| 20:55:12 | First and last recorded ext4 error, 11 errors in all |
| 20:55:17 | `/usr/bin/uptime` fails with `Input/output error` over ssh; `dmesg` fails the same way shortly after |
| 21:01 | Still dead: `nvme0` state `dead`, size 0 |
| 21:05:30 | Reboot. Drive returns and the filesystem mounts after orphan cleanup |
| About 21:05:40 | The queued Beekeeper run auto-starts on Beekeeper's return and is stopped within seconds |
| 21:07:28 | SMART captured (below) |
| 21:10 | 11 GB copied again with no problem, verified by checksum. Training resumes |

The saved journal's end doesn't date the failure, because the journal is buffered before it's written.

## Evidence

While the drive was out:

```text
/sys/class/nvme/nvme0/state               dead
/sys/block/nvme0n1/size                   0
/proc/mounts  /  ext4 rw,relatime,emergency_ro
/sys/fs/ext4/dm-0/errors_count            11
/sys/fs/ext4/dm-0/first_error_func        ext4_journal_check_start
Dirty in /proc/meminfo                    about 2.4 GB, not draining
GPU memory                                1 MiB, 0% on both cards, though the train.py processes still existed
```

The mount line still says `rw`. The `emergency_ro` flag is what counts. `/tmp` is tmpfs, so writing there proves nothing about the disk.

After the reboot: drive `live` at full size, 0 ext4 errors.

## SMART, 21:07:28, after recovery

| Attribute | Value |
|---|---|
| Overall health | PASSED |
| Critical Warning | `0x00` |
| Media and Data Integrity Errors | 0 |
| Available Spare | 100% |
| Percentage Used | 9% |
| Warning / Critical Temperature Time | 0 / 0 |
| Temperature | 43°C (sensor 2: 58°C) |
| Data Written / Read | 44.7 TB / 18.2 TB |
| Power On Hours | 9,960 |
| Power Cycles | 728 |
| Unsafe Shutdowns | 48 |
| Error Information Log Entries | 2,443 |
| Self-tests logged | None |

Only one error log entry was shown: `Invalid Field in Command`, on the admin queue (`SQId 0`). That usually means software sent a command the drive doesn't support rather than a storage fault, but one entry doesn't account for all 2,443. Use these numbers as a baseline if this happens again.

## What was lost

- **Unwritten data:** about 2.4 GB in memory at the time.
- **Training:** run 31, which stopped around step 3700, with checkpoints only through step 3000.
- **Copied demos:** 55 of 197 files in `/data/datasets/franka-kitchen-v2-clean` were 0 bytes after the reboot. rsync had already reported success, so its exit code didn't show this. They were re-copied from the desktop and verified by checksum.

## What we know about the cause

**Ruled out or unlikely:**

- **Flash wear or media damage:** 0 media errors, 100% spare, 9% used.
- **Lifetime overheating:** the drive has never logged time above its 85°C warning threshold. Its temperature at the moment of failure wasn't captured.
- **Full disk:** 32% used.

**Not established. No evidence currently favors any of these:**

- **Power saving on the drive:** APST is available. `nvme_core.default_ps_max_latency_us` is 100000, so deeper power states are allowed.
- **PCIe link or seating.** The AER counters for `01:00.0` were zero when read, but they restart at boot, so they say nothing about the failure.
- **Power delivery** with the GPU under sustained load.
- **Drive firmware or the controller itself.**
- **Write load as a trigger.** The drive stalled within about a minute of an 11 GB rsync on top of training. But an 8 GB copy earlier and the 11 GB re-copy afterward both went fine, so a large copy doesn't reliably cause it.

**Why the logs don't help:** the kernel messages about the dropout were never saved, because the disk was the thing that failed. rasdaemon reports `No disk errors` and `No MCE errors`, but its database is on the same disk, so that isn't good evidence that nothing happened.

## If it happens again

Capture this **before rebooting**, because the kernel log won't survive:

```bash
cat /sys/class/nvme/nvme0/state /sys/block/nvme0n1/size
grep " / " /proc/mounts
sudo bash -c 'while IFS= read -r -t 1 line; do echo "$line"; done < /dev/kmsg' | grep -iE "nvme|i/o error|ext4|aer|pcie" | tail -50
```

`sudo` and `grep` may fail to load. `dmesg` already did. A photo of the screen is fine. Look for lines like `controller is down` or `Removing after probe failure`, as well as any PCIe AER errors.

Then:

- Do a full power-off rather than a reboot, and note whether that made a difference.
- Stop Beekeeper as soon as it boots, because queued runs auto-start.
- Compare SMART against the table above.
- Check for 0-byte files among anything written in the last few minutes.

## Second dropout, 2026-11-08 22:16

The same failure happened again 71 minutes after the 21:05 reboot. It was found the next day at 17:06.

- **Time:** ext4 `first_error_time` was 22:16:15, with 17 errors. `nvme0` was `dead` with size 0, and `/` was `emergency_ro` again.
- **Load:** Beekeeper run 33 alone on the 3090. There was no rsync or other copy, so a large copy is not needed to trigger it.
- **Timing pattern:** both failures came about 70 minutes into a training run. Run 31 started at 19:41 and the drive failed around 20:55, about 74 minutes later. Run 33 started at 21:10 and the drive failed at 22:16, about 66 minutes later. Two cases are too few to call it a pattern, but it points toward heat or sustained load.
- **AER:** all counters for `01:00.0` were 0 since boot, so no PCIe errors were reported before the device went away. Link speed now reads `Unknown` and width `63`, which means the link is down.
- **Kernel log:** lost again. The drive was dead for about 19 hours before anyone checked. journald logs `Read-only file system` every second, and those messages filled the ring buffer and pushed out the NVMe lines. The capture steps above only work within minutes of the failure.
- **Salvage:** files that are still in page cache can be read with `sudo cat` while the drive is dead. Binaries that aren't cached fail with `Input/output error`, including `tar`. This recovered run 33's step 3000 and 4000 checkpoints.

**What this changes:** the drive now fails under training load within about an hour, so lab can't hold an overnight queue. The next run should log the drive's temperature to a different machine every 30 seconds, so a failure shows whether heat came before it.

## Possible follow-ups, not done

- Run `sudo smartctl -t long /dev/nvme0` while idle. No self-test has ever been logged.
- Send logs off the box, for example with netconsole, so kernel messages survive a disk failure.
- Check whether Crucial has newer firmware than `P9CR40A`, and reseat the drive.
- If it drops again, try disabling APST with `nvme_core.default_ps_max_latency_us=0`. Change one thing at a time, so a fix can be attributed.
- `/data` has no backup, and this was a real reminder of that. `restic` is installed but not configured.
