# Function reference for freebsd.sh

This document explains each function in the script and what it is meant to do. The script hardens FreeBSD 14 and 15 for CyberPatriot: it audits the system, fixes users, passwords and login, turns on the pf firewall and kernel hardening, removes unwanted packages and backdoors, and locks down services and browsers.

## Overview of the script

The script is plain `sh`, because FreeBSD does not come with bash. It downloads with FreeBSD's own `fetch` and edits files with BSD `sed -i ''`.

`main` asks before each step, in this order: `audit`, `repos`, `users`, `sudo`, `passwords`, `login`, `firewall`, `kernel`, `misc`, `packages`, `services`, `browsers`, `backdoors`, `media`, `files`, `updates`. Each step is a function named `step_<name>`.

At start-up the script:
- stops unless it runs as root
- takes step names as arguments to run only those, for example `sh cp-freebsd.sh backdoors`. That skips the forensics question and the step prompts.
- takes `README=/path/to/file` from the environment to use a saved README
- does not run `main` when `CP_NO_MAIN` is set, so `CP_NO_MAIN=1 . ./freebsd.sh` loads the functions for testing

Every change is logged to `/root/cp-log.txt`. `/etc`, `/usr/local/etc` and `/boot/loader.conf` are backed up to `/root/etc-backup-HHMMSS.tgz` before anything runs.

---

## Helper and general-purpose functions

### log
Prints a timestamped line and appends it to `/root/cp-log.txt`. Every change the script makes goes through it, which is what the "Changes this run" summary at the end is built from.

### ask
Asks a yes/no question. Only an answer starting with `y` counts as yes, so pressing Enter always means no.

### prompt
Reads one line of input into a variable, showing a prompt.

### prompt_names
Like `prompt`, for the username lists in `step_users`. A `y`, `yes`, `n` or `no` there is almost always a slip, and would replace the whole list, so it asks again.

### hdr
Prints a section header.

### in_list
Checks whether a word is in a list.

### have_pkg / pkg_installed
`have_pkg` checks whether `pkg` is set up (a fresh FreeBSD has only a stub that offers to install it). `pkg_installed` checks whether one package is installed.

### set_kv
Sets `key value` (or `key=value`) in a config file: it replaces the line if the key is there, even commented out, and adds it otherwise. Used for `sshd_config`, `php.ini`, `vsftpd.conf` and `sysctl.conf`.

### ini_set
Sets a value inside a `[section]` of an INI-style file (`smb4.conf`, `my.cnf`), adding the section if it is missing.

### rc_set
Sets `/etc/rc.conf` variables with `sysrc` and logs them.

### unowned
Filters a list of paths down to the files no installed package owns, using `pkg query '%Fp'`. Planted files are usually unowned, so this keeps the reviews short. On 15 the base system can be installed as packages too, which makes it even more precise.

### review_lines
Takes `file:line:text` matches (from `grep -nH`), drops lines that are already comments, shows each one and asks whether to comment it out. It skips any match without a valid line number, so it can never comment out a whole file.

### review_files
Shows each file (the first 15 lines, or its type if it is binary) and asks whether to delete it.

---

## README functions

### saved_readme
Looks on the Desktops, in Downloads and in home folders for a README the user saved from the browser: a file with "readme" in its name, or an HTML file that contains "Authorized Administrators".

### fetch_readme
Downloads the README with `fetch`, using a browser user agent, and retries without certificate checks if the school filter breaks TLS. If that fails it uses a saved copy, or asks you to save the README with Ctrl+S and press Enter, or type `s` to skip.

### html_text
Turns README HTML into plain text lines: headings start with `== `, list items and line breaks become new lines, tags are removed and common entities decoded.

### readme_text
Finds the README: the `README` variable, the cached copy in `/root/cp-readme.html`, a saved copy, or the README shortcut on a Desktop. A `.desktop` shortcut is followed to its link (a local file or a web page). A downloaded README is cached so later steps don't download it again.

### readme_names
Pulls the usernames listed under a heading such as "Authorized Administrators" or "Authorized Users", skipping `password:` lines and `(you)`.

### readme_groups
Finds README lines like `Create a group called "devs" with members: bob, carol`, including members listed on the lines below. Prints `group|member member`.

### readme_todo
Picks out README lines that ask you to do something (create, install, update, keep, must, should, prohibited, ...), leaving out the standard CyberPatriot boilerplate. `step_audit` prints them as a checklist, because the script does not handle all of them.

### readme_service_text
Returns the README's "Critical Services" section, or the whole README if it has none. `step_services` matches service names against it.

---

## Steps

### step_audit
Read-only overview:
- the pkg repositories
- listening ports (`sockstat`)
- UID 0 accounts besides root. `toor` is FreeBSD's spare root account and is normal while it can't log in.
- system accounts with a login shell, empty passwords, password hashes that are not SHA-512 or bcrypt
- duplicate UIDs, GIDs and names
- members of `wheel`, `operator` and `kmem`
- `/etc/hosts`, world-writable files in `/etc` and `/usr/local/etc`, enabled services
- packages with known vulnerabilities (`pkg audit`)
- the README to-do list from `readme_todo`

It waits for Enter before continuing.

### step_repos
Shows the pkg repositories and warns if the official FreeBSD repo is turned off. It offers to comment out lines that turn off signature checks, point somewhere other than `pkg.FreeBSD.org`, or turn a repo off in `/usr/local/etc/pkg/repos`. It offers to delete repo files there that add repos other than FreeBSD's own, and reviews `pkg.conf` settings that move where pkg looks for repos or keys. The stock files (FreeBSD 15 ships a disabled base repo in `/etc/pkg/FreeBSD.conf` and turns it on in `/usr/local/etc/pkg/repos/FreeBSD.conf`) are not flagged.

### cp_group
Creates a group if you agree, adds the listed members, and offers to remove anyone else in it.

### step_users
Reads the authorized admins and users from the README, lets you correct both lists, and adds you (the user who ran `su` or `sudo`). Then it:
- offers to delete each regular account (UID 1000 and up) that is not authorized
- handles extra UID 0 accounts. An unauthorized one is deleted. An authorized one is given a new UID and its home folder is handed over to it. `toor` is kept, but its password is turned off if it has one.
- finds hidden accounts (system UID under 1000 with a login shell) and offers to delete or lock them
- offers to create README users that are missing
- offers to remove non-admins from `wheel` and `operator`, and everyone but root from `kmem`. On FreeBSD, `wheel` is who may `su` to root.
- fixes accounts whose primary group is `wheel`, and offers to add admins missing from `wheel`
- creates the groups the README asks for (`readme_groups`, then `cp_group`) and asks for more
- sets one new password for all authorized users except you, sets their passwords to expire in 90 days, and can force a change at next login
- offers to set a root password if root has none, because then any `wheel` member can `su` without one

### step_sudo
Backs up the sudoers files, then offers to comment out risky lines: `NOPASSWD`, `!authenticate`, `Defaults` with `!`, and rules for single users instead of `%wheel`. It offers to delete sudoers.d files no package installed, adds `Defaults use_pty`, fixes permissions, and restores the backup if `visudo -c` fails. It reviews `doas.conf` the same way (`nopass`, rules for single users). If neither is installed it says so: admins then use `su`.

### login_conf_set
Sets a capability in the `default` class of `/etc/login.conf`, adding it if it is missing.

### step_passwords
- `/etc/login.conf`: SHA-512 hashes, at least 12 characters, passwords expire after 90 days. `cap_mkdb` rebuilds the database, and the old file comes back if it fails.
- `/etc/pam.d/passwd`: turns on `pam_passwdqc` (12+ characters using 3 kinds of characters)
- removes `nullok` from PAM, so empty passwords don't work
- offers to lock accounts with no password

FreeBSD has no account lockout module in base; `MaxAuthTries` in the SSH hardening limits tries per connection. The step reminds you to test `su -` from a second terminal.

### step_login
- marks the console `insecure` in `/etc/ttys`, so single-user mode asks for the root password
- offers to switch terminals that log someone in automatically (`getty al.*`) back to the normal login prompt
- checks `/etc/gettytab` for `al=` (autologin) in entries other than FreeBSD's own `autologin`/`al.*` ones, and offers to remove it
- turns off guest and autologin in LightDM, SDDM, SLiM and GDM if they are installed

### allow_port
If pf is on, adds a rule to `/etc/pf.conf` that lets one port in and reloads pf. Services kept in `step_services` use it.

### step_firewall
If ipfw is already on, it shows the rules and asks whether to keep it. Otherwise it shows the current `pf.conf`, asks before replacing it (the old one is kept as `pf.conf.bak`), and writes a simple ruleset: block everything coming in, allow everything going out. If sshd is running:
- if someone is logged in over SSH right now, SSH stays allowed without asking, so nobody locks themselves out
- otherwise it asks whether to let SSH in, defaulting to yes if the README mentions SSH and no if it doesn't

It loads the pf module and checks the rules with `pfctl -nf` before turning pf and pflog on.

### step_kernel
- sets the sysctls in `SYSCTLS` now and in `/etc/sysctl.conf`: hide other users' processes, block unprivileged debugging and reading the kernel message buffer, random PIDs, ASLR, no reboot from the keyboard, drop packets to closed ports, ignore redirects and source routing, no forwarding
- `rc.conf`: clear `/tmp` at boot, syslogd without network sockets (restarted so it closes port 514 now), sendmail off, no crash dumps, no routing
- `loader.conf`: no destructive DTrace
- fixes the permissions of `master.passwd`, `passwd`, `group`, the sudo/doas config and `/tmp`

### step_misc
Turns on `auditd`, sets home folders to 750 and `/root` to 700, and lists files that have no owner or group.

### pkg_remove
Removes a package. It checks first what else `pkg delete` would remove (packages that depend on it) and asks again if anything would. Every removal in the script goes through it.

### step_packages
Lists the packages installed on purpose, newest first, and removes the numbers you type. Base system packages (`FreeBSD-*`) are left out. Then it goes through `BAD_PKGS` (hacking tools, remote access, P2P, games), and finally shows what `pkg autoremove` would remove and asks first.

### harden_ssh / harden_ftpd / harden_vsftpd / harden_php / harden_apache / harden_nginx / harden_samba / harden_mysql / harden_inetd
Called by `step_services` for services you keep:
- SSH: no root login, no empty passwords, no X11 forwarding, 3 tries, PAM on. `sshd -t` checks the config before the restart.
- base `ftpd`: offers to delete the `ftp` account (which turns on anonymous FTP) and blocks root in `/etc/ftpusers`
- vsftpd: no anonymous login or uploads, users kept in their home folders, transfer log on
- PHP: `php.ini` from `php.ini-production`, errors hidden, no remote includes, shell functions disabled
- Apache and nginx: no version banner, no directory listings, then PHP, then a config test before the restart
- Samba: no guest access, SMB2 or newer, encryption required, guest shares turned off
- MySQL/MariaDB: optionally local connections only, no `LOAD DATA LOCAL`, then deletes anonymous users, remote root and the test database
- inetd: reviews every service it starts (telnet, ftp, tftp and the r-commands are unsafe)

Each one also opens the service's port in pf.

### svc_keep
Calls the right `harden_*` function for a kept service, or opens its port.

### step_services
Goes through the services in `SVC_LIST` that are enabled. If the README's critical services mention one, the default is keep and harden; otherwise the default is disable. You can also remove the package the service came from. It also tells you when the README seems to need a service that is not enabled, with the commands to turn it on.

### ff_policy
Builds Firefox's `policies.json` from `FF_PREFS`: Safe Browsing on, pop-ups blocked, no saved passwords, tracking protection, HTTPS-only, telemetry off.

### step_browsers
Offers to delete existing Chromium policy files and writes its own (`CHROME_POLICY`), writes Firefox's `policies.json` for every Firefox install, and writes `user.js` into every Firefox profile. Close the browsers first.

### step_backdoors
Looks for ways an attacker could get back in:
- cron: suspicious lines in system cron files, every user crontab entry, and cron.d files no package installed. `at` jobs are listed.
- `rc.conf`, `rc.local`, `periodic.conf` and the rc.d and periodic scripts: suspicious commands, and scripts no package installed
- shell startup files and desktop autostart entries: suspicious lines, aliases for `sudo`/`su`/`passwd`, and autostart entries no package installed
- PAM: `pam_exec` and `sufficient pam_permit` (log in with any password)
- library redirects in `libmap.conf` and `libmap.d`, and `LD_PRELOAD` in `login.conf`
- kernel modules loaded at boot (`loader.conf`, `kld_list`)
- SSH `authorized_keys` files
- SUID/SGID programs that can give a shell (`GTFO`), that are outside system folders, or that no package installed
- programs in `/usr/local/bin` and `/usr/local/sbin` no package installed
- files containing reverse-shell or web shell code in home folders, web roots and temp folders (never the script's own file). In `/etc` and `/usr/local/etc` it offers to comment out the matching lines instead of deleting files, because FreeBSD 14 packages don't own the stock files there.
- executable or hidden files in `/tmp` and `/var/tmp`
- listening processes that are shells, interpreters or `nc`, or that run from temp or home folders; and any process running from those folders. It offers to kill each.
- optionally checks base system files against FreeBSD's official hashes (`freebsd-update IDS`) and installed packages against their checksums (`pkg check -s`). When the base system is installed as packages, `pkg check -s` covers it and the IDS question is skipped.

### step_media
Lists audio and video files in home folders, web roots and temp folders and offers to delete them all.

### step_files
Offers to delete files that look like they hold passwords or personal data (by name, or containing SSNs, card numbers or `password:`; READMEs are left out, because the CyberPatriot README lists passwords), and programs disguised as documents, pictures or media (an ELF header behind a document extension). Answer the forensics questions about them first.

### step_updates
- offers to set up `pkg` if it isn't, and to unlock packages locked against updates
- shows the `freebsd-update` server and key, which should be the official ones
- installs base system updates: with `pkg upgrade` if the base is installed as packages, otherwise with `freebsd-update fetch install`, and adds a daily `freebsd-update cron` to `/etc/crontab`
- offers to upgrade all packages, then shows which still have known vulnerabilities. If `pkg update` fails (a planted or broken repo does that), it tells you to run the repos step first.

If the kernel was updated, reboot.

### main
Checks that it runs as root and that any step names are valid. Without step names it asks whether the Forensics Questions are answered and stops if not. It creates the log, makes the backup, then asks before each step in order (or runs just the named steps). At the end it prints the changes from this run and how to restore a file from the backup.

---

## Pattern constants and configuration

These are not functions, but the steps rely on them:

- `STEPS`: the steps in the order `main` offers them
- `SYSCTLS`: the kernel settings `step_kernel` applies
- `BAD_PKGS`: unwanted packages (hacking tools, remote access, P2P, games)
- `SVC_LIST`: services `step_services` reviews, each with the README words that mean it is needed
- `FF_PREFS` / `CHROME_POLICY`: browser settings
- `SUS`: patterns for suspicious commands in cron, rc and startup files
- `STRONG`: reverse-shell and web shell code patterns
- `GTFO`: programs that can give a shell if they are SUID

---

## Execution flow summary

1. The script checks it runs as root and backs up `/etc`, `/usr/local/etc` and `loader.conf`.
2. `main` confirms the forensics questions are done.
3. `readme_text` finds the README whenever a step needs it.
4. Each step runs only if you say yes, and asks again before deleting or removing anything.
5. The log and the backup let you undo any change that costs points.
