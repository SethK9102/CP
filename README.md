# CP

Our team's CyberPatriot hardening scripts.

| Script | For |
| --- | --- |
| [debian.sh](debian.sh) | Debian 12/13, Ubuntu 22.04+, Linux Mint 21 |
| [windows.ps1](windows.ps1) | Windows 10/11 and Windows Server, including domain controllers |
| [freebsd.sh](freebsd.sh) | FreeBSD 14 and 15 |

Answer the Forensics Questions before running a script. Cleaning up can delete what they ask about.

Each script asks `Run step: <name>?` before every step, and asks again before anything it deletes or rewrites (Enter means no). It reads the image's README for the authorized users, admins, groups and critical services, and lets you correct what it found. Every change is logged, so you can undo one if the score drops.

## Linux

```
wget https://gjjb.de/cp-linux.sh
sudo bash cp-linux.sh
```

If the school filter breaks the download with a certificate error, add `--no-check-certificate` to the wget line.

- Log: `/root/cp-log.txt`
- Backup of `/etc`: `/root/etc-backup-HHMMSS.tgz`. Undo one file with `sudo tar xzf <backup> -C / etc/<path>`
- Run one step again: `sudo bash cp-linux.sh backdoors` (no other prompts)
- What each function does: [debian-functions.md](debian-functions.md)

## Windows

In PowerShell as administrator:

```
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
iwr https://gjjb.de/cp-windows.ps1 -OutFile cp-windows.ps1 -UseBasicParsing
powershell -ExecutionPolicy Bypass -File .\cp-windows.ps1
```

If the download fails, open the link in the browser and run the downloaded file instead.

- Log: `C:\cp-log.txt`
- Backups: `C:\cp-backup-HHMMSS`. The undo commands are printed at the end of the run.
- If it can't read the README, open the README, press Ctrl+S to save it to the Desktop, and press Enter.
- Run one step again: add `-Step Backdoors` to the last line (no other prompts)
- What each function does: [windows-functions.md](windows-functions.md)

## FreeBSD

As root (`su -`, or put `sudo` in front of the second line):

```
fetch https://gjjb.de/cp-freebsd.sh
sh cp-freebsd.sh
```

If the school filter breaks the download with a certificate error, add `--no-verify-peer` after `fetch`.

- Log: `/root/cp-log.txt`
- Backup of `/etc`, `/usr/local/etc` and `/boot/loader.conf`: `/root/etc-backup-HHMMSS.tgz`. Undo one file with `tar xzf <backup> -C / etc/<path>`
- If it can't find the README, save it from the browser to the Desktop, or run `README=/path/to/README.html sh cp-freebsd.sh`
- Run one step again: `sh cp-freebsd.sh backdoors` (no other prompts)
- What each function does: [freebsd-functions.md](freebsd-functions.md)

## Changing a script

Test in a container or throwaway VM, never on a competition image. `bash -n debian.sh` catches syntax errors, and `source debian.sh` loads the functions without running anything, so you can call one step. For freebsd.sh that is `sh -n freebsd.sh` and `CP_NO_MAIN=1 . ./freebsd.sh`. Then copy it to gjjb.de so the links above get the new version.
