<#
 00_inspect_windows.ps1  -  READ-ONLY inventory of the email tooling on this Windows PC.

 Run in PowerShell (no admin needed):
     powershell -ExecutionPolicy Bypass -File scripts\00_inspect_windows.ps1

 Writes env-report.txt next to this folder (git-ignored). It never opens
 logins.json / key4.db, never prints passwords, tokens or cookies, and never
 touches mail data. Any pref whose name contains "password" is skipped.
#>

$ErrorActionPreference = 'SilentlyContinue'
$report = Join-Path $PSScriptRoot '..\env-report.txt'
$out = New-Object System.Collections.Generic.List[string]
function Say($s) { $out.Add($s); Write-Host $s }

Say "# Email environment report  $(Get-Date -Format s)"
Say "Computer: $env:COMPUTERNAME   User: $env:USERNAME   OS: $([Environment]::OSVersion.VersionString)"
Say ""

# ---- Thunderbird install -------------------------------------------------
Say "## Thunderbird"
$tbExe = @(
  "$env:ProgramFiles\Mozilla Thunderbird\thunderbird.exe",
  "${env:ProgramFiles(x86)}\Mozilla Thunderbird\thunderbird.exe",
  "$env:LOCALAPPDATA\Mozilla Thunderbird\thunderbird.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($tbExe) {
  $v = (Get-Item $tbExe).VersionInfo.ProductVersion
  Say "installed: $tbExe  (version $v)"
} else {
  $pkg = Get-AppxPackage -Name '*Thunderbird*'
  if ($pkg) { Say "installed (Store/MSIX): $($pkg.PackageFullName)" } else { Say "NOT FOUND in Program Files / LocalAppData" }
}
$running = Get-Process thunderbird -ErrorAction SilentlyContinue
Say ("running now: " + $(if ($running) { 'yes (pid ' + ($running.Id -join ',') + ')' } else { 'no' }))
Say ""

# ---- Profiles ------------------------------------------------------------
Say "## Thunderbird profiles"
$roots = @("$env:APPDATA\Thunderbird", "$env:LOCALAPPDATA\Packages\*Thunderbird*\LocalCache\Roaming\Thunderbird")
$profilesIni = Get-ChildItem -Path $roots -Filter profiles.ini -Recurse -Depth 1 | Select-Object -First 1
if (-not $profilesIni) { Say "profiles.ini NOT FOUND"; }
else {
  Say "profiles.ini: $($profilesIni.FullName)"
  $ini = Get-Content $profilesIni.FullName
  $paths = $ini | Where-Object { $_ -match '^Path=' } | ForEach-Object { ($_ -split '=',2)[1] }
  foreach ($p in $paths) {
    $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $profilesIni.DirectoryName $p }
    Say ""
    Say "### profile: $full"
    if (-not (Test-Path $full)) { Say "  (path missing)"; continue }
    $prefs = Join-Path $full 'prefs.js'
    if (Test-Path $prefs) {
      # Accounts, servers and identities. Passwords are never in prefs.js, but skip defensively.
      $lines = Get-Content $prefs | Where-Object {
        $_ -match 'user_pref\("mail\.(server|identity|account|accountmanager)\.' -and $_ -notmatch 'password' -and $_ -notmatch 'oauth'
      } | Where-Object {
        $_ -match '\.(hostname|userName|type|port|socketType|authMethod|directory|useremail|fullName|server|identities|accounts|defaultaccount|offline_download|storeContractID|archive_granularity|trash_folder_name|name)"'
      }
      Say "  prefs.js account/server settings (no secrets):"
      $lines | ForEach-Object { Say "    $_" }
    } else { Say "  prefs.js not found" }

    # Local IMAP cache: which folders have offline copies and how big they are.
    $imapDir = Join-Path $full 'ImapMail'
    if (Test-Path $imapDir) {
      Say "  ImapMail offline store:"
      Get-ChildItem $imapDir -Directory | ForEach-Object {
        $size = (Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
        Say ("    {0}  ({1:N1} MB)" -f $_.Name, $size)
        # mbox files have no extension; .msf are index files; .sbd are subfolders
        Get-ChildItem $_.FullName -Recurse -File | Where-Object { $_.Extension -eq '' } |
          ForEach-Object { Say ("      {0,-45} {1,9:N1} MB" -f ($_.FullName.Substring($imapDir.Length+1)), ($_.Length/1MB)) }
      }
    } else { Say "  no ImapMail directory (no offline copies)" }
    $localDir = Join-Path $full 'Mail'
    if (Test-Path $localDir) { Say "  Local Folders present: $localDir" }
    Say "  credential store present (NOT read): " + $(if (Test-Path (Join-Path $full 'logins.json')) {'logins.json + key4.db'} else {'none'})
    Say "  message filters: " + ((Get-ChildItem $full -Recurse -Filter msgFilterRules.dat | Select-Object -ExpandProperty FullName) -join '; ')
  }
}
Say ""

# ---- Scripting runtimes ---------------------------------------------------
Say "## Runtimes"
foreach ($c in 'python','py','python3','node','git','claude','code') {
  $cmd = Get-Command $c -ErrorAction SilentlyContinue
  if ($cmd) {
    $ver = try { & $c --version 2>&1 | Select-Object -First 1 } catch { '?' }
    Say ("  {0,-8} {1}   {2}" -f $c, $cmd.Source, $ver)
  } else { Say ("  {0,-8} MISSING" -f $c) }
}
$py = (Get-Command python -ErrorAction SilentlyContinue)
if ($py) {
  Say "  python packages:"
  & python -m pip list 2>$null | Select-String -Pattern '^(keyring|imapclient|beautifulsoup4|requests|playwright|pypdf)\s' | ForEach-Object { Say "    $_" }
}
Say ""

# ---- Other mail clients / tools that might also hold the mailbox -----------
Say "## Other mail software"
foreach ($p in "$env:ProgramFiles\Microsoft Office\root\Office16\OUTLOOK.EXE", "$env:LOCALAPPDATA\Microsoft\WindowsApps\olk.exe", "$env:ProgramFiles\eM Client\MailClient.exe") {
  if (Test-Path $p) { Say "  found: $p" }
}
Say ""
Say "## Network"
Say "  IMAP reachability is tested by scripts/01_inventory.py --check once config.toml exists."

$out | Set-Content -Path $report -Encoding UTF8
Write-Host ""
Write-Host "Report written to $report  (review it, then share it with Claude)."
