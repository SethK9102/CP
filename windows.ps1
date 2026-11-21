#Requires -RunAsAdministrator

param([string]$Readme, [string[]]$Step)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Log = 'C:\cp-log.txt'
$Bak = "C:\cp-backup-$(Get-Date -Format HHmmss)"
$script:Me = $env:USERNAME
$script:Auth = @()
$script:Admins = @()
$script:ReadmeLines = $null
$script:ReadmeSkipped = $false
$AppCmd = "$env:windir\System32\inetsrv\appcmd.exe"

$IsDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4
if ($IsDC) { Import-Module ActiveDirectory -ErrorAction SilentlyContinue }

if ($IsDC) {
  $AdminGroups = @('Administrators', 'Domain Admins', 'Enterprise Admins', 'Schema Admins')
  $PrivGroups  = @('Account Operators', 'Backup Operators', 'Server Operators', 'Print Operators', 'DnsAdmins', 'Group Policy Creator Owners')
} else {
  $AdminGroups = @('Administrators')
  $PrivGroups  = @('Backup Operators', 'Power Users', 'Hyper-V Administrators', 'Remote Management Users', 'Network Configuration Operators', 'Cryptographic Operators')
}

function Log([string]$m) {
  $l = '[{0}] {1}' -f (Get-Date -Format T), $m
  Write-Host $l -ForegroundColor Green
  Add-Content -Path $Log -Value $l
}
function Ask([string]$q) { (Read-Host "$q [y/N]") -match '^\s*[yY]' }
function Hdr([string]$t) { Write-Host "`n===== $t =====" -ForegroundColor Cyan }
function Warn([string]$t) { Write-Host $t -ForegroundColor Yellow }
function InList($x, $list) { foreach ($y in $list) { if ($x -ieq $y) { return $true } }; return $false }
function Show($x) {
  if ($x) { $x | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
  else { Write-Host '  none' }
}

function Try-Do([string]$what, [scriptblock]$sb) {
  $ErrorActionPreference = 'Stop'
  try { & $sb | Out-Null; Log $what } catch { Warn "$what - FAILED: $($_.Exception.Message)" }
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
  try {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    Log "$Path\$Name = $Value"
  } catch { Warn "Could not set $Path\$Name - $($_.Exception.Message)" }
}

function Review-Files([string[]]$files) {
  $files = @($files | Where-Object { $_ } | Sort-Object -Unique)
  if (-not $files.Count) { Write-Host '  none'; return }
  foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $item = Get-Item -LiteralPath $f -Force
    Write-Host "--- $f" -ForegroundColor White
    if ($item.PSIsContainer) {
      Get-ChildItem -LiteralPath $f -Force -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { Write-Host "  $($_.Name)" }
    } elseif ($item.Length -lt 2MB -and $item.Extension -match '^\.(txt|csv|ini|xml|config|ps1|bat|cmd|vbs|js|json|log|md|aspx?|ashx|asmx|ascx|php|jsp|html?|url)$') {
      Get-Content -LiteralPath $f -TotalCount 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    } else {
      Write-Host ('  {0:N0} bytes, modified {1}' -f $item.Length, $item.LastWriteTime)
    }
    if (Ask "  Delete ${f}?") {
      Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $f) { Warn '  Still there. It may be in use: kill its process or uninstall it first.' }
      else { Log "deleted $f" }
    }
  }
}

function Get-DataDirs {
  $skip = @('Windows', '$Recycle.Bin', 'System Volume Information', 'Recovery', 'Config.Msi', 'PerfLogs',
            '$WinREAgent', '$SysReset', 'Documents and Settings', 'Program Files', 'Program Files (x86)', 'ProgramData')
  @(Get-ChildItem C:\ -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $skip -notcontains $_.Name -and $_.Name -notlike 'cp-backup-*' } | ForEach-Object { $_.FullName })
}

function Get-WebRoots {
  $r = @('C:\inetpub')
  if (Test-Path $AppCmd) {
    $r += @(& $AppCmd list vdir /text:physicalPath 2>$null | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
  }
  @($r | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique)
}

function Resolve-Sid([string]$s) {
  try { (New-Object Security.Principal.SecurityIdentifier($s)).Translate([Security.Principal.NTAccount]).Value } catch { $s }
}
function Resolve-Name([string]$n) {
  try { (New-Object Security.Principal.NTAccount($n)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $null }
}

function Convert-HtmlToLines([string]$raw) {
  $t = $raw -replace '(?is)<(script|style)[^>]*>.*?</\1>', ''
  $t = $t -replace '(?i)<h[1-6][^>]*>', "`n== "
  $t = $t -replace '(?i)<(br|/p|li|/li|/div|/tr|/td|/h[1-6]|pre|/pre)[^>]*>', "`n"
  $t = $t -replace '<[^>]*>', ''
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  @($t -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Find-ReadmeFiles {
  $dirs = @("$env:PUBLIC\Desktop")
  foreach ($u in Get-ChildItem C:\Users -Directory -Force -ErrorAction SilentlyContinue) {
    $dirs += "$($u.FullName)\Desktop"; $dirs += "$($u.FullName)\Downloads"
  }
  Get-ChildItem -Path $dirs -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'readme' -or $_.Extension -match '^\.(html?|mht(ml)?)$' } |
    Sort-Object LastWriteTime -Descending
}

function Get-ReadmeLines {
  if ($script:ReadmeLines) { return $script:ReadmeLines }
  if ($script:ReadmeSkipped) { return @() }
  $raw = $null
  if ($Readme) { $raw = Get-Content -LiteralPath $Readme -Raw -ErrorAction SilentlyContinue }
  while (-not $raw) {
    foreach ($f in Find-ReadmeFiles) {
      $c = $null
      if ($f.Extension -eq '.url') {
        $m = Select-String -LiteralPath $f.FullName -Pattern '^URL=(.+)$' | Select-Object -First 1
        if (-not $m) { continue }
        $url = $m.Matches[0].Groups[1].Value.Trim()
        Write-Host "README: $($f.Name) -> $url"
        if ($url -match '^file:') {
          $c = Get-Content -LiteralPath ([uri]$url).LocalPath -Raw -ErrorAction SilentlyContinue
        } else {
          try { $c = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content }
          catch { Warn "README: download failed: $($_.Exception.Message)" }
        }
      } elseif ($f.Extension -ne '.lnk') {
        $c = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
      }
      if ($c -match 'Authorized') { $raw = $c; Write-Host "README: using $($f.FullName)"; break }
    }
    if ($raw) { break }
    Warn 'README: could not read it. Open the README icon on the Desktop, press Ctrl+S and save it to the Desktop.'
    $a = Read-Host 'README: press Enter to retry, type a file path, or type s to skip and enter users yourself'
    if ($a -match '^\s*s\s*$') { $script:ReadmeSkipped = $true; return @() }
    if ($a -and (Test-Path -LiteralPath $a)) { $raw = Get-Content -LiteralPath $a -Raw }
  }
  $script:ReadmeLines = Convert-HtmlToLines $raw
  $script:ReadmeLines
}

function Get-ReadmeNames($lines, [string]$header) {
  $on = $false
  foreach ($l in $lines) {
    if (-not $on) {
      $i = $l.IndexOf("${header}:", [StringComparison]::OrdinalIgnoreCase)
      if ($i -lt 0) { continue }
      $on = $true
      $l = $l.Substring($i + $header.Length + 1).Trim()
      if (-not $l) { continue }
    }
    if ($l -match '^password') { continue }
    $w = ($l -split '\s+')[0]
    if ($l -match 'Authorized' -or $w -cnotmatch '^[a-z_][a-z0-9_.\-]*$') { break }
    $w
  }
}

function Get-ReadmeGroups($lines) {
  foreach ($l in $lines) {
    if ($l -notmatch '(?i)create (?:a |the )?(?:new )?(?:local |security )?group (?:called|named) [\u201C\u201D"'']?([\w .-]+?)[\u201C\u201D"'']?(?:\s|,|\.|$)') { continue }
    $name = $Matches[1].Trim()
    $members = @()
    if ($l -match ':\s*(.+)$') {
      $members = @($Matches[1] -split ',|\band\b' | ForEach-Object { $_.Trim(' .') } | Where-Object { $_ -cmatch '^[a-z_][a-z0-9_.\-]*$' })
    }
    [pscustomobject]@{ Name = $name; Members = $members }
  }
}

function Get-ReadmeTodo($lines) {
  $lines | Where-Object {
    $_ -match '(?i)\b(create|install|update|up-to-date|keep|enable|disable|default|must|should|not authori[sz]ed|prohibited|remove)\b' -and
    $_ -notmatch '(?i)forensics|unique identifier|scoring report|CCS Client|time zone|Feature Updates|Reset this PC|JavaScript|Malwarebytes|Stop Scoring|home directories|auto-login'
  }
}

function Get-ReadmeServiceText($lines) {
  $on = $false; $out = @()
  foreach ($l in $lines) {
    if (-not $on) {
      if ($l -match '(?i)critical services') {
        $on = $true
        $rest = ($l -replace '(?i).*critical services:?', '').Trim()
        if ($rest) { $out += $rest }
      }
      continue
    }
    if ($l -match '^== ' -or $l -match ':\s*$') { break }
    $out += $l
  }
  if ($out) { $out -join "`n" } else { $lines -join "`n" }
}

function Get-Users {
  if ($IsDC) { Get-ADUser -Filter * | Where-Object { $_.SID.Value -notmatch '-(500|501|502|503)$' } | ForEach-Object { $_.SamAccountName } }
  else { Get-LocalUser | Where-Object { $_.SID.Value -notmatch '-(500|501|503|504)$' } | ForEach-Object { $_.Name } }
}
function Get-UserObj($u) {
  if ($IsDC) { Get-ADUser -Filter "SamAccountName -eq '$u'" } else { Get-LocalUser -Name $u -ErrorAction SilentlyContinue }
}
function Get-BuiltinUser([string]$rid) {
  if ($IsDC) { Get-ADUser -Filter * | Where-Object { $_.SID.Value -match "-$rid`$" } | Select-Object -First 1 }
  else { Get-LocalUser | Where-Object { $_.SID.Value -match "-$rid`$" } | Select-Object -First 1 }
}
function Get-GroupUsers([string]$g) {
  try {
    if ($IsDC) { Get-ADGroupMember -Identity $g -ErrorAction Stop | Where-Object { $_.objectClass -eq 'user' } | ForEach-Object { $_.SamAccountName } }
    else { Get-LocalGroupMember -Group $g -ErrorAction Stop | Where-Object { $_.ObjectClass -eq 'User' } | ForEach-Object { ($_.Name -split '\\')[-1] } }
  } catch {
    if (-not $IsDC) {
      net localgroup "$g" 2>$null | Select-Object -Skip 6 |
        Where-Object { $_ -and $_ -notmatch 'command completed' } | ForEach-Object { ($_ -split '\\')[-1].Trim() }
    }
  }
}
function Remove-FromGroup($u, $g) {
  if ($IsDC) { Remove-ADGroupMember -Identity $g -Members $u -Confirm:$false } else { Remove-LocalGroupMember -Group $g -Member $u }
}
function Add-ToGroup($u, $g) {
  if ($IsDC) { Add-ADGroupMember -Identity $g -Members $u } else { Add-LocalGroupMember -Group $g -Member $u }
}

function Get-Installed {
  $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
  $keys += @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
    ForEach-Object { "Registry::$($_.Name)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" })
  Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName } |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, UninstallString, QuietUninstallString, PSChildName
}

function Uninstall-App($app) {
  $cmd = if ($app.QuietUninstallString) { $app.QuietUninstallString } else { $app.UninstallString }
  if (-not $cmd) { Warn "  No uninstaller registered. Delete $($app.InstallLocation) by hand."; return }
  if ($cmd -match '(?i)msiexec' -and $app.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
    $p = Start-Process msiexec.exe -ArgumentList "/x $($app.PSChildName) /qn /norestart" -Wait -PassThru
  } else {
    Write-Host "  running: $cmd   (click through the uninstaller if a window opens)"
    $p = Start-Process cmd.exe -ArgumentList "/c `"$cmd`"" -Wait -PassThru
  }
  $still = Get-Installed | Where-Object { $_.PSChildName -eq $app.PSChildName }
  if (-not $still) { Log "uninstalled $($app.DisplayName)" }
  else { Warn "  $($app.DisplayName) still listed (exit code $($p.ExitCode)). Finish it in Settings > Apps." }
  if ($app.InstallLocation -and (Test-Path $app.InstallLocation)) {
    if (Ask "  Leftover folder $($app.InstallLocation). Delete it?") {
      Remove-Item -LiteralPath $app.InstallLocation -Recurse -Force -ErrorAction SilentlyContinue; Log "deleted $($app.InstallLocation)"
    }
  }
}

function Backup {
  New-Item -ItemType Directory -Path $Bak -Force | Out-Null
  secedit /export /cfg "$Bak\secpol.inf" /quiet | Out-Null
  auditpol /backup /file:"$Bak\auditpol.csv" | Out-Null
  netsh advfirewall export "$Bak\firewall.wfw" | Out-Null
  foreach ($k in 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer', 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation',
                 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
                 'HKLM\SOFTWARE\Policies', 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon') {
    reg export $k "$Bak\$($k -replace '[\\ ]', '_').reg" /y 2>$null | Out-Null
  }
  Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Path = $_.Path
      Access = (Get-SmbShareAccess -Name $_.Name -ErrorAction SilentlyContinue | ForEach-Object { "$($_.AccountName)=$($_.AccessControlType)/$($_.AccessRight)" }) -join '; ' }
  } | Export-Csv "$Bak\shares.csv" -NoTypeInformation
  if (Test-Path $AppCmd) { & $AppCmd add backup "cp-$(Get-Date -Format HHmmss)" | Out-Null }
  Log "backed up settings to $Bak"
}

function Step-Audit {
  Hdr 'Accounts'
  if ($IsDC) {
    Show (Get-ADUser -Filter * -Properties PasswordNeverExpires, PasswordNotRequired, DoesNotRequirePreAuth, LastLogonDate, ServicePrincipalName |
      Select-Object SamAccountName, Enabled, PasswordNeverExpires, PasswordNotRequired, DoesNotRequirePreAuth, LastLogonDate,
        @{ n = 'SPN'; e = { $_.ServicePrincipalName -join ',' } })
  } else {
    Show (Get-LocalUser | Select-Object Name, Enabled, PasswordRequired, PasswordExpires, UserMayChangePassword, LastLogon, Description)
  }
  Hdr 'Admin and privileged groups'
  foreach ($g in @($AdminGroups) + @($PrivGroups) + @('Remote Desktop Users')) {
    $m = @(Get-GroupUsers $g)
    if ($m.Count) { Write-Host ('{0,-30} {1}' -f $g, ($m -join ', ')) }
  }
  Hdr 'Shares'
  try { Show (Get-SmbShare -ErrorAction Stop | Select-Object Name, Path, Description) }
  catch { Show (Get-RegistryShares) ; Warn '  (Server service is off: shares read from the registry)' }
  Hdr 'SMB server settings'
  try { Show (Get-SmbServerConfiguration -ErrorAction Stop | Select-Object EnableSMB1Protocol, RequireSecuritySignature, EnableSecuritySignature, EncryptData) }
  catch { Warn '  Server service is off.' }
  Hdr 'Defender exclusions'
  try {
    $mp = Get-MpPreference -ErrorAction Stop
    foreach ($k in 'ExclusionExtension', 'ExclusionPath', 'ExclusionProcess') { Write-Host ('{0,-20} {1}' -f $k, (@($mp.$k) -join ', ')) }
  } catch { Warn '  Defender not available.' }
  Hdr 'Firewall'
  Show (Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction)
  Hdr 'Installed programs (not Microsoft)'
  Show (Get-Installed | Where-Object { $_.Publisher -notmatch 'Microsoft' } | Sort-Object DisplayName -Unique |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate)
  Hdr 'Password policy'
  net accounts | Write-Host
  $todo = @(Get-ReadmeTodo @(Get-ReadmeLines))
  if ($todo.Count) {
    Hdr 'README instructions to check off (the script does not do all of these)'
    $todo | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
  }
  Read-Host 'Press Enter to continue' | Out-Null
}

function Step-Users {
  Hdr "Users ($(if ($IsDC) { 'Active Directory' } else { 'local accounts' }))"
  $lines = @(Get-ReadmeLines)
  $admins = @(Get-ReadmeNames $lines 'Authorized Administrators')
  $users = @(Get-ReadmeNames $lines 'Authorized Users')
  if ($admins.Count + $users.Count) { Write-Host 'Parsed from README. Check against the README and retype if wrong.' }
  else { Warn 'Could not read README users. Type them in.' }
  Write-Host "  admins: $($admins -join ' ')"
  Write-Host "  users : $($users -join ' ')"
  Write-Host 'Also include any account the README tells you to create.'
  $a = Read-Host 'Enter = use the lists above, or type ALL authorized usernames (admins too), space-separated'
  $all = if ($a.Trim()) { @($a.Trim() -split '\s+') } else { @($admins) + @($users) }
  $b = Read-Host 'Enter = use README admins, or type the admins'
  if ($b.Trim()) { $admins = @($b.Trim() -split '\s+') }
  if (-not $all.Count) { Warn 'No users entered, skipping.'; return }
  $script:Auth = @(@($all) + $script:Me | Sort-Object -Unique)
  $script:Admins = @(@($admins) + $script:Me | Sort-Object -Unique)
  $builtinAdmin = (Get-BuiltinUser 500)
  $builtinName = if ($IsDC) { $builtinAdmin.SamAccountName } else { $builtinAdmin.Name }

  foreach ($u in @(Get-Users)) {
    if (InList $u $script:Auth) { continue }
    if (Ask "Delete unauthorized user '$u'?") {
      Try-Do "deleted user $u" { if ($IsDC) { Remove-ADUser -Identity $u -Confirm:$false } else { Remove-LocalUser -Name $u } }
    }
  }

  $pw = Read-Host 'New password for all authorized users except you (blank = skip)' -AsSecureString
  $setPw = $pw.Length -gt 0

  foreach ($u in $script:Auth) {
    if (Get-UserObj $u) { continue }
    if (-not (Ask "README user '$u' does not exist. Create it?")) { continue }
    $p = if ($setPw) { $pw } else { Read-Host "  Password for $u" -AsSecureString }
    if ($IsDC) { Try-Do "created user $u" { New-ADUser -Name $u -SamAccountName $u -AccountPassword $p -Enabled $true } }
    else { Try-Do "created user $u" { New-LocalUser -Name $u -Password $p; Add-LocalGroupMember -Group 'Users' -Member $u } }
  }

  foreach ($g in $AdminGroups) {
    foreach ($u in @(Get-GroupUsers $g)) {
      if ((InList $u $script:Admins) -or $u -ieq $builtinName) { continue }
      if (Ask "'$u' is in $g but is not a README admin. Remove from ${g}?") { Try-Do "removed $u from $g" { Remove-FromGroup $u $g } }
    }
  }
  $mainAdmin = if ($IsDC) { 'Domain Admins' } else { 'Administrators' }
  foreach ($u in $script:Admins) {
    if (-not (Get-UserObj $u)) { continue }
    $isAdmin = $false
    foreach ($g in $AdminGroups) { if (InList $u @(Get-GroupUsers $g)) { $isAdmin = $true } }
    if (-not $isAdmin -and (Ask "README admin '$u' is not an administrator. Add to ${mainAdmin}?")) {
      Try-Do "added $u to $mainAdmin" { Add-ToGroup $u $mainAdmin }
    }
  }
  foreach ($g in $PrivGroups) {
    foreach ($u in @(Get-GroupUsers $g)) {
      if ($u -ieq $builtinName) { continue }
      if (Ask "'$u' is in privileged group $g (normally empty). Remove?") { Try-Do "removed $u from $g" { Remove-FromGroup $u $g } }
    }
  }
  foreach ($rg in @(Get-ReadmeGroups $lines)) {
    $exists = if ($IsDC) { [bool](Get-ADGroup -Filter "Name -eq '$($rg.Name)'" -ErrorAction SilentlyContinue) }
              else { [bool](Get-LocalGroup -Name $rg.Name -ErrorAction SilentlyContinue) }
    Write-Host "README group '$($rg.Name)' with members: $($rg.Members -join ', ')"
    if (-not $exists -and (Ask "  Create group '$($rg.Name)'?")) {
      Try-Do "created group $($rg.Name)" { if ($IsDC) { New-ADGroup -Name $rg.Name -GroupScope Global } else { New-LocalGroup -Name $rg.Name } }
    }
    $have = @(Get-GroupUsers $rg.Name)
    foreach ($m in $rg.Members) {
      if (InList $m $have) { continue }
      Try-Do "added $m to $($rg.Name)" { Add-ToGroup $m $rg.Name }
    }
    foreach ($m in $have) {
      if (-not (InList $m $rg.Members) -and (Ask "  '$m' is in $($rg.Name) but the README does not list them. Remove?")) {
        Try-Do "removed $m from $($rg.Name)" { Remove-FromGroup $m $rg.Name }
      }
    }
  }

  $rdp = @(Get-GroupUsers 'Remote Desktop Users')
  if ($rdp.Count) { Write-Host "Remote Desktop Users: $($rdp -join ', ')  (fine only if the README wants them to use RDP)" }

  foreach ($u in $script:Auth) {
    $o = Get-UserObj $u
    if (-not $o) { continue }
    if (-not $o.Enabled -and (Ask "Authorized user '$u' is disabled. Enable?")) {
      Try-Do "enabled $u" { if ($IsDC) { Enable-ADAccount -Identity $u } else { Enable-LocalUser -Name $u } }
    }
    if ($IsDC) {
      if ($setPw -and $u -ne $script:Me) { Try-Do "password set: $u" { Set-ADAccountPassword -Identity $u -Reset -NewPassword $pw } }
      Try-Do "$u - password expires, password required, no reversible encryption, Kerberos pre-auth on" {
        Set-ADUser -Identity $u -PasswordNeverExpires $false -PasswordNotRequired $false -AllowReversiblePasswordEncryption $false -CannotChangePassword $false
        Set-ADAccountControl -Identity $u -DoesNotRequirePreAuth $false
      }
    } else {
      if ($setPw -and $u -ne $script:Me) { Try-Do "password set: $u" { Set-LocalUser -Name $u -Password $pw } }
      Try-Do "$u - password expires, user may change it, password required" {
        Set-LocalUser -Name $u -PasswordNeverExpires $false -UserMayChangePassword $true
        net user $u /passwordreq:yes | Out-Null
      }
    }
  }
  $chg = Read-Host 'Accounts that must change password at next logon (space-separated, blank = none)'
  foreach ($u in ($chg -split '\s+' | Where-Object { $_ })) {
    if ($IsDC) { Try-Do "must change password: $u" { Set-ADUser -Identity $u -ChangePasswordAtLogon $true } }
    else { Try-Do "must change password: $u" { net user $u /logonpasswordchg:yes | Out-Null } }
  }

  $guest = Get-BuiltinUser 501
  if ($guest -and $guest.Enabled) {
    Try-Do 'Guest account disabled' { if ($IsDC) { Disable-ADAccount -Identity $guest } else { Disable-LocalUser -SID $guest.SID } }
  }
  if (-not $IsDC -and $builtinAdmin.Enabled -and $builtinName -ne $script:Me -and
      (Ask "Disable the built-in '$builtinName' account? (only if nobody logs in with it)")) {
    Try-Do "disabled $builtinName" { Disable-LocalUser -SID $builtinAdmin.SID }
  }
}

$PolicyValues = [ordered]@{
  MinimumPasswordLength = 12; PasswordComplexity = 1; PasswordHistorySize = 24; MinimumPasswordAge = 1
  MaximumPasswordAge = 90; ClearTextPassword = 0; LockoutBadCount = 5; ResetLockoutCount = 15; LockoutDuration = 15
}

function Set-InfValues([string]$path, $vals, [string]$section = 'System Access') {
  $lines = [System.Collections.Generic.List[string]]@(Get-Content -LiteralPath $path)
  foreach ($k in $vals.Keys) {
    $i = -1
    for ($j = 0; $j -lt $lines.Count; $j++) { if ($lines[$j] -match "^\s*$k\s*=") { $i = $j; break } }
    if ($i -ge 0) { $lines[$i] = "$k = $($vals[$k])" }
    else {
      $s = $lines.IndexOf("[$section]")
      if ($s -lt 0) { $lines.Add("[$section]"); $s = $lines.Count - 1 }
      $lines.Insert($s + 1, "$k = $($vals[$k])")
    }
  }
  Set-Content -LiteralPath $path -Value $lines -Encoding Unicode
}

function Step-Policy {
  Hdr 'Password + lockout policy'
  if ($IsDC) {
    Try-Do 'domain password policy: min 12, complexity, history 24, age 1-90 days, lockout 5 tries / 15 min' {
      Set-ADDefaultDomainPasswordPolicy -Identity (Get-ADDomain).DistinguishedName -MinPasswordLength 12 -ComplexityEnabled $true `
        -PasswordHistoryCount 24 -MinPasswordAge '1.00:00:00' -MaxPasswordAge '90.00:00:00' -LockoutThreshold 5 `
        -LockoutDuration '00:15:00' -LockoutObservationWindow '00:15:00' -ReversibleEncryptionEnabled $false
    }
    Get-ADDefaultDomainPasswordPolicy | Out-String | Write-Host
    $dom = (Get-ADDomain).DNSRoot
    $gpo = "\\$dom\SYSVOL\$dom\Policies\{31B2F340-016D-11D2-945F-00C04FB984F9}"
    $tmpl = "$gpo\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
    if (Test-Path $tmpl) {
      Write-Host 'Default Domain Policy GPO currently says:'
      Get-Content $tmpl | Where-Object { $_ -match 'Password|Lockout' } | ForEach-Object { Write-Host "  $_" }
      if (Ask 'Write the same values into the Default Domain Policy GPO (so gpupdate keeps them)?') {
        Copy-Item $tmpl "$Bak\GptTmpl.inf"
        Set-InfValues $tmpl $PolicyValues
        $dn = "CN={31B2F340-016D-11D2-945F-00C04FB984F9},CN=Policies,CN=System,$((Get-ADDomain).DistinguishedName)"
        $ver = [int](Get-ADObject $dn -Properties versionNumber).versionNumber + 1
        Set-ADObject $dn -Replace @{ versionNumber = $ver }
        (Get-Content "$gpo\GPT.INI") -replace '^Version=\d+', "Version=$ver" | Set-Content "$gpo\GPT.INI" -Encoding ASCII
        gpupdate /target:computer /force | Out-Null
        Log 'Default Domain Policy GPO updated with the password + lockout values'
      }
    }
  } else {
    $inf = "$env:TEMP\cp-secpol.inf"
    $body = "[Unicode]`r`nUnicode=yes`r`n[System Access]`r`n"
    foreach ($k in $PolicyValues.Keys) { $body += "$k = $($PolicyValues[$k])`r`n" }
    $body += "[Version]`r`nsignature=`"`$CHICAGO`$`"`r`nRevision=1`r`n"
    Set-Content -Path $inf -Value $body -Encoding Unicode
    secedit /configure /db "$env:TEMP\cp-secpol.sdb" /cfg $inf /areas SECURITYPOLICY /quiet | Out-Null
    if ($LASTEXITCODE -eq 0) { Log 'local policy: min length 12, complexity, history 24, age 1-90 days, no reversible encryption, lockout 5 / 15 min' }
    else { Warn "secedit returned $LASTEXITCODE. See $env:windir\security\logs\scesrv.log" }
    net accounts | Write-Host
  }
  Hdr 'Audit policy'
  auditpol /set /category:* /success:enable /failure:enable | Out-Null
  if ($LASTEXITCODE -eq 0) { Log 'audit policy: success + failure for every category' }
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' SCENoApplyLegacyAuditPolicy 1
}

$SensitiveRights = [ordered]@{
  SeTcbPrivilege = 'Act as part of the operating system'; SeDebugPrivilege = 'Debug programs'
  SeBackupPrivilege = 'Back up files and directories'; SeRestorePrivilege = 'Restore files and directories'
  SeTakeOwnershipPrivilege = 'Take ownership of files or other objects'; SeSecurityPrivilege = 'Manage auditing and security log'
  SeLoadDriverPrivilege = 'Load and unload device drivers'; SeCreateTokenPrivilege = 'Create a token object'
  SeAssignPrimaryTokenPrivilege = 'Replace a process level token'; SeSystemEnvironmentPrivilege = 'Modify firmware environment values'
  SeManageVolumePrivilege = 'Perform volume maintenance tasks'; SeTrustedCredManAccessPrivilege = 'Access Credential Manager as a trusted caller'
  SeCreatePermanentPrivilege = 'Create permanent shared objects'; SeLockMemoryPrivilege = 'Lock pages in memory'
  SeEnableDelegationPrivilege = 'Enable accounts to be trusted for delegation'; SeImpersonatePrivilege = 'Impersonate a client after authentication'
  SeCreateGlobalPrivilege = 'Create global objects'; SeRemoteShutdownPrivilege = 'Force shutdown from a remote system'
  SeSystemtimePrivilege = 'Change the system time'; SeCreateSymbolicLinkPrivilege = 'Create symbolic links'
  SeIncreaseQuotaPrivilege = 'Adjust memory quotas for a process'; SeCreatePagefilePrivilege = 'Create a pagefile'
  SeProfileSingleProcessPrivilege = 'Profile single process'; SeSystemProfilePrivilege = 'Profile system performance'
  SeIncreaseBasePriorityPrivilege = 'Increase scheduling priority'; SeRelabelPrivilege = 'Modify an object label'
  SeSyncAgentPrivilege = 'Synchronize directory service data'; SeMachineAccountPrivilege = 'Add workstations to domain'
}

$BroadSids = '^(S-1-5-21-.*|S-1-1-0|S-1-5-32-545|S-1-5-32-546|S-1-5-11|S-1-5-7|S-1-5-4)$'

function Step-Rights {
  Hdr 'User rights assignments (secpol.msc > Local Policies > User Rights Assignment)'
  $inf = "$env:TEMP\cp-rights.inf"
  secedit /export /cfg $inf /areas USER_RIGHTS /quiet | Out-Null
  Copy-Item $inf "$Bak\rights-before.inf" -ErrorAction SilentlyContinue
  $changed = [ordered]@{}
  $found = $false
  foreach ($line in Get-Content $inf) {
    if ($line -notmatch '^\s*(Se\w+)\s*=\s*(.*)$') { continue }
    $right = $Matches[1]; $vals = @($Matches[2] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $SensitiveRights.Contains($right)) { continue }
    $keep = @()
    foreach ($v in $vals) {
      $sid = if ($v.StartsWith('*')) { $v.Substring(1) } else { Resolve-Name $v }
      $name = if ($v.StartsWith('*')) { Resolve-Sid $sid } else { $v }
      if ($sid -and $sid -match $BroadSids) {
        $found = $true
        if (Ask "'$name' has '$($SensitiveRights[$right])' ($right). Remove it?") { continue }
      }
      $keep += $v
    }
    if ($keep.Count -ne $vals.Count) { $changed[$right] = $keep -join ',' }
  }
  if (-not $found) { Write-Host '  No regular users or broad groups hold sensitive rights.' }
  if ($changed.Count) {
    $body = "[Unicode]`r`nUnicode=yes`r`n[Version]`r`nsignature=`"`$CHICAGO`$`"`r`nRevision=1`r`n[Privilege Rights]`r`n"
    foreach ($k in $changed.Keys) { $body += "$k = $($changed[$k])`r`n" }
    Set-Content -Path $inf -Value $body -Encoding Unicode
    secedit /configure /db "$env:TEMP\cp-rights.sdb" /cfg $inf /areas USER_RIGHTS /quiet | Out-Null
    if ($LASTEXITCODE -eq 0) { foreach ($k in $changed.Keys) { Log "user right $k now: $($changed[$k])" } }
    else { Warn "secedit returned $LASTEXITCODE. Fix these in secpol.msc instead." }
  }
  Write-Host 'Deny rights worth a glance (Guests should be denied network/RDP logon):'
  secedit /export /cfg $inf /areas USER_RIGHTS /quiet | Out-Null
  Get-Content $inf | Where-Object { $_ -match '^SeDeny' } | ForEach-Object {
    $l = $_
    foreach ($m in [regex]::Matches($_, '\*(S-[\d-]+)')) { $l = $l.Replace($m.Value, (Resolve-Sid $m.Groups[1].Value)) }
    Write-Host "  $l"
  }
}

function Step-SecOptions {
  Hdr 'Security options'
  $srv = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
  $wks = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
  $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
  $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  $nl  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
  $wl  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

  Set-Reg $srv RequireSecuritySignature 1; Set-Reg $srv EnableSecuritySignature 1; Set-Reg $srv RestrictNullSessAccess 1
  Set-Reg $wks RequireSecuritySignature 1; Set-Reg $wks EnableSecuritySignature 1; Set-Reg $wks EnablePlainTextPassword 0
  Try-Do 'SMB signing required (server + client)' {
    Set-SmbServerConfiguration -RequireSecuritySignature $true -EnableSecuritySignature $true -Force
    Set-SmbClientConfiguration -RequireSecuritySignature $true -EnableSecuritySignature $true -Force
  }

  Set-Reg $lsa LimitBlankPasswordUse 1; Set-Reg $lsa NoLMHash 1; Set-Reg $lsa LmCompatibilityLevel 5
  Set-Reg $lsa RestrictAnonymous 1; Set-Reg $lsa RestrictAnonymousSAM 1; Set-Reg $lsa EveryoneIncludesAnonymous 0
  Set-Reg "$lsa\MSV1_0" NTLMMinClientSec 537395200; Set-Reg "$lsa\MSV1_0" NTLMMinServerSec 537395200
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' UseLogonCredential 0

  Set-Reg $nl RequireSignOrSeal 1; Set-Reg $nl SealSecureChannel 1; Set-Reg $nl SignSecureChannel 1; Set-Reg $nl RequireStrongKey 1

  Set-Reg $sys EnableLUA 1; Set-Reg $sys ConsentPromptBehaviorAdmin 2; Set-Reg $sys PromptOnSecureDesktop 1
  Set-Reg $sys EnableInstallerDetection 1; Set-Reg $sys EnableVirtualization 1; Set-Reg $sys FilterAdministratorToken 1
  Set-Reg $sys LocalAccountTokenFilterPolicy 0; Set-Reg $sys DontDisplayLastUserName 1; Set-Reg $sys DisableCAD 0
  Set-Reg $sys InactivityTimeoutSecs 900
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\CredUI' EnumerateAdministrators 0
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\CredUI' DisablePasswordReveal 1

  $w = Get-ItemProperty $wl
  if ($w.DefaultPassword) {
    Warn "Winlogon stores a plain-text DefaultPassword (user $($w.DefaultUserName))."
    if (Ask 'Delete it?') { Remove-ItemProperty $wl -Name DefaultPassword; Log 'removed Winlogon DefaultPassword' }
  }
  Set-Reg $wl AutoAdminLogon '0' String

  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' fAllowToGetHelp 0
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' NoDriveTypeAutoRun 255
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' NoAutorun 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' EnableSmartScreen 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' ShellSmartScreenLevel 'Block' String
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' EnableMulticast 0
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\LDAP' LDAPClientIntegrity 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' EnableScriptBlockLogging 1
  [string[]]$pipes = @()
  if ($IsDC) { $pipes = 'netlogon', 'samr', 'lsarpc' }
  $pipeText = if ($pipes.Count) { $pipes -join ', ' } else { 'none' }
  Try-Do "anonymous access: no shares, named pipes $pipeText" {
    $k = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    [Microsoft.Win32.Registry]::SetValue($k, 'NullSessionShares', [string[]]@(), [Microsoft.Win32.RegistryValueKind]::MultiString)
    [Microsoft.Win32.Registry]::SetValue($k, 'NullSessionPipes', $pipes, [Microsoft.Win32.RegistryValueKind]::MultiString)
  }
  Warn 'Some of these apply after a reboot or log off.'
}

function Step-Domain {
  $dns = [bool](Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) -and
         (Get-Service DNS -ErrorAction SilentlyContinue).Status -eq 'Running'
  if (-not $IsDC -and -not $dns) { Write-Host '  Not a domain controller or DNS server, nothing to do.'; return }
  if ($IsDC) {
    Hdr 'Domain controller: LDAP signing, Netlogon (Zerologon), delegation'
    $ntds = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    Set-Reg $ntds LDAPServerIntegrity 2
    Set-Reg $ntds LdapEnforceChannelBinding 2
    $nl = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
    Set-Reg $nl FullSecureChannelProtection 1
    $allow = (Get-ItemProperty $nl -ErrorAction SilentlyContinue).vulnerablechannelallowlist
    if ($allow) {
      Warn "Netlogon still allows vulnerable (Zerologon) connections from: $allow"
      if (Ask '  Delete that allow list?') { Remove-ItemProperty $nl -Name vulnerablechannelallowlist; Log 'deleted Netlogon vulnerablechannelallowlist' }
    }
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.Name })
    $f = 'TrustedForDelegation -eq $true -or TrustedToAuthForDelegation -eq $true'
    $deleg = @(Get-ADUser -Filter $f -Properties TrustedForDelegation, TrustedToAuthForDelegation) +
             @(Get-ADComputer -Filter $f -Properties TrustedForDelegation, TrustedToAuthForDelegation | Where-Object { $dcs -notcontains $_.Name })
    if (-not $deleg.Count) { Write-Host '  No accounts are trusted for delegation (domain controllers are, by default).' }
    foreach ($o in $deleg) {
      if (Ask "'$($o.SamAccountName)' is trusted for delegation (it can act as other users on other servers). Turn that off?") {
        Try-Do "delegation off: $($o.SamAccountName)" { Set-ADAccountControl -Identity $o -TrustedForDelegation $false -TrustedToAuthForDelegation $false }
      }
    }
  }
  if ($dns) {
    Hdr 'DNS zones: zone transfers and dynamic updates'
    $zones = @(Get-DnsServerZone -ErrorAction SilentlyContinue |
      Where-Object { $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated -and $_.ZoneName -ne 'TrustAnchors' })
    foreach ($z in $zones) {
      Write-Host ('--- {0}  transfers: {1}  dynamic updates: {2}  AD-integrated: {3}' -f $z.ZoneName, $z.SecureSecondaries, $z.DynamicUpdate, $z.IsDsIntegrated)
      if ("$($z.SecureSecondaries)" -match 'TransferAnyServer' -and
          (Ask "  $($z.ZoneName) gives a full copy of the zone to any server that asks. Turn zone transfers off?")) {
        Try-Do "DNS $($z.ZoneName): zone transfers off" { Set-DnsServerPrimaryZone -Name $z.ZoneName -SecureSecondaries NoTransfer }
      }
      if ("$($z.DynamicUpdate)" -eq 'NonsecureAndSecure') {
        $to = if ($z.IsDsIntegrated) { 'Secure' } else { 'None' }
        if (Ask "  $($z.ZoneName) accepts dynamic updates from anyone. Set dynamic updates to $to?") {
          Try-Do "DNS $($z.ZoneName): dynamic updates $to" { Set-DnsServerPrimaryZone -Name $z.ZoneName -DynamicUpdate $to }
        }
      }
    }
  }
  Warn 'The LDAP and Netlogon settings may need a reboot.'
}

function Step-Smb1 {
  Hdr 'SMB 1.x'
  Try-Do 'SMB1 server protocol off' { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force }
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' SMB1 0
  if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    $f = Get-WindowsFeature FS-SMB1 -ErrorAction SilentlyContinue
    if ($f -and $f.Installed) { Try-Do 'removed Windows feature FS-SMB1' { Uninstall-WindowsFeature FS-SMB1 } }
  }
  $f = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
  if ($f -and $f.State -eq 'Enabled') { Try-Do 'disabled optional feature SMB1Protocol' { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart } }
  if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10') {
    sc.exe config lanmanworkstation depend= bowser/mrxsmb20/nsi | Out-Null
    sc.exe config mrxsmb10 start= disabled | Out-Null
    Log 'SMB1 client driver mrxsmb10 disabled'
  }
  Warn 'Reboot later to finish removing SMB1.'
}

function Fix-ShareAccess([string]$name) {
  foreach ($e in @(Get-SmbShareAccess -Name $name)) {
    if ($e.AccessControlType -ne 'Allow' -or $e.AccessRight -eq 'Read') { continue }
    $a = Read-Host "  $($e.AccountName) has $($e.AccessRight). (r)ead only, (d)elete entry, (k)eep? [k]"
    if ($a -match '^r') {
      Try-Do "share $name - $($e.AccountName) now Read" {
        Revoke-SmbShareAccess -Name $name -AccountName $e.AccountName -Force
        Grant-SmbShareAccess -Name $name -AccountName $e.AccountName -AccessRight Read -Force
      }
    } elseif ($a -match '^d') {
      Try-Do "share $name - removed $($e.AccountName)" { Revoke-SmbShareAccess -Name $name -AccountName $e.AccountName -Force }
    }
  }
  while ($true) {
    $add = Read-Host '  Grant another account? Type "account right" (e.g. "BUILTIN\Administrators Full", "Domain Users Change"), Enter = done'
    if (-not $add.Trim()) { break }
    $add = $add.Trim()
    $right = ($add -split '\s+')[-1]
    $acct = $add.Substring(0, $add.LastIndexOf(' ')).Trim()
    Try-Do "share $name - granted $acct $right" { Grant-SmbShareAccess -Name $name -AccountName $acct -AccessRight $right -Force }
  }
  Get-SmbShareAccess -Name $name | ForEach-Object { Write-Host ('    {0,-32} {1,-6} {2}' -f $_.AccountName, $_.AccessControlType, $_.AccessRight) }
}

function Get-RegistryShares {
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Shares'
  $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
  if (-not $p) { return }
  foreach ($n in $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
    $path = (@($n.Value) | Where-Object { $_ -like 'Path=*' }) -replace '^Path=', ''
    [pscustomobject]@{ Name = $n.Name; Path = $path; Description = '(registry)' }
  }
}

function Step-Shares {
  Hdr 'SMB shares (keep only what the README needs)'
  $default = '^(ADMIN\$|IPC\$|[A-Z]\$|print\$|NETLOGON|SYSVOL)$'
  if ((Get-Service LanmanServer).Status -ne 'Running') {
    Warn 'Server service is off, so no share is reachable right now. Shares saved in the registry (they come back if it is turned on):'
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Shares'
    foreach ($s in @(Get-RegistryShares)) {
      Write-Host "--- $($s.Name) -> $($s.Path)"
      if ($s.Name -notmatch $default -and (Ask "  Delete share '$($s.Name)' from the registry?")) {
        Remove-ItemProperty $k -Name $s.Name; Remove-ItemProperty "$k\Security" -Name $s.Name -ErrorAction SilentlyContinue
        Log "deleted share $($s.Name) (registry)"
      }
    }
    return
  }
  foreach ($s in @(Get-SmbShare)) {
    $hidden = if ($s.Name -like '*$' -and $s.Name -notmatch $default) { '  (HIDDEN share)' } else { '' }
    Write-Host "--- $($s.Name) -> $($s.Path)$hidden" -ForegroundColor White
    Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host ('    {0,-32} {1,-6} {2}' -f $_.AccountName, $_.AccessControlType, $_.AccessRight) }
    if ($s.Name -match $default) { continue }
    $def = if ($hidden) { 'r' } else { 'k' }
    $a = Read-Host "  (k)eep, (r)emove share, (f)ix permissions? [$def]"
    if (-not $a) { $a = $def }
    if ($a -match '^r') { Try-Do "removed share $($s.Name)" { Remove-SmbShare -Name $s.Name -Force }; continue }
    if ($a -match '^f') { Fix-ShareAccess $s.Name }
    if ($s.Path -and (Test-Path $s.Path)) {
      $bad = @((Get-Acl $s.Path).Access | Where-Object {
        -not $_.IsInherited -and $_.AccessControlType -eq 'Allow' -and
        $_.IdentityReference -match 'Everyone|ANONYMOUS|Guests|\\Users$|Authenticated Users|Domain Users' -and
        $_.FileSystemRights -match 'FullControl|Modify|Write' })
      foreach ($r in $bad) { Write-Host "    NTFS: $($r.IdentityReference) has $($r.FileSystemRights)" }
      if ($bad.Count -and (Ask '  Remove those broad explicit NTFS grants on the folder?')) {
        foreach ($r in $bad) { icacls $s.Path /remove:g "$($r.IdentityReference)" | Out-Null }
        Log "NTFS: removed broad grants on $($s.Path)"
      }
    }
  }
}

function Step-Defender {
  Hdr 'Windows Defender'
  $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
  foreach ($k in @($pol, "$pol\Real-Time Protection", "$pol\Spynet", "$pol\Scan")) {
    if (-not (Test-Path $k)) { continue }
    $p = Get-ItemProperty $k
    foreach ($n in $p.PSObject.Properties.Name) {
      if ($n -like 'PS*') { continue }
      if ($n -match '^Disable' -and $p.$n -eq 1 -and (Ask "Policy $k\$n = 1 turns protection off. Delete it?")) {
        Remove-ItemProperty -Path $k -Name $n; Log "deleted $k\$n"
      }
    }
  }
  foreach ($t in 'Extensions', 'Paths', 'Processes', 'IpAddresses') {
    $k = "$pol\Exclusions\$t"
    if (-not (Test-Path $k)) { continue }
    $p = Get-ItemProperty $k
    foreach ($n in @($p.PSObject.Properties.Name | Where-Object { $_ -notlike 'PS*' -and $_ -notmatch '(?i)CyberPatriot' })) {
      if (Ask "Group Policy Defender exclusion ($t): '$n'. Delete?") { Remove-ItemProperty -Path $k -Name $n; Log "deleted policy exclusion $t $n" }
    }
  }
  try { $mp = Get-MpPreference -ErrorAction Stop }
  catch {
    Warn 'Defender is not available. On Server: Install-WindowsFeature Windows-Defender, reboot, run this step again.'
    return
  }
  $map = [ordered]@{ ExclusionExtension = 'file extension'; ExclusionPath = 'path'; ExclusionProcess = 'process'; ExclusionIpAddress = 'IP' }
  foreach ($key in $map.Keys) {
    foreach ($e in @($mp.$key)) {
      if (-not $e) { continue }
      if ($e -match '(?i)CyberPatriot') { Write-Host "  keeping exclusion $e (CyberPatriot scoring folder)"; continue }
      if (Ask "Defender excludes $($map[$key]) '$e'. Remove the exclusion?") {
        $h = @{ $key = $e }
        Try-Do "removed Defender exclusion $key $e" { Remove-MpPreference @h }
      }
    }
  }
  $set = [ordered]@{
    DisableRealtimeMonitoring = $false; DisableBehaviorMonitoring = $false; DisableIOAVProtection = $false
    DisableScriptScanning = $false; DisableArchiveScanning = $false; DisableBlockAtFirstSeen = $false
    DisableRemovableDriveScanning = $false; DisableEmailScanning = $false
    MAPSReporting = 'Advanced'; SubmitSamplesConsent = 'SendSafeSamples'; PUAProtection = 'Enabled'; EnableNetworkProtection = 'Enabled'
  }
  foreach ($k in $set.Keys) {
    $h = @{ $k = $set[$k] }
    try { Set-MpPreference @h -ErrorAction Stop; Log "Defender $k = $($set[$k])" } catch { Warn "Defender $k - $($_.Exception.Message)" }
  }
  if ((Get-Service WinDefend -ErrorAction SilentlyContinue).Status -ne 'Running') { Try-Do 'started WinDefend' { Start-Service WinDefend } }
  Write-Host 'Updating signatures...'
  Try-Do 'Defender signatures updated' { Update-MpSignature }
  Show (Get-MpComputerStatus | Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled, IsTamperProtected, AntivirusSignatureLastUpdated)
  if (Ask 'Start a Defender quick scan in the background?') { Start-MpScan -ScanType QuickScan -AsJob | Out-Null; Log 'Defender quick scan started' }
}

function Step-Firewall {
  Hdr 'Firewall'
  if ((Get-Service MpsSvc).Status -ne 'Running') { Try-Do 'started firewall service' { Start-Service MpsSvc } }
  Try-Do 'firewall on for all profiles, inbound blocked by default, dropped packets logged' {
    Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow -NotifyOnListen True -LogBlocked True
  }
  Hdr 'Enabled inbound Allow rules added by programs or people (not Windows)'
  $rules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow | Where-Object { -not $_.Group })
  if (-not $rules.Count) { Write-Host '  none' }
  foreach ($r in $rules) {
    $app = ($r | Get-NetFirewallApplicationFilter).Program
    $pf = $r | Get-NetFirewallPortFilter
    Write-Host "--- $($r.DisplayName)  program=$app  $($pf.Protocol) port=$($pf.LocalPort)  profile=$($r.Profile)"
    if (Ask '  Disable this rule?') { Try-Do "disabled firewall rule $($r.DisplayName)" { $r | Disable-NetFirewallRule } }
  }
}

function Step-IIS {
  Hdr 'IIS'
  if (-not (Test-Path $AppCmd)) { Write-Host '  IIS is not installed.'; return }
  & $AppCmd set config /section:system.webServer/directoryBrowse /enabled:false /commit:apphost | Out-Null
  Log 'IIS: directory browsing off (server level)'
  foreach ($site in @(& $AppCmd list site /text:name)) {
    & $AppCmd set config "$site" /section:system.webServer/directoryBrowse /enabled:false | Out-Null
    & $AppCmd set config "$site" /section:system.webServer/directoryBrowse /enabled:false /commit:apphost | Out-Null
    Log "IIS: directory browsing off for site '$site'"
  }
  foreach ($wc in Get-ChildItem (Get-WebRoots) -Recurse -Force -Filter web.config -ErrorAction SilentlyContinue) {
    $t = Get-Content -LiteralPath $wc.FullName -Raw
    if ($t -match '(?i)<directoryBrowse[^>]*enabled\s*=\s*"true"') {
      Copy-Item $wc.FullName "$Bak\$($wc.FullName -replace '[:\\ ]', '_')"
      ($t -replace '(?i)(<directoryBrowse[^>]*enabled\s*=\s*")true"', '${1}false"') | Set-Content -LiteralPath $wc.FullName -Encoding UTF8
      Log "IIS: directoryBrowse false in $($wc.FullName)"
    }
  }
  & $AppCmd set config /section:system.webServer/security/requestFiltering /removeServerHeader:true 2>$null | Out-Null
  & $AppCmd set config /section:system.webServer/security/requestFiltering /allowDoubleEscaping:false | Out-Null
  & $AppCmd set config /section:system.webServer/httpErrors /errorMode:DetailedLocalOnly | Out-Null
  Log 'IIS: server header removed, double escaping blocked, detailed errors local only'

  foreach ($p in @(& $AppCmd list apppool /text:name)) {
    $id = & $AppCmd list apppool "$p" /text:processModel.identityType
    if ($id -match 'LocalSystem|LocalService|NetworkService' -and (Ask "App pool '$p' runs as $id. Switch to ApplicationPoolIdentity?")) {
      & $AppCmd set apppool "$p" /processModel.identityType:ApplicationPoolIdentity | Out-Null; Log "IIS: app pool $p -> ApplicationPoolIdentity"
    }
  }
  if ((& $AppCmd list site /text:bindings) -match 'ftp/') {
    & $AppCmd set config /section:system.applicationHost/sites /siteDefaults.ftpServer.security.authentication.anonymousAuthentication.enabled:false /commit:apphost | Out-Null
    Log 'IIS FTP: anonymous login off'
  }
  if (Ask 'Restart IIS now so the changes load?') { iisreset /noforce | Out-Null; Log 'iisreset' }
  Write-Host 'Run the Webshells step to look for ASPX shells in the web roots.'
}

$ShellPat = 'cmd\.exe|cmd /c|powershell|Process\.Start|ProcessStartInfo|WScript\.Shell|Shell\.Application|eval\s*\(\s*Request|Execute\s*\(\s*Request|Assembly\.Load|FromBase64String|shell_exec|passthru|system\s*\(\s*\$_|proc_open|Language\s*=\s*"?Jscript'

function Step-Webshells {
  Hdr 'Web shells (pages that run commands)'
  $roots = @(Get-WebRoots) + @(Get-DataDirs)
  $hits = @(Get-ChildItem $roots -Recurse -Force -File -Include *.aspx, *.asp, *.ashx, *.asmx, *.ascx, *.cshtml, *.php, *.jsp, *.jspx -ErrorAction SilentlyContinue |
    Select-String -Pattern $ShellPat -List -ErrorAction SilentlyContinue | Sort-Object Path -Unique)
  foreach ($h in $hits) {
    $line = $h.Line.Trim(); if ($line.Length -gt 160) { $line = $line.Substring(0, 160) }
    Write-Host "$($h.Path):$($h.LineNumber): $line" -ForegroundColor Yellow
  }
  Review-Files @($hits | ForEach-Object { $_.Path })
}

$BadApps = 'hashcat|\bHFS\b|HTTP File Server|TeamViewer|AnyDesk|RustDesk|Pinball|Wireshark|Npcap|WinPcap|\bNmap\b|Zenmap|\bCain\b|John the Ripper|Ophcrack|Angry IP|Advanced IP Scanner|Advanced Port Scanner|Metasploit|Burp Suite|mimikatz|netcat|LOIC|uTorrent|BitTorrent|qBittorrent|Vuze|FrostWire|Deluge|Transmission|Tor Browser|CCleaner|\bSteam\b|Epic Games|Minecraft|Roblox|Battle\.net|RealVNC|TightVNC|UltraVNC|Ammyy|Radmin|LogMeIn|Splashtop|ngrok|Hydra|Aircrack|Ettercap|Cheat Engine|Shareaza|LimeWire|eMule|WinDirStat|TreeSize|Everything Search|TigerVNC|Chrome Remote Desktop|NoMachine|Parsec|Supremo|Remote Utilities|DWService|MeshAgent|ScreenConnect|Zoho Assist|L0phtCrack|Brutus|Nessus|OpenVAS|Acunetix|sqlmap|Nikto|BitComet|Tixati|BitLord|WebTorrent|Psiphon|Ultrasurf|Hotspot Shield|\bOrigin\b|\bEA app\b|Ubisoft Connect|GOG Galaxy|Riot Client|League of Legends|VALORANT|Fortnite'
$BadFiles = @('*hashcat*', 'hfs.exe', 'hfs*.exe', '*pinball*', '*SharpHound*', '*BloodHound*', '*mimikatz*', 'nc.exe', 'nc64.exe',
              'ncat.exe', '*netcat*', '*psexec*', 'Rubeus*', '*lazagne*', 'procdump*', '*pwdump*', '*kerbrute*', 'PowerView*',
              '*CrackMapExec*', 'john.exe', '*hydra*.exe', 'wce.exe', '*keylog*', '*.torrent', '*TeamViewer*', '*AnyDesk*',
              'winPEAS*', 'Seatbelt*', 'SharpUp*', '*Inveigh*', 'Certify.exe', 'Snaffler*', 'chisel*.exe', 'ngrok*.exe', 'frpc*.exe',
              'winvnc*.exe', 'tvnserver.exe', 'lsass*.dmp', 'ntds.dit', 'sam.save', 'system.save', 'security.save')
$BadAppx = 'Solitaire|CandyCrush|BubbleWitch|MarchofEmpires|HiddenCity|Minecraft|Roblox|king\.com|Disney|FarmVille|Asphalt|Mahjong|Minesweeper|Sudoku|Jigsaw|Fishdom|Gardenscapes|Township|RoyalRevolt'

function Step-Software {
  Hdr 'Installed hacking tools, games, remote access, P2P'
  $apps = @(Get-Installed)
  $bad = @($apps | Where-Object { $_.DisplayName -match $BadApps } | Sort-Object DisplayName -Unique)
  if (-not $bad.Count) { Write-Host '  none' }
  foreach ($a in $bad) { if (Ask "Uninstall '$($a.DisplayName)' $($a.DisplayVersion)?") { Uninstall-App $a } }

  Hdr 'Everything else installed that is not from Microsoft (skip anything the README needs)'
  $others = @($apps | Where-Object { $_.DisplayName -notmatch $BadApps -and $_.Publisher -notmatch 'Microsoft' } | Sort-Object DisplayName -Unique)
  for ($i = 0; $i -lt $others.Count; $i++) {
    Write-Host ('{0,3}. {1} {2}  ({3})' -f ($i + 1), $others[$i].DisplayName, $others[$i].DisplayVersion, $others[$i].Publisher)
  }
  $pick = Read-Host 'Numbers to uninstall (space-separated, Enter = none)'
  foreach ($n in ($pick -split '\s+' | Where-Object { $_ -match '^\d+$' })) {
    if ([int]$n -ge 1 -and [int]$n -le $others.Count) { Uninstall-App $others[[int]$n - 1] }
  }

  Hdr 'Portable hacking tools, archives and games (searching, takes a minute)'
  $dirs = @(Get-DataDirs) + @('C:\ProgramData', 'C:\Program Files', 'C:\Program Files (x86)', "$env:windir\Temp")
  $found = @(Get-ChildItem $dirs -Recurse -Force -Include $BadFiles -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\Windows Defender\\|\\WindowsApps\\' } | ForEach-Object { $_.FullName })
  Review-Files $found

  Hdr 'Store apps / games'
  $appx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $BadAppx })
  if (-not $appx.Count) { Write-Host '  none' }
  foreach ($x in $appx) {
    if (Ask "Remove Store app $($x.Name)?") { Try-Do "removed Store app $($x.Name)" { Remove-AppxPackage -Package $x.PackageFullName -AllUsers } }
  }
}

function Step-Features {
  Hdr 'Optional Windows features'
  if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    foreach ($n in 'Telnet-Client', 'Telnet-Server', 'TFTP-Client', 'Simple-TCPIP', 'PowerShell-V2', 'SNMP-Service', 'Web-Ftp-Server', 'Web-DAV-Publishing') {
      $f = Get-WindowsFeature $n -ErrorAction SilentlyContinue
      if ($f -and $f.Installed -and (Ask "Remove server feature $n ($($f.DisplayName))? Keep it if the README needs it.")) {
        Try-Do "removed feature $n" { Uninstall-WindowsFeature $n }
      }
    }
    $d = Get-WindowsFeature Windows-Defender -ErrorAction SilentlyContinue
    if ($d -and -not $d.Installed -and (Ask 'Windows Defender is not installed. Install it (needs a reboot)?')) {
      Try-Do 'installed Windows-Defender' { Install-WindowsFeature Windows-Defender }
    }
  }
  foreach ($c in @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
      Where-Object { $_.State -eq 'Installed' -and $_.Name -match 'SNMP|OpenSSH\.Server|Telnet|TFTP' })) {
    if (Ask "Remove Windows capability $($c.Name)? Keep it if the README needs it.") {
      Try-Do "removed capability $($c.Name)" { Remove-WindowsCapability -Online -Name $c.Name }
    }
  }
  foreach ($n in 'TelnetClient', 'TFTP', 'SimpleTCP', 'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2', 'SNMP', 'IIS-FTPServer') {
    $f = Get-WindowsOptionalFeature -Online -FeatureName $n -ErrorAction SilentlyContinue
    if ($f -and $f.State -eq 'Enabled' -and (Ask "Disable optional feature ${n}? Keep it if the README needs it.")) {
      Try-Do "disabled optional feature $n" { Disable-WindowsOptionalFeature -Online -FeatureName $n -NoRestart }
    }
  }
}

$RiskySvcs = [ordered]@{
  W3SVC = 'IIS|web ?server|web ?site|intranet|\bhttp'; FTPSVC = '\bFTP'; TermService = 'Remote Desktop|\bRDP\b'
  WinRM = 'WinRM|remote management|PowerShell remoting'; RemoteRegistry = 'remote registry'; Spooler = 'print'
  SNMP = 'SNMP'; SNMPTRAP = 'SNMP'; TlntSvr = 'telnet'; RemoteAccess = 'routing|\bVPN\b|remote access'
  SharedAccess = 'internet connection sharing'; SSDPSRV = 'UPnP|SSDP'; upnphost = 'UPnP'; simptcp = 'simple tcp'
  LanmanServer = 'file shar|\bSMB\b|\bshares?\b'; Fax = '\bfax'; WebClient = 'WebDAV'; RpcLocator = 'rpc locator'
  icssvc = 'hotspot'; XblAuthManager = 'xbox'; XblGameSave = 'xbox'; XboxNetApiSvc = 'xbox'; MSFTPSVC = '\bFTP'
  sshd = 'SSH'; tvnserver = 'VNC'; uvnc_service = 'VNC'; vncserver = 'VNC'; WinVNC4 = 'VNC'; 'FileZilla Server' = '\bFTP'
  'Apache2.4' = 'apache|web ?server|web ?site|\bhttp'; MySQL = 'mysql|database'; MySQL80 = 'mysql|database'
  MSSQLSERVER = 'SQL Server|database'; SMTPSVC = 'SMTP|mail'; DHCPServer = 'DHCP'; WMSvc = 'IIS|web ?server|web ?site'; LPDSVC = 'print|LPD'
}

function Step-Services {
  Hdr 'Services: keep only what the README needs'
  $lines = @(Get-ReadmeLines)
  $src = if ($lines.Count) { Get-ReadmeServiceText $lines } else { '' }
  if ($src) { Write-Host "README critical services / text used:`n$src`n" } else { Warn 'No README: no defaults, decide each one.' }
  foreach ($name in $RiskySvcs.Keys) {
    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $s) { continue }
    if ($IsDC -and $name -eq 'LanmanServer') { continue }
    $mode = (Get-CimInstance Win32_Service -Filter "Name='$name'").StartMode
    if ($s.Status -ne 'Running' -and $mode -eq 'Disabled') { continue }
    $need = $src -and ($src -match $RiskySvcs[$name])
    $def = if (-not $src) { '' } elseif ($need) { 'k' } else { 'd' }
    $why = if ($need) { 'README seems to need it' } elseif ($src) { 'not in README' } else { '' }
    $a = Read-Host "$name ($($s.DisplayName)) is $($s.Status)/$mode. $why. (k)eep, (d)isable, (s)kip? [$def]"
    if (-not $a) { $a = $def }
    if ($a -match '^d') {
      Try-Do "disabled service $name" { Stop-Service -Name $name -Force; Set-Service -Name $name -StartupType Disabled }
      if ($name -eq 'TermService') {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' fDenyTSConnections 1
      }
    } elseif ($a -match '^k' -and $name -eq 'TermService') {
      $rdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
      Set-Reg $rdp UserAuthentication 1; Set-Reg $rdp SecurityLayer 2; Set-Reg $rdp MinEncryptionLevel 3
    }
  }
}

function Mount-UserHives {
  $mounted = @()
  foreach ($p in Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and -not $_.Loaded }) {
    $dat = Join-Path $p.LocalPath 'NTUSER.DAT'
    if (-not (Test-Path $dat)) { continue }
    $key = "HKU\cp_$($p.SID)"
    reg load $key $dat 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $mounted += $key }
  }
  $mounted
}

function Step-Backdoors {
  $susp = '-enc|FromBase64|IEX|DownloadString|Invoke-WebRequest|Net\.WebClient|\\Users\\|\\Temp\\|\\AppData\\|\bnc(64)?\.exe|ncat|mshta|https?://|\\Public\\|\.ps1|\.vbs|\.hta'

  Hdr 'Scheduled tasks not from Microsoft (plus suspicious Microsoft ones)'
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    $acts = (@($t.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; '
    if ($t.TaskPath -like '\Microsoft\*' -and $acts -notmatch $susp) { continue }
    $hint = if ($t.TaskName -match 'GoogleUpdate|MicrosoftEdgeUpdate|OneDrive|Mozilla|Firefox') { '  [usually fine]' } else { '' }
    Write-Host "--- $($t.TaskPath)$($t.TaskName) [$($t.State)] runs as $($t.Principal.UserId)$hint" -ForegroundColor White
    Write-Host "    $acts"
    if (Ask '  Delete this task?') {
      Try-Do "deleted task $($t.TaskPath)$($t.TaskName)" { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false }
    }
  }

  Hdr 'Run / RunOnce keys (all users)'
  $mounted = @(Mount-UserHives)
  $hives = @('HKLM:') + @(Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.PSChildName -match '^(cp_)?S-1-5-21-[\d-]+$' } |
    ForEach-Object { "Registry::$($_.Name)" })
  $subs = 'Software\Microsoft\Windows\CurrentVersion\Run', 'Software\Microsoft\Windows\CurrentVersion\RunOnce',
          'Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run', 'Software\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
          'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'
  foreach ($h in $hives) {
    foreach ($s in $subs) {
      $k = "$h\$s"
      if (-not (Test-Path $k)) { continue }
      $p = Get-ItemProperty $k
      foreach ($n in @($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
        Write-Host "--- $k" -ForegroundColor White
        Write-Host "    $($n.Name) = $($n.Value)"
        if (Ask '  Delete this autorun?') { Remove-ItemProperty -Path $k -Name $n.Name; Log "deleted autorun $k\$($n.Name)" }
      }
    }
  }
  [gc]::Collect(); Start-Sleep -Milliseconds 500
  foreach ($m in $mounted) { reg unload $m 2>$null | Out-Null }

  Hdr 'Winlogon and AppInit_DLLs'
  $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  $w = Get-ItemProperty $wl
  if ($w.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') {
    Write-Host "Userinit = $($w.Userinit)"
    if (Ask 'Reset Userinit to the default?') { Set-Reg $wl Userinit 'C:\Windows\system32\userinit.exe,' String }
  }
  if ($w.Shell -and $w.Shell -ne 'explorer.exe') {
    Write-Host "Shell = $($w.Shell)"
    if (Ask 'Reset Shell to explorer.exe?') { Set-Reg $wl Shell 'explorer.exe' String }
  }
  foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows NT\CurrentVersion\Windows') {
    $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).AppInit_DLLs
    if ($v -and (Ask "AppInit_DLLs = $v. Clear it?")) { Set-Reg $k AppInit_DLLs '' String; Set-Reg $k LoadAppInit_DLLs 0 }
  }

  Hdr 'Startup folders'
  $startup = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") +
    @(Get-ChildItem C:\Users -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup" })
  Review-Files @(Get-ChildItem $startup -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { $_.FullName })

  Hdr 'Group Policy logon/startup scripts'
  $gp = @(Get-ChildItem "$env:windir\System32\GroupPolicy\Machine\Scripts", "$env:windir\System32\GroupPolicy\User\Scripts" -Recurse -Force -File -ErrorAction SilentlyContinue)
  if (-not $gp.Count) { Write-Host '  none' }
  foreach ($g in $gp) { Write-Host "--- $($g.FullName)"; Get-Content $g.FullName -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" } }
  Review-Files @($gp | Where-Object { $_.Name -notmatch '^(scripts|psscripts)\.ini$' } | ForEach-Object { $_.FullName })

  Hdr 'Sticky Keys / Utilman backdoors'
  $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
  foreach ($k in @(Get-ChildItem $ifeo -ErrorAction SilentlyContinue)) {
    $d = (Get-ItemProperty $k.PSPath).Debugger
    if (-not $d) { continue }
    Write-Host "$($k.PSChildName) -> Debugger = $d"
    if (Ask '  Delete this Debugger value?') { Remove-ItemProperty $k.PSPath -Name Debugger; Log "deleted IFEO debugger for $($k.PSChildName)" }
  }
  $realNames = @{ 'sethc.exe' = 'sethc.exe'; 'utilman.exe' = 'utilman2.exe'; 'osk.exe' = 'osk.exe'; 'Magnify.exe' = 'ScreenMagnifier.exe'
                  'Narrator.exe' = 'SR.exe'; 'DisplaySwitch.exe' = 'DisplaySwitch.exe'; 'AtBroker.exe' = 'AtBroker.exe' }
  foreach ($n in $realNames.Keys) {
    $p = "$env:windir\System32\$n"
    if (-not (Test-Path $p)) { continue }
    $orig = (Get-Item $p).VersionInfo.OriginalFilename -replace '\.mui$', ''
    if ($orig -and $orig -ine $realNames[$n]) {
      Warn "$p is really $orig (it was replaced)."
      if (Ask "  Restore it with sfc /scanfile?") { sfc /scanfile=$p | Out-Null; Log "sfc /scanfile=$p" }
    }
  }

  Hdr 'Services running from odd places'
  foreach ($s in @(Get-CimInstance Win32_Service)) {
    $p = $s.PathName
    if (-not $p -or $p -match '(?i)\\CyberPatriot\\') { continue }
    $normal = $p -match '(?i)^"?(C:\\Windows\\|%SystemRoot%|\\SystemRoot\\|system32\\|C:\\Program Files|C:\\ProgramData\\Microsoft\\Windows Defender)'
    if ($normal -and $p -notmatch '(?i)powershell|cmd(\.exe)?\s+/c|mshta|wscript|cscript|\\Temp\\|\\Users\\|\bnc(64)?\.exe') { continue }
    Write-Host "--- $($s.Name) ($($s.DisplayName)) [$($s.State)/$($s.StartMode)] runs as $($s.StartName)" -ForegroundColor White
    Write-Host "    $p"
    if (Ask '  Stop, disable and delete this service?') {
      Try-Do "deleted service $($s.Name)" { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue; sc.exe delete $s.Name | Out-Null }
    }
  }

  Hdr 'WMI event subscriptions'
  $cons = @(Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction SilentlyContinue |
    Where-Object { $_.CimClass.CimClassName -in 'CommandLineEventConsumer', 'ActiveScriptEventConsumer' })
  if (-not $cons.Count) { Write-Host '  none' }
  foreach ($c in $cons) {
    Write-Host "--- $($c.CimClass.CimClassName) '$($c.Name)': $($c.CommandLineTemplate)$($c.ScriptText)"
    if (Ask '  Remove it and its filter/binding?') {
      foreach ($b in @(Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding | Where-Object { $_.Consumer.Name -eq $c.Name })) {
        $fn = $b.Filter.Name
        $b | Remove-CimInstance
        Get-CimInstance -Namespace root\subscription -ClassName __EventFilter | Where-Object { $_.Name -eq $fn } | Remove-CimInstance
      }
      $c | Remove-CimInstance; Log "removed WMI subscription $($c.Name)"
    }
  }

  Hdr 'Port forwarding (should be empty)'
  $pp = @(netsh interface portproxy show all)
  if (($pp -join '') -match '\d+\.\d+|\d{2,5}') {
    $pp | Write-Host
    if (Ask 'Delete all port forwarding rules?') { netsh interface portproxy reset | Out-Null; Log 'netsh portproxy reset' }
  } else { Write-Host '  none' }

  Hdr 'hosts file'
  $hf = "$env:windir\System32\drivers\etc\hosts"
  $entries = @(Get-Content $hf | Where-Object { $_ -notmatch '^\s*(#|$)' })
  if ($entries.Count) {
    $entries | Write-Host
    if (Ask 'Reset the hosts file to the Windows default?') {
      Copy-Item $hf "$Bak\hosts"; Set-Content $hf '# Default hosts file (reset by cp-windows.ps1)' -Encoding ASCII; Log 'hosts file reset'
    }
  } else { Write-Host '  none' }

  Hdr 'Listening ports'
  $rows = @(foreach ($c in Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue) {
    $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    [pscustomobject]@{ Port = $c.LocalPort; Address = $c.LocalAddress; PID = $c.OwningProcess; Name = $pr.ProcessName; Path = $pr.Path }
  }) | Sort-Object Port, PID -Unique
  Show ($rows | Select-Object Port, PID, Name, Path)
  foreach ($r in $rows) {
    if ($r.PID -le 4) { continue }
    $odd = $r.Name -match '^(nc|nc64|ncat|netcat|socat|powershell|pwsh|cmd|python\d*|perl|ruby|plink|hfs)$' -or
           ($r.Path -and $r.Path -notmatch '(?i)^C:\\(Windows|Program Files)') -or
           ($r.Path -and (Get-AuthenticodeSignature -FilePath $r.Path).Status -ne 'Valid')
    if ($odd -and $r.Path) { Warn "  $($r.Path): signature $((Get-AuthenticodeSignature -FilePath $r.Path).Status)" }
    if ($odd -and (Ask "Kill $($r.Name) (pid $($r.PID)) listening on port $($r.Port)?")) {
      Try-Do "killed $($r.Name) pid $($r.PID)" { Stop-Process -Id $r.PID -Force }
    }
  }
  Write-Host 'Killed something? Run this step again: if it comes back, its autostart is still somewhere.'
}

function Step-Files {
  $dirs = @(Get-DataDirs)
  Hdr 'Media files'
  $ext = '*.mp3', '*.mp4', '*.m4a', '*.m4v', '*.wav', '*.flac', '*.aac', '*.ogg', '*.wma', '*.avi', '*.mkv', '*.mov', '*.wmv', '*.flv', '*.mpg', '*.mpeg'
  $media = @(Get-ChildItem $dirs -Recurse -Force -File -Include $ext -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\AppData\\|^C:\\CyberPatriot\\|cp-windows.*\.ps1$' } | ForEach-Object { $_.FullName })
  if ($media.Count) {
    $media | ForEach-Object { Write-Host "  $_" }
    if (Ask "Delete all $($media.Count) media files above?") {
      $media | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }; Log "deleted $($media.Count) media files"
    } elseif (Ask 'Go through them one by one?') { Review-Files $media }
  } else { Write-Host '  none' }

  Hdr 'Files with passwords or personal data (searching)'
  $all = @(Get-ChildItem $dirs -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\AppData\\|^C:\\CyberPatriot\\|cp-windows.*\.ps1$' })
  $byName = @($all | Where-Object { $_.Name -match '(?i)passw|pwd|cred|secret|\.kdbx$|\bssn|credit|customers?\b|\.pcapn?g?$|logins?\.' } |
    ForEach-Object { $_.FullName })
  $byText = @($all | Where-Object { $_.Length -lt 5MB -and $_.Extension -match '^\.(txt|csv|ini|xml|json|log|md|ps1|bat|cmd|vbs|rtf|conf|cfg)$' } |
    Select-String -Pattern 'passw(or)?d\s*[:=]|\b\d{3}-\d{2}-\d{4}\b|\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{4}\b' -List -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Path })
  Review-Files (@($byName) + @($byText))

  Hdr 'Programs disguised as documents, pictures or media (answer forensics questions about them first)'
  $docExt = '^\.(pdf|docx?|xlsx?|pptx?|txt|csv|rtf|jpe?g|png|gif|bmp|mp3|mp4|wav|html?)$'
  $disg = foreach ($f in $all | Where-Object { $_.Extension -match $docExt -and $_.Length -gt 64 }) {
    try {
      $fs = [IO.File]::OpenRead($f.FullName); $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2); $fs.Close()
      if ($b[0] -eq 0x4D -and $b[1] -eq 0x5A) { $f.FullName }
    } catch {}
  }
  Review-Files @($disg)
}

$FFPolicy = @'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "PopupBlocking": {"Default": true, "Locked": true},
    "OfferToSaveLogins": false,
    "PasswordManagerEnabled": false,
    "EnableTrackingProtection": {"Value": true, "Locked": true, "Cryptomining": true, "Fingerprinting": true},
    "HttpsOnlyMode": "force_enabled",
    "Preferences": {
      "browser.safebrowsing.malware.enabled": {"Value": true, "Status": "locked"},
      "browser.safebrowsing.phishing.enabled": {"Value": true, "Status": "locked"},
      "browser.safebrowsing.downloads.enabled": {"Value": true, "Status": "locked"},
      "dom.disable_open_during_load": {"Value": true, "Status": "locked"},
      "xpinstall.whitelist.required": {"Value": true, "Status": "locked"}
    }
  }
}
'@

function Step-Browsers {
  Hdr 'Browsers (close them first)'
  foreach ($base in 'HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge') {
    $fl = "$base\ExtensionInstallForcelist"
    if (Test-Path $fl) {
      $p = Get-ItemProperty $fl
      foreach ($n in @($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
        Write-Host "Force-installed extension ($base): $($n.Value)"
        if (Ask '  Remove it?') { Remove-ItemProperty $fl -Name $n.Name; Log "removed forced extension $($n.Value)" }
      }
    }
    Set-Reg $base PasswordManagerEnabled 0
    Set-Reg $base DefaultPopupsSetting 2
    Set-Reg $base DownloadRestrictions 1
    Set-Reg $base BlockThirdPartyCookies 1
    Set-Reg $base AutofillCreditCardEnabled 0
    Set-Reg $base AutofillAddressEnabled 0
  }
  Set-Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' SafeBrowsingProtectionLevel 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' HttpsOnlyMode 'force_enabled' String
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' SmartScreenEnabled 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' SmartScreenPuaEnabled 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' PreventSmartScreenPromptOverride 1
  foreach ($d in 'C:\Program Files\Mozilla Firefox', 'C:\Program Files (x86)\Mozilla Firefox') {
    if (-not (Test-Path "$d\firefox.exe")) { continue }
    $f = "$d\distribution\policies.json"
    New-Item -ItemType Directory -Path "$d\distribution" -Force | Out-Null
    if (Test-Path $f) { Write-Host "--- old $f"; Get-Content $f | Write-Host; Copy-Item $f "$Bak\firefox-policies.json" }
    [IO.File]::WriteAllText($f, $FFPolicy); Log "wrote $f"
  }
  Write-Host 'Check chrome://policy, edge://policy and about:policies.'
}

$UpdateMap = [ordered]@{
  'Notepad\+\+'    = @('Notepad++.Notepad++', 'https://notepad-plus-plus.org/downloads/')
  'WinSCP'         = @('WinSCP.WinSCP', 'https://winscp.net/eng/download.php')
  'Mozilla Firefox'= @('Mozilla.Firefox', 'https://www.mozilla.org/firefox/new/')
  'Google Chrome'  = @('Google.Chrome', 'https://www.google.com/chrome/')
  '7-Zip'          = @('7zip.7zip', 'https://www.7-zip.org/')
  'VLC'            = @('VideoLAN.VLC', 'https://www.videolan.org/vlc/')
  'PuTTY'          = @('PuTTY.PuTTY', 'https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html')
  'FileZilla'      = @('TimKosse.FileZilla.Client', 'https://filezilla-project.org/download.php')
  'Thunderbird'    = @('Mozilla.Thunderbird', 'https://www.thunderbird.net/')
}

function Step-Updates {
  Hdr 'Third-party app updates (the README may name ones that must be updated)'
  $apps = @(Get-Installed)
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  foreach ($re in $UpdateMap.Keys) {
    $a = $apps | Where-Object { $_.DisplayName -match $re } | Select-Object -First 1
    if (-not $a) { continue }
    $id = $UpdateMap[$re][0]; $url = $UpdateMap[$re][1]
    if (-not (Ask "$($a.DisplayName) $($a.DisplayVersion) is installed. Update it?")) { continue }
    $ok = $false
    if ($winget) {
      & winget upgrade --id $id -e --silent --accept-source-agreements --accept-package-agreements
      $ok = $LASTEXITCODE -eq 0
    }
    if (-not $ok) {
      Warn "  No winget upgrade. Opening $url - download the latest installer and run it."
      Warn '  (On Server, turn off IE Enhanced Security Configuration in Server Manager if the page will not load.)'
      Start-Process $url
      Read-Host '  Press Enter when the install has finished' | Out-Null
    }
    $now = (Get-Installed | Where-Object { $_.DisplayName -match $re } | Select-Object -First 1).DisplayVersion
    Log "$($a.DisplayName): $($a.DisplayVersion) -> $now"
  }
  if ($winget -and (Ask 'List everything else winget can upgrade?')) {
    & winget upgrade --accept-source-agreements
    if (Ask 'Upgrade all of them now?') { & winget upgrade --all --silent --accept-source-agreements --accept-package-agreements; Log 'winget upgrade --all' }
  }

  Hdr 'Windows Update settings'
  $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $w = Get-ItemProperty $wu -ErrorAction SilentlyContinue
  if ($w.WUServer -and (Ask "Updates are pointed at $($w.WUServer). Remove that and use Microsoft Update?")) {
    Remove-ItemProperty $wu -Name WUServer, WUStatusServer -ErrorAction SilentlyContinue
    Set-Reg "$wu\AU" UseWUServer 0
  }
  if ($w.DisableWindowsUpdateAccess) { Set-Reg $wu DisableWindowsUpdateAccess 0 }
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' NoWindowsUpdate 0
  Set-Reg "$wu\AU" NoAutoUpdate 0
  Set-Reg "$wu\AU" AUOptions 4
  Set-Reg "$wu\AU" ScheduledInstallDay 0
  Set-Reg "$wu\AU" ScheduledInstallTime 3
  foreach ($s in 'wuauserv', 'BITS', 'UsoSvc', 'CryptSvc') {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    if ($svc.StartMode -eq 'Disabled') { sc.exe config $s start= demand | Out-Null; Log "service $s no longer disabled" }
    Start-Service $s -ErrorAction SilentlyContinue
  }
  if (Ask 'Open Windows Update and start checking now (slow)?') {
    Start-Process 'ms-settings:windowsupdate' -ErrorAction SilentlyContinue
    UsoClient StartInteractiveScan 2>$null
    Log 'Windows Update scan started'
  }
}

$AllSteps = 'Audit', 'Users', 'Policy', 'Rights', 'SecOptions', 'Domain', 'Smb1', 'Shares', 'Defender', 'Firewall', 'IIS',
            'Webshells', 'Software', 'Features', 'Services', 'Backdoors', 'Files', 'Browsers', 'Updates'

function Main {
  $only = @($Step | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
  foreach ($s in $only) {
    if ($AllSteps -notcontains $s) { Warn "Unknown step '$s'. Steps: $($AllSteps -join ', ')"; return }
  }
  if (-not $only.Count -and -not (Ask 'Forensics Questions answered already?')) { Write-Host 'Do those first.'; return }
  if (-not (Test-Path $Log)) { New-Item -ItemType File -Path $Log -Force | Out-Null }
  $start = @(Get-Content $Log).Count
  Write-Host "Domain controller: $IsDC   You: $script:Me"
  Backup
  if ($only.Count) {
    foreach ($s in $only) { & "Step-$s" }
  } else {
    foreach ($s in $AllSteps) { if (Ask "Run step: ${s}?") { & "Step-$s" } }
  }
  Hdr 'Changes this run'
  Get-Content $Log | Select-Object -Skip $start | ForEach-Object { Write-Host $_ }
  Write-Host "Backups are in $Bak. Lost points? Undo that change:"
  Write-Host "  registry:  reg import `"$Bak\<file>.reg`""
  Write-Host "  policy:    secedit /configure /db $env:TEMP\undo.sdb /cfg `"$Bak\secpol.inf`""
  Write-Host "  firewall:  netsh advfirewall import `"$Bak\firewall.wfw`""
}

Main
