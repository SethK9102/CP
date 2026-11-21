# Function reference for windows.ps1

This document explains each function in the script and what it is meant to do. The script hardens Windows 10/11, Windows Server and domain controllers for CyberPatriot: it audits the system, fixes users and policy, removes unwanted software and backdoors, and locks down services, shares, Defender, the firewall, IIS and browsers.

## Overview of the script

`Main` asks before each step, in this order: `Audit`, `Users`, `Policy`, `Rights`, `SecOptions`, `Smb1`, `Shares`, `Defender`, `Firewall`, `IIS`, `Webshells`, `Software`, `Features`, `Services`, `Backdoors`, `Files`, `Browsers`, `Updates`. Each step is a function named `Step-<name>`.

At start-up the script:
- requires an elevated PowerShell (`#Requires -RunAsAdministrator`)
- takes an optional `-Readme <file>` to use a saved README
- turns on TLS 1.2 so downloads work in Windows PowerShell 5.1
- checks whether the machine is a domain controller (`$IsDC`). If it is, it loads the ActiveDirectory module and works on domain accounts and domain policy instead of local ones.

Every change is logged to `C:\cp-log.txt`. Settings are backed up to `C:\cp-backup-HHMMSS` before anything runs.

---

## Helper and general-purpose functions

### Log
Prints a timestamped line in green and appends it to `C:\cp-log.txt`. Every change the script makes goes through it, which is what the "Changes this run" summary at the end is built from.

### Ask
Asks a yes/no question. Only an answer starting with `y` counts as yes, so pressing Enter always means no.

### Hdr / Warn
Print a cyan section header or a yellow warning.

### InList
Case-insensitive check whether a name is in a list. Windows account names are not case-sensitive, so all user comparisons use it.

### Show
Prints objects as a wide table, or `none` when there is nothing to show.

### Try-Do
Runs a block of code with errors turned into exceptions. On success it logs the description; on failure it prints the description with `FAILED` and the error message instead of stopping the script.

### Set-Reg
Creates a registry key if needed and sets one value (DWord unless told otherwise), then logs it. Most settings in the script are applied with this.

### Review-Files
Goes through a list of files and folders one at a time. For a folder it shows the first 10 entries; for a small text-type file (txt, csv, ps1, bat, aspx, php, ...) the first 12 lines; otherwise the size and date. It then asks whether to delete it. If the file is still there afterwards, it says the file is probably in use.

### Get-DataDirs
Returns the top-level folders on `C:\` where people and attackers leave files: everything except Windows, Program Files, ProgramData, the recycle bin, recovery folders and the script's own backups. `C:\Users` is included. Most file searches start from here.

### Get-WebRoots
Returns `C:\inetpub` plus the physical path of every IIS virtual directory.

### Resolve-Sid / Resolve-Name
Turn a SID into an account name and back. Used by the Rights step, because `secedit` exports rights as a mix of SIDs and names.

---

## README functions

### Convert-HtmlToLines
Turns README HTML into plain text lines: drops scripts and styles, turns headings into lines starting with `== `, breaks lines at paragraphs, list items and table cells, removes tags and decodes entities like `&amp;`.

### Find-ReadmeFiles
Lists likely README files, newest first: anything with "readme" in the name or an `.htm`, `.html`, `.mht` or `.mhtml` extension on the Public Desktop and on each user's Desktop and Downloads folder.

### Get-ReadmeLines
Loads the README once and keeps it for later steps. It uses `-Readme` if given. Otherwise it goes through `Find-ReadmeFiles`: for a `.url` shortcut it reads the `file:` target or downloads the web page; other files are read directly. The first one that contains "Authorized" wins. If none works, it asks you to open the README, save it with Ctrl+S, and press Enter to retry. You can also type a file path, or `s` to skip and type the users yourself.

### Get-ReadmeNames
Reads the usernames listed under a heading such as "Authorized Administrators:" or "Authorized Users:". It skips `password:` lines and stops at the first line that does not look like a username.

### Get-ReadmeGroups
Finds README lines like "Create a group called "X" and add the new members of the group: a, b, c" and returns the group name and its members.

### Get-ReadmeTodo
Picks out README lines that ask you to do something (create, install, update, keep, enable, disable, must, should, prohibited, ...), leaving out the standard CyberPatriot boilerplate. The Audit step prints them as a checklist, because the script does not handle all of them.

### Get-ReadmeServiceText
Returns the README's "Critical Services" section, or the whole README if there is no such section. The Services step matches against this text.

---

## Account wrappers

These hide the difference between local accounts and Active Directory, so the Users step works the same way on a workstation and on a domain controller.

### Get-Users
Lists account names, leaving out the built-in ones (Administrator, Guest, DefaultAccount, WDAGUtilityAccount, and krbtgt on a DC) so they are never offered for deletion.

### Get-UserObj
Returns one user object, or nothing if the account does not exist.

### Get-BuiltinUser
Finds a built-in account by the end of its SID (500 = Administrator, 501 = Guest), so it works even if the account was renamed.

### Get-GroupUsers
Lists the user members of a group. If `Get-LocalGroupMember` fails (it breaks when a group contains a deleted account), it falls back to parsing `net localgroup`.

### Add-ToGroup / Remove-FromGroup
Add or remove a group member, locally or in AD.

---

## Installed programs

### Get-Installed
Lists installed programs from the 64-bit, 32-bit and per-user Uninstall registry keys, without system components and updates.

### Uninstall-App
Runs a program's uninstaller: silently through `msiexec /x` for MSI installs, otherwise its own uninstall command, where you may have to click through a window. It then checks whether the program is really gone and offers to delete its leftover install folder.

---

## Steps

### Backup
Runs before the steps. It saves:
- the security policy (`secedit /export`)
- the audit policy
- the firewall configuration
- registry exports of the SMB server and client, LSA, Policies and Winlogon keys
- a list of shares and their permissions
- an IIS configuration backup, if IIS is installed

### Step-Audit
Read-only overview:
- accounts and their password flags. On a DC this includes "password not required", "no Kerberos pre-auth" and service principal names.
- members of the admin and privileged groups, and Remote Desktop Users
- shares, SMB server settings, Defender exclusions and firewall profiles
- programs not made by Microsoft
- the password policy (`net accounts`)
- the README to-do list from `Get-ReadmeTodo`

It waits for Enter before continuing.

### Step-Users
Shows the authorized users and admins read from the README and lets you accept or retype them (you are always included). Then it:
- offers to delete every account not on the list
- asks for one new password for all authorized users except you (blank skips this)
- offers to create README users that do not exist
- offers to remove anyone who is not a README admin from the admin groups (Administrators, plus Domain/Enterprise/Schema Admins on a DC). It never removes the built-in Administrator.
- offers to add README admins who are not administrators
- offers to remove members of privileged groups that are normally empty, such as Backup Operators, Power Users and Remote Management Users, or Account/Server/Print Operators and DnsAdmins on a DC
- creates the groups the README asks for, adds their members and offers to remove anyone else
- lists Remote Desktop Users
- offers to enable authorized accounts that are disabled
- sets passwords. Locally it also makes passwords expire, required and changeable by the user. On a DC it also turns off reversible encryption and turns Kerberos pre-auth back on.
- asks which accounts must change their password at next logon
- disables Guest, and offers to disable the built-in Administrator (not on a DC)

### Set-InfValues
Edits `key = value` lines in a security template (INF) file. Used to write the password policy into the Default Domain Policy.

### Step-Policy
Sets these values without asking again: minimum length 12, complexity on, history 24, minimum age 1 day, maximum age 90 days, no reversible encryption, and lockout after 5 bad tries for 15 minutes.
- Workstation or member server: applied with `secedit /configure`.
- Domain controller: applied with `Set-ADDefaultDomainPasswordPolicy`. It then offers to write the same values into the Default Domain Policy GPO (and raise its version number), so `gpupdate` does not put the old values back.

It also turns on success and failure auditing for every audit category, and forces the detailed audit settings to win over legacy ones.

### Step-Rights
Exports the user rights assignments (secpol.msc > User Rights Assignment) and checks about 30 sensitive rights, such as debug, back up and restore, take ownership, manage the security log, load drivers and act as part of the OS. It asks before removing any of these from a holder:
- regular users and custom groups
- Everyone, Users, Guests, Authenticated Users, Anonymous or Interactive

The changes are written back with `secedit`. Then it prints the "Deny ..." rights with names in place of SIDs, so you can check that Guests are denied network and RDP logon.

On a domain controller, Authenticated Users holding "Add workstations to domain" is the Windows default.

### Step-SecOptions
Sets these registry values without asking again:
- SMB signing required on both the server and client side, no null-session shares, no plain-text passwords to SMB servers
- no blank-password network logons, no LM hashes, NTLMv2 only, 128-bit NTLM session security
- anonymous access restricted: no anonymous listing of accounts or shares, and Everyone does not include Anonymous
- WDigest off (stops plain-text passwords in memory)
- signed, sealed and strong-key Netlogon secure channel
- UAC on, with consent prompts on the secure desktop. Admin Approval Mode applies to the built-in Administrator too, and remote local admins get filtered tokens.
- last username hidden at logon, Ctrl+Alt+Del required, 15-minute inactivity lock
- administrator accounts not listed on elevation, password reveal button off
- autologon off, with an offer to delete a stored plain-text `DefaultPassword`
- Remote Assistance off, AutoPlay and AutoRun off, SmartScreen on, LLMNR off

Some of these need a reboot or log off.

### Step-Smb1
Turns off the SMB1 server protocol and removes SMB1, without asking again:
- the `FS-SMB1` feature on Server
- the `SMB1Protocol` optional feature on Windows 10/11
- the `mrxsmb10` client driver, with the Workstation service's dependencies fixed so it still starts

Finishes after a reboot.

### Get-RegistryShares
Reads shares straight from the registry. Used when the Server service is off, because the share cmdlets fail then.

### Fix-ShareAccess
For each share permission above Read, asks whether to make it Read, delete it, or keep it. Then lets you grant more accounts (for example `BUILTIN\Administrators Full`) and prints the result.

### Step-Shares
Lists every share with its permissions. The default shares (ADMIN$, IPC$, C$, print$, NETLOGON, SYSVOL) are left alone. For every other share you choose keep, remove, or fix permissions. Hidden shares like `Backup$` default to remove. It also looks at the shared folder's NTFS permissions and offers to remove explicit Full/Modify/Write grants to Everyone, Anonymous, Guests, Users, Authenticated Users or Domain Users.

If the Server service is off, it lists the shares saved in the registry (they come back when the service is turned on) and offers to delete them.

### Step-Defender
Asks before:
- deleting Group Policy values that turn Defender off (`Disable...` = 1)
- removing each Defender exclusion, both Group Policy and local: file extensions, paths, processes and IPs. The CyberPatriot folder is always kept.

Then, without asking:
- turns real-time, behavior, download, script, archive, removable drive and email scanning back on
- sets cloud protection to Advanced, sample submission on, potentially unwanted app (PUA) blocking on and network protection on
- starts the Defender service and updates signatures
- prints the status, including tamper protection

It offers a quick scan in the background. If Defender is missing on Server, it says to install it (the Features step offers that).

### Step-Firewall
Starts the firewall service, turns the firewall on for all profiles, blocks inbound by default and logs dropped packets. Then it lists enabled inbound Allow rules that are not part of a built-in Windows rule group (the ones programs or people added), with program, port and profile, and asks whether to disable each one.

### Step-IIS
Skips itself if IIS is not installed. Otherwise, without asking again, it:
- turns directory browsing off at the server level, for every site, and in any `web.config` under the web roots that turns it on (the old file is backed up)
- removes the Server header, blocks double-escaped URLs and shows detailed errors only locally

It asks before switching app pools that run as LocalSystem, LocalService or NetworkService to ApplicationPoolIdentity. If there is an FTP site, it turns off anonymous FTP login. It offers `iisreset` at the end.

### Step-Webshells
Searches the web roots and data folders for ASPX/ASP/ASHX/ASMX/ASCX/CSHTML/PHP/JSP pages containing code that runs commands or loads code (`cmd.exe`, `powershell`, `Process.Start`, `WScript.Shell`, `eval(Request`, `FromBase64String`, `shell_exec`, ...). It prints each matching line and goes through the files with `Review-Files`.

### Step-Software
In four parts:
1. Installed programs matching the unwanted list (hacking tools, remote access, P2P, games, cleaners): asks to uninstall each.
2. Every other program not made by Microsoft, as a numbered list. Type the numbers to uninstall, and skip anything the README needs.
3. Portable tools and files anywhere in the data folders, ProgramData, Program Files and Windows\Temp: hashcat, HFS, netcat, mimikatz, SharpHound/BloodHound, PsExec, Rubeus, LaZagne, keyloggers, `.torrent` files and more. Reviewed with `Review-Files`.
4. Store apps and games such as Solitaire, Candy Crush and Minecraft, for all users: asks to remove each.

### Step-Features
Asks before removing or disabling each of these, so keep anything the README needs:
- Server features: Telnet client/server, TFTP, Simple TCP/IP, PowerShell 2.0, SNMP, IIS FTP and WebDAV. It also offers to install Windows Defender if it is missing.
- Windows capabilities: SNMP, OpenSSH Server, Telnet, TFTP.
- Optional features on Windows 10/11: Telnet, TFTP, Simple TCP/IP, PowerShell 2.0, SNMP, IIS FTP.

### Step-Services
Goes through services that are risky when not needed: IIS, FTP, Remote Desktop, WinRM, Remote Registry, Print Spooler, SNMP, Telnet, Routing/VPN, Internet Connection Sharing, UPnP/SSDP, Simple TCP/IP, File Sharing (Server), Fax, WebDAV, RPC Locator, Mobile Hotspot and Xbox services. Each is matched against the README's critical services. The default answer is keep when the README seems to mention it and disable when it does not. Without a README there is no default.
- Disable stops the service and sets it to Disabled. For Remote Desktop it also blocks RDP connections.
- Keep, for Remote Desktop, requires Network Level Authentication, TLS and high encryption.

Services that are already stopped and disabled are skipped. On a DC the Server service is always kept.

### Mount-UserHives
Loads the registry hive (`NTUSER.DAT`) of every user who is not logged in, so the Backdoors step can check their Run keys too. The hives are unloaded afterwards.

### Step-Backdoors
Looks for persistence and asks before removing each item:
- scheduled tasks outside `\Microsoft\`, plus Microsoft ones whose actions look suspicious (encoded PowerShell, downloads, files in Users/Temp/AppData, netcat, mshta, scripts)
- Run and RunOnce entries for the machine and every user, including the 32-bit and policy Run keys
- a changed Winlogon `Userinit` or `Shell`, and `AppInit_DLLs`
- files in the all-users and per-user Startup folders
- Group Policy startup, shutdown, logon and logoff scripts (their contents are printed)
- Sticky Keys / Utilman backdoors: `Debugger` values under Image File Execution Options, and accessibility programs (sethc, utilman, osk, Magnify, Narrator, ...) that were replaced by another program. These are restored with `sfc /scanfile`.
- services running from odd places or through powershell, cmd, mshta, wscript or netcat. These are stopped and deleted.
- WMI event subscriptions that run commands or scripts, with their filters and bindings
- port forwarding rules (`netsh interface portproxy`)
- entries in the hosts file (it can reset the file to the default)
- listening ports, with the process and path. It flags shells, netcat, scripting languages, programs outside Windows/Program Files and unsigned programs, and offers to kill them.

If you kill something and it comes back, its autostart is still somewhere, so run the step again.

### Step-Files
- Media files (mp3, mp4, wav, mkv, ...) in the data folders: delete all at once, or go through them one by one.
- Files with passwords or personal data. It matches file names (password, cred, secret, `.kdbx`, ssn, credit, customers, `.pcap`, logins) and file contents (`password:` or `password=`, SSN-shaped and credit-card-shaped numbers).
- Programs disguised as documents, pictures or media: files with those extensions that start with the `MZ` header of a Windows program.

AppData and `C:\CyberPatriot` are skipped. Everything is reviewed with `Review-Files`, so answer forensics questions about these files first.

### Step-Browsers
For Chrome and Edge it asks before removing force-installed extensions. Then, without asking again, it sets policies: no password manager, pop-ups blocked, dangerous downloads blocked, third-party cookies blocked, card and address autofill off. Chrome also gets Safe Browsing and HTTPS-only. Edge gets SmartScreen, PUA blocking and no way to click past SmartScreen. For Firefox it writes `distribution\policies.json`, after printing and backing up any existing one. Close the browsers first, and check `chrome://policy`, `edge://policy` and `about:policies`.

### Step-Updates
For Notepad++, WinSCP, Firefox, Chrome, 7-Zip, VLC, PuTTY, FileZilla and Thunderbird, it asks whether to update each one that is installed. It uses winget if it is there. Otherwise it opens the download page and waits while you install. The old and new versions are logged. It can also list and run all other winget upgrades.

For Windows Update it asks before removing a planted update server (WSUS) setting. Then, without asking, it:
- re-enables update access
- sets automatic download and install, every day at 3:00
- un-disables and starts the update services (wuauserv, BITS, UsoSvc, CryptSvc)

It offers to open Windows Update and start a scan.

### Main
Asks whether the Forensics Questions are answered and stops if not. It creates the log, prints whether this is a DC and who you are, runs `Backup`, then asks before each step in order. At the end it prints the changes from this run and how to undo them: `reg import` for registry exports, `secedit /configure` for the policy backup and `netsh advfirewall import` for the firewall.

---

## Pattern constants and configuration

These are not functions, but the steps rely on them:

- `$AdminGroups` / `$PrivGroups`: admin groups and normally-empty privileged groups, different on a DC
- `$PolicyValues`: the password and lockout values used by the Policy step
- `$SensitiveRights` / `$BroadSids`: the rights the Rights step checks, and the accounts that should never hold them
- `$ShellPat`: web shell code patterns
- `$BadApps` / `$BadFiles` / `$BadAppx`: unwanted installed programs, portable tool file names, and Store apps
- `$RiskySvcs`: services the Services step reviews, each with the README words that mean it is needed
- `$FFPolicy`: the Firefox `policies.json`
- `$UpdateMap`: apps the Updates step knows how to update, with their winget ID and download page

---

## Execution flow summary

1. The script checks it is elevated and whether it is on a domain controller.
2. `Main` confirms the forensics questions are done and backs up the current settings.
3. `Get-ReadmeLines` reads the README the first time a step needs it.
4. Each step runs only if you say yes, and asks again before deleting or removing anything.
5. The log and backups let you undo any change that costs points.
