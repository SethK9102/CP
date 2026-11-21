# Function reference for debian.sh

This document explains each function in the script and what it is meant to do. The script hardens Debian 12/13, Ubuntu 22.04+ and Linux Mint 21 for CyberPatriot: it audits the system, fixes users, sudo and password policy, removes unwanted packages and backdoors, and locks down services, the firewall and browsers.

## Overview of the script

`main` asks before each step, in this order: `audit`, `repos`, `apt_update`, `users`, `sudo`, `passwords`, `login`, `firewall`, `kernel`, `misc`, `packages`, `services`, `browsers`, `backdoors`, `media`, `files`, `updates`. Each step is a function named `step_<name>`. To run only some steps, name them: `sudo bash cp-linux.sh backdoors` or `sudo bash cp-linux.sh users passwords`. That skips the forensics question and the step prompts.

Run it as root with sudo. `$ME` (you) comes from `SUDO_USER`, so your own account is never deleted or locked. Every change is logged to `/root/cp-log.txt`, and all of `/etc` is backed up to `/root/etc-backup-HHMMSS.tgz` before anything runs.

`source debian.sh` loads the functions without running `main`, which is how single steps are tested.

---

## Helper and general-purpose functions

### log
Prints a timestamped line and appends it to `/root/cp-log.txt`. Every change goes through it, which is what the "Changes this run" summary at the end is built from.

### ask
Asks a yes/no question. Only an answer starting with `y` counts as yes, so pressing Enter always means no.

### hdr
Prints a section header.

### in_list
Checks whether a word is one of the following arguments. Used to compare usernames against the authorized lists.

### installed
Checks whether a package is installed (via `dpkg-query`).

### set_kv
Sets `key value` (or `key = value`) in a config file. If the key is already there, even commented out, the line is replaced; otherwise it is appended. The change is logged. Used for `login.defs`, `pwquality.conf`, `faillock.conf`, `sysctl.conf`, `sshd_config`, `vsftpd.conf`, `php.ini`, the Apache security config and MySQL configs.

### unowned
Filters a list of paths down to the files that do not belong to any installed package. Used to find cron files, systemd units, startup scripts, sudoers files and programs that someone added by hand.

### review_lines
Takes `file:line:text` matches and shows them one at a time, asking whether to comment each line out in place. Lines that are already comments are skipped. Used for cron, rc.local, shell startup files, PAM and sudoers.

### review_files
Shows each file (the first 15 lines of a text file, or its type for a binary) and asks whether to delete it.

### review_units
Shows the key lines (`Exec...`, `On...`, `Listen...`, `User=`) of each systemd unit and asks whether to stop, disable and delete it, then reloads systemd.

---

## README functions

### saved_readme
Finds a README saved from the browser with Ctrl+S: the newest file on a Desktop, in Downloads or in a home folder whose name contains "readme", or any `.htm`/`.html`/`.mhtml` file that contains "Authorized Administrators".

### session_env
Copies the environment (DISPLAY, Wayland, D-Bus...) of a user's running desktop session, so programs started as that user show up on their screen.

### as_user
Runs a command as a user inside their desktop session, using `session_env`. If there is no session, it builds a basic environment (HOME, DISPLAY, XAUTHORITY, XDG_RUNTIME_DIR, D-Bus) instead.

### open_in_browser
Opens a URL in the user's default browser with `xdg-open`, as that user.

### browser_dump
Reads a page through the user's Chromium/Chrome sign-in. It copies only the cookies and `Local State` into a temporary profile, runs the browser headless with `--dump-dom`, prints the page and deletes the copy. This gets past the school's Securly filter, which sends `wget` to a Google sign-in page.

### fetch_readme
Downloads the README page with `wget` (and retries without the certificate check). If a filter or sign-in page answers instead, it tries `browser_dump`, then a saved copy (`saved_readme`). If that fails too, it opens the README in your browser so you can sign in, and tries again when you press Enter. Typing `s` skips the README and you type the users yourself.

### readme_text
Returns the README as plain text. It uses `README=/path` if given. Otherwise it looks for the cached copy `/root/cp-readme.html`, then a saved copy, then the README shortcut on a Desktop. For a `.desktop` shortcut it follows the link (a local file or a web page through `fetch_readme`) and caches a successful download. The HTML is turned into lines: headings start with `== `, tags are removed and entities decoded.

### readme_names
Reads the usernames listed under a heading such as "Authorized Administrators:" or "Authorized Users:". It skips `password:` lines and stops at the first line that does not look like a username.

### readme_groups
Finds README lines like "Create a group called "X" and add ...: a, b, c" and returns each group name with its members (listed after the colon, or one per line below it). `step_users` shows what it found so it can be corrected before the group is created.

### readme_service_text
Returns the README's "Critical Services" section, or the whole README if there is no such section. `step_services` matches against this text.

---

## Steps

### step_audit
Read-only overview, then waits for Enter:
- APT sources, held packages and APT proxy settings
- listening ports
- UID 0 accounts other than root, and system accounts with a login shell
- accounts with empty passwords or weak (MD5/DES) password hashes
- duplicate UIDs, GIDs, user names and group names
- `/etc/hosts` entries
- world-writable files in `/etc`
- enabled services

### step_repos
Shows the current APT source file for the detected distro (Debian, Ubuntu or Mint, including the newer `.sources` format) and the official one it would write, and asks before writing it. The old file is kept as `.bak`. On Debian with `debian.sources` it also offers to comment out leftover entries in `sources.list`, such as a cdrom line.

### step_apt_update
Runs `apt-get update`.

### step_users
Installs sudo if missing. Shows the authorized users and admins read from the README and lets you edit them (you are always included). Then it:
- offers to delete every account with UID 1000 or higher that is not on the list
- offers to delete any other account with UID 0 (a second root). An authorized user with UID 0 is moved to a normal UID instead.
- for accounts in the system range (UID below 1000) that can still log in and are not on the list: delete, lock (no shell, no password) or keep
- offers to create README users that do not exist
- offers to remove anyone who is not a README admin from sudo, admin, wheel, adm, lxd, docker, lpadmin and sambashare, and anyone at all from disk and shadow
- offers to fix accounts whose primary group is one of those groups
- offers to add README admins to sudo
- creates the groups the README asks for, adds their members and offers to remove anyone else. You can also type in groups it missed.
- asks for one new password for all authorized users except you (blank skips this)
- sets password aging for each authorized user: maximum 90 days, minimum 7, warning 14, and the account locks if the password stays expired for 30 days
- asks which accounts must change their password at next login
- offers to lock the root password

### step_sudo
Backs up sudoers to `/root/sudoers-backup.tgz`. It shows risky lines one at a time and offers to comment each out: `NOPASSWD`, `!authenticate`, `Defaults` with `!`, and rules for single users (only `%sudo` should have one). It offers to delete sudoers.d files that no package installed. It adds `Defaults use_pty` and fixes the owner and permissions of `/etc/sudoers`. If `visudo -c` fails afterwards, it restores the backup.

### step_passwords
- `login.defs`: maximum age 90 days, minimum 7, warning 14, SHA512 hashing, UMASK 027
- new accounts lock if their password stays expired for 30 days
- pwquality: minimum length 12, at least one upper case letter, lower case letter, digit and symbol
- faillock: lock for 15 minutes after 5 failed logins, set up through `pam-auth-update`
- PAM: removes `nullok` (empty passwords), remembers the last 5 passwords
- offers to lock accounts that have no password

At the end it tells you to test `su - $ME` in a new terminal before closing the root shell, because a broken PAM setup can lock you out.

### step_login
- LightDM (Mint, Debian MATE): guest login off, autologin commented out
- GDM (Debian GNOME): automatic and timed login off. It also offers to hide the user list on the login screen.
- SDDM (KDE): autologin commented out

### step_firewall
Installs ufw, denies incoming and allows outgoing traffic, turns logging on and enables it. Services kept in `step_services` open their own ports.

### step_kernel
Writes hardened values to `/etc/sysctl.conf` and loads them:
- SYN cookies on
- no IP forwarding, ICMP redirects or source routing
- reverse-path filtering on, and odd ("martian") packets logged
- broadcast pings ignored
- full ASLR
- protected symlinks and hardlinks
- no core dumps from SUID programs

It also fixes the owner and permissions of shadow/gshadow (640), passwd/group (644, including their `-` backups) and sudoers (440), and makes `/tmp` and `/var/tmp` sticky (1777).

### user_gsettings
Runs `gsettings set` as `$ME` inside their D-Bus session. Used by `step_misc` and `step_updates` for desktop settings.

### step_misc
Installs and enables auditd and enables AppArmor. It masks Ctrl-Alt-Del, sets home folders to 750, and turns on the screen lock after 5 minutes idle for Cinnamon, GNOME and MATE. Then it lists files with no owner or group (planted or left over).

### apt_installed_by_hand
Reads the APT history logs and lists packages that were installed by hand (not as dependencies) after the OS was installed, with the date.

### step_packages
- packages from `apt_installed_by_hand`: asks to purge each, never offering the script's own packages (`SELF_PKGS`)
- lists packages added since the OS install, from the installer's package list, for information
- packages installed from a `.deb` file instead of a repo: asks to purge each
- known prohibited packages (`BAD_PKGS`): asks to purge each
- Flatpak apps (system and per-user) and Snap apps (except base and system snaps): asks to remove each
- runs `apt-get autoremove`

### svc_wanted
Decides whether the README needs a service. It is needed if the README names it, for example "ssh" or "apache". If the README only names the kind of service, for example "web server", "FTP" or "database", every service of that kind is needed unless the README names a specific one of them.

### step_services
Shows the README's critical services. For each installed service in `SERVICES`, the default answer is keep when `svc_wanted` says the README needs it, and purge when it does not. Without a README there is no default. Keep runs the matching `harden_*` function and opens its firewall port. Purge removes the package. If the README names a service that is not installed, it says so.

Then it goes through default services that are rarely needed (`EXTRA_SVC`: avahi, cups-browsed, rpcbind, dnsmasq, slapd, the DHCP server and rsync). For each one that is enabled or running it offers to disable it, defaulting to keep when the README mentions it.

### ff_policy
Prints the Firefox `policies.json`: telemetry and studies off, pop-ups blocked, no saved logins, tracking protection, HTTPS-only, and the `FF_PREFS` preferences locked.

### step_browsers
Warns if a browser is still running.
- Chromium/Chrome: offers to delete existing policy files (planted ones can turn off Safe Browsing or force-install extensions), then writes `cp.json` with `CHROME_POLICY` into each managed policy folder.
- Firefox and Firefox ESR: writes `policies.json` (printing and backing up any old one), and writes `user.js` with `FF_PREFS` into every profile.

Check `chrome://policy` and `about:policies` afterwards.

### step_backdoors
Looks for persistence. It asks before commenting out, deleting, changing or killing anything:
- cron: suspicious lines, every user crontab entry, and cron files no package installed. at jobs are only listed (remove them with `atrm`).
- systemd units no package installed, including per-user units
- `rc.local` commands
- shell startup files, autostart entries and NetworkManager dispatcher scripts: suspicious lines and aliases (sudo, su, passwd...), plus startup files no package installed
- PAM backdoors (`pam_exec`, `sufficient pam_permit`) and `/etc/ld.so.preload`
- APT hooks, the commands apt runs on every update or install (`Pre-Invoke`, `Post-Invoke`...), in files no package installed, plus suspicious lines in any APT config
- udev rules that run programs (`RUN`, `PROGRAM`) in files no package installed, plus suspicious lines in any rule
- SSH `authorized_keys` files
- SUID/SGID on programs that can give a shell (`GTFO`) or that no package installed, and dangerous file capabilities
- programs in bin folders that no package installed
- files containing reverse-shell or web shell code (`STRONG`)
- executable or hidden files in temp folders (listed only)
- listening processes that are shells, netcat, scripting languages or telnet, or that run from temp/home folders or deleted files
- processes running from temp folders or deleted files
- optionally, `debsums` to find package files that were changed

If you kill something and it comes back, its autostart is still somewhere, so run the step again.

### step_media
Lists media files (mp3, mp4, wav, mkv, ...) in /home, /root, /srv, /var/www, /opt and /tmp, skipping `/opt/CyberPatriot`, and asks once whether to delete all of them.

### step_files
- Files with passwords or personal data. It matches file names (password, cred, secret, `.kdbx`, ssn, credit, customer, `.pcap`) and file contents (`password:` or `password=`, SSN-shaped and credit-card-shaped numbers).
- Programs disguised as documents, pictures or media: files with those extensions that are really Linux (ELF) programs.

Each file is reviewed with `review_files`, so answer forensics questions about these files first.

### step_updates
- offers to unhold each held package
- installs unattended-upgrades, sets daily update checks, downloads and installs, and enables the security updates origin
- flags `APT::Periodic` settings that turn updates off
- unmasks and enables the APT timers
- turns on automatic updates in GNOME Software and Mint Update Manager
- runs `apt-get full-upgrade`

It reminds you to check the update settings in the GUI too.

### main
Checks it runs as root and asks whether the Forensics Questions are answered (it stops if not). It backs up `/etc`, then asks before each step in order. With step names as arguments it runs just those steps, without the forensics question or the step prompts. At the end it prints the changes from this run and how to restore one file from the backup.

---

## Service hardening functions

These run from `step_services` when you keep a service.

### harden_ssh
No root login, no empty passwords, no X11 forwarding, 3 auth tries, 60-second login grace time, no host-based or rhosts auth, PAM on. If `sshd_config` includes `sshd_config.d`, the same settings also go into `00-cp.conf`, which is read first and wins. Other drop-in files are printed for you to check. It tests the config, restarts SSH and opens port 22.

### harden_vsftpd
No anonymous login, upload or folder creation. Local users on and kept in their home folder (chroot), transfer logging on. It restarts vsftpd and opens port 21.

### harden_php
In every Apache and PHP-FPM `php.ini`: `expose_php`, `display_errors`, `allow_url_include` and `allow_url_fopen` off, and the functions that run commands (`exec`, `system`, `shell_exec`, `passthru`, `proc_open`, `popen`, `pcntl_exec`) disabled. It restarts PHP-FPM.

### harden_apache2
`ServerTokens Prod`, `ServerSignature Off`, `TraceEnable Off`, and directory listings (`Indexes`) removed. It runs `harden_php`, restarts Apache if the config test passes and opens ports 80 and 443.

### harden_nginx
`server_tokens off` and `autoindex off`. It runs `harden_php`, reloads nginx if `nginx -t` passes and opens ports 80 and 443.

### smb_set
Sets one option in the `[global]` section of `/etc/samba/smb.conf`, replacing it if it is already there.

### harden_samba
No guest mapping, `restrict anonymous = 2`, no guest user shares, SMB2 minimum, encryption required, and `guest ok`/`public` turned off on every share. It restarts Samba if `testparm` passes and opens the Samba ports.

### harden_mysql
Offers to bind MySQL/MariaDB to 127.0.0.1 and turns off `local-infile`. It lists the database users and offers to delete anonymous users, remote root logins and the test database, then restarts the server.

---

## Pattern constants and configuration

These are not functions, but the steps rely on them:

- `SUS`: suspicious command patterns (netcat, `/dev/tcp`, `bash -i`, piping downloads into a shell, `LD_PRELOAD`...) for cron, rc.local and startup files
- `STRONG`: reverse shell and web shell code, used to search files
- `GTFO`: programs that can give a root shell when they are SUID
- `BAD_PKGS`: prohibited packages (password crackers, scanners, sniffers, VNC/RDP and TFTP servers, telnet/rsh servers, games including terminal games, torrent and P2P clients)
- `SELF_PKGS`: packages the script installs itself, so `step_packages` never offers them
- `FF_PREFS` / `CHROME_POLICY`: browser settings written by `step_browsers`
- `SERVICES`: the services `step_services` reviews
- `SVC_RE` / `SVC_KIND`: README words for each service and for each kind of service, used by `svc_wanted`
- `EXTRA_SVC`: default services `step_services` offers to disable, with the README words that mean they are needed
- `STEPS`: the steps in the order `main` offers them
- `README_CACHE`: `/root/cp-readme.html`, the saved README

---

## Execution flow summary

1. `main` checks it runs as root and that the forensics questions are done, then backs up `/etc`.
2. `readme_text` reads the README the first time a step needs it, and caches it.
3. Each step runs only if you say yes, and asks again before deleting, purging or killing anything.
4. The log and the `/etc` backup let you undo any change that costs points.
