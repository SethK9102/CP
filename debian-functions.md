# Function reference for debian.sh

This document explains each function defined in the script and what it is meant to do. The script is a Debian/Ubuntu hardening and forensic cleanup utility: it audits the system, removes suspicious items, repairs package sources, hardens common services, enforces user and password policies, and secures browser and OS settings.

## Overview of the script

The script defines a large set of helper functions that work together in a step-based workflow. The main entry point is `main()`, which runs a sequence of specialized hardening steps such as `audit`, `repos`, `users`, `sudo`, `passwords`, `login`, `firewall`, `kernel`, `packages`, `services`, `browsers`, `backdoors`, `media`, `files`, and `updates`.

The explanations below cover every function defined in the script, including the main execution flow and helper routines.

---

## Helper and general-purpose functions

### set_kv
Sets a configuration key in a file. It checks whether the key already exists in a config file; if it does, it replaces the line, otherwise it appends a new line. It also logs the change to the log file. This is used repeatedly throughout the script to enforce secure settings in config files such as `/etc/login.defs`, `/etc/sysctl.conf`, and service configuration files.

### saved_readme
Searches likely directories for a README or HTML file containing the phrase "Authorized Administrators" or a file name with "Readme" in it. It picks the newest relevant file. This helps the script discover the official CyberPatriot README without requiring the user to enter the data manually.

### session_env
Tries to collect the environment variables of a logged-in user session from the process environment of desktop session processes. It searches for processes owned by a user that have `DISPLAY` or `WAYLAND_DISPLAY` set and returns their environment. This is used to run GUI utilities or browser commands in the same session as the user.

### as_user
Executes a command as a target user, preserving a desktop session environment when possible. It uses `runuser` and tries to reuse the current X11/Wayland session environment. If the user has no session, it falls back to a synthetic environment with `HOME`, `USER`, `DISPLAY`, and `XDG_RUNTIME_DIR` values. This is used to run browser and desktop-related actions as the correct user.

### open_in_browser
Opens a URL in the browser of a specific user using `xdg-open`, launched through `as_user`. This is used when the script needs the user to sign in to a protected README or website in a logged-in browser session.

### browser_dump
Copies Chromium/Chrome profile data from a given user and launches the browser in headless mode with the copied profile to dump the DOM of a target URL. This is used to bypass filters or sign-in pages when the script needs to read the CyberPatriot README through the browser session that already has the correct login.

### fetch_readme
Attempts to fetch the README from a URL and validate that it contains the expected content. It tries direct download, a browser dump via Chromium if needed, a saved local README, and user guidance prompting them to sign in in the browser. This is the script’s main mechanism for retrieving the authoritative task instructions.

### readme_text
Loads the README content from a supplied file path or by locating a likely file on the desktop or cache. If the README is a `.desktop` link, it reads the URL and fetches the target page. It strips HTML markup and leaves readable text, then returns the final extracted instructions. This is the source text used for parsing authorized users, admins, and critical services.

### readme_names
Parses user lists from the README text. It looks for headings like “Authorized Administrators” or “Authorized Users,” then extracts valid usernames from the lines underneath while ignoring blank lines, password entries, and non-user-style entries. This generates the `AUTH` and `ADMINS` arrays used in the user-management step.

### readme_service_text
Extracts the “Critical Services” section from the README when present. If that section is missing, it falls back to the whole README text. This gives the script a list of services the README says must remain active, which helps decide whether to keep, remove, or harden services.

### unowned
Compares files from the package database against file paths on disk to find files that are not owned by any installed package. It is used to locate suspicious configuration files, cron entries, startup scripts, and rogue binaries added outside normal package management.

### review_lines
Takes a block of lines with file:line references and shows each suspicious entry. It prompts the user whether to comment out the line in place. This is used for cron jobs, startup scripts, PAM entries, system startup files, and other suspicious config lines that may be malicious.

### review_files
Displays suspicious files and asks whether they should be deleted. It handles missing files safely and works for both text files and binary files. This function is used commonly for rogue binaries, malicious scripts, policy files, and planted backdoors.

### review_units
Displays suspicious systemd unit files, prints their key directives, and asks whether to stop, disable, and delete them. It reloads systemd after cleanup. This helps remove persistence hidden in custom service units.

---

## Audit and inspection steps

### step_audit
Runs a broad system audit and prints key forensic findings. It shows:
- APT sources
- Held packages
- Proxy settings
- Listening ports
- UID 0 accounts
- System accounts with login shells
- Empty passwords
- Weak password hashes
- Duplicate IDs/names
- `/etc/hosts`
- World-writable files in `/etc`
- Enabled systemd services

It pauses so the user can inspect the output before continuing. This step is meant to establish the baseline security state.

### step_backdoors
Looks for common persistence and backdoor mechanisms:
- suspicious cron and at jobs
- custom systemd units
- rc.local commands
- shell startup files
- PAM-based backdoors
- `/etc/ld.so.preload`
- SSH authorized keys
- unexpected SUID/SGID binaries
- dangerous capabilities
- non-package binaries in system directories
- reverse-shell / webshell code patterns
- suspicious running processes and temp-dir executables
- package file tampering via `debsums`

It prompts before removing or killing anything. This is the main persistence-removal and malware hunting stage.

### step_repos
Restores official package repositories based on the detected distro (`ubuntu`, `linuxmint`, or `debian`) and writes the standard apt source configuration back if it has been tampered with. It backs up the old file first and prompts for confirmation. This re-establishes trusted software sources before performing updates.

### step_apt_update
Runs `apt-get update` to refresh the package index and prepare for package installation or security upgrades.

### step_users
Reads the README to parse authorized users/admins and compares them against the system. It prompts the user to confirm or correct the list, creates missing accounts, deletes unauthorized users, manages group memberships, sets passwords, and enforces password aging and lockout settings. It also locks the root password if the user approves.

### step_sudo
Reviews `/etc/sudoers` and `/etc/sudoers.d` for risky entries such as `NOPASSWD`, `!authenticate`, and overly permissive rules. It removes or warns about suspicious sudoers files, enforces `Defaults use_pty`, and validates the config with `visudo`. This prevents privilege escalation and misconfigured sudo rights.

### step_passwords
Configures password policy and lockout settings:
- maximum/minimum password age
- warning period
- hashing method
- UMASK
- inactive account lockout
- PAM quality requirements and history
- failed-login lockout with `pam_faillock`
- no `nullok` password entries
- `remember=5`

It also prints a reminder to test `su - $ME` in a new terminal before continuing.

### step_login
Disables guest sessions and automatic login for the common login managers: LightDM, GDM, and SDDM. For GDM it also optionally hides the user list on the login screen. This reduces unauthorized local access and keeps user identification visible.

### step_firewall
Installs `ufw`, sets default deny rules for incoming traffic, allows outbound traffic, enables logging, and enables the firewall. This restricts network exposure.

### step_kernel
Applies a hardened kernel configuration via `/etc/sysctl.conf` with secure defaults (such as disabling IP forwarding, disabling redirects, enabling TCP syncookies, and turning on ASLR). It corrects ownership and permission bits for sensitive files and ensures `/tmp` is sticky. This is a baseline hardening step for OS-level security.

### user_gsettings
Applies a GNOME/Cinnamon/MATE DConf setting as the active user via `gsettings`. It is a small wrapper for setting desktop security preferences like screen lock, idle time, and update policies. It is used to avoid repeated boilerplate in `step_misc` and `step_updates`.

### step_misc
Installs and enables `auditd` and AppArmor, masks `ctrl-alt-del`, fixes home directory permissions to `750`, and sets common screensaver/idle-lock settings for desktops. It also reports files with no owner or group, which can signal planted or orphaned files. This step strengthens session security and auditing.

### step_packages
Audits installed packages and removes software that is suspicious or prohibited. It:
- removes packages installed by hand after OS installation
- purges non-repo `.deb` installations
- removes known bad tools (e.g., password crackers, network scanners)
- uninstalls flatpak and snap apps that are not needed
- runs autoremove

It uses user confirmation for each item, minimizing accidental deletion of required packages.

### step_services
Evaluates which services should remain installed and active based on the README’s “Critical Services” section. It matches service names to expected requirements and prompts the user to keep, purge, or skip each service. If kept, it invokes the matching hardening function (`harden_ssh`, `harden_apache2`, etc.). This keeps the system lean and valid to the task’s requirements.

### step_media
Finds media files in likely user and service directories, prints them, and asks whether to delete them. It avoids `/opt/CyberPatriot` paths so the script does not delete necessary challenge materials. This helps remove unnecessary or suspicious media content. 

### step_files
Finds files likely containing passwords, secrets, customer information, packet captures, or disguised executables. It also searches for files named like documents or images that are actually ELF executables disguised as harmless files. It prompts before deletion. This is an anti-data-leak and forensics cleanup workflow.

### step_updates
Unholds blocked packages, installs `unattended-upgrades`, enables automatic updates, configures update timers, and runs a full system upgrade. It also checks GUI update settings for Mint/GNOME and prints reminder notes about update managers. This keeps the OS current and prevents stale or vulnerable packages from remaining installed.

### main
The top-level entry point. It checks that the script is being run as root, confirms the user has answered forensics questions, creates a log, backs up `/etc`, and then prompts to run each major step in order. After the selected steps complete, it prints a summary of changes from the log. This is the orchestrator for the whole script.

---

## Security hardening functions

### harden_ssh
Applies secure SSH settings: disables root login, blocks empty passwords, disables X11 forwarding, limits auth retries, shortens login grace time, disables hostbased auth and rhosts, ensures PAM is used, and allows SSH from the firewall. It then validates the config and restarts the service. This hardens the system against brute-force and remote compromise.

### harden_vsftpd
Sets secure VSFTPD defaults: disables anonymous login, disallows upload and write access for anonymous users, enables local users, enforces chroot, enables logging, and restarts the service. It also opens only necessary firewall rules for FTP. This makes file transfer more controlled and less risky.

### harden_php
Edits the PHP INI files to disable dangerous features such as `expose_php`, `display_errors`, `allow_url_include`, `allow_url_fopen`, and dangerous execution functions like `exec`, `system`, and `shell_exec`. It restarts PHP-FPM if present. This reduces the risk of code injection and command execution vulnerabilities.

### harden_apache2
Applies secure Apache settings by disabling version leakage and server signatures, removing directory indexing, and calling `harden_php` to secure PHP behind Apache. It validates the config and restarts Apache. This reduces information disclosure and exploitability in the web server.

### harden_nginx
Disables server version headers and directory autoindexing in Nginx, then invokes `harden_php` to secure PHP if applicable. It validates the nginx config and reloads the service. This reduces web fingerprinting and unsafe file exposure.

### smb_set
A helper for setting Samba config options in `/etc/samba/smb.conf`. It checks if the key already exists and updates it; otherwise, it inserts it in the `[global]` section. This keeps Samba security settings consistent and avoids manual edits.

### harden_samba
Disables guest access, restricts anonymous access, disables guest shares, requires SMB2 or newer, requires SMB encryption, and restarts `smbd` if the configuration validates. This prevents insecure share access and enforces encrypted file transfers.

### harden_mysql
Limits MySQL/MariaDB network exposure by binding to `127.0.0.1` when the user confirms, disables local-infile, and removes anonymous users, remote root logins, and the default test database. This reduces the attack surface of database services.

### ff_policy
Builds a Firefox policy JSON object with several locked settings, including telemetry disablement, popup blocking, tracking protection, HTTPS-only enforcement, and safe browsing preference enforcement. It is used to create browser policy files that prevent users from bypassing security settings.

### step_browsers
Protects Chrome/Chromium and Firefox by writing managed policy files (for example, `cp.json` or `policies.json`) to system or distribution directories, locking in secure browsing settings, and writing `user.js` values for Firefox profiles. It also warns if browsers are still open because active browser sessions could overwrite profile settings. This enforces safer browser configurations.

---

## Service selection and helper routines

### svc_wanted
Determines whether a service is likely required from the README content. It matches the service name and its known configuration patterns against the text extracted from the README. It can also consider grouped services such as Apache/Nginx or database packages. This supports the automated keep/purge decision in `step_services`.

---

## Additional function summaries

### apt_installed_by_hand
Reads historical APT logs to list packages that were installed manually after the operating system was first installed. This lets the script identify packages not part of the baseline and ask whether to remove them.

---

## Pattern constants and configuration arrays

These are not functions, but they are important supporting pieces in the script:

- `SUS`: suspicious command patterns used to detect malicious cron jobs, startup commands, and shell injections.
- `STRONG`: stronger malicious patterns used to find reverse shells and webshell code.
- `GTFO`: suspicious executable names that should be treated as non-standard or risky.
- `BAD_PKGS`: known prohibited packages such as password crackers, scanners, and offensive security tools.
- `SELF_PKGS`: packages the script intentionally keeps because it installs or uses them itself.
- `FF_PREFS`: Firefox preferences to enforce in `user.js`.
- `CHROME_POLICY`: Chrome managed policy values.
- `SERVICES`: list of services the script audits.
- `SVC_RE`: regex patterns for matching services in README text.
- `SVC_KIND`: service family groupings used by `svc_wanted`.

These arrays and regex values support the script’s automated logic but are not functions by themselves.

---

## Execution flow summary

The script’s heart is:

1. `main()` checks permissions and starts the audit.
2. `readme_text()` extracts instructions from the README.
3. The script runs a series of hardening steps, one by one.
4. `step_backdoors()` removes persistence and suspicious files.
5. `step_users()`, `step_sudo()`, and `step_passwords()` lock down identity and privilege management.
6. `step_services()`, `step_browsers()`, and `step_firewall()` secure network and software exposure.
7. `step_updates()` ensures the system stays current.

This makes the script a full-image hardening checklist designed for a CyberPatriot-style challenge environment.
