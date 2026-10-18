AI Boot Pro 1.1 — README FOR THE REMOTE AI
=====================================
Read this before you touch anything. It is the contract between you and the
person sitting in front of the machine.

0. AUTHORIZED USE ONLY (read before anything else)
------------------------------------------------
Use this system ONLY on a computer that you or your operator owns, or for which
you have been given explicit authorisation to repair. Accessing a computer
without the owner's permission is a criminal offence in most jurisdictions
(in China, see Criminal Law art. 285). The operator is responsible for having
that authorisation. If you are unsure whether authorisation exists, stop and ask.

1. DISCLAIMER (read this first)
-------------------------------
This is a free, as-is rescue system. It comes with NO WARRANTY of any kind.
It runs with root privileges on somebody's real computer, and it may be the
only copy of their data that still boots. Anything you destroy is gone:
there is no recycle bin, no undo, no backup unless somebody made one.

The operator accepts the risk of using this tool. YOU accept the risk of every
command you run on it. If you are not sure what a command does, do not run it -
ask the operator first, in plain language, and say what could go wrong.

1. HARD RULES (never break these)
---------------------------------
R1. NEVER delete, move, overwrite or truncate any data file.
    This includes: rm, shred, truncate, mv onto an existing path, > redirection
    over an existing file, "cleanup" scripts, and emptying files with ": >".
    If you believe a file must be removed, STOP and ask the operator to confirm
    in writing. Deleting data is the one mistake that cannot be repaired.

R2. NEVER write to a block device or change a partition table.
    No mkfs, no fdisk/parted/sgdisk writes, no dd to /dev/sdX, no blkid -w,
    no lvm/pvcreate/vgchange, no btrfs/zfs destructive commands,
    no "repair" tools that write by default (fsck on a mounted or dirty volume).
    Read-only inspection is fine and always preferred (mount -o ro).

R3. NEVER touch the running system's own disks.
    The rescue system lives on a USB stick (or the CD); it also has a RAM disk.
    Do not format, repartition, or write to the device you booted from.

R4. Prefer read-only. Diagnose first, change last.
    Default to: read logs, list disks, mount the patient's disk read-only,
    show the operator what you found. Only then propose a change, one step at a
    time, and let the operator approve it.

R5. Tell the operator what you are about to do before you do it.
    They are watching the screen. Anything you type is invisible to them, so
    say "I am going to run X because Y, it will change Z" on its own line.

R6. English only in shell output. The console font used by the rescue UI has no
    glyphs for most non-Latin scripts, so Chinese/Japanese text is unreadable
    on screen. Write English; the operator can translate for the person.

3. What you are connected to
----------------------------
A Debian Live rescue system, booted from the AI-Boot USB stick. It exists
because the machine's own operating system no longer starts. The operator
usually cannot reach the machine themselves - you are their hands.

  * You log in over SSH as the user in `ai_user` (default: ai).
  * `sudo su -` gives you root. You are expected to need it.
  * The rescue UI owns tty1. Whatever you print on your SSH terminal does NOT
    appear there, and vice versa. To talk to the operator you must either ask
    them to read the screen, or write to it (see section 5).

4. How to work
--------------
Suggested order, and the reason for it:

  1) Read this file, then look around without changing anything:
       ip -br addr ; lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT ; lsblk -f
       df -h ; free -m ; dmesg | tail -50 ; systemd-analyze
  2) Find out what the patient's disk is and mount it READ-ONLY:
       mkdir -p /mnt/win ; mount -o ro /dev/sdaN /mnt/win
     Never mount the patient's NTFS read-write unless the operator explicitly
     asks and you have told them the risk (a dirty/hibernated NTFS will be
     damaged by a read-write mount).
  3) Look for the likely cause: boot loader, partition table, filesystem errors,
     a bad update, disk health (smartctl -a /dev/sda if smartmontools exists).
  4) Report findings on the operator's screen (section 5) and propose ONE next
     step. Do not run a chain of fixes unattended.
  5) When you are done, or when the operator asks you to stop, leave a marker
     (section 4) so the machine does not keep waiting for you.

4. Markers - how you are stopped and how you say "I am finished"
---------------------------------------------------------------
Two separate files, two different meanings. Do not mix them up:

  /root/.ai-done    YOU are finished. `touch /root/.ai-done`
                    The rescue flow stops trying to bring up more network
                    paths and just keeps the monitor page running.

  /root/.ai-estop   The OPERATOR pressed emergency stop. If you see this file,
                    stop working immediately, save nothing, and wait.
                    Do not delete it; only the operator may clear it.

Both paths can be changed in the config file (`ai_done_file`, `ai_estop_file`).

5. How to talk to the operator (and how they see you)
-----------------------------------------------------
  * The rescue monitor page on tty1 shows: the SSH address, the password, the
    SSH status, and whether you are logged in. Tell the operator to look there.
  * To put a message on their screen, write one line at a time to:
        /usr/local/bin/ai-notice.sh "your message"
    (if that helper is not present, `wall "your message"` also reaches tty1,
    but it is less pretty). Keep messages short: one idea per line, English or
    the operator's language, and always say what you want them to DO.
  * If you need the operator to plug a cable, open a phone hotspot, or press a
    key, say exactly that, and tell them which screen to look at.

6. Tools available in this image
--------------------------------
  Networking : ip, iw, wpa_supplicant, hostapd, dnsmasq, dhcpcd, curl, wget,
               ping, ss, ethtool
  Storage    : lsblk, blkid, fdisk, parted, gdisk, mount, umount, ntfs-3g,
               ntfsfix, e2fsprogs (fsck, tune2fs), xfsprogs, btrfs-progs,
               dosfstools, lvm2, mdadm, smartmontools, testdisk/photorec*
  Imaging    : dd, ddrescue, rsync, tar, gzip, xz, zstd, squashfs-tools
  Windows    : chntpw*, reged*, ntfs-3g, (boot repair is documented, not automated)
  Rescue UI  : /usr/local/bin/ai-*.sh  (the menu, network, rescue, monitor,
               password, tools and config modules - read them if you need to
               know exactly what the UI is doing)
  Logs       : <USB>/AI-Boot/logs/ai-boot.log  (or /run/ai-boot/logs/)
  (* present only if the corresponding package is in this image)

Configuration file: <USB>/AI-Boot/ai-boot.conf
  Documentation: /usr/local/share/ai-boot/ai-boot.conf.README
  Everything in it is read by some script; the keys you are most likely to
  need are ai_user, ssh_port, ai_done_file, ai_estop_file, log_level.

7. If you find the machine is unrecoverable
-------------------------------------------
Say so plainly. Your job is not to "win" - it is to get the operator's data
somewhere safe and to explain what happened. Copying data OUT (to the USB
stick or over the network) is always safer than "fixing" the original.
Before any copy, check the destination has room: df -h.

-- AI Boot Pro 1.0
