# CP

Our team's CyberPatriot scripts, one per operating system. New scripts are added here as they get finished.

| Script | For | Status |
| --- | --- | --- |
| [debian.sh](debian.sh) | Debian 12/13, Ubuntu 22.04+, Linux Mint 21 | Ready, used in Round 2 (Debian 12) |
| freebsd | FreeBSD | Planned |
| windows-server | Windows Server | Planned |
| windows-desktop | Windows 10/11 | Planned |

Every script should follow the same rules:

- Answer the Forensics Questions before running it. Cleaning up can destroy the evidence they ask about.
- Ask before every change that removes or rewrites something, so nothing the README needs gets deleted by surprise.
- Log every change so it can be undone if the score drops.
- Read the image's README for users and critical services, but let the person running it check and correct what it found.

## debian.sh

Despite the name, it also works on Ubuntu and Linux Mint. It looks at `/etc/os-release` and adjusts.

### Running it

On the image, in a terminal:

```
wget https://raw.githubusercontent.com/SethK9102/CP/main/debian.sh
sudo bash debian.sh
```

If the school web filter breaks the download with a certificate error, add `--no-check-certificate` to the wget line.

The script asks `Run step: <name>? [y/N]` before each step, and asks again before anything destructive inside a step. Press Enter to say no.

- Log of every change: `/root/cp-log.txt` (also printed at the end of the run)
- Backup of all of `/etc` from the start of each run: `/root/etc-backup-HHMMSS.tgz`
- Undo one file: `sudo tar xzf /root/etc-backup-HHMMSS.tgz -C / etc/<path>`
- Function reference: [debian-functions.md](debian-functions.md)

### Steps

| Step | What it does |
| --- | --- |
| audit | Prints apt sources, held packages, listening ports, extra UID 0 accounts, empty or weak passwords, duplicate IDs, /etc/hosts, world-writable files and enabled services. Changes nothing. |
| repos | Rewrites the official apt sources (images often comment them out), including Debian 13's `debian.sources` format. |
| apt_update | `apt-get update` |
| users | Reads authorized users and admins from the README, deletes unauthorized users, creates missing ones, fixes admin groups (sudo, adm, lpadmin, sambashare...), sets passwords and password aging, forces password changes, locks root. |
| sudo | Flags NOPASSWD and other risky sudoers lines and unpackaged sudoers.d files, adds `use_pty`, restores the backup if sudoers stops parsing. |
| passwords | login.defs aging, pwquality (length 12, mixed characters), faillock lockout (5 tries, 15 min), removes `nullok`, password history, offers to lock accounts with no password. |
| login | No guest or automatic login on LightDM (Mint, Debian MATE), GDM (Debian GNOME) and SDDM (KDE). |
| firewall | Installs and enables ufw: deny incoming, allow outgoing. |
| kernel | Hardened sysctl settings; correct permissions on shadow, passwd, group (and their `-` backups), sudoers and /tmp. |
| misc | auditd, AppArmor, Ctrl-Alt-Del off, home folders 750, screen lock for Cinnamon, GNOME and MATE, lists files with no owner. |
| packages | Offers to purge packages installed by hand after the OS, `.deb` installs, known hacking tools and games, Flatpaks and Snaps. Never offers the packages it installs itself. |
| services | Keeps and hardens the services the README lists as critical (SSH, FTP, Apache, nginx, Samba, MySQL/MariaDB...), offers to purge the rest. |
| browsers | Chromium/Chrome and Firefox (including Debian's Firefox ESR) policies: Safe Browsing, pop-up blocking, HTTPS-only, no saved passwords. Flags planted policy files. |
| backdoors | Cron jobs, systemd units, rc.local, shell startup files, PAM backdoors, ld.so.preload, SSH keys, SUID/capabilities, unpackaged programs, reverse-shell code, odd listening processes. Optional debsums check. |
| media | Finds and offers to delete media files (skips the CyberPatriot score sounds). |
| files | Files with passwords or personal data, and programs disguised as documents or pictures. |
| updates | Unattended upgrades on, security updates enabled, apt timers on, unholds held packages, full upgrade. |

### How it reads the README

It finds the README shortcut on the Desktop and downloads the page it points to. The school's Securly filter blocks scripts from downloading it and sends them to a Google sign-in instead. When that happens, the script:

1. Reads the README through Chromium, using the sign-in your browser already has.
2. Otherwise uses a copy saved from the browser with Ctrl+S (Downloads, Desktop or your home folder, any name).
3. Otherwise opens the README in Chromium so you can sign in, then tries again when you press Enter. Type `s` to skip and enter the users yourself.

The README is then kept at `/root/cp-readme.html`, so later steps and runs don't hit the filter again. Always check the users and admins it fills in against the README before pressing Enter.

### Testing changes

Test in a throwaway container before pushing, for example:

```
docker run --rm -it -v "$PWD":/work debian:12 bash
source /work/debian.sh      # loads the functions without running main
step_kernel                 # run a single step
```

`bash -n debian.sh` catches syntax errors. Don't test on a real competition image.

## Adding a script

- Name it after the OS (`freebsd.sh`, `windows-server.ps1`, `windows-desktop.ps1`, ...) and add it to the table at the top.
- Add a function reference like `debian-functions.md` if it's big.
- Keep the rules above: forensics first, ask before destructive changes, log everything.
