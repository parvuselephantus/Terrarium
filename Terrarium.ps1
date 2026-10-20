<#
Terrarium 0.4.0 - the AI cage: isolated Debian VMs on Hyper-V for AI agents.
(Formerly "AI Cage": internal names - the .aicage folder, the AICage switch, the Aic commands -
keep the old name so existing VMs go on working.)
Start it with Terrarium.cmd (it asks for Administrator rights).   Terrarium.cmd console = commands only.

Part 1 is the engine (loaded as an in-memory PowerShell module), part 2 the window.
Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
#>
param([switch]$Console)
$AicToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# =============================================================================================
# Part 1: the engine, loaded as the in-memory module "AiCage"
# =============================================================================================
$AicModuleBlock = {
param($AicToolRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---- Private/Cleanup.ps1 --------------------------------------------------------------
# Leftovers: things Terrarium made for VMs that no longer exist (e.g. a VM deleted in Hyper-V
# Manager instead of with Remove-AicVm, or a removal that stopped half way).

function Get-AicLeftovers {
    $names = @(Get-AicState | ForEach-Object { $_.Name })
    $items = New-Object System.Collections.Generic.List[object]

    Get-LocalUser -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'aic-*' -and ("$($_.Description)" -like 'Terrarium*' -or "$($_.Description)" -like 'AI Cage*') -and $names -notcontains $_.Name.Substring(4) } |
        ForEach-Object { $items.Add([pscustomobject]@{ Kind = 'Account'; Name = $_.Name; Detail = 'share account'; Sid = $_.SID.Value }) }

    Get-SmbShare -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'AICage-*' -and $names -notcontains $_.Name.Substring(7) } |
        ForEach-Object { $items.Add([pscustomobject]@{ Kind = 'Share'; Name = $_.Name; Detail = $_.Path; Sid = $null }) }

    Get-NetFirewallRule -Name 'AICage-SMB-*' -ErrorAction SilentlyContinue |
        Where-Object { $names -notcontains $_.Name.Substring(11) } |
        ForEach-Object { $items.Add([pscustomobject]@{ Kind = 'Firewall'; Name = $_.Name; Detail = $_.DisplayName; Sid = $null }) }

    $putty = 'HKCU:\Software\SimonTatham\PuTTY\Sessions'
    if (Test-Path $putty) {
        Get-ChildItem $putty | Where-Object { $_.PSChildName -like 'AICage-*' -and $names -notcontains $_.PSChildName.Substring(7) } |
            ForEach-Object { $items.Add([pscustomobject]@{ Kind = 'PuTTY'; Name = $_.PSChildName; Detail = 'saved PuTTY session'; Sid = $null }) }
    }

    # Port forwards to an address in the VM subnet that no VM has any more.
    $ips = @(Get-AicState | ForEach-Object { $_.Ip })
    Get-AicPortProxy | Where-Object { $_.ConnectAddress -like "$((Get-AicConfig).SubnetBase).*" -and $ips -notcontains $_.ConnectAddress } |
        ForEach-Object { $items.Add([pscustomobject]@{ Kind = 'Port'; Name = "$($_.ListenAddress):$($_.ListenPort)"; Detail = "forward to $($_.ConnectAddress):$($_.ConnectPort)"; Sid = $_ }) }

    # The fixed folder AI Cage 0.1 used, unless it is still the tool folder or holds a VM.
    $old = 'C:\AICage'
    $root = (Get-AicConfig).Root.TrimEnd('\')
    if ((Test-Path -LiteralPath $old) -and $root -ine $old -and -not (Test-AicFolderHasVm $old)) {
        $items.Add([pscustomobject]@{ Kind = 'Folder'; Name = $old; Detail = 'files of AI Cage 0.1 (old images, logs, keys)'; Sid = $null })
    }
    return $items.ToArray()
}

function Test-AicFolderHasVm([string]$Path) {
    $p = $Path.TrimEnd('\') + '\'
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        if ("$($vm.Path)\" -like "$p*") { return $true }
        foreach ($d in @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue)) { if ("$($d.Path)" -like "$p*") { return $true } }
    }
    return $false
}

function Remove-AicLeftovers {
    <#
    .SYNOPSIS
    Removes share accounts, shares, firewall rules and PuTTY sessions of VMs that no longer
    exist, and the folder of AI Cage 0.1 (C:\AICage) when no VM uses it.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    if (-not (Test-AicAdmin)) { throw 'Run as Administrator.' }
    $items = @(Get-AicLeftovers)
    if (-not $items.Count) { Write-Host 'Nothing left over.'; return }
    if (-not $PSCmdlet.ShouldProcess("$($items.Count) leftover item(s)", 'Remove')) { return }
    Start-AicLog 'cleanup'
    Initialize-AicNative
    $sharePaths = @($items | Where-Object Kind -eq 'Share' | ForEach-Object { $_.Detail })
    foreach ($it in $items) {
        try {
            switch ($it.Kind) {
                'Share' { Write-AicLog "Remove-SmbShare $($it.Name)" -Level Cmd; Remove-SmbShare -Name $it.Name -Force }
                'Firewall' { Write-AicLog "Remove-NetFirewallRule $($it.Name)" -Level Cmd; Remove-NetFirewallRule -Name $it.Name }
                'PuTTY' { Write-AicLog "Remove PuTTY session $($it.Name)" -Level Cmd; Remove-Item "HKCU:\Software\SimonTatham\PuTTY\Sessions\$($it.Name)" -Recurse -Force }
                'Port' { Remove-AicPortProxy -Entry $it.Sid }
                'Account' {
                    Write-AicLog "Remove user rights and account $($it.Name)" -Level Cmd
                    [AiCage.Native.Lsa]::RemoveAllRights($it.Sid)
                    foreach ($sp in $sharePaths) {
                        if ($sp -and (Test-Path -LiteralPath $sp)) {
                            Invoke-AicNative -FilePath 'icacls.exe' -ArgumentList @($sp, '/remove', "*$($it.Sid)") -Quiet -OkExitCodes 0, 1332 | Out-Null
                        }
                    }
                    Remove-LocalUser -SID $it.Sid
                }
                'Folder' {
                    if (Test-AicFolderHasVm $it.Name) { Write-AicLog "Kept $($it.Name): a VM uses it" -Level Warn; continue }
                    Write-AicLog "Remove-Item $($it.Name) -Recurse" -Level Cmd
                    Remove-Item -LiteralPath $it.Name -Recurse -Force
                }
            }
        } catch {
            Write-AicLog "Could not remove $($it.Kind) $($it.Name): $($_.Exception.Message)" -Level Error
        }
    }
    Write-AicLog 'Cleanup finished.' -Level Ok
}

# ---- Private/CloudInit.ps1 ------------------------------------------------------------
# cloud-init "NoCloud" seed: a tiny ISO labelled "cidata" that configures the VM on first boot.

$script:AicTimeZones = @{
    'Central European Standard Time' = 'Europe/Warsaw'
    'W. Europe Standard Time'        = 'Europe/Berlin'
    'Romance Standard Time'          = 'Europe/Paris'
    'GMT Standard Time'              = 'Europe/London'
    'FLE Standard Time'              = 'Europe/Kyiv'
    'E. Europe Standard Time'        = 'Europe/Chisinau'
    'GTB Standard Time'              = 'Europe/Bucharest'
    'Russian Standard Time'          = 'Europe/Moscow'
    'Eastern Standard Time'          = 'America/New_York'
    'Central Standard Time'          = 'America/Chicago'
    'Mountain Standard Time'         = 'America/Denver'
    'Pacific Standard Time'          = 'America/Los_Angeles'
    'UTC'                            = 'Etc/UTC'
}

$script:AicKeyboards = @{ pl = 'pl'; de = 'de'; fr = 'fr'; gb = 'gb'; us = 'us'; cz = 'cz'; sk = 'sk'; ua = 'ua'; es = 'es'; it = 'it' }

function Get-AicDefaultTimeZone {
    $id = (Get-TimeZone).Id
    if ($script:AicTimeZones.ContainsKey($id)) { return $script:AicTimeZones[$id] }
    Write-AicLog "No Linux name known for Windows time zone '$id' - using UTC (pass -TimeZone to choose)" -Level Warn
    return 'Etc/UTC'
}

function Get-AicDefaultKeyboard {
    $tag = (Get-Culture).Name                  # e.g. pl-PL
    $cc = ($tag -split '-')[-1].ToLower()
    if ($cc -eq 'uk') { $cc = 'gb' }
    if ($script:AicKeyboards.ContainsKey($cc)) { return $script:AicKeyboards[$cc] }
    return 'us'
}

function ConvertTo-AicYamlString([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function ConvertTo-AicB64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($s -replace "`r`n", "`n"))) }

# Runs as root. Written to disk every 30 s (not 5 min), so even a hard hang leaves its traces.
$script:AicJournalSetup = 'mkdir -p /etc/systemd/journald.conf.d /var/log/journal && printf "[Journal]\nStorage=persistent\nSyncIntervalSec=30s\n" > /etc/systemd/journald.conf.d/terrarium.conf && systemd-tmpfiles --create --prefix /var/log/journal && systemctl restart systemd-journald'

function New-AicFirstBootScript {
    param($State, [string]$Keyboard)
    $ro = if ($State.SharedReadOnly) { '1' } else { '0' }
    $lines = @(
        '#!/bin/bash'
        '# Terrarium first-boot setup. Runs once, from cloud-init; output lands in /var/log/cloud-init-output.log.'
        'set -u'
        "USER_NAME='$($State.User)'; HOST_IP='$(Get-AicHostIp)'; SHARE='$($State.ShareName)'; RO='$ro'; KB='$Keyboard'"
        'log() { echo "aicage: $*"; }'
        ''
        'if [ -f /etc/locale.gen ]; then'
        '  sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen'
        '  locale-gen >/dev/null && update-locale LANG=en_US.UTF-8 && log "locale en_US.UTF-8"'
        'fi'
        '[ -f /etc/default/keyboard ] && sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"$KB\"/" /etc/default/keyboard'
        '# Keep the system log across restarts: after a hang, "journalctl -b -1" shows what happened.'
        $script:AicJournalSetup
        ''
        'uid=$(id -u "$USER_NAME"); gid=$(id -g "$USER_NAME")'
        'opts="credentials=/root/.smb-aicage,uid=$uid,gid=$gid,vers=3.1.1,file_mode=0664,dir_mode=0775,_netdev,nofail,x-systemd.automount"'
        '[ "$RO" = 1 ] && opts="ro,$opts"'
        'mkdir -p /mnt/shared'
        'grep -q " /mnt/shared " /etc/fstab || echo "//$HOST_IP/$SHARE /mnt/shared cifs $opts 0 0" >> /etc/fstab'
        'systemctl daemon-reload'
        'systemctl restart remote-fs.target || true'
        'if ls /mnt/shared >/dev/null 2>&1; then log "shared folder mounted at /mnt/shared"; else log "WARNING: shared folder did not mount"; fi'
        'ln -sfn /mnt/shared "/home/$USER_NAME/shared" && chown -h "$USER_NAME:$USER_NAME" "/home/$USER_NAME/shared"'
        ''
        'if [ -x /usr/local/sbin/aicage-setup.sh ]; then'
        '  log "running setup script"'
        '  USER_NAME="$USER_NAME" /usr/local/sbin/aicage-setup.sh || { log "ERROR: setup script failed with code $?"; exit 1; }'
        'fi'
        ''
        '# Once cloud-init has finished: switch it off for later boots (the seed disk is removed) and'
        '# delete its copies of user-data, which contain the passwords.'
        'systemd-run --no-block --unit=aicage-scrub /bin/sh -c "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 2; done; sleep 3; touch /etc/cloud/cloud-init.disabled; rm -f /var/lib/cloud/instances/*/user-data.txt* /var/lib/cloud/instances/*/cloud-config.txt /var/lib/cloud/instances/*/obj.pkl /run/cloud-init/instance-data-sensitive.json /run/cloud-init/combined-cloud-config.json" || log "WARNING: could not schedule the user-data cleanup"'
        'log "first boot setup finished"'
    )
    return ($lines -join "`n") + "`n"
}

function New-AicUserData {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$LinuxPassword,
        [Parameter(Mandatory)][string]$SharePassword,
        [Parameter(Mandatory)][string]$PublicKey,
        [string]$TimeZone, [string]$Keyboard,
        [string[]]$Packages, [string]$SetupScript,
        [bool]$PasswordlessSudo, [bool]$Upgrade, [int]$SwapMB
    )
    $q = { param($s) ConvertTo-AicYamlString $s }
    $y = New-Object System.Collections.Generic.List[string]
    $y.Add('#cloud-config')
    $y.Add("hostname: $($State.Name)")
    $y.Add('manage_etc_hosts: true')
    $y.Add("timezone: $(& $q $TimeZone)")
    $y.Add('users:')
    $y.Add("  - name: $(& $q $State.User)")
    $y.Add("    gecos: 'Terrarium user'")
    $y.Add('    groups: [sudo, adm]')
    $y.Add('    shell: /bin/bash')
    if ($PasswordlessSudo) { $y.Add("    sudo: 'ALL=(ALL) NOPASSWD:ALL'") }
    $y.Add('    ssh_authorized_keys:')
    $y.Add("      - $(& $q $PublicKey.Trim())")
    $y.Add('chpasswd:')
    $y.Add('  expire: false')
    $y.Add('  users:')
    $y.Add("    - name: $(& $q $State.User)")
    $y.Add("      password: $(& $q $LinuxPassword)")
    $y.Add('      type: text')
    $y.Add('ssh_pwauth: true')
    $y.Add('disable_root: true')
    $y.Add('package_update: true')
    $y.Add("package_upgrade: $(if ($Upgrade) { 'true' } else { 'false' })")
    $y.Add('packages:')
    foreach ($p in $Packages) { $y.Add("  - $(& $q $p)") }
    if ($SwapMB -gt 0) {
        $bytes = [int64]$SwapMB * 1MB
        $y.Add('swap:')
        $y.Add('  filename: /swapfile')
        $y.Add("  size: $bytes")
        $y.Add("  maxsize: $bytes")
    }
    $y.Add('write_files:')
    $y.Add('  - path: /root/.smb-aicage')
    $y.Add("    owner: 'root:root'")
    $y.Add("    permissions: '0600'")
    $y.Add('    encoding: b64')
    $y.Add("    content: $(ConvertTo-AicB64 "username=$($State.ShareAccount)`npassword=$SharePassword`n")")
    $y.Add('  - path: /usr/local/sbin/aicage-firstboot.sh')
    $y.Add("    permissions: '0755'")
    $y.Add('    encoding: b64')
    $y.Add("    content: $(ConvertTo-AicB64 (New-AicFirstBootScript -State $State -Keyboard $Keyboard))")
    if ($SetupScript) {
        $y.Add('  - path: /usr/local/sbin/aicage-setup.sh')
        $y.Add("    permissions: '0755'")
        $y.Add('    encoding: b64')
        $y.Add("    content: $(ConvertTo-AicB64 $SetupScript)")
    }
    $y.Add('runcmd:')
    $y.Add('  - [bash, /usr/local/sbin/aicage-firstboot.sh]')
    $y.Add("final_message: 'Terrarium: cloud-init finished after `$UPTIME seconds'")
    return ($y -join "`n") + "`n"
}

function New-AicNetworkConfig {
    param([Parameter(Mandatory)][string]$Ip)
    $cfg = Get-AicConfig
    $dns = ($cfg.Dns | ForEach-Object { $_ }) -join ', '
    return @(
        'version: 2'
        'ethernets:'
        '  eth0:'
        '    match:'
        '      driver: hv_netvsc'
        '    set-name: eth0'
        "    addresses: [$Ip/24]"
        '    routes:'
        '      - to: default'
        "        via: $(Get-AicHostIp)"
        '    nameservers:'
        "      addresses: [$dns]"
    ) -join "`n"
}

function New-AicSeedIso {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$UserData,
          [Parameter(Mandatory)][string]$MetaData, [Parameter(Mandatory)][string]$NetworkConfig)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('aicage-seed-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $utf8 = New-Object Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $tmp 'user-data'), $UserData, $utf8)
        [IO.File]::WriteAllText((Join-Path $tmp 'meta-data'), $MetaData, $utf8)
        [IO.File]::WriteAllText((Join-Path $tmp 'network-config'), $NetworkConfig, $utf8)

        Initialize-AicNative
        Write-AicLog 'Building seed ISO with IMAPI2FS (label cidata)' -Level Cmd
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 3          # ISO9660 + Joliet (keeps the long file names)
        $fsi.VolumeName = 'cidata'
        $fsi.Root.AddTree($tmp, $false)
        $img = $fsi.CreateResultImage()
        [AiCage.Native.Iso]::SaveStream($img.ImageStream, $Path)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- Private/Config.ps1 ---------------------------------------------------------------
# Defaults. Override any of them in config.json, e.g. { "SubnetBase": "192.168.252" }; it is read
# from <your home>\.aicage and from the tool folder (the tool folder wins).
# The subnet differs from the manual setup guide (192.168.250.x) so both can live side by side.
# Two places can hold VMs: <your home>\.aicage ("Home", also Terrarium's own logs, image cache and
# settings) and the program folder ("Program"). Each VM is in one of them, chosen when it is
# made; Terrarium looks in both. Root is the Home place ("Root" in config.json overrides it).

$script:AicVersion = '0.4.0'

# Terrarium.ps1 (the single-file build) passes the tool folder as $AicToolRoot; the module form
# (development) finds it as the parent of the module folder.
$script:AicToolRootValue = Get-Variable -Name AicToolRoot -ValueOnly -ErrorAction SilentlyContinue
if (-not $script:AicToolRootValue) { $script:AicToolRootValue = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:AicHome = Join-Path $env:USERPROFILE '.aicage'

$script:AicDefaults = [ordered]@{
    Root        = $null
    SwitchName  = 'AICage'
    NatName     = 'AICageNAT'
    SubnetBase  = '192.168.251'          # a /24: host is .1, VMs get .10 and up
    FirstVmHost = 10
    Dns         = @('1.1.1.1', '9.9.9.9')
    ImageBase   = 'https://cloud.debian.org/images/cloud/trixie/latest'
    ImageName   = 'debian-13-generic-amd64'
}

$script:AicConfigCache = $null

function Get-AicConfig {
    <#
    .SYNOPSIS
    Shows the settings Terrarium uses (defaults merged with <Root>\config.json).
    #>
    [CmdletBinding()]
    param()
    if ($script:AicConfigCache) { return $script:AicConfigCache }

    $cfg = [ordered]@{}
    foreach ($k in $script:AicDefaults.Keys) { $cfg[$k] = $script:AicDefaults[$k] }

    foreach ($file in (Get-AicUserConfigPath), (Join-Path $script:AicToolRootValue 'config.json')) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $over = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        foreach ($p in $over.PSObject.Properties) {
            if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
        }
    }
    if (-not $cfg.Root) { $cfg.Root = $script:AicHome }
    $cfg.Root = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($cfg.Root)).TrimEnd('\')
    $script:AicConfigCache = [pscustomobject]$cfg
    return $script:AicConfigCache
}

function Get-AicUserConfigPath { Join-Path $script:AicHome 'config.json' }

function Get-AicLocationRoot {
    param([ValidateSet('Home', 'Program')][string]$Location = 'Home')
    if ($Location -eq 'Program') { return $script:AicToolRootValue.TrimEnd('\') }
    return (Get-AicConfig).Root
}

function Get-AicLocations {
    # The places that can hold VMs, Home first; just Home when the program runs from it.
    if ((Get-AicLocationRoot Home) -ieq (Get-AicLocationRoot Program)) { return @('Home') }
    return @('Home', 'Program')
}

function Get-AicStateLocation($State) {
    if ($State.PSObject.Properties['Location'] -and $State.Location -eq 'Program') { return 'Program' }
    return 'Home'
}

# Layout of each place: <place>\logs and <place>\data\{images,keys,ssh,vms,shared,network.json}.
# Per VM (in the VM's place): vms\<name>, keys\<name>, ssh\known_hosts, shared\<name>.
# Terrarium's own (always Home): logs, images, network.json, settings.json, ssh\config.
$script:AicDataDirs = @{ Vms = 'vms'; Images = 'images'; Keys = 'keys'; Ssh = 'ssh'; Shared = 'shared' }

function Get-AicPath {
    param([ValidateSet('Root', 'Data', 'Vms', 'Images', 'Keys', 'Ssh', 'Logs', 'Shared')][string]$Kind,
          [ValidateSet('Home', 'Program')][string]$Location = 'Home')
    $root = Get-AicLocationRoot $Location
    $path = switch ($Kind) {
        'Root' { $root }
        'Logs' { Join-Path $root 'logs' }
        'Data' { Join-Path $root 'data' }
        default { Join-Path (Join-Path $root 'data') $script:AicDataDirs[$Kind] }
    }
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    return $path
}

function Get-AicHostIp { return '{0}.1' -f (Get-AicConfig).SubnetBase }

# ---- Choices made in the window: <Root>\data\settings.json ------------------------------
# A plain file next to the VMs, never the registry, so deleting the folder removes them too.

function Get-AicSettingsPath { Join-Path (Get-AicPath Data) 'settings.json' }

function Get-AicSetting {
    param([Parameter(Mandatory)][string]$Name, $Default = $null)
    $p = Get-AicSettingsPath
    if (-not (Test-Path -LiteralPath $p)) { return $Default }
    try { $all = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { return $Default }
    if ($all -and $all.PSObject.Properties[$Name]) { return $all.$Name }
    return $Default
}

function Set-AicSetting {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $p = Get-AicSettingsPath
    $all = [ordered]@{}
    if (Test-Path -LiteralPath $p) {
        try { (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $all[$_.Name] = $_.Value } } catch { }
    }
    $all[$Name] = $Value
    [pscustomobject]$all | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $p -Encoding UTF8
}

# ---- Per-VM state: <Root>\vms\<name>\aicage.json ---------------------------------------

function Get-AicStatePath {
    # <place>\data\vms\<name>\aicage.json; without -Location, the place that has it (Home if none).
    param([string]$Name, [string]$Location)
    if (-not $Location) {
        $Location = 'Home'
        foreach ($l in Get-AicLocations) {
            if (Test-Path -LiteralPath (Get-AicStatePath -Name $Name -Location $l)) { $Location = $l; break }
        }
    }
    return Join-Path (Join-Path (Join-Path (Get-AicLocationRoot $Location) "data\$($script:AicDataDirs.Vms)") $Name) 'aicage.json'
}

function Read-AicStateFile([string]$Path, [string]$Location) {
    # Location comes from where the file is, so a VM folder copied by hand is found correctly.
    $s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $s | Add-Member -NotePropertyName Location -NotePropertyValue $Location -Force
    return $s
}

function Get-AicState {
    param([string]$Name)
    foreach ($l in Get-AicLocations) {
        if ($Name) {
            $p = Get-AicStatePath -Name $Name -Location $l
            if (Test-Path -LiteralPath $p) { return Read-AicStateFile $p $l }
            continue
        }
        # Not Get-AicPath: looking must not create folders in the program folder.
        $vms = Join-Path (Get-AicLocationRoot $l) "data\$($script:AicDataDirs.Vms)"
        if (-not (Test-Path -LiteralPath $vms)) { continue }
        Get-ChildItem -LiteralPath $vms -Directory | ForEach-Object {
            $p = Join-Path $_.FullName 'aicage.json'
            if (Test-Path -LiteralPath $p) { Read-AicStateFile $p $l }
        }
    }
    if ($Name) { return $null }
}

function Save-AicState {
    param([Parameter(Mandatory)]$State)
    $p = Get-AicStatePath -Name $State.Name -Location (Get-AicStateLocation $State)
    $dir = Split-Path $p
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $p -Encoding UTF8
}

function Get-AicState1 {
    # Like Get-AicState but fails with a clear message when the VM is unknown.
    param([Parameter(Mandatory)][string]$Name)
    $s = Get-AicState -Name $Name
    if (-not $s) { throw "No Terrarium VM named '$Name'. Get-AicVm lists them." }
    return $s
}

function Get-AicNextIp {
    $cfg = Get-AicConfig
    $used = @(Get-AicState | ForEach-Object { $_.Ip })
    # Also skip addresses other VMs report (e.g. a manually made VM on a shared subnet).
    try { $used += @(Get-VM | Get-VMNetworkAdapter | ForEach-Object { $_.IPAddresses }) } catch { }
    for ($i = [int]$cfg.FirstVmHost; $i -lt 250; $i++) {
        $ip = '{0}.{1}' -f $cfg.SubnetBase, $i
        if ($used -notcontains $ip) { return $ip }
    }
    throw "No free address left in $($cfg.SubnetBase).0/24."
}

function New-AicPassword {
    # Letters and digits only (safe in YAML, fstab credentials and cmd lines), with at least
    # one upper, lower and digit so it passes the Windows complexity policy.
    param([int]$Length = 24)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $lower = 'abcdefghijkmnopqrstuvwxyz'; $digit = '23456789'
    $all = $upper + $lower + $digit
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    do {
        $rng.GetBytes($bytes)
        $pw = -join ($bytes | ForEach-Object { $all[$_ % $all.Length] })
    } until ($pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and $pw -match '[0-9]')
    return $pw
}

function ConvertFrom-AicSecureString([Security.SecureString]$Secure) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Move-AicOldLayout {
    # 0.2 kept images, keys, ssh, vms, shared and network.json directly in the program folder;
    # they now live in its data folder. Moved once, as Administrator (the folders are locked to
    # Administrators). Then Terrarium's own files of 0.3 move from there to Home.
    $root = Get-AicLocationRoot Program
    $data = Join-Path $root 'data'
    foreach ($kind in @($script:AicDataDirs.get_Keys())) {   # not .Keys: one entry is named Keys
        $old = Join-Path $root $script:AicDataDirs[$kind]
        if (-not (Test-Path -LiteralPath $old -PathType Container)) { continue }
        if (-not (Test-Path -LiteralPath $data)) { New-Item -ItemType Directory -Path $data -Force | Out-Null }
        $new = Join-Path $data $script:AicDataDirs[$kind]
        $oldItems = @(Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue)
        if ($kind -eq 'Vms' -and $oldItems.Count) {
            Write-AicLog "Kept $old where it is: it contains VMs, and Hyper-V would lose them if moved" -Level Warn
            continue
        }
        if (Test-Path -LiteralPath $new) {
            if (@(Get-ChildItem -LiteralPath $new -Force).Count) { Write-AicLog "Both $old and $new exist - kept both, please merge by hand" -Level Warn; continue }
            Remove-Item -LiteralPath $new -Force
        }
        if ($oldItems.Count) {
            Write-AicLog "Move $old -> $new" -Level Cmd
            Move-Item -LiteralPath $old -Destination $new
        } else {
            Remove-Item -LiteralPath $old -Force
        }
    }
    $oldNet = Join-Path $root 'network.json'
    if ((Test-Path -LiteralPath $oldNet) -and -not (Test-Path -LiteralPath (Join-Path $data 'network.json'))) {
        if (-not (Test-Path -LiteralPath $data)) { New-Item -ItemType Directory -Path $data -Force | Out-Null }
        Write-AicLog "Move $oldNet -> $data" -Level Cmd; Move-Item -LiteralPath $oldNet -Destination $data
    }
    $marker = Join-Path $root '.acl-set'          # left by 0.1
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }

    # 0.3 kept everything in the program folder. Its VMs stay there (the Program place); Terrarium's
    # own files move to Home, unless Home already has them.
    if ((Get-AicLocations) -notcontains 'Program' -or -not (Test-Path -LiteralPath $data)) { return }
    foreach ($item in 'images', 'network.json', 'settings.json') {
        $old = Join-Path $data $item
        $new = Join-Path (Get-AicPath Data) $item
        if (-not (Test-Path -LiteralPath $old)) { continue }
        if ($item -eq 'images' -and -not @(Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue).Count) { Remove-Item -LiteralPath $old -Force; continue }
        if (Test-Path -LiteralPath $new) {
            if ($item -ne 'images' -or @(Get-ChildItem -LiteralPath $new -Force).Count) { Write-AicLog "Both $old and $new exist - kept both" -Level Debug; continue }
            Remove-Item -LiteralPath $new -Force
        }
        Write-AicLog "Move $old -> $new" -Level Cmd
        Move-Item -LiteralPath $old -Destination $new
    }
}

function Initialize-AicRoot {
    # The tool folder may be visible to a VM (e.g. the manual guide's shared folder). Logs stay
    # readable there, but the folders holding secrets or things a VM must not tamper with are
    # limited to Administrators, SYSTEM and you: SSH keys, VM disks and seed ISOs, the base image
    # and the per-VM shared folders (each share account gets its own explicit grant).
    Move-AicOldLayout
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $grants = @('/grant:r', '*S-1-5-32-544:(OI)(CI)F', '/grant:r', '*S-1-5-18:(OI)(CI)F', '/grant:r', "*${me}:(OI)(CI)F")
    $dirs = @('Keys', 'Ssh', 'Vms', 'Images', 'Shared' | ForEach-Object { [pscustomobject]@{ Kind = $_; Location = 'Home' } })
    # The program folder's data folder only when it is in use (it is not created for nothing).
    if ((Get-AicLocations) -contains 'Program' -and (Test-Path -LiteralPath (Join-Path (Get-AicLocationRoot Program) 'data'))) {
        $dirs += 'Keys', 'Ssh', 'Vms', 'Shared' | ForEach-Object { [pscustomobject]@{ Kind = $_; Location = 'Program' } }
    }
    foreach ($d in $dirs) {
        $kind = $d.Kind
        $dir = Get-AicPath $kind -Location $d.Location
        if ((Get-Acl -LiteralPath $dir).AreAccessRulesProtected) { continue }
        Invoke-AicNative -FilePath 'icacls.exe' -Quiet -ArgumentList (@($dir, '/inheritance:r') + $grants) | Out-Null
        # Files already in keys and ssh get a private ACL too (OpenSSH refuses keys others can read).
        # VM folders are left alone: Hyper-V puts its own grants on the disk files.
        if ($kind -in 'Keys', 'Ssh') {
            Get-ChildItem -LiteralPath $dir -File | ForEach-Object { Set-AicPrivateAcl -Path $_.FullName }
        }
        Write-AicLog "Restricted $dir to Administrators, SYSTEM and you" -Level Debug
    }
}

# ---- Private/Image.ps1 ----------------------------------------------------------------
# Debian cloud image: download once, verify, convert to a cached base VHDX.

function Get-AicDownload {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        # -L: cloud.debian.org redirects to a mirror.
        Invoke-AicNative -FilePath $curl.Source -ArgumentList @('-fsSL', '--retry', '3', '-o', $OutFile, $Url) | Out-Null
    } else {
        Write-AicLog "Invoke-WebRequest $Url" -Level Cmd
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 very slow
        try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing } finally { $ProgressPreference = $old }
    }
}

function Get-AicBaseImage {
    # Returns the path of the cached base VHDX for the configured Debian image.
    $cfg = Get-AicConfig
    $dir = Get-AicPath Images
    $file = "$($cfg.ImageName).qcow2"

    $sums = Join-Path $dir 'SHA512SUMS'
    $expected = $null
    try {
        Get-AicDownload -Url "$($cfg.ImageBase)/SHA512SUMS" -OutFile $sums
        $line = Get-Content -LiteralPath $sums | Where-Object { $_ -match "\s$([regex]::Escape($file))$" } | Select-Object -First 1
        if ($line) { $expected = ($line -split '\s+')[0].ToUpper() }
    } catch {
        Write-AicLog "Could not fetch the checksum list: $($_.Exception.Message)" -Level Warn
    }

    if ($expected) {
        $vhdx = Join-Path $dir ('{0}-{1}.vhdx' -f $cfg.ImageName, $expected.Substring(0, 12).ToLower())
    } else {
        # Offline: fall back to the newest cached image.
        $cached = Get-ChildItem -LiteralPath $dir -Filter "$($cfg.ImageName)-*.vhdx" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($cached) { Write-AicLog "Offline - using cached image $($cached.Name)" -Level Warn; return $cached.FullName }
        throw 'Cannot reach cloud.debian.org and no cached image exists.'
    }

    if (Test-Path -LiteralPath $vhdx) {
        Write-AicLog "Using cached base image $vhdx" -Level Debug
        return $vhdx
    }

    $qcow = Join-Path $dir $file
    $haveGood = $false
    if (Test-Path -LiteralPath $qcow) {
        $haveGood = (Get-FileHash -LiteralPath $qcow -Algorithm SHA512).Hash -eq $expected
    }
    if (-not $haveGood) {
        Write-AicLog "Downloading $file (about 420 MB, once)..." -Level Info
        Get-AicDownload -Url "$($cfg.ImageBase)/$file" -OutFile $qcow
        $actual = (Get-FileHash -LiteralPath $qcow -Algorithm SHA512).Hash
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $qcow -Force
            throw "Checksum mismatch for $file (download damaged). Try again."
        }
        Write-AicLog 'SHA512 checksum matches debian.org' -Level Debug
    }

    Initialize-AicNative
    $vhd = [IO.Path]::ChangeExtension($vhdx, '.tmp.vhd')
    Write-AicLog 'Converting qcow2 -> VHD (built-in converter)' -Level Info
    [void][AiCage.Native.Qcow2]::ConvertToFixedVhd($qcow, $vhd, [Action[int]] { param($p) Write-AicLog "  $p%" -Level Debug })

    Write-AicLog "Convert-VHD -Path $vhd -DestinationPath $vhdx -VHDType Dynamic" -Level Cmd
    Convert-VHD -Path $vhd -DestinationPath $vhdx -VHDType Dynamic
    Remove-Item -LiteralPath $vhd -Force
    Remove-Item -LiteralPath $qcow -Force
    # Older cached versions are no longer needed.
    Get-ChildItem -LiteralPath $dir -Filter "$($cfg.ImageName)-*.vhdx" | Where-Object { $_.FullName -ne $vhdx } |
        ForEach-Object { Write-AicLog "Removing old image $($_.Name)" -Level Debug; Remove-Item -LiteralPath $_.FullName -Force }
    return $vhdx
}

# ---- Private/Log.ps1 ------------------------------------------------------------------
# Logging: every line goes to the console, to a per-operation log file and to any registered
# sinks (the GUI registers one to show a live log console).

$script:AicLogFile = $null
$script:AicLogSinks = New-Object System.Collections.ArrayList

function Register-AicLogSink {
    <#
    .SYNOPSIS
    Registers a scriptblock called as & $sink $level $message for every log line.
    #>
    param([Parameter(Mandatory)][scriptblock]$Sink)
    [void]$script:AicLogSinks.Add($Sink)
}

function Unregister-AicLogSink {
    param([Parameter(Mandatory)][scriptblock]$Sink)
    $script:AicLogSinks.Remove($Sink)
}

function Get-AicLogPath {
    <#
    .SYNOPSIS
    Path of the current (or latest) log file - send it along when reporting a problem.
    #>
    if ($script:AicLogFile) { return $script:AicLogFile }
    Get-ChildItem -LiteralPath (Get-AicPath Logs) -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Start-AicLog {
    param([Parameter(Mandatory)][string]$Operation)
    $script:AicConfigCache = $null      # pick up config.json edits without re-importing
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:AicLogFile = Join-Path (Get-AicPath Logs) "$stamp-$Operation.log"
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $osText = if ($os) { '{0} {1} (build {2})' -f $os.Caption, $os.OSArchitecture, $os.BuildNumber } else { 'unknown' }
    Write-AicLog "Terrarium $script:AicVersion - $Operation" -Level Info
    Write-AicLog "Windows: $osText; PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)" -Level Debug
    Write-AicLog "Log file: $script:AicLogFile" -Level Debug

    # Keep the newest 50 logs.
    Get-ChildItem -LiteralPath (Get-AicPath Logs) -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 50 |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    # Folder layout and protection, logged into this operation's log.
    $admin = $false
    try { $admin = Test-AicAdmin } catch { }
    if ($admin) {
        try { Initialize-AicRoot } catch { Write-AicLog "Could not protect the data folders: $($_.Exception.Message)" -Level Warn }
    }
}

function Write-AicLog {
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Step', 'Ok', 'Warn', 'Error', 'Cmd', 'Guest', 'Debug')][string]$Level = 'Info'
    )
    $colors = @{ Info = 'Gray'; Step = 'Cyan'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red'; Cmd = 'DarkCyan'; Guest = 'DarkGray'; Debug = 'DarkGray' }
    $prefix = @{ Info = ''; Step = '==> '; Ok = '  ok '; Warn = ' !!  '; Error = ' XX  '; Cmd = '  > '; Guest = '  | '; Debug = '    ' }[$Level]
    $line = '{0} {1,-5} {2}{3}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $prefix, $Message

    Write-Host $line -ForegroundColor $colors[$Level]
    if ($script:AicLogFile) {
        try { Add-Content -LiteralPath $script:AicLogFile -Value $line -Encoding UTF8 } catch { }
    }
    foreach ($sink in @($script:AicLogSinks)) {
        try { & $sink $Level $Message } catch { }
    }
}

function Invoke-AicStep {
    # Runs one named step, logs its duration and turns failures into a clear log line.
    param([Parameter(Mandatory)][string]$StepTitle, [Parameter(Mandatory)][scriptblock]$StepScript)
    Write-AicLog $StepTitle -Level Step
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $StepScript
        Write-AicLog ('done in {0:n1}s' -f $sw.Elapsed.TotalSeconds) -Level Ok
        return $result
    } catch {
        Write-AicLog "FAILED: $StepTitle - $($_.Exception.Message)" -Level Error
        $pos = $_.InvocationInfo.PositionMessage
        if ($pos) { $pos -split "`r?`n" | ForEach-Object { Write-AicLog $_ -Level Debug } }
        throw
    }
}

function Invoke-AicNative {
    # Runs an external program, logs the call and every output line, throws on a non-zero exit.
    # Do not pass empty-string arguments: Windows PowerShell 5.1 drops them.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$LogLevel = 'Debug',
        [string]$DisplayArgs,           # shown instead of the real arguments (hide secrets)
        [int[]]$OkExitCodes = @(0),
        [switch]$Quiet                   # do not log output lines, just return them
    )
    $shown = if ($DisplayArgs) { $DisplayArgs } else { $ArgumentList -join ' ' }
    Write-AicLog "$FilePath $shown" -Level Cmd

    $ErrorActionPreference = 'Continue'     # stderr lines of native programs are not errors here
    $out = New-Object System.Collections.Generic.List[string]
    & $FilePath @ArgumentList 2>&1 | ForEach-Object {
        $text = "$_"
        $out.Add($text)
        if (-not $Quiet) { Write-AicLog $text -Level $LogLevel }
    }
    $code = $LASTEXITCODE
    $script:AicLastExitCode = $code
    if ($OkExitCodes -notcontains $code) {
        if ($Quiet) { $out | Select-Object -Last 20 | ForEach-Object { Write-AicLog $_ -Level Debug } }
        throw "$FilePath exited with code $code"
    }
    return , $out.ToArray()
}

# ---- Private/Native.ps1 ---------------------------------------------------------------
# Small C# helpers for what Windows has no cmdlet for. C# 5 syntax only (Windows PowerShell
# 5.1 compiles Add-Type code with the old csc): no $"..", no "out var", no "=>" members.

$script:AicNativeSource = @'
using System;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace AiCage.Native
{
    // Converts a qcow2 image (v2/v3, zlib-compressed or plain clusters, no backing file) into a
    // fixed VHD: the raw disk followed by a 512-byte VHD footer. Hyper-V's Convert-VHD then
    // turns that into a dynamic VHDX.
    public static class Qcow2
    {
        static ulong BE64(byte[] b, int o) { ulong v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | b[o + i]; return v; }
        static uint BE32(byte[] b, int o) { return (uint)((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]); }

        static void ReadExact(Stream s, long offset, byte[] buf, int count)
        {
            s.Position = offset;
            int got = 0;
            while (got < count)
            {
                int n = s.Read(buf, got, count - got);
                if (n <= 0) throw new EndOfStreamException("qcow2: unexpected end of file");
                got += n;
            }
        }

        public static long GetVirtualSize(string path)
        {
            using (var s = File.OpenRead(path))
            {
                byte[] h = new byte[32];
                ReadExact(s, 0, h, 32);
                return (long)BE64(h, 24);
            }
        }

        // progress: called with 0..100 now and then (may be null). Returns the virtual size.
        public static long ConvertToFixedVhd(string src, string dst, Action<int> progress)
        {
            using (var s = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
            {
                byte[] h = new byte[112];
                ReadExact(s, 0, h, 104);
                if (BE32(h, 0) != 0x514649FB) throw new InvalidDataException("not a qcow2 file");
                uint version = BE32(h, 4);
                if (version != 2 && version != 3) throw new InvalidDataException("qcow2 version " + version + " not supported");
                if (BE64(h, 8) != 0) throw new InvalidDataException("qcow2 with a backing file is not supported");
                int clusterBits = (int)BE32(h, 20);
                long size = (long)BE64(h, 24);
                if (BE32(h, 32) != 0) throw new InvalidDataException("encrypted qcow2 is not supported");
                uint l1Size = BE32(h, 36);
                long l1Offset = (long)BE64(h, 40);
                if (version == 3)
                {
                    ulong incompat = BE64(h, 72);
                    if ((incompat & 0x2) != 0) throw new InvalidDataException("qcow2 is marked corrupt");
                    if ((incompat & 0x4) != 0) throw new InvalidDataException("qcow2 external data file not supported");
                    if ((incompat & 0x10) != 0) throw new InvalidDataException("qcow2 extended L2 entries not supported");
                    if ((incompat & 0x8) != 0)
                    {
                        uint hdrLen = BE32(h, 100);
                        if (hdrLen > 104) { ReadExact(s, 104, h, 1); if (h[0] != 0) throw new InvalidDataException("qcow2 zstd compression not supported"); }
                    }
                }
                if (size % 512 != 0) throw new InvalidDataException("disk size is not a multiple of 512");

                int clusterSize = 1 << clusterBits;
                int l2Entries = clusterSize / 8;
                int csizeShift = 62 - (clusterBits - 8);
                ulong csizeMask = (1UL << (clusterBits - 8)) - 1;
                ulong coffMask = (1UL << csizeShift) - 1;
                const ulong OffMask = 0x00fffffffffffe00UL;

                byte[] l1 = new byte[l1Size * 8];
                ReadExact(s, l1Offset, l1, l1.Length);
                byte[] l2 = new byte[clusterSize];
                byte[] cluster = new byte[clusterSize];
                byte[] cbuf = new byte[clusterSize * 2 + 1024];
                long totalClusters = (size + clusterSize - 1) / clusterSize;
                int lastPct = -1;

                using (var o = new FileStream(dst, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
                {
                    o.SetLength(size);   // unwritten ranges read back as zeros
                    for (long i1 = 0; i1 < l1Size; i1++)
                    {
                        ulong l2Off = BE64(l1, (int)(i1 * 8)) & OffMask;
                        if (l2Off == 0) continue;
                        ReadExact(s, (long)l2Off, l2, clusterSize);
                        for (int i2 = 0; i2 < l2Entries; i2++)
                        {
                            long vcluster = i1 * l2Entries + i2;
                            if (vcluster >= totalClusters) break;
                            ulong e = BE64(l2, i2 * 8);
                            if (e == 0) continue;
                            long vOff = vcluster * clusterSize;
                            int len = (int)Math.Min(clusterSize, size - vOff);

                            if ((e & (1UL << 62)) != 0)
                            {
                                long hostOff = (long)(e & coffMask);
                                long nsect = (long)((e >> csizeShift) & csizeMask);
                                int csize = (int)((nsect + 1) * 512 - (hostOff & 511));
                                long avail = s.Length - hostOff;
                                if (csize > avail) csize = (int)avail;
                                if (csize > cbuf.Length) cbuf = new byte[csize];
                                ReadExact(s, hostOff, cbuf, csize);
                                using (var ms = new MemoryStream(cbuf, 0, csize))
                                using (var ds = new DeflateStream(ms, CompressionMode.Decompress))
                                {
                                    int got = 0;
                                    while (got < clusterSize)
                                    {
                                        int n = ds.Read(cluster, got, clusterSize - got);
                                        if (n <= 0) break;
                                        got += n;
                                    }
                                    if (got < len) throw new InvalidDataException("qcow2: short compressed cluster at " + vOff);
                                }
                            }
                            else
                            {
                                if ((e & 1UL) != 0) continue;          // "reads as zeros" flag
                                long hostOff = (long)(e & OffMask);
                                if (hostOff == 0) continue;            // unallocated
                                ReadExact(s, hostOff, cluster, len);
                            }
                            if (IsZero(cluster, len)) continue;
                            o.Position = vOff;
                            o.Write(cluster, 0, len);

                            if (progress != null)
                            {
                                int pct = (int)(vcluster * 100 / totalClusters);
                                if (pct != lastPct && pct % 10 == 0) { lastPct = pct; progress(pct); }
                            }
                        }
                    }
                    o.Position = size;
                    byte[] footer = Vhd.Footer(size);
                    o.Write(footer, 0, footer.Length);
                }
                if (progress != null) progress(100);
                return size;
            }
        }

        static bool IsZero(byte[] b, int len)
        {
            for (int i = 0; i < len; i++) if (b[i] != 0) return false;
            return true;
        }
    }

    // Footer of a fixed VHD (Microsoft "Virtual Hard Disk Image Format Specification").
    public static class Vhd
    {
        static void PutBE(byte[] b, int o, ulong v, int n) { for (int i = n - 1; i >= 0; i--) { b[o + i] = (byte)(v & 0xFF); v >>= 8; } }
        static void PutAscii(byte[] b, int o, string s) { for (int i = 0; i < s.Length; i++) b[o + i] = (byte)s[i]; }

        public static byte[] Footer(long size)
        {
            byte[] f = new byte[512];
            PutAscii(f, 0, "conectix");
            PutBE(f, 8, 2, 4);                       // features: reserved bit always set
            PutBE(f, 12, 0x00010000, 4);             // format version 1.0
            PutBE(f, 16, 0xFFFFFFFFFFFFFFFFUL, 8);   // data offset: none for fixed disks
            uint stamp = (uint)(DateTime.UtcNow - new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            PutBE(f, 24, stamp, 4);
            PutAscii(f, 28, "aicg");
            PutBE(f, 32, 0x00010000, 4);
            PutAscii(f, 36, "Wi2k");
            PutBE(f, 40, (ulong)size, 8);            // original size
            PutBE(f, 48, (ulong)size, 8);            // current size

            long totalSectors = size / 512;
            if (totalSectors > 65535L * 16 * 255) totalSectors = 65535L * 16 * 255;
            long spt, heads, cth;
            if (totalSectors >= 65535L * 16 * 63) { spt = 255; heads = 16; cth = totalSectors / spt; }
            else
            {
                spt = 17; cth = totalSectors / spt;
                heads = (cth + 1023) / 1024;
                if (heads < 4) heads = 4;
                if (cth >= heads * 1024 || heads > 16) { spt = 31; heads = 16; cth = totalSectors / spt; }
                if (cth >= heads * 1024) { spt = 63; heads = 16; cth = totalSectors / spt; }
            }
            PutBE(f, 56, (ulong)(cth / heads), 2);
            f[58] = (byte)heads;
            f[59] = (byte)spt;
            PutBE(f, 60, 2, 4);                      // disk type: fixed
            Guid.NewGuid().ToByteArray().CopyTo(f, 68);
            uint sum = 0;
            for (int i = 0; i < 512; i++) sum += f[i];   // checksum field (64..67) is still zero
            PutBE(f, 64, ~sum, 4);
            return f;
        }
    }

    // Grants / removes user rights such as SeDenyInteractiveLogonRight (no cmdlet exists).
    public static class Lsa
    {
        [StructLayout(LayoutKind.Sequential)]
        struct UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }

        [StructLayout(LayoutKind.Sequential)]
        struct OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }

        [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr systemName, ref OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
        [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr handle, byte[] sid, UNICODE_STRING[] rights, uint count);
        [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr handle, byte[] sid, bool allRights, UNICODE_STRING[] rights, uint count);
        [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
        [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);

        const uint POLICY_ALL_ACCESS = 0x000F0FFF;
        const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;

        static void Check(uint status) { if (status != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(status)); }

        static byte[] SidBytes(string sid)
        {
            var s = new SecurityIdentifier(sid);
            byte[] b = new byte[s.BinaryLength];
            s.GetBinaryForm(b, 0);
            return b;
        }

        static IntPtr Open()
        {
            var oa = new OBJECT_ATTRIBUTES();
            oa.Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES));
            IntPtr h;
            Check(LsaOpenPolicy(IntPtr.Zero, ref oa, POLICY_ALL_ACCESS, out h));
            return h;
        }

        public static void AddRights(string sid, string[] rights)
        {
            var arr = new UNICODE_STRING[rights.Length];
            for (int i = 0; i < rights.Length; i++)
            {
                arr[i].Buffer = Marshal.StringToHGlobalUni(rights[i]);
                arr[i].Length = (ushort)(rights[i].Length * 2);
                arr[i].MaximumLength = (ushort)(rights[i].Length * 2 + 2);
            }
            IntPtr h = Open();
            try { Check(LsaAddAccountRights(h, SidBytes(sid), arr, (uint)arr.Length)); }
            finally
            {
                LsaClose(h);
                for (int i = 0; i < arr.Length; i++) Marshal.FreeHGlobal(arr[i].Buffer);
            }
        }

        public static void RemoveAllRights(string sid)
        {
            IntPtr h = Open();
            try
            {
                uint st = LsaRemoveAccountRights(h, SidBytes(sid), true, null, 0);
                if (st != 0 && st != STATUS_OBJECT_NAME_NOT_FOUND) Check(st);
            }
            finally { LsaClose(h); }
        }
    }

    // Writes the IStream that IMAPI2FS (Windows' built-in ISO builder) produces to a file.
    public static class Iso
    {
        public static void SaveStream(object comStream, string path)
        {
            var s = (System.Runtime.InteropServices.ComTypes.IStream)comStream;
            byte[] buf = new byte[65536];
            IntPtr pcb = Marshal.AllocHGlobal(4);
            try
            {
                using (var fs = File.Create(path))
                {
                    while (true)
                    {
                        s.Read(buf, buf.Length, pcb);
                        int n = Marshal.ReadInt32(pcb);
                        if (n <= 0) break;
                        fs.Write(buf, 0, n);
                    }
                }
            }
            finally { Marshal.FreeHGlobal(pcb); }
        }
    }
}
'@

function Initialize-AicNative {
    if (-not ('AiCage.Native.Qcow2' -as [type])) {
        Add-Type -TypeDefinition $script:AicNativeSource -Language CSharp
    }
}

# ---- Private/Net.ps1 ------------------------------------------------------------------
# Host network (internal switch + NAT) and the per-VM isolation filter.

# Private, link-local and carrier-grade NAT ranges: everything that could be a home, office or
# cowork network. Strict isolation denies them all except the host's own address on the VM switch.
$script:AicLanRanges = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10')
$script:AicLanRanges6 = @('fe80::/10', 'fc00::/7')

function ConvertTo-AicUInt([string]$Ip) {
    $b = ([Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    return ([uint64]$b[0] -shl 24) + ([uint64]$b[1] -shl 16) + ([uint64]$b[2] -shl 8) + [uint64]$b[3]
}

function ConvertFrom-AicUInt([uint64]$N) {
    return '{0}.{1}.{2}.{3}' -f (($N -shr 24) -band 255), (($N -shr 16) -band 255), (($N -shr 8) -band 255), ($N -band 255)
}

function Get-AicMask([int]$Len) {
    if ($Len -eq 0) { return [uint64]0 }
    return ([uint64]4294967295 -shl (32 - $Len)) -band [uint64]4294967295
}

function Split-AicCidr {
    # Returns CIDR blocks covering $Cidr minus the single address $ExcludeIp. With these, no
    # Deny rule ever covers the host address, so we never depend on Hyper-V's rule precedence
    # (the manual guide's "filter blocks the laptop too" problem).
    param([Parameter(Mandatory)][string]$Cidr, [Parameter(Mandatory)][string]$ExcludeIp)
    $parts = $Cidr.Split('/')
    $len = [int]$parts[1]
    $net = (ConvertTo-AicUInt $parts[0]) -band (Get-AicMask $len)
    $x = ConvertTo-AicUInt $ExcludeIp
    if (($x -band (Get-AicMask $len)) -ne $net) { return , @($Cidr) }

    $out = @()
    for ($l = $len + 1; $l -le 32; $l++) {
        $bit = [uint64]1 -shl (32 - $l)
        $sibling = ($x -band (Get-AicMask $l)) -bxor $bit
        $addr = ConvertFrom-AicUInt $sibling
        $out += if ($l -eq 32) { $addr } else { "$addr/$l" }
    }
    return , $out
}

function Get-AicDenyRanges {
    $hostIp = Get-AicHostIp
    $list = @()
    foreach ($r in $script:AicLanRanges) { $list += Split-AicCidr -Cidr $r -ExcludeIp $hostIp }
    return , ($list + $script:AicLanRanges6)
}

function Get-AicSwitchAdapter {
    $cfg = Get-AicConfig
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "vEthernet ($($cfg.SwitchName))" } | Select-Object -First 1
}

function Initialize-AicHostNetwork {
    # Idempotent: creates whatever part of the host network is missing.
    $cfg = Get-AicConfig
    $hostIp = Get-AicHostIp
    $prefix = "$($cfg.SubnetBase).0/24"

    $sw = Get-VMSwitch -Name $cfg.SwitchName -ErrorAction SilentlyContinue
    if (-not $sw) {
        Write-AicLog "New-VMSwitch -Name $($cfg.SwitchName) -SwitchType Internal" -Level Cmd
        New-VMSwitch -Name $cfg.SwitchName -SwitchType Internal | Out-Null
        Add-AicCreatedNetwork -Kind Switch -Name $cfg.SwitchName
    } else { Write-AicLog "Virtual switch '$($cfg.SwitchName)' exists" -Level Debug }

    $adapter = $null
    for ($i = 0; $i -lt 20 -and -not $adapter; $i++) {
        $adapter = Get-AicSwitchAdapter
        if (-not $adapter) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $adapter) { throw "Host adapter 'vEthernet ($($cfg.SwitchName))' did not appear." }

    # Our subnet must not be in use anywhere else on the laptop.
    $clash = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$($cfg.SubnetBase).*" -and $_.InterfaceIndex -ne $adapter.ifIndex }
    if ($clash) {
        throw "Subnet $prefix is already used by adapter '$($clash[0].InterfaceAlias)'. Set another SubnetBase in $(Get-AicUserConfigPath)."
    }

    $ips = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    if (-not ($ips | Where-Object { $_.IPAddress -eq $hostIp })) {
        foreach ($old in $ips) {
            Write-AicLog "Remove-NetIPAddress $($old.IPAddress) (automatic address on the VM switch)" -Level Cmd
            Remove-NetIPAddress -InputObject $old -Confirm:$false
        }
        Write-AicLog "New-NetIPAddress -IPAddress $hostIp -PrefixLength 24 -InterfaceAlias '$($adapter.Name)'" -Level Cmd
        New-NetIPAddress -IPAddress $hostIp -PrefixLength 24 -InterfaceIndex $adapter.ifIndex | Out-Null
    } else { Write-AicLog "Host address $hostIp is set" -Level Debug }

    # No IPv6 on the VM switch: the VM must not reach the host over link-local IPv6.
    $b6 = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -IncludeHidden -ErrorAction SilentlyContinue
    if ($b6 -and $b6.Enabled) {
        Write-AicLog "Disable-NetAdapterBinding -Name '$($adapter.Name)' -ComponentID ms_tcpip6" -Level Cmd
        Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -IncludeHidden
    }

    try {
        $prof = Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
        if ($prof.NetworkCategory -ne 'Public') {
            Write-AicLog "Set-NetConnectionProfile -InterfaceAlias '$($adapter.Name)' -NetworkCategory Public" -Level Cmd
            Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Public
        }
    } catch { Write-AicLog "Network profile not set yet (normal for a new switch): $($_.Exception.Message)" -Level Debug }

    $nat = Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $cfg.NatName }
    if (-not $nat) {
        $others = @(Get-NetNat -ErrorAction SilentlyContinue)
        foreach ($o in $others) { Write-AicLog "Existing NAT on this laptop: $($o.Name) $($o.InternalIPInterfaceAddressPrefix)" -Level Debug }
        Write-AicLog "New-NetNat -Name $($cfg.NatName) -InternalIPInterfaceAddressPrefix $prefix" -Level Cmd
        try {
            New-NetNat -Name $cfg.NatName -InternalIPInterfaceAddressPrefix $prefix | Out-Null
            Add-AicCreatedNetwork -Kind Nat -Name $cfg.NatName
        } catch {
            if ($others.Count -gt 0) {
                $o = $others[0]
                Write-AicLog "New-NetNat failed: $($_.Exception.Message)" -Level Error
                Write-AicLog "Windows allows only one NAT here and '$($o.Name)' ($($o.InternalIPInterfaceAddressPrefix)) exists." -Level Error
                $hint = Get-AicReuseHint -Nat $o
                if ($hint) {
                    Write-AicLog "Terrarium can share that network instead:" -Level Warn
                    Write-AicLog "  1. Remove-AicHostNetwork   (removes only the '$($cfg.SwitchName)' switch Terrarium just made)" -Level Warn
                    Write-AicLog "  2. create $(Get-AicUserConfigPath) containing:  $hint" -Level Warn
                    Write-AicLog "  3. New-AicVm again" -Level Warn
                }
                throw "Another NAT ($($o.Name)) blocks a second one - see the log above."
            }
            throw
        }
    } elseif ($nat.InternalIPInterfaceAddressPrefix -ne $prefix) {
        throw "NAT '$($cfg.NatName)' exists with prefix $($nat.InternalIPInterfaceAddressPrefix), expected $prefix."
    } else { Write-AicLog "NAT '$($cfg.NatName)' exists" -Level Debug }

    New-AicBlockRules -Prefix $prefix
}

function Get-AicBlockRuleName([string]$Prefix) { return 'AICage-Block-' + ($Prefix -replace '/', '_') }

function New-AicBlockRules {
    # Windows Firewall: block rules win over allow rules, so these keep every laptop service
    # (RPC 135, NetBIOS 139, anything an app opened "for all networks") closed to the VMs on
    # $Prefix, whatever other rules say. Only TCP 445, the shared folder, stays reachable.
    param([Parameter(Mandatory)][string]$Prefix)
    $fw = Get-AicBlockRuleName $Prefix
    if (-not (Get-NetFirewallRule -Name "$fw-TCP" -ErrorAction SilentlyContinue)) {
        Write-AicLog "New-NetFirewallRule $fw-TCP: block inbound TCP from $Prefix except port 445" -Level Cmd
        New-NetFirewallRule -Name "$fw-TCP" -DisplayName "Terrarium - block VMs ($Prefix), TCP except 445" -Group 'Terrarium' `
            -Direction Inbound -Action Block -Protocol TCP -LocalPort '1-444', '446-65535' -RemoteAddress $Prefix -Profile Any | Out-Null
        Add-AicCreatedNetwork -Kind Firewall -Name "$fw-TCP"
    }
    if (-not (Get-NetFirewallRule -Name "$fw-UDP" -ErrorAction SilentlyContinue)) {
        Write-AicLog "New-NetFirewallRule $fw-UDP: block all inbound UDP from $Prefix" -Level Cmd
        New-NetFirewallRule -Name "$fw-UDP" -DisplayName "Terrarium - block VMs ($Prefix), UDP" -Group 'Terrarium' `
            -Direction Inbound -Action Block -Protocol UDP -RemoteAddress $Prefix -Profile Any | Out-Null
        Add-AicCreatedNetwork -Kind Firewall -Name "$fw-UDP"
    }
}

function Test-AicBlockRules([string]$Prefix) {
    $fw = Get-AicBlockRuleName $Prefix
    return [bool]((Get-NetFirewallRule -Name "$fw-TCP" -ErrorAction SilentlyContinue) -and (Get-NetFirewallRule -Name "$fw-UDP" -ErrorAction SilentlyContinue))
}

function Protect-AicNetwork {
    <#
    .SYNOPSIS
    Adds the Terrarium firewall block rules for another VM network, e.g. the manual guide's
    192.168.250.0/24: its VMs then reach only the laptop's shared-folder port (TCP 445).
    .NOTES
    Remove-AicHostNetwork removes these rules again.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\.\d+/\d+$')][string]$Prefix)
    if (-not (Test-AicAdmin)) { throw 'Run as Administrator.' }
    if (-not $PSCmdlet.ShouldProcess($Prefix, 'Block VM access to laptop services except TCP 445')) { return }
    Start-AicLog 'protect-network'
    Invoke-AicStep "Firewall block rules for $Prefix" { New-AicBlockRules -Prefix $Prefix }
}

function Get-AicReuseHint {
    # config.json content that makes Terrarium use an existing NAT network (e.g. the manual setup's).
    param([Parameter(Mandatory)]$Nat)
    $parts = "$($Nat.InternalIPInterfaceAddressPrefix)".Split('/')
    if ($parts.Count -ne 2 -or $parts[1] -ne '24') { return $null }
    $base = ($parts[0].Split('.')[0..2]) -join '.'
    $addr = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq "$base.1" -and $_.InterfaceAlias -match '^vEthernet \((.+)\)$' } | Select-Object -First 1
    if (-not $addr) { return $null }
    $switch = [regex]::Match($addr.InterfaceAlias, '^vEthernet \((.+)\)$').Groups[1].Value
    return (@{ SubnetBase = $base; SwitchName = $switch; NatName = $Nat.Name; FirstVmHost = 20 } | ConvertTo-Json -Compress)
}

# Only what Terrarium created itself is ever removed: <Root>\data\network.json records it, so a
# shared network (e.g. the manual guide's, via config.json) is never touched.
function Get-AicCreatedNetwork {
    $p = Join-Path (Get-AicPath Data) 'network.json'
    if (Test-Path -LiteralPath $p) { return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json }
    return [pscustomobject]@{ Switch = @(); Nat = @(); Firewall = @() }
}

function Get-AicCreatedList($Made, [string]$Kind) {
    # network.json from 0.1.0 has no Firewall entry yet.
    if ($Made.PSObject.Properties[$Kind]) { return @($Made.$Kind | Where-Object { $_ }) }
    return @()
}

function Add-AicCreatedNetwork([ValidateSet('Switch', 'Nat', 'Firewall')][string]$Kind, [string]$Name) {
    $n = Get-AicCreatedNetwork
    $list = @(@(Get-AicCreatedList $n $Kind) + $Name | Select-Object -Unique)
    if ($n.PSObject.Properties[$Kind]) { $n.$Kind = $list } else { $n | Add-Member -NotePropertyName $Kind -NotePropertyValue $list }
    $n | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Get-AicPath Data) 'network.json') -Encoding UTF8
}

function Remove-AicHostNetwork {
    <#
    .SYNOPSIS
    Removes the virtual switch and NAT that Terrarium created (only when no Terrarium VM is left).
    A network Terrarium did not create is never removed.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([switch]$Force)
    if (@(Get-AicState).Count -gt 0 -and -not $Force) { throw 'Terrarium VMs still exist. Remove them first (or use -Force).' }
    $made = Get-AicCreatedNetwork
    $nats = @(Get-AicCreatedList $made 'Nat'); $switches = @(Get-AicCreatedList $made 'Switch'); $rules = @(Get-AicCreatedList $made 'Firewall')
    if (-not ($nats + $switches + $rules)) { Write-Host 'Terrarium created no switch, NAT or firewall rule - nothing to remove.'; return }
    if (-not $PSCmdlet.ShouldProcess("switch $($switches -join ', ') and NAT $($nats -join ', ')", 'Remove')) { return }
    Start-AicLog 'remove-network'
    Invoke-AicStep 'Remove NAT, virtual switch and firewall rules created by Terrarium' {
        foreach ($rn in $rules) {
            $r = Get-NetFirewallRule -Name $rn -ErrorAction SilentlyContinue
            if ($r) { Write-AicLog "Remove-NetFirewallRule $rn" -Level Cmd; $r | Remove-NetFirewallRule }
        }
        foreach ($nn in $nats) {
            $n = Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $nn }
            if ($n) { Write-AicLog "Remove-NetNat $nn" -Level Cmd; $n | Remove-NetNat -Confirm:$false }
        }
        foreach ($sn in $switches) {
            $sw = Get-VMSwitch -Name $sn -ErrorAction SilentlyContinue
            if ($sw) { Write-AicLog "Remove-VMSwitch $sn" -Level Cmd; $sw | Remove-VMSwitch -Force }
        }
        Remove-Item -LiteralPath (Join-Path (Get-AicPath Data) 'network.json') -Force
    }
}

function Set-AicIsolation {
    # Replaces all port ACLs on the VM's network adapter. Rules live on the host side, so root
    # inside the VM cannot change them.
    param([Parameter(Mandatory)][string]$VmName, [ValidateSet('Strict', 'Open')][string]$Isolation)
    $existing = @(Get-VMNetworkAdapterAcl -VMName $VmName -ErrorAction SilentlyContinue)
    if ($existing.Count) {
        Write-AicLog "Removing $($existing.Count) existing network filter rules" -Level Debug
        $existing | Remove-VMNetworkAdapterAcl
    }
    if ($Isolation -eq 'Open') {
        Write-AicLog 'Isolation: Open (VM may reach the local network)' -Level Warn
        return
    }
    $ranges = Get-AicDenyRanges
    Write-AicLog "Isolation: Strict - $($ranges.Count) deny rules (all LAN ranges except $(Get-AicHostIp))" -Level Debug
    foreach ($r in $ranges) {
        Write-AicLog "Add-VMNetworkAdapterAcl -VMName $VmName -Direction Both -Action Deny -RemoteIPAddress $r" -Level Cmd
        Add-VMNetworkAdapterAcl -VMName $VmName -Direction Both -Action Deny -RemoteIPAddress $r
    }
}

# ---- Private/Ports.ps1 ----------------------------------------------------------------
# Port forwards, laptop -> VM: Windows' own port proxy (netsh interface portproxy, run by the IP
# Helper service) listens on the laptop's loopback only - 127.0.0.1 and ::1 - so apps on this
# laptop reach e.g. a Docker container in the VM as localhost:8080, and the local network does
# not. TCP only. Windows keeps the forwards across restarts. Even without a forward the laptop
# reaches the VM's ports directly at http://<VM address>:<port>; the VM still reaches nothing of
# the laptop (the direction VM -> laptop stays blocked by the firewall rules above).

$script:AicPortProxyKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy'

function ConvertTo-AicPortList {
    <#
    .SYNOPSIS
    Checks and normalizes port forwards: '8080', '3000:80' (laptop:VM) or '8080, 3000:80'.
    Returns 'laptop:vm' strings.
    #>
    param([AllowEmptyCollection()][string[]]$Ports)
    $out = @()
    foreach ($p in @($Ports | ForEach-Object { "$_" -split '[\s,;]+' } | Where-Object { $_ })) {
        if ($p -notmatch '^(\d{1,5})(?::(\d{1,5}))?$') { throw "Port '$p': use a number (8080) or laptop:VM (3000:80)." }
        $h = [int]$Matches[1]
        $v = if ($Matches[2]) { [int]$Matches[2] } else { $h }
        if ($h -lt 1 -or $h -gt 65535 -or $v -lt 1 -or $v -gt 65535) { throw "Port '$p': numbers from 1 to 65535." }
        $out += "${h}:$v"
    }
    $dup = @($out | ForEach-Object { $_.Split(':')[0] } | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($dup.Count) { throw "Laptop port $($dup -join ', ') is listed twice." }
    return $out      # callers wrap it in @(): one port comes back as a plain string
}

function Get-AicPortForward($State) {
    if ($State.PSObject.Properties['Ports'] -and $State.Ports) { return @($State.Ports) }
    return @()
}

function Get-AicPortProxy {
    # Every port proxy entry on the laptop (not only ours), read from the registry, where netsh
    # keeps them as "<listen address>/<port>" = "<connect address>/<port>".
    foreach ($kind in 'v4tov4', 'v6tov4') {
        $key = Join-Path $script:AicPortProxyKey "$kind\tcp"
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $item = Get-Item -LiteralPath $key
        foreach ($n in $item.GetValueNames()) {
            $l = $n.Split('/'); $c = "$($item.GetValue($n))".Split('/')
            if ($l.Count -ne 2 -or $c.Count -ne 2) { continue }
            [pscustomobject]@{ Kind = $kind; ListenAddress = $l[0]; ListenPort = $l[1]; ConnectAddress = $c[0]; ConnectPort = $c[1] }
        }
    }
}

function Remove-AicPortProxy {
    param([Parameter(Mandatory)]$Entry)
    Invoke-AicNative -FilePath 'netsh.exe' -ArgumentList @('interface', 'portproxy', 'delete', $Entry.Kind,
        "listenaddress=$($Entry.ListenAddress)", "listenport=$($Entry.ListenPort)") | Out-Null
}

function Get-AicPortConflict {
    # Why some of these laptop ports cannot be forwarded to VM $Name (empty: all fine).
    param([Parameter(Mandatory)][string]$Name, [string[]]$Ports, [string]$Ip)
    $msgs = @()
    $mine = @(Get-AicPortProxy | Where-Object { $Ip -and $_.ConnectAddress -eq $Ip } | ForEach-Object { $_.ListenPort })
    $others = @(Get-AicState | Where-Object { $_.Name -ne $Name })
    foreach ($f in $Ports) {
        $h = $f.Split(':')[0]
        $o = $others | Where-Object { @(Get-AicPortForward $_ | ForEach-Object { $_.Split(':')[0] }) -contains $h } | Select-Object -First 1
        if ($o) { $msgs += "laptop port $h already goes to VM $($o.Name)"; continue }
        if ($mine -contains $h) { continue }
        $busy = Get-NetTCPConnection -State Listen -LocalPort ([int]$h) -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in '127.0.0.1', '0.0.0.0', '::1', '::' } | Select-Object -First 1
        if ($busy) {
            $prog = (Get-Process -Id $busy.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            $msgs += "laptop port $h is already used by $(if ($prog) { $prog } else { "process $($busy.OwningProcess)" })"
        }
    }
    return $msgs
}

function Set-AicPortForward {
    # Makes the port proxy match the VM's Ports list.
    param([Parameter(Mandatory)]$State)
    $want = @(Get-AicPortForward $State)
    $bad = @(Get-AicPortConflict -Name $State.Name -Ports $want -Ip $State.Ip)
    if ($bad.Count) { throw "Cannot forward: $($bad -join '; ')." }
    foreach ($e in @(Get-AicPortProxy | Where-Object { $_.ConnectAddress -eq $State.Ip })) { Remove-AicPortProxy -Entry $e }
    if (-not $want.Count) { Write-AicLog 'No port forwards' -Level Debug; return }

    $svc = Get-Service iphlpsvc -ErrorAction SilentlyContinue
    if (-not $svc) { throw 'The IP Helper service (iphlpsvc), which forwards the ports, is missing on this laptop.' }
    if ("$($svc.StartType)" -eq 'Disabled') { Write-AicLog 'Set-Service iphlpsvc -StartupType Automatic' -Level Cmd; Set-Service iphlpsvc -StartupType Automatic }
    if ($svc.Status -ne 'Running') { Write-AicLog 'Start-Service iphlpsvc (IP Helper, forwards the ports)' -Level Cmd; Start-Service iphlpsvc }

    foreach ($f in $want) {
        $h, $v = $f.Split(':')
        foreach ($pair in @(@('v4tov4', '127.0.0.1'), @('v6tov4', '::1'))) {
            Invoke-AicNative -FilePath 'netsh.exe' -ArgumentList @('interface', 'portproxy', 'add', $pair[0],
                "listenaddress=$($pair[1])", "listenport=$h", "connectaddress=$($State.Ip)", "connectport=$v") | Out-Null
        }
        Write-AicLog "localhost:$h on this laptop -> $($State.Name) port $v" -Level Info
    }
    Start-Sleep -Seconds 1
    foreach ($f in $want) {
        $h = $f.Split(':')[0]
        if (-not (Get-NetTCPConnection -State Listen -LocalPort ([int]$h) -LocalAddress 127.0.0.1 -ErrorAction SilentlyContinue)) {
            Write-AicLog "Windows does not listen on localhost:$h yet. If it stays so: Restart-Service iphlpsvc" -Level Warn
        }
    }
}

# ---- Private/Share.ps1 ----------------------------------------------------------------
# Shared folder: a locked-down local account per VM that can open only that VM's share.

$script:AicDenyRights = @('SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight', 'SeDenyBatchLogonRight', 'SeDenyServiceLogonRight')

function Assert-AicSafeFolder {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $bad = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, (Split-Path $env:USERPROFILE)) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    if ($full -match '^[A-Za-z]:$') { throw "Refusing to share a whole drive ($full). Pick a dedicated folder." }
    foreach ($b in $bad) {
        if ($full -ieq $b) { throw "Refusing to share $full - the VM (and the AI in it) would see all of it. Pick a dedicated folder." }
    }
    if ($full -like "$env:SystemRoot\*") { throw "Refusing to share a folder inside Windows ($full)." }
    return $full
}

function New-AicShare {
    # Creates the account, folder permission, SMB share and firewall rule. Returns the password.
    param([Parameter(Mandatory)]$State)
    $acct = $State.ShareAccount
    $pw = New-AicPassword 24

    if (Get-LocalUser -Name $acct -ErrorAction SilentlyContinue) {
        Write-AicLog "Account $acct exists - resetting its password" -Level Warn
        Set-LocalUser -Name $acct -Password (ConvertTo-SecureString $pw -AsPlainText -Force)
    } else {
        Write-AicLog "New-LocalUser -Name $acct -PasswordNeverExpires -UserMayNotChangePassword (random password)" -Level Cmd
        New-LocalUser -Name $acct -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -PasswordNeverExpires `
            -UserMayNotChangePassword -AccountNeverExpires -Description "Terrarium: share for VM $($State.Name), no logon" | Out-Null
    }
    $user = Get-LocalUser -Name $acct
    $sid = $user.SID.Value

    # Not a member of Users (group found by SID, so this works on any Windows language).
    $users = Get-LocalGroupMember -SID 'S-1-5-32-545' -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -eq $sid }
    if ($users) {
        Write-AicLog "Remove-LocalGroupMember -SID S-1-5-32-545 (Users) -Member $acct" -Level Cmd
        Remove-LocalGroupMember -SID 'S-1-5-32-545' -Member $user
    }

    Initialize-AicNative
    Write-AicLog "Deny logon rights for $acct`: $($script:AicDenyRights -join ', ')" -Level Cmd
    [AiCage.Native.Lsa]::AddRights($sid, $script:AicDenyRights)

    Publish-AicShare -State $State -Sid $sid
    New-AicShareFirewallRule -State $State
    return $pw
}

function Publish-AicShare {
    # Folder permission for the share account and the SMB share itself (replaced if it exists).
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Sid)
    $sid = $Sid
    $acct = $State.ShareAccount
    $folder = $State.SharedFolder
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $perm = if ($State.SharedReadOnly) { 'RX' } else { 'M' }
    Invoke-AicNative -FilePath 'icacls.exe' -ArgumentList @($folder, '/grant', "*${sid}:(OI)(CI)$perm") -Quiet | Out-Null

    $existing = Get-SmbShare -Name $State.ShareName -ErrorAction SilentlyContinue
    if ($existing) { Remove-SmbShare -Name $State.ShareName -Force }
    $full = "$env:COMPUTERNAME\$acct"
    if ($State.SharedReadOnly) {
        Write-AicLog "New-SmbShare -Name $($State.ShareName) -Path '$folder' -ReadAccess $full" -Level Cmd
        New-SmbShare -Name $State.ShareName -Path $folder -ReadAccess $full -CachingMode None -Description "Terrarium VM $($State.Name)" | Out-Null
    } else {
        Write-AicLog "New-SmbShare -Name $($State.ShareName) -Path '$folder' -ChangeAccess $full" -Level Cmd
        New-SmbShare -Name $State.ShareName -Path $folder -ChangeAccess $full -CachingMode None -Description "Terrarium VM $($State.Name)" | Out-Null
    }
    # Only our account may use the share (Windows sometimes adds Everyone).
    Get-SmbShareAccess -Name $State.ShareName | Where-Object { $_.AccountName -ne $full } | ForEach-Object {
        Write-AicLog "Revoke-SmbShareAccess -Name $($State.ShareName) -AccountName '$($_.AccountName)'" -Level Cmd
        Revoke-SmbShareAccess -Name $State.ShareName -AccountName $_.AccountName -Force | Out-Null
    }
}

function Set-AicShareFolder {
    # Points the VM's share at another folder and/or switches read-only. The share keeps its name,
    # so the VM only has to mount it again.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][bool]$ReadOnly, [bool]$Running)
    $user = Get-LocalUser -Name $State.ShareAccount -ErrorAction SilentlyContinue
    if (-not $user) { throw "The share account $($State.ShareAccount) is missing - re-create the VM." }
    $sid = $user.SID.Value
    $old = $State.SharedFolder
    if ($old -and ($old -ine $Folder -or [bool]$State.SharedReadOnly -ne $ReadOnly) -and (Test-Path -LiteralPath $old)) {
        Write-AicLog "icacls $old /remove $($State.ShareAccount)" -Level Cmd
        Invoke-AicNative -FilePath 'icacls.exe' -ArgumentList @($old, '/remove', "*$sid") -Quiet -OkExitCodes 0, 1332 | Out-Null
    }
    $State.SharedFolder = $Folder
    $State.SharedReadOnly = $ReadOnly
    Publish-AicShare -State $State -Sid $sid
    Save-AicState $State
    if ($Running) {
        $ro = if ($ReadOnly) { '1' } else { '0' }
        Invoke-AicSsh -State $State -Script @"
set -e
RO=$ro
if [ "`$RO" = 1 ]; then sudo sed -i -E '/ \/mnt\/shared cifs /{/ cifs ro,/!s/ cifs / cifs ro,/}' /etc/fstab
else sudo sed -i -E '/ \/mnt\/shared cifs /s/ cifs ro,/ cifs /' /etc/fstab; fi
sudo systemctl daemon-reload
sudo umount -l /mnt/shared 2>/dev/null || true
sudo systemctl restart mnt-shared.automount
ls /mnt/shared >/dev/null
echo "shared folder mounted again"
"@ | Out-Null
        Test-AicShareRoundTrip -State $State
    }
}

function New-AicShareFirewallRule {
    param([Parameter(Mandatory)]$State)
    $ruleName = "AICage-SMB-$($State.Name)"
    Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-AicLog "New-NetFirewallRule TCP 445 from $($State.Ip) to $(Get-AicHostIp) only" -Level Cmd
    New-NetFirewallRule -Name $ruleName -DisplayName "Terrarium - share for VM $($State.Name)" -Group 'Terrarium' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -LocalAddress (Get-AicHostIp) `
        -RemoteAddress $State.Ip -Profile Any | Out-Null
}

function Remove-AicShare {
    # Tolerant of partial setups: each piece is removed if it exists.
    param([Parameter(Mandatory)]$State)
    $rule = Get-NetFirewallRule -Name "AICage-SMB-$($State.Name)" -ErrorAction SilentlyContinue
    if ($rule) { Write-AicLog "Remove firewall rule $($rule.Name)" -Level Cmd; $rule | Remove-NetFirewallRule }

    if (Get-SmbShare -Name $State.ShareName -ErrorAction SilentlyContinue) {
        Write-AicLog "Remove-SmbShare $($State.ShareName)" -Level Cmd
        Remove-SmbShare -Name $State.ShareName -Force
    }

    $user = Get-LocalUser -Name $State.ShareAccount -ErrorAction SilentlyContinue
    if ($user) {
        Initialize-AicNative
        $sid = $user.SID.Value
        Write-AicLog "Remove user rights and account $($State.ShareAccount)" -Level Cmd
        [AiCage.Native.Lsa]::RemoveAllRights($sid)
        if (Test-Path -LiteralPath $State.SharedFolder) {
            Invoke-AicNative -FilePath 'icacls.exe' -ArgumentList @($State.SharedFolder, '/remove', "*$sid") -Quiet -OkExitCodes 0, 1332 | Out-Null
        }
        Remove-LocalUser -SID $user.SID
    }
}

# ---- Private/Ssh.ps1 ------------------------------------------------------------------
# SSH from the host into the VMs, with a key the tool generates per VM.

function Get-AicSshExe {
    $c = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $c) { throw "ssh.exe not found. Install it: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" }
    return $c.Source
}

function Set-AicPrivateAcl {
    # OpenSSH refuses keys and config files that other users can read.
    param([Parameter(Mandatory)][string]$Path)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Invoke-AicNative -FilePath 'icacls.exe' -ArgumentList @($Path, '/inheritance:r', '/grant:r', "*${me}:F", '/grant:r', '*S-1-5-18:F') -Quiet | Out-Null
}

function Get-AicKeyPath($State) { Join-Path (Get-AicPath Keys -Location (Get-AicStateLocation $State)) $State.Name }
function Get-AicKnownHostsPath($State) { Join-Path (Get-AicPath Ssh -Location (Get-AicStateLocation $State)) 'known_hosts' }

function New-AicSshKey {
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('Home', 'Program')][string]$Location = 'Home')
    $keyDir = Get-AicPath Keys -Location $Location
    $key = Join-Path $keyDir $Name
    foreach ($f in $key, "$key.pub", "$key.ppk") { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    $gen = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
    # Start-Process passes the command line as written, so the empty passphrase survives (PS 5.1 drops "" args).
    Write-AicLog "ssh-keygen -q -t ed25519 -N `"`" -C aicage-$Name -f $key" -Level Cmd
    $p = Start-Process -FilePath $gen -ArgumentList "-q -t ed25519 -N `"`" -C aicage-$Name -f `"$key`"" -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "ssh-keygen failed with code $($p.ExitCode)" }
    Set-AicPrivateAcl -Path $key
    return (Get-Content -LiteralPath "$key.pub" -Raw).Trim()
}

function Get-AicSshArgs {
    param([Parameter(Mandatory)]$State)
    $known = Get-AicKnownHostsPath $State
    return @(
        '-i', (Get-AicKeyPath $State),
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$known",
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=30',
        "$($State.User)@$($State.Ip)"
    )
}

function Invoke-AicSsh {
    # Runs a bash script in the VM. The script travels base64-encoded, so no quoting rules of
    # cmd, PowerShell or ssh can mangle it. Returns the output lines.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Script,
          [string]$LogLevel = 'Guest', [switch]$Quiet, [int[]]$OkExitCodes = @(0))
    $b64 = ConvertTo-AicB64 $Script
    $args2 = (Get-AicSshArgs $State) + "echo $b64 | base64 -d | bash"
    $first = ($Script -split "`n" | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | Select-Object -First 1)
    return Invoke-AicNative -FilePath (Get-AicSshExe) -ArgumentList $args2 -LogLevel $LogLevel -Quiet:$Quiet `
        -DisplayArgs "$($State.User)@$($State.Ip) [script: $first ...]" -OkExitCodes $OkExitCodes
}

function Test-AicSshReady {
    param([Parameter(Mandatory)]$State)
    $ErrorActionPreference = 'Continue'
    $null = & (Get-AicSshExe) @((Get-AicSshArgs $State) + 'true') 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Test-AicTcpPort {
    param([string]$Ip, [int]$Port, [int]$TimeoutMs = 2000)
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($Ip, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar); return $true
    } catch { return $false } finally { $c.Close() }
}

function Remove-AicKnownHost {
    param([Parameter(Mandatory)]$State)
    $Ip = $State.Ip
    $known = Get-AicKnownHostsPath $State
    if (Test-Path -LiteralPath $known) {
        $kept = @(Get-Content -LiteralPath $known | Where-Object { $_ -and -not $_.StartsWith("$Ip ") })
        Set-Content -LiteralPath $known -Value $kept -Encoding Ascii
    }
}

function Update-AicSshConfig {
    # <Root>\ssh\config lists every VM, so "ssh -F C:\AICage\ssh\config <name>" works by hand too.
    $cfgPath = Join-Path (Get-AicPath Ssh) 'config'
    $lines = @('# Generated by Terrarium - changes are overwritten.')
    foreach ($s in @(Get-AicState)) {
        $lines += "Host $($s.Name)"
        $lines += "  HostName $($s.Ip)"
        $lines += "  User $($s.User)"
        $lines += "  IdentityFile `"$(Get-AicKeyPath $s)`""
        $lines += '  IdentitiesOnly yes'
        $lines += "  UserKnownHostsFile `"$(Get-AicKnownHostsPath $s)`""
        $lines += '  ServerAliveInterval 30'
        $lines += ''
    }
    Set-Content -LiteralPath $cfgPath -Value $lines -Encoding Ascii
    Set-AicPrivateAcl -Path $cfgPath
    return $cfgPath
}

function Remove-AicPuttySession {
    # AI Cage 0.3.0 and older saved a PuTTY session per VM in the registry; now PuTTY gets
    # everything on its command line. Only removes what an older version left behind.
    param([Parameter(Mandatory)]$State)
    $key = "HKCU:\Software\SimonTatham\PuTTY\Sessions\AICage-$($State.Name)"
    if (Test-Path $key) { Remove-Item $key -Recurse -Force }
}

# ---- PuTTY ------------------------------------------------------------------------------
# PuTTY is started with the host, user, key and the VM's host key on its command line, so it
# needs no saved session and does not write the VM's host key into the registry either.

function Get-AicPuttyExe {
    $c = Get-Command putty.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($dir in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'PuTTY\putty.exe'))) { return Join-Path $dir 'PuTTY\putty.exe' }
    }
    return $null
}

function Read-AicSshField([byte[]]$Data, [ref]$Pos) {
    # One length-prefixed field of the SSH wire format (RFC 4251 "string").
    $p = $Pos.Value
    $len = ([int]$Data[$p] -shl 24) -bor ([int]$Data[$p + 1] -shl 16) -bor ([int]$Data[$p + 2] -shl 8) -bor [int]$Data[$p + 3]
    $out = New-Object byte[] $len
    [Array]::Copy($Data, $p + 4, $out, 0, $len)
    $Pos.Value = $p + 4 + $len
    return , $out
}

function Write-AicSshField([IO.Stream]$Stream, [byte[]]$Bytes) {
    $len = [BitConverter]::GetBytes([uint32]$Bytes.Length)
    [Array]::Reverse($len)
    $Stream.Write($len, 0, 4)
    $Stream.Write($Bytes, 0, $Bytes.Length)
}

function ConvertTo-AicPpk {
    # PuTTY cannot read OpenSSH key files. Writes <key>.ppk (PuTTY key format 2, no passphrase)
    # from the ed25519 key Terrarium made, so PuTTY logs in without a password too.
    param([Parameter(Mandatory)][string]$KeyPath)
    $ppk = "$KeyPath.ppk"
    if ((Test-Path -LiteralPath $ppk) -and (Get-Item -LiteralPath $ppk).LastWriteTimeUtc -ge (Get-Item -LiteralPath $KeyPath).LastWriteTimeUtc) { return $ppk }

    $b64 = (Get-Content -LiteralPath $KeyPath -Raw) -replace '-----[^-]+-----', '' -replace '\s', ''
    $data = [Convert]::FromBase64String($b64)
    $ascii = [Text.Encoding]::ASCII
    $magic = 'openssh-key-v1'
    if ($ascii.GetString($data, 0, $magic.Length) -ne $magic) { throw "$KeyPath is not an OpenSSH key." }
    $pos = $magic.Length + 1
    $cipher = $ascii.GetString((Read-AicSshField $data ([ref]$pos)))
    $null = Read-AicSshField $data ([ref]$pos)                      # kdf name
    $null = Read-AicSshField $data ([ref]$pos)                      # kdf options
    $pos += 4                                                       # number of keys (1)
    $public = Read-AicSshField $data ([ref]$pos)
    $section = Read-AicSshField $data ([ref]$pos)
    if ($cipher -ne 'none') { throw "$KeyPath has a passphrase; PuTTY needs a key without one." }

    $pos = 8                                                        # two check numbers
    $type = $ascii.GetString((Read-AicSshField $section ([ref]$pos)))
    if ($type -ne 'ssh-ed25519') { throw "$KeyPath is a $type key; only ssh-ed25519 is converted." }
    $null = Read-AicSshField $section ([ref]$pos)                   # public key again
    $secret = Read-AicSshField $section ([ref]$pos)                 # 32-byte seed + 32-byte public key
    $comment = $ascii.GetString((Read-AicSshField $section ([ref]$pos)))
    $seed = New-Object byte[] 32
    [Array]::Copy($secret, 0, $seed, 0, 32)
    $ms = New-Object IO.MemoryStream
    Write-AicSshField $ms $seed
    $private = $ms.ToArray()

    # The MAC covers algorithm, encryption, comment and both blobs; its key is SHA-1 of a fixed
    # string followed by the (empty) passphrase.
    $ms = New-Object IO.MemoryStream
    foreach ($f in @($ascii.GetBytes($type), $ascii.GetBytes('none'), $ascii.GetBytes($comment), $public, $private)) { Write-AicSshField $ms $f }
    $sha = [Security.Cryptography.SHA1]::Create()
    $hmac = New-Object Security.Cryptography.HMACSHA1 (, $sha.ComputeHash($ascii.GetBytes('putty-private-key-file-mac-key')))
    $mac = -join ($hmac.ComputeHash($ms.ToArray()) | ForEach-Object { $_.ToString('x2') })

    $lines64 = { param($Bytes) $s = [Convert]::ToBase64String($Bytes); for ($i = 0; $i -lt $s.Length; $i += 64) { $s.Substring($i, [math]::Min(64, $s.Length - $i)) } }
    $pubLines = @(& $lines64 $public)
    $privLines = @(& $lines64 $private)
    $text = @("PuTTY-User-Key-File-2: $type", 'Encryption: none', "Comment: $comment", "Public-Lines: $($pubLines.Count)") +
        $pubLines + "Private-Lines: $($privLines.Count)" + $privLines + "Private-MAC: $mac"
    if (Test-Path -LiteralPath $ppk) { Remove-Item -LiteralPath $ppk -Force }
    Set-Content -LiteralPath $ppk -Value $text -Encoding Ascii
    Set-AicPrivateAcl -Path $ppk
    Write-AicLog "PuTTY key written: $ppk" -Level Debug
    return $ppk
}

function Get-AicHostKeyFingerprint {
    # The VM's host keys as OpenSSH saw them on the first connect, as MD5 fingerprints
    # ("aa:bb:..."), the form every PuTTY version accepts for -hostkey.
    param([Parameter(Mandatory)]$State)
    $Ip = $State.Ip
    $known = Get-AicKnownHostsPath $State
    if (-not (Test-Path -LiteralPath $known)) { return @() }
    $md5 = [Security.Cryptography.MD5]::Create()
    return @(Get-Content -LiteralPath $known | Where-Object { $_.StartsWith("$Ip ") } | ForEach-Object {
        $blob = [Convert]::FromBase64String(($_ -split '\s+')[2])
        ($md5.ComputeHash($blob) | ForEach-Object { $_.ToString('x2') }) -join ':'
    })
}

function Start-AicPutty {
    param([Parameter(Mandatory)]$State)
    $exe = Get-AicPuttyExe
    if (-not $exe) { throw 'PuTTY is not installed (or not found). Install it from putty.org, or choose Windows terminal.' }
    $ppk = ConvertTo-AicPpk -KeyPath (Get-AicKeyPath $State)
    $fps = @(Get-AicHostKeyFingerprint -State $State)
    if (-not $fps.Count) {
        # Not connected yet from this PC: one quick OpenSSH login records the VM's host key.
        $null = Test-AicSshReady -State $State
        $fps = @(Get-AicHostKeyFingerprint -State $State)
    }
    if (-not $fps.Count) { throw "Could not reach $($State.Name) to learn its host key. Is it running?" }
    $a = @('-ssh', '-P', '22', '-l', $State.User, '-i', "`"$ppk`"")
    foreach ($fp in $fps) { $a += '-hostkey', $fp }
    $a += $State.Ip
    Write-AicLog "putty.exe $($a -join ' ')" -Level Debug
    Start-Process -FilePath $exe -ArgumentList ($a -join ' ')
}

# ---- Public/Host.ps1 ------------------------------------------------------------------
# ---- Remote Desktop -------------------------------------------------------------------------
# The VM's desktop (xrdp) in Windows' Remote Desktop, with a .rdp file that shares nothing of
# this laptop: no drives, printers, devices - and no clipboard, which often holds passwords.
# (Set redirectclipboard:i:1 in the file if you want copy and paste.)

function Start-AicDesktop {
    param([Parameter(Mandatory)]$State)
    $rdp = Join-Path (Split-Path (Get-AicStatePath -Name $State.Name -Location (Get-AicStateLocation $State))) "$($State.Name).rdp"
    if (-not (Test-Path -LiteralPath $rdp)) {
        $lines = @(
            "full address:s:$($State.Ip)", "username:s:$($State.User)", 'screen mode id:i:1', 'smart sizing:i:1', 'dynamic resolution:i:1'
            'authentication level:i:0', 'enablecredsspsupport:i:0', 'prompt for credentials:i:0'
            'redirectclipboard:i:0', 'redirectprinters:i:0', 'redirectdrives:i:0', 'drivestoredirect:s:', 'redirectcomports:i:0'
            'redirectsmartcards:i:0', 'devicestoredirect:s:', 'camerastoredirect:s:', 'audiomode:i:0', 'audiocapturemode:i:0'
        )
        Set-Content -LiteralPath $rdp -Value $lines -Encoding Unicode
    }
    Write-AicLog "mstsc.exe $rdp  (log in as $($State.User) with your Linux password)" -Level Debug
    Start-Process -FilePath 'mstsc.exe' -ArgumentList "`"$rdp`""
}

function Test-AicAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-AicReady {
    if (-not (Test-AicAdmin)) { throw 'Run PowerShell as Administrator (right-click -> Run as administrator), or start Terrarium.cmd.' }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { throw 'The Hyper-V PowerShell module is missing. Run Test-AicHost for details.' }
}

function Test-AicHost {
    <#
    .SYNOPSIS
    Checks whether this laptop can run Terrarium VMs and prints what to fix.
    #>
    [CmdletBinding()]
    param()
    Start-AicLog 'test-host'
    $results = New-Object System.Collections.Generic.List[object]
    # Fix: a command that solves the problem (the GUI offers it as a button).
    function Add-Check([string]$Name, [string]$Status, [string]$Detail, [string]$Fix = '') {
        $results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail; Fix = $Fix })
        $lvl = @{ PASS = 'Ok'; WARN = 'Warn'; FAIL = 'Error'; INFO = 'Info' }[$Status]
        Write-AicLog ('{0,-22} {1}  {2}' -f $Name, $Status, $Detail) -Level $lvl
    }

    if (Test-AicAdmin) { Add-Check 'Administrator' PASS 'running elevated' }
    else { Add-Check 'Administrator' FAIL 'start PowerShell with "Run as administrator"' }

    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    Add-Check 'Windows' INFO "$($os.Caption) build $($os.BuildNumber)"

    $feature = $null
    try { $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop } catch { }
    if (-not $feature) {
        if (Test-AicAdmin) { Add-Check 'Hyper-V available' FAIL 'not offered by this Windows edition (Home?) - needs Pro, Enterprise or Education' }
        else { Add-Check 'Hyper-V available' WARN 'cannot check without Administrator' }
    } elseif ($feature.State -ne 'Enabled') {
        Add-Check 'Hyper-V enabled' FAIL "state: $($feature.State) - turn it on, then restart Windows" 'Enable-AicHyperV -Confirm:$false'
    } else { Add-Check 'Hyper-V enabled' PASS 'feature is on' }

    if ($cs.HypervisorPresent) { Add-Check 'Hypervisor running' PASS 'yes' }
    else {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        if ($cpu.VirtualizationFirmwareEnabled) { Add-Check 'Hypervisor running' FAIL 'not running - restart after enabling Hyper-V, or: bcdedit /set hypervisorlaunchtype auto' }
        else { Add-Check 'Hypervisor running' FAIL 'virtualization is off in BIOS/UEFI - turn on Intel VT-x / AMD SVM' }
    }

    if (Get-Module -ListAvailable -Name Hyper-V) { Add-Check 'Hyper-V PowerShell' PASS 'module present' }
    else { Add-Check 'Hyper-V PowerShell' FAIL 'missing - turning on Hyper-V installs it' 'Enable-AicHyperV -Confirm:$false' }

    $ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    if ($ramGb -ge 8) { Add-Check 'RAM' PASS "$ramGb GB" } else { Add-Check 'RAM' WARN "$ramGb GB - keep VM maximum memory low" }

    $root = (Get-AicConfig).Root
    $drive = Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGb = [math]::Round($drive.Free / 1GB, 1)
        if ($freeGb -ge 10) { Add-Check 'Free disk' PASS "$freeGb GB on $($drive.Name):" } else { Add-Check 'Free disk' WARN "$freeGb GB on $($drive.Name): - 10 GB recommended" }
    }

    foreach ($exe in 'ssh.exe', 'ssh-keygen.exe') {
        if (Get-Command $exe -ErrorAction SilentlyContinue) { Add-Check $exe PASS 'found' }
        else { Add-Check $exe FAIL 'OpenSSH client is not installed' 'Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 | Out-Null' }
    }
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) { Add-Check 'curl.exe' PASS 'found' } else { Add-Check 'curl.exe' WARN 'missing - slower download fallback is used' }

    $srv = Get-Service LanmanServer -ErrorAction SilentlyContinue
    if ($srv -and $srv.Status -eq 'Running') { Add-Check 'File sharing service' PASS 'Server (LanmanServer) running' }
    else { Add-Check 'File sharing service' FAIL 'the "Server" service is not running - shared folders will not work' }

    try {
        [void](New-Object -ComObject IMAPI2FS.MsftFileSystemImage)
        Add-Check 'ISO builder' PASS 'IMAPI2FS available'
    } catch { Add-Check 'ISO builder' FAIL 'IMAPI2FS COM object missing' }

    $cfg = Get-AicConfig
    $ours = "vEthernet ($($cfg.SwitchName))"
    $clash = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$($cfg.SubnetBase).*" -and $_.InterfaceAlias -ne $ours }
    if ($clash) { Add-Check 'Subnet free' FAIL "$($cfg.SubnetBase).0/24 is used by '$($clash[0].InterfaceAlias)' - set SubnetBase in config.json" }
    else { Add-Check 'Subnet free' PASS "$($cfg.SubnetBase).0/24" }

    foreach ($n in @(Get-NetNat -ErrorAction SilentlyContinue)) {
        $pfx = "$($n.InternalIPInterfaceAddressPrefix)"
        if ($n.Name -eq $cfg.NatName) { Add-Check 'NAT' PASS "$($n.Name) $pfx" }
        elseif (Test-AicBlockRules $pfx) { Add-Check 'Other VM network' PASS "$($n.Name) $pfx - protected by Terrarium firewall rules" }
        else {
            Add-Check 'Other VM network' WARN "$($n.Name) $pfx (e.g. the manual setup, Docker): its VMs can reach laptop services such as RPC and NetBIOS. Protecting it leaves them only the shared folder (TCP 445)." "Protect-AicNetwork -Prefix '$pfx' -Confirm:`$false"
        }
    }

    if (Test-AicAdmin) {
        $left = @()
        try { $left = @(Get-AicLeftovers) } catch { }
        if ($left.Count) {
            $what = ($left | ForEach-Object { "$($_.Kind) $($_.Name)" }) -join ', '
            Add-Check 'Leftovers' WARN "from removed VMs or AI Cage 0.1: $what" 'Remove-AicLeftovers -Confirm:$false'
        } else { Add-Check 'Leftovers' PASS 'none' }
    }

    $failed = @($results | Where-Object Status -eq 'FAIL').Count
    if ($failed) { Write-AicLog "$failed check(s) failed - see above." -Level Error }
    else { Write-AicLog 'This laptop is ready for Terrarium.' -Level Ok }
    Write-AicLog "Log: $(Get-AicLogPath)" -Level Info
    return $results
}

function Enable-AicHyperV {
    <#
    .SYNOPSIS
    Turns on Hyper-V (including its PowerShell module). Needs a restart afterwards.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-AicAdmin)) { throw 'Run as Administrator.' }
    Start-AicLog 'enable-hyperv'
    if (-not $PSCmdlet.ShouldProcess('Windows', 'Enable Hyper-V')) { return }
    Invoke-AicStep 'Enable-WindowsOptionalFeature Microsoft-Hyper-V-All' {
        $r = Enable-WindowsOptionalFeature -Online -All -FeatureName Microsoft-Hyper-V-All -NoRestart
        if ($r.RestartNeeded) { Write-AicLog 'Restart Windows to finish (Restart-Computer).' -Level Warn }
    }
}

function Show-AiCage {
    <#
    .SYNOPSIS
    Prints the quick-start command list.
    #>
    Write-Host "Terrarium $script:AicVersion - the AI cage: isolated Debian VMs on Hyper-V" -ForegroundColor Cyan
    Write-Host @'

  Test-AicHost                     check this laptop (run first)
  Enable-AicHyperV                 turn on Hyper-V (then restart Windows)
  New-AicVm -Name agent1           create a VM (asks for the Linux password)
  Get-AicVm                        list VMs: state, address, memory
  Connect-AicVm agent1             open an SSH terminal into the VM
  Connect-AicVm agent1 -With PuTTY the same in PuTTY (-With Desktop: the graphical desktop)
  Test-AicVm agent1                check the isolation from inside the VM
  Debug-AicVm agent1               why the VM does not answer (or did not, before a restart)
  Set-AicVm agent1 -MemoryMaxMB 3072 -AutoStart $false
  Set-AicVm agent1 -SharedFolder D:\Work\agent1   change the shared folder
  Set-AicVm agent1 -Ports 8080,3000:80   localhost:8080 on this laptop -> port 8080 in the VM
  Install-AicTool agent1 -Tool Desktop   add Docker, ClaudeCode, Codex or Desktop later
  Start-AicVm / Stop-AicVm / Restart-AicVm agent1   (Restart-AicVm -Force: hard reset)
  Move-AicVm agent1 -To Home       move the VM to your user folder (-To Program: back)
  Remove-AicVm agent1              delete the VM and everything made for it
  Get-AicLogPath                   the log file to send when something fails

  Details: Get-Help New-AicVm -Full
'@
}

# ---- Public/Test.ps1 ------------------------------------------------------------------
function Test-AicVm {
    <#
    .SYNOPSIS
    Checks from inside the VM what it can and cannot reach (the manual guide's Step 11, automated).
    If an isolation test fails, Terrarium repairs the host-side protection and tests again; if it
    still fails, the VM is quarantined (network disconnected) until a later test passes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name, [switch]$NoRepair)
    process {
        Assert-AicReady
        $s = Get-AicState1 -Name $Name
        Start-AicLog "test-$Name"
        $r = Invoke-AicVmCheck -State $s -NoRepair:$NoRepair
        Write-AicLog "Log: $(Get-AicLogPath)" -Level Info
        return $r
    }
}

function Test-AicSecurityFailure($Result) {
    # A failure that means the VM can reach something it must not (as opposed to e.g. no internet).
    return $Result.Status -eq 'FAIL' -and $Result.Expected -in 'blocked', 'denied'
}

function Invoke-AicVmCheck {
    # Test -> repair -> test again -> quarantine. Used by Test-AicVm and at the end of New-AicVm.
    param([Parameter(Mandatory)]$State, [switch]$NoRepair)
    $vm = Get-VM -Name $State.Name
    if ($vm.State -ne 'Running') { throw "VM $($State.Name) is not running - start it to test it." }
    if (Test-AicQuarantined $State) {
        Write-AicLog 'VM is quarantined - reconnecting its network for the test' -Level Warn
        Set-AicQuarantine -State $State -On:$false
        Wait-AicSsh -State $State -TimeoutSeconds 60
    }

    $results = Invoke-AicStep 'Isolation tests (from inside the VM)' { Invoke-AicIsolationTest -State $State }
    $bad = @($results | Where-Object { Test-AicSecurityFailure $_ })
    if ($bad.Count -and -not $NoRepair) {
        Write-AicLog "$($bad.Count) isolation test(s) failed - repairing the protection and testing again" -Level Warn
        Invoke-AicStep 'Repair host firewall and network filter' { Repair-AicVm -State $State }
        $results = Invoke-AicStep 'Isolation tests, second run' { Invoke-AicIsolationTest -State $State }
        $bad = @($results | Where-Object { Test-AicSecurityFailure $_ })
    }

    if ($bad.Count) {
        Set-AicQuarantine -State $State -On
        Write-AicLog "QUARANTINED: $($State.Name) still reaches $($bad.Count) thing(s) it must not. Its network is disconnected; the VM keeps running. Run the test again after fixing the cause - the network comes back when all tests pass." -Level Error
        foreach ($b in $bad) { Write-AicLog "  still open: $($b.Test)" -Level Error }
    } else {
        $other = @($results | Where-Object Status -eq 'FAIL').Count
        if ($other) { Write-AicLog "Isolation OK, but $other other test(s) failed (see above)" -Level Warn }
        else { Write-AicLog "All tests passed ($($State.Isolation) isolation)" -Level Ok }
    }
    return $results
}

function Repair-AicVm {
    # Re-applies every host-side protection of one VM (idempotent).
    param([Parameter(Mandatory)]$State)
    Initialize-AicHostNetwork
    Set-AicIsolation -VmName $State.Name -Isolation $State.Isolation
    Set-VMNetworkAdapter -VMName $State.Name -DhcpGuard On -RouterGuard On
    if (-not (Get-NetFirewallRule -Name "AICage-SMB-$($State.Name)" -ErrorAction SilentlyContinue)) { New-AicShareFirewallRule -State $State }
}

function Test-AicQuarantined($State) { return [bool]($State.PSObject.Properties['Quarantined'] -and $State.Quarantined) }

function Set-AicQuarantine {
    param([Parameter(Mandatory)]$State, [switch]$On)
    if ($On) {
        Write-AicLog "Disconnect-VMNetworkAdapter -VMName $($State.Name)" -Level Cmd
        Disconnect-VMNetworkAdapter -VMName $State.Name
    } else {
        $sw = (Get-AicConfig).SwitchName
        Write-AicLog "Connect-VMNetworkAdapter -VMName $($State.Name) -SwitchName $sw" -Level Cmd
        Connect-VMNetworkAdapter -VMName $State.Name -SwitchName $sw
    }
    $State | Add-Member -NotePropertyName Quarantined -NotePropertyValue ([bool]$On) -Force
    Save-AicState $State
}

function Invoke-AicIsolationTest {
    param([Parameter(Mandatory)]$State)
    $s = $State
    $Name = $s.Name
    $hostIp = Get-AicHostIp
    $strict = $s.Isolation -eq 'Strict'

    # The laptop's real network: default gateway and own address (not the VM switch).
    $gw = $null; $lanIp = $null
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notlike 'vEthernet*' } |
        Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4).InterfaceMetric } |
        Select-Object -First 1
    if ($route) {
        $gw = $route.NextHop
        $lanIp = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 | Select-Object -First 1).IPAddress
        Write-AicLog "Laptop network: address $lanIp, router $gw ($($route.InterfaceAlias))" -Level Info
    } else { Write-AicLog 'No default route on the laptop - skipping router tests' -Level Warn }

    # Every other VM we can find an address for, Terrarium or not.
    $others = @()
    foreach ($vm in Get-VM) {
        if ($vm.Name -eq $Name) { continue }
        $ips = @(Get-VMNetworkAdapter -VMName $vm.Name | ForEach-Object { $_.IPAddresses } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        $st = Get-AicState -Name $vm.Name
        if ($st -and $st.Ip) { $ips += $st.Ip }
        $others += $ips | Select-Object -Unique
    }

    $lan = if ($strict) { 'blocked' } else { 'any' }
    $script = @"
HOST='$hostIp'; GW='$gw'; LANIP='$lanIp'; LAN='$lan'; OTHERS='$($others -join ' ')'
r() { echo "RESULT|`$1|`$2|`$3"; }
tcp() { timeout 3 bash -c "</dev/tcp/`$1/`$2" 2>/dev/null && echo open || echo blocked; }
png() { ping -c 2 -W 2 "`$1" >/dev/null 2>&1 && echo reachable || echo blocked; }
code=`$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://deb.debian.org/debian/)
[ "`$code" = 200 ] && r 'Internet (https://deb.debian.org)' ok ok || r 'Internet (https://deb.debian.org)' ok "http `$code"
getent hosts debian.org >/dev/null && r 'DNS' ok ok || r 'DNS' ok fail
r "Laptop `$HOST port 445 (shared folder)" open `$(tcp `$HOST 445)
r "Laptop `$HOST port 22 (SSH from the VM)" blocked `$(tcp `$HOST 22)
r "Laptop `$HOST port 135 (RPC)" blocked `$(tcp `$HOST 135)
r "Laptop `$HOST port 139 (NetBIOS)" blocked `$(tcp `$HOST 139)
r "Laptop `$HOST port 3389 (Remote Desktop)" blocked `$(tcp `$HOST 3389)
r "Laptop `$HOST port 5985 (PowerShell remoting)" blocked `$(tcp `$HOST 5985)
[ -n "`$GW" ] && r "Router `$GW (ping)" `$LAN `$(png `$GW)
[ -n "`$GW" ] && r "Router `$GW port 80 (admin page)" `$LAN `$(tcp `$GW 80)
[ -n "`$LANIP" ] && r "Laptop Wi-Fi/LAN address `$LANIP (ping)" `$LAN `$(png `$LANIP)
[ -n "`$LANIP" ] && r "Laptop Wi-Fi/LAN address `$LANIP port 445" `$LAN `$(tcp `$LANIP 445)
for o in `$OTHERS; do r "Other VM `$o (ping)" blocked `$(png `$o); r "Other VM `$o port 22" blocked `$(tcp `$o 22); done
if sudo -n true 2>/dev/null; then
  sudo mkdir -p /tmp/aicage-cdrive
  if sudo mount -t cifs "//`$HOST/C`$" /tmp/aicage-cdrive -o credentials=/root/.smb-aicage,vers=3.1.1 >/dev/null 2>&1; then
    r 'Laptop C: drive (C$ share)' denied mounted; sudo umount /tmp/aicage-cdrive
  else r 'Laptop C: drive (C$ share)' denied denied; fi
  sudo rmdir /tmp/aicage-cdrive
  st=`$(sudo -n passwd -S "`$(id -un)" | awk '{print `$2}')
  r 'Linux password usable (PuTTY, sudo)' P "`$st"
else r 'Laptop C: drive (C$ share)' denied 'skipped (sudo needs a password)'; fi
exit 0
"@
    $lines = Invoke-AicSsh -State $s -Script $script -Quiet
    $results = foreach ($l in $lines) {
        if ($l -notmatch '^RESULT\|') { continue }
        $p = $l.Split('|')
        $exp = $p[2]; $act = $p[3]
        $status = if ($exp -eq 'any') { 'INFO' } elseif ($exp -eq $act) { 'PASS' } elseif ($act -like 'skipped*') { 'SKIP' } else { 'FAIL' }
        $lvl = @{ PASS = 'Ok'; FAIL = 'Error'; INFO = 'Info'; SKIP = 'Warn' }[$status]
        Write-AicLog ('{0,-4}  {1,-46} expected {2,-8} got {3}' -f $status, $p[1], $exp, $act) -Level $lvl
        [pscustomobject]@{ Test = $p[1]; Expected = $exp; Actual = $act; Status = $status }
    }

    try {
        Test-AicShareRoundTrip -State $s
        Write-AicLog 'PASS  Shared folder works in both directions' -Level Ok
        $results = @($results) + [pscustomobject]@{ Test = 'Shared folder round trip'; Expected = 'ok'; Actual = 'ok'; Status = 'PASS' }
    } catch {
        Write-AicLog "FAIL  Shared folder: $($_.Exception.Message)" -Level Error
        $results = @($results) + [pscustomobject]@{ Test = 'Shared folder round trip'; Expected = 'ok'; Actual = $_.Exception.Message; Status = 'FAIL' }
    }

    return $results
}

# ---- Private/Tools.ps1 ----------------------------------------------------------------
# Optional programs Terrarium installs into a new VM, after its first boot. Each one is a bash
# script run over SSH as the VM's user (sudo where needed). What was installed is recorded in the
# VM's aicage.json.

$script:AicTools = [ordered]@{
    Docker     = @{ Title = 'Docker'; Script = @'
set -e
if ! command -v docker >/dev/null; then
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get -o DPkg::Lock::Timeout=300 update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo usermod -aG docker "$(id -un)"
sudo systemctl enable --now docker
sudo docker --version
'@ }
    ClaudeCode = @{ Title = 'Claude Code'; Script = @'
set -e
curl -fsSL https://claude.ai/install.sh | bash
"$HOME/.local/bin/claude" --version
'@ }
    Codex      = @{ Title = 'Codex'; Script = @'
set -e
case "$(uname -m)" in x86_64) a=x86_64 ;; aarch64) a=aarch64 ;; *) echo "unsupported CPU $(uname -m)"; exit 1 ;; esac
# /var/tmp, not /tmp: /tmp lives in memory on Debian 13 and the download is about 300 MB.
d=$(mktemp -d -p /var/tmp)
curl -fsSL "https://github.com/openai/codex/releases/latest/download/codex-$a-unknown-linux-musl.tar.gz" | tar -xz -C "$d"
sudo install -m 0755 "$d/codex-$a-unknown-linux-musl" /usr/local/bin/codex
rm -rf "$d"
codex --version
'@ }
    # XFCE: a full desktop at a fraction of GNOME's or KDE's size (about 1 GB on disk, 400 MB
    # of memory). It is opened with Remote Desktop (xrdp in the VM), which unlike the Hyper-V
    # screen resizes with the window. The VM's screen keeps its text login.
    Desktop    = @{ Title = 'Desktop (XFCE)'; Script = @'
set -e
sudo apt-get -o DPkg::Lock::Timeout=300 update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q --no-install-recommends \
  xfce4 xfce4-terminal xfce4-notifyd mousepad dbus-x11 at-spi2-core xrdp xorgxrdp firefox-esr
sudo adduser xrdp ssl-cert >/dev/null 2>&1 || true   # xrdp reads the TLS key
echo xfce4-session > "$HOME/.xsession"
sudo systemctl enable xrdp
sudo systemctl restart xrdp
systemctl is-active xrdp
'@ }
}

function Get-AicInstalledTool($State) {
    if ($State.PSObject.Properties['Tools'] -and $State.Tools) { return @($State.Tools) }
    return @()
}

function Install-AicToolCore {
    # Installs the tools one by one; one failing does not stop the others. Returns the failed ones.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string[]]$Tool)
    $failed = @()
    foreach ($t in $Tool) {
        $def = $script:AicTools[$t]
        try {
            Invoke-AicStep "Install $($def.Title)" {
                $script = "sudo -n true 2>/dev/null || { echo 'sudo needs a password in this VM - cannot install'; exit 1; }`n" + $def.Script
                Invoke-AicSsh -State $State -Script $script | Out-Null
            }
            $have = @(Get-AicInstalledTool $State | Where-Object { $_ -ne $t }) + $t
            $State | Add-Member -NotePropertyName Tools -NotePropertyValue $have -Force
            Save-AicState $State
        } catch { $failed += $t }
    }
    return $failed
}

function Install-AicTool {
    <#
    .SYNOPSIS
    Installs optional programs into an existing, running VM: Docker, ClaudeCode, Codex, Desktop.
    .EXAMPLE
    Install-AicTool agent1 -Tool Desktop
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name,
          [Parameter(Mandatory)][ValidateSet('Docker', 'ClaudeCode', 'Codex', 'Desktop')][string[]]$Tool)
    process {
        Assert-AicReady
        $s = Get-AicState1 -Name $Name
        if ((Get-VM -Name $Name).State -ne 'Running') { throw "Start $Name first: programs are installed over SSH." }
        Start-AicLog "install-$Name"
        $failed = @(Install-AicToolCore -State $s -Tool $Tool)
        if ($failed.Count) { throw "Not installed: $($failed -join ', ') - the log shows why." }
        Write-AicLog "Installed in ${Name}: $(($Tool | ForEach-Object { $script:AicTools[$_].Title }) -join ', ')" -Level Ok
        if ($Tool -contains 'Desktop') { Write-AicLog "Open it with the Desktop button (or: Connect-AicVm $Name -With Desktop); log in as $($s.User) with your Linux password." -Level Info }
    }
}

# ---- Public/Vm.ps1 --------------------------------------------------------------------
$script:AicBasePackages = @('hyperv-daemons', 'cifs-utils', 'locales', 'git', 'curl', 'ca-certificates', 'tmux', 'htop', 'unzip')
$script:AicGuestServiceId = '6C09BB55-D683-4DA0-8931-C9BF705F6480'   # "Guest Service Interface"; its display name is localized

function New-AicVm {
    <#
    .SYNOPSIS
    Creates a ready-to-use, isolated Debian 13 VM: network, shared folder, user, SSH key, autostart.

    .EXAMPLE
    New-AicVm -Name agent1 -SharedFolder C:\AICage\shared\agent1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,14}[a-z0-9]$')][string]$Name,
        [ValidatePattern('^[a-z_][a-z0-9_-]{0,31}$')][string]$User = 'ai',
        [Security.SecureString]$Password,
        [ValidateRange(256, 65536)][int]$MemoryStartupMB = 1024,
        [ValidateRange(128, 65536)][int]$MemoryMinMB = 1024,
        [ValidateRange(256, 262144)][int]$MemoryMaxMB = 2048,
        [ValidateRange(1, 64)][int]$Cpu = 2,
        [ValidateRange(4, 2048)][int]$DiskGB = 30,
        [string]$SharedFolder,
        [switch]$SharedReadOnly,
        [bool]$AutoStart = $true,
        [ValidateSet('Strict', 'Open')][string]$Isolation = 'Strict',
        [string]$TimeZone,
        [string]$Keyboard,
        [string[]]$Packages = @(),
        [ValidateSet('Docker', 'ClaudeCode', 'Codex', 'Desktop')][string[]]$Tools = @(),
        [string[]]$Ports = @(),
        [ValidateSet('Home', 'Program')][string]$Location = 'Home',
        [string]$SetupScriptPath,
        [bool]$PasswordlessSudo = $true,
        [bool]$Upgrade = $true,
        [ValidateRange(0, 16384)][int]$SwapMB = 1024,
        [bool]$SecureBoot = $true,
        [ValidateRange(5, 120)][int]$TimeoutMinutes = 20
    )

    Assert-AicReady
    if ($MemoryMinMB -gt $MemoryStartupMB -or $MemoryStartupMB -gt $MemoryMaxMB) { throw 'Memory must satisfy Min <= Startup <= Max.' }
    if ($User -in 'root', 'daemon', 'bin', 'sys', 'nobody', 'admin') { throw "User name '$User' is reserved." }
    $hostCpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if ($Cpu -gt $hostCpus) { throw "This laptop has $hostCpus logical processors; -Cpu $Cpu is too many." }
    if (Get-AicState -Name $Name) { throw "Terrarium VM '$Name' already exists (Remove-AicVm $Name first)." }
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "A Hyper-V VM named '$Name' already exists (not made by Terrarium)." }
    $Ports = @(ConvertTo-AicPortList $Ports)
    $portProblems = @(Get-AicPortConflict -Name $Name -Ports $Ports)
    if ($portProblems.Count) { throw "Ports: $($portProblems -join '; ')." }

    if (-not $Password) {
        $Password = Read-Host "Password for Linux user '$User' (used for sudo and PuTTY)" -AsSecureString
        $again = Read-Host 'Repeat the password' -AsSecureString
        if ((ConvertFrom-AicSecureString $Password) -cne (ConvertFrom-AicSecureString $again)) { throw 'Passwords differ.' }
    }
    $linuxPw = ConvertFrom-AicSecureString $Password
    if ($linuxPw.Length -lt 1) { throw 'The Linux password must not be empty.' }

    $setupScript = $null
    if ($SetupScriptPath) { $setupScript = Get-Content -LiteralPath $SetupScriptPath -Raw }
    if ((Get-AicLocations) -notcontains $Location) { $Location = 'Home' }
    if (-not $SharedFolder) { $SharedFolder = Join-Path (Get-AicPath Shared -Location $Location) $Name }
    $SharedFolder = Assert-AicSafeFolder $SharedFolder
    if (-not $TimeZone) { $TimeZone = Get-AicDefaultTimeZone }
    if (-not $Keyboard) { $Keyboard = Get-AicDefaultKeyboard }

    [void](Get-AicPath Data -Location $Location)   # before Start-AicLog, so it gets protected like the rest
    Start-AicLog "create-$Name"
    $cfg = Get-AicConfig
    $total = [Diagnostics.Stopwatch]::StartNew()

    $state = [pscustomobject][ordered]@{
        Name           = $Name
        Location       = $Location
        Ip             = $null
        User           = $User
        ShareAccount   = "aic-$Name"
        ShareName      = "AICage-$Name"
        SharedFolder   = $SharedFolder
        SharedReadOnly = [bool]$SharedReadOnly
        Isolation      = $Isolation
        Status         = 'creating'
        Created        = (Get-Date).ToString('s')
        Image          = $null
        ToolVersion    = $script:AicVersion
    }
    Write-AicLog ("Settings: user={0} RAM={1}/{2}/{3} MB (min/startup/max) CPU={4} disk={5} GB share='{6}'{7} autostart={8} isolation={9} tz={10} kb={11}" -f `
        $User, $MemoryMinMB, $MemoryStartupMB, $MemoryMaxMB, $Cpu, $DiskGB, $SharedFolder, $(if ($SharedReadOnly) { ' (read-only)' } else { '' }), $AutoStart, $Isolation, $TimeZone, $Keyboard) -Level Info

    try {
        Invoke-AicStep 'Host network (virtual switch, host address, NAT)' { Initialize-AicHostNetwork }

        $state.Ip = Get-AicNextIp
        Save-AicState $state
        Write-AicLog "VM address: $($state.Ip)" -Level Info
        $vmDir = Split-Path (Get-AicStatePath -Name $Name -Location $Location)
        Write-AicLog "Stored in: $(Split-Path $vmDir)" -Level Info

        $base = Invoke-AicStep 'Debian base image' { Get-AicBaseImage }
        $state.Image = Split-Path $base -Leaf

        $disk = Join-Path $vmDir "$Name.vhdx"
        Invoke-AicStep "Virtual disk ($DiskGB GB, grows as needed)" {
            Write-AicLog "Copy-Item $base -> $disk" -Level Cmd
            Copy-Item -LiteralPath $base -Destination $disk
            Write-AicLog "Resize-VHD -Path $disk -SizeBytes $($DiskGB)GB" -Level Cmd
            Resize-VHD -Path $disk -SizeBytes ([int64]$DiskGB * 1GB)
        }

        $pub = Invoke-AicStep 'SSH key' { New-AicSshKey -Name $Name -Location $Location }

        $sharePw = Invoke-AicStep "Shared folder $SharedFolder (account $($state.ShareAccount), share, firewall rule)" { New-AicShare -State $state }
        Save-AicState $state

        $iso = Join-Path $vmDir 'seed.iso'
        Invoke-AicStep 'First-boot configuration (cloud-init seed ISO)' {
            $ud = New-AicUserData -State $state -LinuxPassword $linuxPw -SharePassword $sharePw -PublicKey $pub `
                -TimeZone $TimeZone -Keyboard $Keyboard -Packages ($script:AicBasePackages + $Packages) -SetupScript $setupScript `
                -PasswordlessSudo $PasswordlessSudo -Upgrade $Upgrade -SwapMB $SwapMB
            $md = "instance-id: aicage-$Name-$([guid]::NewGuid().ToString('N').Substring(0, 8))`nlocal-hostname: $Name`n"
            $nc = New-AicNetworkConfig -Ip $state.Ip
            New-AicSeedIso -Path $iso -UserData $ud -MetaData $md -NetworkConfig $nc
        }

        Invoke-AicStep 'Hyper-V VM' {
            Write-AicLog "New-VM -Name $Name -Generation 2 -MemoryStartupBytes $($MemoryStartupMB)MB -VHDPath $disk -SwitchName $($cfg.SwitchName)" -Level Cmd
            New-VM -Name $Name -Generation 2 -MemoryStartupBytes ([int64]$MemoryStartupMB * 1MB) -VHDPath $disk `
                -SwitchName $cfg.SwitchName -Path (Get-AicPath Vms -Location $Location) | Out-Null
            Write-AicLog "Set-VMMemory -DynamicMemoryEnabled `$true -MinimumBytes $($MemoryMinMB)MB -MaximumBytes $($MemoryMaxMB)MB" -Level Cmd
            Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes ([int64]$MemoryMinMB * 1MB) `
                -StartupBytes ([int64]$MemoryStartupMB * 1MB) -MaximumBytes ([int64]$MemoryMaxMB * 1MB)
            Write-AicLog "Set-VMProcessor -Count $Cpu" -Level Cmd
            Set-VMProcessor -VMName $Name -Count $Cpu
            if ($SecureBoot) {
                Write-AicLog 'Set-VMFirmware -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority' -Level Cmd
                Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
            } else {
                Write-AicLog 'Set-VMFirmware -EnableSecureBoot Off' -Level Cmd
                Set-VMFirmware -VMName $Name -EnableSecureBoot Off
            }
            Write-AicLog "Add-VMDvdDrive -Path $iso; boot from the hard disk first" -Level Cmd
            Add-VMDvdDrive -VMName $Name -Path $iso
            Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1)
            Get-VMIntegrationService -VMName $Name | Where-Object { $_.Id -like "*$script:AicGuestServiceId" } | Enable-VMIntegrationService
            $startAction = if ($AutoStart) { 'Start' } else { 'Nothing' }
            Write-AicLog "Set-VM -AutomaticStartAction $startAction -AutomaticStartDelay 20 -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled `$false" -Level Cmd
            Set-VM -Name $Name -AutomaticStartAction $startAction -AutomaticStartDelay 20 -AutomaticStopAction ShutDown `
                -AutomaticCheckpointsEnabled $false -Notes "Managed by Terrarium. Change it with Set-AicVm / Remove-AicVm."
            Write-AicLog 'Set-VMNetworkAdapter -DhcpGuard On -RouterGuard On' -Level Cmd
            Set-VMNetworkAdapter -VMName $Name -DhcpGuard On -RouterGuard On
        }

        Invoke-AicStep "Network filter ($Isolation)" { Set-AicIsolation -VmName $Name -Isolation $Isolation }

        Invoke-AicStep 'Start VM and wait for SSH' {
            Remove-AicKnownHost -State $state
            Write-AicLog "Start-VM $Name" -Level Cmd
            Start-VM -Name $Name
            Wait-AicSsh -State $state -TimeoutSeconds 300
        }

        Invoke-AicStep 'First boot: cloud-init (packages, user, shared folder) - live guest log below' {
            Wait-AicCloudInit -State $state -TimeoutSeconds ($TimeoutMinutes * 60)
        }

        Invoke-AicStep 'Remove the seed ISO (it contains the passwords)' {
            Write-AicLog "Set-VMDvdDrive -Path `$null; delete $iso" -Level Cmd
            Get-VMDvdDrive -VMName $Name | Set-VMDvdDrive -Path $null
            try { Get-VMDvdDrive -VMName $Name | Remove-VMDvdDrive } catch { Write-AicLog 'Empty DVD drive stays attached (Hyper-V cannot remove it while the VM runs) - harmless' -Level Debug }
            Remove-Item -LiteralPath $iso -Force
        }

        if ($Tools.Count) {
            $failedTools = @(Install-AicToolCore -State $state -Tool $Tools)
            if ($failedTools.Count) { Write-AicLog "Not installed: $($failedTools -join ', ') - the VM works without them; the log above shows why" -Level Warn }
        }

        if ($Ports.Count) {
            $state | Add-Member -NotePropertyName Ports -NotePropertyValue $Ports -Force
            Save-AicState $state
            try { Invoke-AicStep 'Port forwards to this laptop' { Set-AicPortForward -State $state } }
            catch { Write-AicLog 'The VM works without them; Settings can try the ports again.' -Level Warn }
        }

        # Shared folder and isolation, with automatic repair (and quarantine if that fails).
        $checks = Invoke-AicVmCheck -State $state

        Invoke-AicStep 'Checkpoint "fresh install"' {
            Write-AicLog "Checkpoint-VM -Name $Name -SnapshotName 'Terrarium: fresh install'" -Level Cmd
            Checkpoint-VM -Name $Name -SnapshotName 'Terrarium: fresh install'
        }

        $state.Status = 'ready'
        Save-AicState $state
        $quarantined = Test-AicQuarantined $state
        $sshCfg = Update-AicSshConfig

        if ($quarantined) { Write-AicLog "VM $Name was created but is QUARANTINED (no network) - see the failed tests above." -Level Error }
        else { Write-AicLog ('VM {0} is ready in {1:n0} min {2:n0} s.' -f $Name, [math]::Floor($total.Elapsed.TotalMinutes), $total.Elapsed.Seconds) -Level Ok }
        Write-AicLog "  Connect:        Connect-AicVm $Name    (or: ssh -F `"$sshCfg`" $Name)" -Level Info
        Write-AicLog "  PuTTY:          host $($state.Ip), user $User, your password" -Level Info
        Write-AicLog "  Shared folder:  $SharedFolder  =  ~/shared in the VM" -Level Info
        Write-AicLog "  Log:            $(Get-AicLogPath)" -Level Info
        return Get-AicVm -Name $Name
    } catch {
        $state.Status = 'failed'
        try { Save-AicState $state } catch { }
        Write-AicLog "Creating $Name failed: $($_.Exception.Message)" -Level Error
        Write-AicLog "The half-made VM is kept for inspection. Clean up with: Remove-AicVm $Name" -Level Warn
        Write-AicLog "Please send this log: $(Get-AicLogPath)" -Level Warn
        throw
    }
}

function Wait-AicSsh {
    param([Parameter(Mandatory)]$State, [int]$TimeoutSeconds = 300)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastReport = -30
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $vm = Get-VM -Name $State.Name
        if ($vm.State -ne 'Running') { throw "VM stopped unexpectedly (state: $($vm.State))." }
        if (Test-AicTcpPort -Ip $State.Ip -Port 22) {
            if (Test-AicSshReady -State $State) { Write-AicLog "SSH answers after $([int]$sw.Elapsed.TotalSeconds) s" -Level Debug; return }
        }
        if ($sw.Elapsed.TotalSeconds - $lastReport -ge 30) {
            $lastReport = $sw.Elapsed.TotalSeconds
            Write-AicLog ("waiting for {0}:22 ... {1:n0} s (VM {2}, heartbeat {3}, uptime {4})" -f $State.Ip, $sw.Elapsed.TotalSeconds, $vm.State, $vm.Heartbeat, $vm.Uptime) -Level Debug
            if ($sw.Elapsed.TotalSeconds -gt 120) {
                Write-AicLog "Slow? Look at the VM screen: Hyper-V Manager -> $($State.Name) -> Connect. A Secure Boot error there means: re-create with -SecureBoot `$false." -Level Warn
            }
        }
        Start-Sleep -Seconds 3
    }
    throw "No SSH on $($State.Ip) after $TimeoutSeconds s."
}

function Wait-AicCloudInit {
    # Streams /var/log/cloud-init-output.log into our log until cloud-init is done. Reconnects if
    # SSH drops (a package upgrade may restart sshd or the network).
    param([Parameter(Mandatory)]$State, [int]$TimeoutSeconds = 1200)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $tailFrom = '+1'
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $left = [int]($deadline - (Get-Date)).TotalSeconds
        if ($left -le 0) { break }
        $script = @"
tail -n $tailFrom -F /var/log/cloud-init-output.log 2>/dev/null &
T=`$!
timeout $left cloud-init status --wait >/dev/null 2>&1
rc=`$?
sleep 1; kill `$T 2>/dev/null
echo "== cloud-init status (exit code `$rc) =="
cloud-init status --long 2>&1
exit `$rc
"@
        try {
            $out = Invoke-AicSsh -State $State -Script $script -OkExitCodes 0, 1, 2, 124
        } catch {
            Write-AicLog "SSH connection dropped ($($_.Exception.Message)) - reconnecting" -Level Warn
            $tailFrom = '0'
            Start-Sleep -Seconds 5
            Wait-AicSsh -State $State -TimeoutSeconds 180
            continue
        }
        $code = $script:AicLastExitCode
        switch ($code) {
            0 { return }
            2 { Write-AicLog 'cloud-init finished with warnings (see above) - continuing' -Level Warn; return }
            124 { throw "cloud-init still running after $TimeoutSeconds s (slow internet? try -TimeoutMinutes 40)." }
            default { throw "cloud-init reported an error (exit code $code) - see the guest log above." }
        }
    }
    throw 'Lost the SSH connection to the VM too many times.'
}

function Test-AicShareRoundTrip {
    param([Parameter(Mandatory)]$State)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $hostFile = Join-Path $State.SharedFolder ".aicage-check-$token"
    if ($State.SharedReadOnly) {
        Set-Content -LiteralPath $hostFile -Value $token -Encoding Ascii
        try {
            $out = Invoke-AicSsh -State $State -Script "cat ~/shared/.aicage-check-$token" -Quiet
            if (($out -join '') -notmatch $token) { throw 'The VM cannot read the shared folder.' }
            Write-AicLog 'VM reads the shared folder (read-only)' -Level Debug
        } finally { Remove-Item -LiteralPath $hostFile -Force -ErrorAction SilentlyContinue }
    } else {
        Invoke-AicSsh -State $State -Script "echo $token > ~/shared/.aicage-check-$token" -Quiet | Out-Null
        if (-not (Test-Path -LiteralPath $hostFile)) { throw "The VM wrote to ~/shared but $hostFile did not appear." }
        Remove-Item -LiteralPath $hostFile -Force
        Write-AicLog "VM writes to ~/shared and the file appears in $($State.SharedFolder)" -Level Debug
    }
}

function Get-AicVm {
    <#
    .SYNOPSIS
    Lists Terrarium VMs with their state, address, memory and settings.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromPipelineByPropertyName)][string]$Name)
    process {
        $states = if ($Name) { @(Get-AicState1 -Name $Name) } else { @(Get-AicState) }
        foreach ($s in $states) {
            $vm = Get-VM -Name $s.Name -ErrorAction SilentlyContinue
            $mem = if ($vm) { Get-VMMemory -VMName $s.Name } else { $null }
            [pscustomobject]@{
                PSTypeName   = 'AiCage.Vm'
                Name         = $s.Name
                State        = if ($vm) { "$($vm.State)" } else { 'missing' }
                Status       = if (Test-AicQuarantined $s) { 'quarantined' } else { $s.Status }
                Ip           = $s.Ip
                User         = $s.User
                MemoryMB     = if ($vm) { [int]($vm.MemoryAssigned / 1MB) } else { 0 }
                MemoryMinMB  = if ($mem) { [int]($mem.Minimum / 1MB) } else { 0 }
                MemoryMaxMB  = if ($mem) { [int]($mem.Maximum / 1MB) } else { 0 }
                Cpu          = if ($vm) { $vm.ProcessorCount } else { 0 }
                AutoStart    = if ($vm) { "$($vm.AutomaticStartAction)" -eq 'Start' } else { $false }
                Isolation    = $s.Isolation
                SharedFolder = $s.SharedFolder
                SharedReadOnly = [bool]$s.SharedReadOnly
                Location     = Get-AicStateLocation $s
                StoredIn     = Split-Path (Split-Path (Get-AicStatePath -Name $s.Name -Location (Get-AicStateLocation $s)))
                Uptime       = if ($vm) { $vm.Uptime } else { $null }
                # Heartbeat comes from the VM's kernel: LostCommunication or NoContact long after
                # the start means the VM is stuck (no SSH, no keyboard on its screen).
                Heartbeat    = if ($vm) { "$($vm.Heartbeat)" } else { '' }
                MemoryDemandMB = if ($vm) { [int]($vm.MemoryDemand / 1MB) } else { 0 }
                Tools        = @(Get-AicInstalledTool $s)
                Ports        = @(Get-AicPortForward $s)
            }
        }
    }
}

function Set-AicVm {
    <#
    .SYNOPSIS
    Changes memory, processors, autostart, isolation, the shared folder or the port forwards of a
    Terrarium VM.
    .PARAMETER Ports
    Laptop ports forwarded to the VM, e.g. 8080, '3000:80' (laptop:VM). Apps on this laptop then
    reach them as localhost:8080; the local network does not. @() removes all forwards.
    .NOTES
    Processor count and startup memory need the VM off; the rest works while it runs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name,
        [ValidateRange(128, 262144)][int]$MemoryMinMB,
        [ValidateRange(256, 262144)][int]$MemoryStartupMB,
        [ValidateRange(256, 262144)][int]$MemoryMaxMB,
        [ValidateRange(1, 64)][int]$Cpu,
        [bool]$AutoStart,
        [ValidateSet('Strict', 'Open')][string]$Isolation,
        [string]$SharedFolder,
        [bool]$SharedReadOnly,
        [AllowEmptyCollection()][string[]]$Ports
    )
    process {
        Assert-AicReady
        $s = Get-AicState1 -Name $Name
        if (-not $PSCmdlet.ShouldProcess($Name, 'Change settings')) { return }
        Start-AicLog "set-$Name"
        $vm = Get-VM -Name $Name
        $running = $vm.State -ne 'Off'

        $memArgs = @{}
        if ($PSBoundParameters.ContainsKey('MemoryMinMB')) { $memArgs.MinimumBytes = [int64]$MemoryMinMB * 1MB }
        if ($PSBoundParameters.ContainsKey('MemoryMaxMB')) { $memArgs.MaximumBytes = [int64]$MemoryMaxMB * 1MB }
        if ($PSBoundParameters.ContainsKey('MemoryStartupMB')) {
            if ($running) { throw 'Startup memory can be changed only while the VM is off (Stop-AicVm first).' }
            $memArgs.StartupBytes = [int64]$MemoryStartupMB * 1MB
        }
        if ($memArgs.Count) {
            Invoke-AicStep 'Memory' {
                Write-AicLog "Set-VMMemory $(($memArgs.GetEnumerator() | ForEach-Object { '-{0} {1}MB' -f $_.Key, ($_.Value / 1MB) }) -join ' ')" -Level Cmd
                Set-VMMemory -VMName $Name @memArgs
            }
        }
        if ($PSBoundParameters.ContainsKey('Cpu')) {
            if ($running) { throw 'Processor count can be changed only while the VM is off (Stop-AicVm first).' }
            Invoke-AicStep "Processors: $Cpu" { Set-VMProcessor -VMName $Name -Count $Cpu }
        }
        if ($PSBoundParameters.ContainsKey('AutoStart')) {
            $a = if ($AutoStart) { 'Start' } else { 'Nothing' }
            Invoke-AicStep "Start with Windows: $AutoStart" { Set-VM -Name $Name -AutomaticStartAction $a -AutomaticStartDelay 20 }
        }
        if ($PSBoundParameters.ContainsKey('Isolation')) {
            Invoke-AicStep "Network filter: $Isolation" { Set-AicIsolation -VmName $Name -Isolation $Isolation }
            $s.Isolation = $Isolation
            Save-AicState $s
        }
        if ($PSBoundParameters.ContainsKey('SharedFolder') -or $PSBoundParameters.ContainsKey('SharedReadOnly')) {
            $folder = if ($SharedFolder) { Assert-AicSafeFolder $SharedFolder } else { $s.SharedFolder }
            $ro = if ($PSBoundParameters.ContainsKey('SharedReadOnly')) { $SharedReadOnly } else { [bool]$s.SharedReadOnly }
            # Read-only is also set in the VM's mount; with the VM off that cannot be changed.
            if ($vm.State -ne 'Running' -and $ro -ne [bool]$s.SharedReadOnly) { throw 'Start the VM to switch read-only on or off.' }
            Invoke-AicStep "Shared folder: $folder$(if ($ro) { ' (read-only)' })" { Set-AicShareFolder -State $s -Folder $folder -ReadOnly $ro -Running ($vm.State -eq 'Running') }
        }
        if ($PSBoundParameters.ContainsKey('Ports')) {
            $list = @(ConvertTo-AicPortList $Ports)
            $s | Add-Member -NotePropertyName Ports -NotePropertyValue $list -Force
            Invoke-AicStep "Port forwards: $(if ($list.Count) { $list -join ', ' } else { 'none' })" { Set-AicPortForward -State $s }
            Save-AicState $s
        }
        Get-AicVm -Name $Name
    }
}

function Start-AicVm {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name, [switch]$Wait)
    process {
        Assert-AicReady
        $s = Get-AicState1 -Name $Name
        Write-AicLog "Start-VM $Name" -Level Cmd
        Start-VM -Name $Name
        if ($Wait) { Wait-AicSsh -State $s -TimeoutSeconds 180; Write-AicLog "$Name is up at $($s.Ip)" -Level Ok }
    }
}

function Stop-AicVm {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name, [switch]$TurnOff)
    process {
        Assert-AicReady
        [void](Get-AicState1 -Name $Name)
        if ($TurnOff) { Write-AicLog "Stop-VM $Name -TurnOff" -Level Cmd; Stop-VM -Name $Name -TurnOff -Force }
        else { Write-AicLog "Stop-VM $Name (clean shutdown)" -Level Cmd; Stop-VM -Name $Name -Force }
    }
}

function Restart-AicVm {
    <#
    .SYNOPSIS
    Restarts a VM. -Force resets it like a power button, for a VM that no longer answers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name, [switch]$Force)
    process {
        Assert-AicReady
        $s = Get-AicState1 -Name $Name
        Start-AicLog "restart-$Name"
        Invoke-AicStep "Restart $Name$(if ($Force) { ' (hard reset)' })" {
            if ((Get-VM -Name $Name).State -ne 'Off') {
                if ($Force) { Write-AicLog "Stop-VM $Name -TurnOff" -Level Cmd; Stop-VM -Name $Name -TurnOff -Force }
                else { Write-AicLog "Stop-VM $Name (clean shutdown)" -Level Cmd; Stop-VM -Name $Name -Force }
            }
            Write-AicLog "Start-VM $Name" -Level Cmd
            Start-VM -Name $Name
            Wait-AicSsh -State $s -TimeoutSeconds 180
        }
        Write-AicLog "$Name is up again. Diagnose now shows the log of the boot before the restart." -Level Ok
    }
}

function Debug-AicVm {
    <#
    .SYNOPSIS
    Finds out why a VM does not answer (no SSH, no keyboard on its screen), or why it did not
    before its last restart: what Hyper-V sees (heartbeat, memory), Hyper-V's own events for the
    VM and, when SSH works, the VM's system log of this and the previous boot.
    .OUTPUTS
    Name, Responding (SSH works) and Problems (short findings).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name)
    process {
        Assert-AicReady
        $s = Get-AicState1 -Name $Name
        Start-AicLog "diagnose-$Name"
        $problems = New-Object System.Collections.Generic.List[string]
        $vm = Get-VM -Name $Name

        Invoke-AicStep 'What Hyper-V sees' {
            $mem = Get-VMMemory -VMName $Name
            $maxMb = [int]($mem.Maximum / 1MB); $wantMb = [int]($vm.MemoryDemand / 1MB)
            Write-AicLog ('State {0}, running for {1}, heartbeat {2}, CPU {3}%' -f $vm.State, $vm.Uptime, $vm.Heartbeat, $vm.CPUUsage) -Level Info
            Write-AicLog ('Memory: has {0} MB, wants {1} MB, may use {2}-{3} MB' -f [int]($vm.MemoryAssigned / 1MB), $wantMb, [int]($mem.Minimum / 1MB), $maxMb) -Level Info
            if ($vm.State -ne 'Running') {
                $problems.Add("The VM is $($vm.State), not running.")
                if ("$($vm.State)" -like 'Paused*') { $problems.Add('Hyper-V pauses a VM when the laptop disk is full - free some space, then start it.') }
            }
            elseif ("$($vm.Heartbeat)" -in 'LostCommunication', 'NoContact', 'Error' -and $vm.Uptime.TotalMinutes -gt 3) {
                $problems.Add("No heartbeat ($($vm.Heartbeat)): the VM's Linux kernel itself is stuck or completely overloaded.")
            }
            if ($vm.State -eq 'Running' -and $maxMb -and $wantMb -ge 0.95 * $maxMb) {
                $problems.Add("Memory is full: the VM wants $wantMb MB and may use at most $maxMb MB. Raise 'at most' in Settings.")
            }
            $disk = Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1
            if ($disk) {
                $drive = Get-PSDrive -Name $disk.Path.Substring(0, 1) -ErrorAction SilentlyContinue
                if ($drive -and $drive.Free -lt 2GB) { $problems.Add(('Only {0:n1} GB free on {1}: where the VM disk lives.' -f ($drive.Free / 1GB), $drive.Name)) }
            }
        }

        Invoke-AicStep 'Hyper-V events about this VM (last 7 days)' {
            $since = (Get-Date).AddDays(-7)
            $events = @(foreach ($log in 'Microsoft-Windows-Hyper-V-Worker-Admin', 'Microsoft-Windows-Hyper-V-VMMS-Admin') {
                try {
                    Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2, 3; StartTime = $since } -MaxEvents 300 -ErrorAction Stop |
                        Where-Object { $_.Message -like "*$($vm.Id)*" -or $_.Message -like "*'$Name'*" }
                } catch { }   # "no events found" is an error too
            })
            $events = @($events | Sort-Object TimeCreated | Select-Object -Last 15)
            foreach ($e in $events) {
                $lvl = if ($e.Level -le 2) { 'Error' } else { 'Warn' }
                Write-AicLog ('{0:yyyy-MM-dd HH:mm}  {1}' -f $e.TimeCreated, (($e.Message -split "`r?`n")[0])) -Level $lvl
            }
            if ($events.Count) { $problems.Add("Hyper-V logged $($events.Count) warning(s) or error(s) about the VM (in the log above).") }
            else { Write-AicLog 'none' -Level Debug }
        }

        $responding = $false
        if ($vm.State -eq 'Running') {
            $responding = Invoke-AicStep 'SSH' {
                if (-not (Test-AicTcpPort -Ip $s.Ip -Port 22 -TimeoutMs 3000)) {
                    $problems.Add("SSH (port 22 on $($s.Ip)) does not answer at all.")
                    return $false
                }
                if (-not (Test-AicSshReady -State $s)) {
                    $problems.Add('SSH answers but the login does not finish: the VM is probably out of memory or overloaded.')
                    return $false
                }
                Write-AicLog 'SSH works' -Level Ok
                return $true
            }
        }

        if ($responding) {
            Invoke-AicStep "The VM's own log (this boot and the one before the last restart)" {
                $script = @'
J=journalctl; sudo -n true 2>/dev/null && J="sudo -n journalctl"
echo "uptime: $(uptime)"
free -m
df -h / 2>/dev/null | tail -n 1 | awk '{print "disk /: " $3 " used of " $2 " (" $5 ")"}'
df / 2>/dev/null | awk 'NR == 2 && $5 + 0 >= 95 { print "PROBLEM|The VM disk is full (" $5 "). Delete files, or e.g. docker system prune." }'
echo "recent boots:"; $J --list-boots -q --no-pager 2>/dev/null | tail -n 3
if [ ! -f /etc/systemd/journald.conf.d/terrarium.conf ] && sudo -n true 2>/dev/null; then
  if [ ! -d /var/log/journal ]; then echo "PROBLEM|The system log was lost at every restart. It is kept from now on, so the next hang can be explained."; fi
  sudo -n sh -c '__JOURNAL__' && echo "system log: now kept across restarts, written every 30 s"
fi
pat='out of memory|oom-kill|killed process|hung_task|blocked for more than|soft lockup|hard lockup|rcu.*stall|self-detected stall|i/o error|ext4-fs error|remounting filesystem read-only|call trace|watchdog'
for b in -1 0; do
  if [ $b = -1 ]; then w='previous boot'; else w='this boot'; fi
  if ! $J -b $b -n 1 -q --no-pager >/dev/null 2>&1; then echo "== $w: no log kept"; continue; fi
  echo "== $w"
  hits=$($J -b $b -q --no-pager -o short-iso -p warning 2>/dev/null | grep -iE "$pat" | tail -n 15)
  oom=$($J -b $b -q --no-pager 2>/dev/null | grep -ciE 'out of memory|oom-kill')
  [ "${oom:-0}" -gt 0 ] && echo "PROBLEM|$w: $oom out-of-memory event(s). Give the VM more memory ('at most' in Settings)."
  [ -n "$hits" ] && { echo "PROBLEM|$w: the kernel reported trouble (lines below)."; echo "$hits"; }
done
if $J -b -1 -n 1 -q --no-pager >/dev/null 2>&1; then
  echo "== the last lines before the previous boot ended (a hang or a reset cuts them off):"
  $J -b -1 -n 20 -q --no-pager -o short-iso 2>/dev/null
  last=$($J -b -1 -n 1 -q --no-pager 2>/dev/null)
  case "$last" in
    *"Shutting down"*|*"Journal stopped"*|*"journald"*) ;;
    *hv_balloon*) echo "PROBLEM|The previous boot ended abruptly right after Hyper-V took memory back from the VM (hv_balloon). Raise 'at least' memory in Settings to 1024 MB or more." ;;
    *) echo "PROBLEM|The previous boot ended abruptly (no shutdown in its log): the VM froze or was reset. Its last lines are above." ;;
  esac
fi
# Hyper-V's Dynamic Memory squeezing the VM down to its minimum.
squeezed=$($J -b 0 -k -q --no-pager 2>/dev/null | grep -cE 'Balloon floor reached|Not enough memory')
availmb=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
totalmb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
if [ "${squeezed:-0}" -gt 0 ] && [ "${availmb:-999}" -lt 200 ]; then
  echo "PROBLEM|Hyper-V keeps taking memory back: the VM has $totalmb MB, only $availmb MB free. Raise 'at least' memory in Settings."
fi
failed=$(systemctl --failed --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -n "$failed" ] && echo "PROBLEM|Failed services: $failed"
exit 0
'@
                $script = $script.Replace('__JOURNAL__', $script:AicJournalSetup.Replace("'", "'\''"))
                foreach ($l in @(Invoke-AicSsh -State $s -Script $script -Quiet)) {
                    if ($l -like 'PROBLEM|*') { $problems.Add($l.Substring(8)); Write-AicLog $l.Substring(8) -Level Warn }
                    else { Write-AicLog $l -Level Guest }
                }
            }
        }

        if ($problems.Count) {
            Write-AicLog "Found $($problems.Count) problem(s):" -Level Warn
            foreach ($p in $problems) { Write-AicLog "  - $p" -Level Warn }
        } else {
            Write-AicLog 'No problem found. If the VM hung before a restart and the previous boot shows nothing, the hang left no trace in the VM.' -Level Ok
        }
        if (-not $responding -and $vm.State -eq 'Running') { Write-AicLog "A restart helps: Restart-AicVm $Name -Force (then Diagnose again to read the log of the stuck boot)." -Level Info }
        Write-AicLog "Log: $(Get-AicLogPath)" -Level Info
        return [pscustomobject]@{ Name = $Name; Responding = $responding; Running = ($vm.State -eq 'Running'); Problems = $problems.ToArray() }
    }
}

function Connect-AicVm {
    <#
    .SYNOPSIS
    Opens a terminal window with an SSH session into the VM (key login, no password).
    .PARAMETER With
    Terminal (Windows' own ssh) or PuTTY. Without it, the choice made in the window is used
    (kept in data\settings.json). Desktop opens the graphical desktop (Install-AicTool -Tool
    Desktop) in Remote Desktop.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name,
          [ValidateSet('Terminal', 'PuTTY', 'Desktop')][string]$With)
    process {
        $s = Get-AicState1 -Name $Name
        if (-not $With) { $With = Get-AicSetting -Name TerminalProgram -Default 'Terminal' }
        # A quick look first: a stuck VM otherwise just gives a terminal that closes at once.
        $port = if ($With -eq 'Desktop') { 3389 } else { 22 }
        if (-not (Test-AicTcpPort -Ip $s.Ip -Port $port -TimeoutMs 3000)) {
            if ($With -eq 'Desktop' -and (Get-AicInstalledTool $s) -notcontains 'Desktop') { throw "$Name has no desktop yet: Settings -> Advanced -> Install -> Desktop." }
            throw "$Name does not answer on port $port. Diagnose (Debug-AicVm $Name) shows why; a stuck VM needs a restart."
        }
        if ($With -eq 'Desktop') { Start-AicDesktop -State $s; return }
        if ($With -eq 'PuTTY') { Start-AicPutty -State $s; return }
        $cfg = Update-AicSshConfig
        Start-Process -FilePath (Get-AicSshExe) -ArgumentList "-F `"$cfg`" $Name"
    }
}

function Remove-AicVm {
    <#
    .SYNOPSIS
    Deletes a Terrarium VM and everything made for it: disk, checkpoints, share account, share,
    firewall rule, SSH key. The shared folder's files are kept unless -DeleteSharedFolder.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name,
        [switch]$DeleteSharedFolder,
        [switch]$Force
    )
    process {
        Assert-AicReady
        $s = Get-AicState1 -Name $Name
        if (-not $Force -and -not $PSCmdlet.ShouldProcess($Name, 'Delete VM, its disk and its share account')) { return }
        Start-AicLog "remove-$Name"
        $try = {
            param([string]$What, [scriptblock]$Do)
            try { Invoke-AicStep $What $Do | Out-Null } catch { $script:AicRemoveProblems++ }
        }
        $script:AicRemoveProblems = 0
        $script:AicRemoveVmDir = $null

        & $try 'Hyper-V VM' {
            $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
            if ($vm) {
                # Hyper-V's own folder for this VM (it may differ from ours, e.g. VMs made by older versions).
                $script:AicRemoveVmDir = $vm.Path
                if ($vm.State -ne 'Off') { Write-AicLog "Stop-VM $Name -TurnOff" -Level Cmd; Stop-VM -Name $Name -TurnOff -Force }
                Write-AicLog "Remove-VM $Name" -Level Cmd
                Remove-VM -Name $Name -Force
            } else { Write-AicLog 'no Hyper-V VM (already gone)' -Level Debug }
        }
        & $try 'Share, share account and firewall rule' { Remove-AicShare -State $s }
        if ($s.Ip) {
            & $try 'Port forwards' { foreach ($e in @(Get-AicPortProxy | Where-Object { $_.ConnectAddress -eq $s.Ip })) { Remove-AicPortProxy -Entry $e } }
        }
        & $try 'SSH key and saved sessions' {
            if ($s.Ip) { Remove-AicKnownHost -State $s }
            $key = Get-AicKeyPath $s
            foreach ($f in $key, "$key.pub", "$key.ppk") { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
            Remove-AicPuttySession -State $s
        }
        & $try 'VM files (disk, checkpoints, settings)' {
            $dirs = @(Split-Path (Get-AicStatePath -Name $Name -Location (Get-AicStateLocation $s)))
            # Only a folder named after the VM, never a shared Hyper-V default folder.
            if ($script:AicRemoveVmDir -and (Split-Path $script:AicRemoveVmDir -Leaf) -eq $Name -and $dirs -notcontains $script:AicRemoveVmDir) { $dirs += $script:AicRemoveVmDir }
            foreach ($dir in $dirs) {
                if (-not (Test-Path -LiteralPath $dir)) { continue }
                for ($i = 1; $i -le 10; $i++) {
                    try { Remove-Item -LiteralPath $dir -Recurse -Force; break }
                    catch { if ($i -eq 10) { throw }; Start-Sleep -Seconds 2 }   # Hyper-V releases files with a delay
                }
                Write-AicLog "deleted $dir" -Level Debug
            }
        }
        if ($DeleteSharedFolder) {
            & $try "Shared folder $($s.SharedFolder)" {
                if (Test-Path -LiteralPath $s.SharedFolder) { Remove-Item -LiteralPath $s.SharedFolder -Recurse -Force }
            }
        } else { Write-AicLog "Shared folder kept: $($s.SharedFolder)" -Level Info }
        [void](Update-AicSshConfig)

        if ($script:AicRemoveProblems) {
            Write-AicLog "$($script:AicRemoveProblems) step(s) failed - see above. Running Remove-AicVm again retries them." -Level Warn
            if (-not (Test-Path -LiteralPath (Get-AicStatePath -Name $Name -Location (Get-AicStateLocation $s)))) { Save-AicState $s }
        } else { Write-AicLog "VM $Name removed." -Level Ok }
        if (@(Get-AicState).Count -eq 0) {
            Write-AicLog 'No Terrarium VMs left. Remove-AicHostNetwork removes the virtual switch and NAT too.' -Level Info
        }
    }
}

function Move-AicVm {
    <#
    .SYNOPSIS
    Moves a VM (disk, checkpoints, key, settings) to your user folder (Home) or the program folder.
    .NOTES
    Works while the VM runs (Hyper-V storage migration). The shared folder stays where it is.
    .EXAMPLE
    Move-AicVm agent1 -To Home
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name,
          [Parameter(Mandatory)][ValidateSet('Home', 'Program')][string]$To)
    process {
        Assert-AicReady
        $s = Get-AicState1 -Name $Name
        $from = Get-AicStateLocation $s
        if ($from -eq $To) { Write-AicLog "$Name is already stored there." -Level Info; return }
        if ((Get-AicLocations) -notcontains $To) { throw 'The program folder is the user folder here - there is nothing to move.' }
        [void](Get-AicPath Data -Location $To)      # before Start-AicLog, so it gets protected like the rest
        Start-AicLog "move-$Name"
        $oldDir = Split-Path (Get-AicStatePath -Name $Name -Location $from)
        $newDir = Split-Path (Get-AicStatePath -Name $Name -Location $To)
        if (Test-Path -LiteralPath $newDir) { throw "$newDir already exists - move or delete it first." }
        $oldKey = Get-AicKeyPath $s
        $oldKnown = Get-AicKnownHostsPath $s

        Invoke-AicStep "Move disk and checkpoints to $newDir" {
            Write-AicLog "Move-VMStorage -VMName $Name -DestinationStoragePath $newDir" -Level Cmd
            Move-VMStorage -VMName $Name -DestinationStoragePath $newDir
        }
        Invoke-AicStep 'Move key and settings' {
            $s | Add-Member -NotePropertyName Location -NotePropertyValue $To -Force
            $newKey = Get-AicKeyPath $s
            foreach ($ext in '', '.pub', '.ppk') {
                if (-not (Test-Path -LiteralPath "$oldKey$ext")) { continue }
                Move-Item -LiteralPath "$oldKey$ext" -Destination "$newKey$ext" -Force
                Set-AicPrivateAcl -Path "$newKey$ext"
            }
            if (Test-Path -LiteralPath $oldKnown) {
                $all = @(Get-Content -LiteralPath $oldKnown)
                $mine = @($all | Where-Object { $_.StartsWith("$($s.Ip) ") })
                if ($mine.Count) {
                    $newKnown = Get-AicKnownHostsPath $s
                    Add-Content -LiteralPath $newKnown -Value $mine -Encoding Ascii
                    Set-AicPrivateAcl -Path $newKnown
                    Set-Content -LiteralPath $oldKnown -Value @($all | Where-Object { $_ -and -not $_.StartsWith("$($s.Ip) ") }) -Encoding Ascii
                }
            }
            Save-AicState $s
            Remove-Item -LiteralPath (Join-Path $oldDir 'aicage.json') -Force
            Remove-Item -LiteralPath (Join-Path $oldDir "$Name.rdp") -Force -ErrorAction SilentlyContinue   # made again when needed
        }
        if (Test-Path -LiteralPath $oldDir) {
            if (@(Get-ChildItem -LiteralPath $oldDir -Recurse -File -Force).Count) { Write-AicLog "Some files stayed in $oldDir - look at them before deleting" -Level Warn }
            else { Remove-Item -LiteralPath $oldDir -Recurse -Force }
        }
        [void](Update-AicSshConfig)
        $where = if ($To -eq 'Home') { 'your user folder' } else { 'the program folder' }
        Write-AicLog "$Name is now stored in $where ($newDir)." -Level Ok
        Write-AicLog "Shared folder unchanged: $($s.SharedFolder)" -Level Info
    }
}

function Uninstall-AiCage {
    <#
    .SYNOPSIS
    Removes all Terrarium VMs, the host network and the image cache. Shared folders are kept
    unless -DeleteSharedFolders.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([switch]$DeleteSharedFolders)
    Assert-AicReady
    if (-not $PSCmdlet.ShouldProcess('all Terrarium VMs, network and images', 'Remove')) { return }
    foreach ($s in @(Get-AicState)) { Remove-AicVm -Name $s.Name -DeleteSharedFolder:$DeleteSharedFolders -Force }
    Remove-AicHostNetwork -Force -Confirm:$false
    $img = Get-AicPath Images
    Remove-Item -LiteralPath $img -Recurse -Force
    Write-AicLog "Terrarium removed. Logs stay in $(Get-AicPath Logs)." -Level Ok
}

Export-ModuleMember -Function @('Test-AicHost', 'Enable-AicHyperV', 'New-AicVm', 'Remove-AicVm', 'Get-AicVm', 'Set-AicVm', 'Start-AicVm', 'Stop-AicVm', 'Connect-AicVm', 'Move-AicVm', 'Get-AicSetting', 'Set-AicSetting', 'Get-AicPuttyExe', 'Test-AicVm', 'Get-AicConfig', 'Get-AicLogPath', 'Remove-AicHostNetwork', 'Uninstall-AiCage', 'Protect-AicNetwork', 'Remove-AicLeftovers', 'Install-AicTool', 'Restart-AicVm', 'Debug-AicVm', 'ConvertTo-AicPortList', 'Register-AicLogSink', 'Unregister-AicLogSink', 'Show-AiCage')
}
$AicModuleText = $AicModuleBlock.ToString()
$AicLoader = 'New-Module -Name AiCage -ArgumentList $AicToolRoot -ScriptBlock ([scriptblock]::Create($AicModuleText)) | Import-Module -Force'

if ($Console) {
    . ([scriptblock]::Create($AicLoader))
    Show-AiCage
    return
}

# =============================================================================================
# Part 2: the window
# =============================================================================================
# Terrarium - window for creating and managing the VMs. Started by Terrarium.cmd (as Administrator).
# The GUI is a thin layer: every action is an AiCage module command, run in a background
# runspace so the window stays responsive, with its log lines streamed into the log panel.
# ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$ErrorActionPreference = 'Stop'
# $AicLoader is the code that loads the AiCage commands, in this runspace and in the worker.
# Terrarium.ps1 (single-file build) sets it, together with $AicToolRoot and $AicModuleText.
if (-not (Get-Variable -Name AicLoader -ErrorAction SilentlyContinue)) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path      # the AiCage module folder
    $AicToolRoot = Split-Path $here -Parent
    $AicModuleText = ''
    $AicLoader = "Import-Module '$((Join-Path $here 'AiCage.psd1') -replace "'", "''")' -Force"
}

function Show-Fatal([string]$Text) {
    try { Add-Content -LiteralPath (Join-Path $AicToolRoot 'logs\gui-crash.log') -Value ("{0} {1}" -f (Get-Date -Format s), $Text) } catch { }
    [System.Windows.MessageBox]::Show($Text, 'Terrarium', 'OK', 'Error') | Out-Null
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

try {
    . ([scriptblock]::Create($AicLoader))
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Show-Fatal 'Terrarium needs Administrator rights. Start it with Terrarium.cmd (it asks for them).'
        return
    }
} catch {
    Show-Fatal "Terrarium could not start: $($_.Exception.Message)"
    return
}

# ---------------------------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------------------------

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Terrarium - the AI cage" Width="1180" Height="740" MinWidth="820" MinHeight="520"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13" Background="#F5F6F8">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="MinWidth" Value="70"/>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#1F6FEB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#1A5FCC"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
  </Window.Resources>
  <Grid Margin="16,12,16,12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*" MinHeight="120"/>
      <RowDefinition Height="8"/>
      <RowDefinition Height="240" MinHeight="80"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock x:Name="VersionText" DockPanel.Dock="Right" Foreground="#6B7280" VerticalAlignment="Bottom"/>
      <StackPanel>
        <TextBlock FontSize="22" Foreground="#111827"><Run Text="Terrarium" FontWeight="SemiBold"/><Run Text="  the AI cage" Foreground="#6B7280" FontSize="15"/></TextBlock>
        <TextBlock Text="Isolated Debian VMs for AI agents: the internet yes, your files and your network no." Foreground="#6B7280"/>
      </StackPanel>
    </DockPanel>

    <Border Grid.Row="1" x:Name="Banner" CornerRadius="6" Padding="12,8" Margin="0,0,0,10"
            Background="#EEF2F7" BorderBrush="#D0D7E2" BorderThickness="1">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnFix" Content="Fix problems" Visibility="Collapsed" Style="{StaticResource Primary}"/>
          <Button x:Name="BtnRecheck" Content="Check again" Margin="0"/>
        </StackPanel>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="BannerTitle" FontWeight="SemiBold" Text="Checking this laptop..."/>
          <TextBlock x:Name="BannerDetail" TextWrapping="Wrap" Foreground="#4B5563" Visibility="Collapsed" Margin="0,2,12,0"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <DockPanel Grid.Row="2" Margin="0,0,0,8">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock x:Name="BusyText" Foreground="#374151" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <ProgressBar x:Name="BusyBar" Width="110" Height="6" IsIndeterminate="True" Visibility="Collapsed"/>
      </StackPanel>
      <WrapPanel>
        <Button x:Name="BtnNew" Content="+ New VM" Style="{StaticResource Primary}"/>
        <Button x:Name="BtnStart" Content="Start"/>
        <Button x:Name="BtnStop" Content="Stop"/>
        <Button x:Name="BtnTerminal" Content="Terminal" Margin="0" ToolTip="Open a command line in the VM (no password needed)"/>
        <Button x:Name="TerminalChoice" MinWidth="0" Padding="5,5" Margin="1,0,6,0"
                ToolTip="Choose the program: Windows terminal or PuTTY (remembered in data\settings.json)">
          <Path Data="M0,0 L8,0 L4,5 Z" Fill="#374151" VerticalAlignment="Center"/>
          <Button.ContextMenu>
            <ContextMenu>
              <MenuItem Header="Terminal (Windows terminal)" Tag="Terminal" IsCheckable="True"/>
              <MenuItem Header="PuTTY" Tag="PuTTY" IsCheckable="True"/>
            </ContextMenu>
          </Button.ContextMenu>
        </Button>
        <Button x:Name="BtnDesktop" Content="Desktop" ToolTip="Open the VM's graphical desktop in Remote Desktop (install it under Settings - Advanced)"/>
        <Button x:Name="BtnFolder" Content="Shared folder" ToolTip="Open the VM's shared folder in Explorer"/>
        <Button x:Name="BtnScreen" Content="Screen" ToolTip="Show the VM's screen (Hyper-V console)"/>
        <Button x:Name="BtnTest" Content="Test and secure" ToolTip="Check what the VM can reach; repair or quarantine it if something is open"/>
        <Button x:Name="BtnDiagnose" Content="Diagnose" ToolTip="Find out why the VM does not answer - or why it did not, before its last restart"/>
        <Button x:Name="BtnSettings" Content="Settings"/>
        <Button x:Name="BtnRemove" Content="Remove"/>
      </WrapPanel>
    </DockPanel>

    <Grid Grid.Row="3">
      <ListView x:Name="VmList" SelectionMode="Single" Background="White" BorderBrush="#D0D7E2">
        <ListView.View>
          <GridView>
            <GridViewColumn Header="Name" Width="120" DisplayMemberBinding="{Binding Name}"/>
            <GridViewColumn Header="State" Width="85" DisplayMemberBinding="{Binding State}"/>
            <GridViewColumn Header="Health" Width="105">
              <GridViewColumn.CellTemplate>
                <DataTemplate>
                  <TextBlock Text="{Binding Health}" Foreground="{Binding HealthBrush}" FontWeight="SemiBold"/>
                </DataTemplate>
              </GridViewColumn.CellTemplate>
            </GridViewColumn>
            <GridViewColumn Header="Address" Width="115" DisplayMemberBinding="{Binding Ip}"/>
            <GridViewColumn Header="Memory now (min-max)" Width="170" DisplayMemberBinding="{Binding Memory}"/>
            <GridViewColumn Header="CPUs" Width="50" DisplayMemberBinding="{Binding Cpu}"/>
            <GridViewColumn Header="Starts with Windows" Width="130" DisplayMemberBinding="{Binding AutoStart}"/>
            <GridViewColumn Header="Network" Width="75" DisplayMemberBinding="{Binding Isolation}"/>
            <GridViewColumn Header="Ports (localhost)" Width="110" DisplayMemberBinding="{Binding Ports}"/>
            <GridViewColumn Header="Shared folder" Width="260" DisplayMemberBinding="{Binding SharedFolder}"/>
            <GridViewColumn Header="Stored in" Width="200" DisplayMemberBinding="{Binding StoredIn}"/>
          </GridView>
        </ListView.View>
      </ListView>
      <TextBlock x:Name="EmptyText" Text="No VMs yet. Click &quot;+ New VM&quot; to create one - it takes about 2-3 minutes."
                 HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#6B7280" IsHitTestVisible="False"/>
    </Grid>

    <GridSplitter Grid.Row="4" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Background="Transparent" ResizeDirection="Rows"/>

    <DockPanel Grid.Row="5">
      <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="BtnCopyLog" Content="Copy"/>
          <Button x:Name="BtnOpenLog" Content="Open log file"/>
          <Button x:Name="BtnLogFolder" Content="Logs folder"/>
          <Button x:Name="BtnClearLog" Content="Clear" Margin="0"/>
        </StackPanel>
        <TextBlock Text="Log" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </DockPanel>
      <ListBox x:Name="LogList" FontFamily="Consolas" FontSize="12" Background="White" BorderBrush="#D0D7E2"
               VirtualizingStackPanel.IsVirtualizing="True" VirtualizingStackPanel.VirtualizationMode="Recycling"
               ScrollViewer.HorizontalScrollBarVisibility="Auto">
        <ListBox.ItemTemplate>
          <DataTemplate>
            <TextBlock Text="{Binding Text}" Foreground="{Binding Brush}"/>
          </DataTemplate>
        </ListBox.ItemTemplate>
      </ListBox>
    </DockPanel>
  </Grid>
</Window>
'@

$newXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="New VM" Width="600" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13" Background="White">
  <Window.Resources>
    <Style TargetType="TextBlock" x:Key="Label">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Hint">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>
    <Style TargetType="TextBox"><Setter Property="Padding" Value="4,3"/></Style>
    <Style TargetType="ComboBox"><Setter Property="Padding" Value="6,3"/></Style>
    <Style TargetType="Button"><Setter Property="Padding" Value="12,4"/></Style>
  </Window.Resources>
  <StackPanel Margin="20,16,20,16">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="160"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <TextBlock Grid.Row="0" Style="{StaticResource Label}" Text="Name"/>
      <StackPanel Grid.Row="0" Grid.Column="1">
        <TextBox x:Name="NameBox"/>
        <TextBlock Style="{StaticResource Hint}" Text="Lowercase letters, digits and dashes, up to 16 characters."/>
      </StackPanel>

      <TextBlock Grid.Row="2" Style="{StaticResource Label}" Text="Shared folder"/>
      <StackPanel Grid.Row="2" Grid.Column="1">
        <DockPanel>
          <Button x:Name="BtnBrowse" DockPanel.Dock="Right" Content="Browse..." Margin="6,0,0,0"/>
          <TextBox x:Name="FolderBox"/>
        </DockPanel>
        <CheckBox x:Name="ReadOnlyBox" Content="The VM may only read this folder" Margin="0,6,0,0"/>
        <TextBlock Style="{StaticResource Hint}" Text="The only folder of this laptop the VM can see (as ~/shared). Put nothing there the AI must not read."/>
      </StackPanel>

      <TextBlock Grid.Row="4" Style="{StaticResource Label}" Text="Linux user"/>
      <TextBox Grid.Row="4" Grid.Column="1" x:Name="UserBox"/>

      <TextBlock Grid.Row="6" Style="{StaticResource Label}" Text="Password"/>
      <StackPanel Grid.Row="6" Grid.Column="1">
        <TextBox x:Name="PassBox"/>
        <TextBlock Style="{StaticResource Hint}" Text="For sudo, PuTTY and the Desktop. The Terminal button logs in with a key, no password needed."/>
      </StackPanel>

      <TextBlock Grid.Row="8" Style="{StaticResource Label}" Text="Memory (MB)"/>
      <StackPanel Grid.Row="8" Grid.Column="1">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="at least" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <ComboBox x:Name="MinMemBox" Width="90" IsEditable="True"/>
          <TextBlock Text="at most" VerticalAlignment="Center" Margin="14,0,6,0"/>
          <ComboBox x:Name="MaxMemBox" Width="90" IsEditable="True"/>
        </StackPanel>
        <TextBlock Style="{StaticResource Hint}" Text="The VM takes what it needs between the two. Below 1024 MB, Hyper-V may squeeze a busy VM until it freezes."/>
      </StackPanel>

      <TextBlock Grid.Row="10" Style="{StaticResource Label}" Text="Processors / disk"/>
      <StackPanel Grid.Row="10" Grid.Column="1" Orientation="Horizontal">
        <ComboBox x:Name="CpuBox" Width="60"/>
        <TextBlock Text="CPUs" VerticalAlignment="Center" Margin="6,0,18,0"/>
        <ComboBox x:Name="DiskBox" Width="70" IsEditable="True"/>
        <TextBlock Text="GB disk (grows as needed)" VerticalAlignment="Center" Margin="6,0,0,0"/>
      </StackPanel>

      <TextBlock Grid.Row="12" Style="{StaticResource Label}" Text="Startup"/>
      <CheckBox Grid.Row="12" Grid.Column="1" x:Name="AutoBox" Content="Start automatically with Windows" VerticalAlignment="Center"/>

      <TextBlock Grid.Row="14" Style="{StaticResource Label}" Text="Network" VerticalAlignment="Top"/>
      <StackPanel Grid.Row="14" Grid.Column="1">
        <RadioButton x:Name="StrictBox" GroupName="Iso" Content="Strict (recommended): internet only - no home, office or cowork network"/>
        <RadioButton x:Name="OpenBox" GroupName="Iso" Content="Open: the VM may also reach the local network" Margin="0,4,0,0"/>
      </StackPanel>

      <TextBlock Grid.Row="16" Style="{StaticResource Label}" Text="Ports to this laptop" VerticalAlignment="Top" Margin="0,4,10,0"/>
      <StackPanel Grid.Row="16" Grid.Column="1">
        <TextBox x:Name="PortsBox"/>
        <TextBlock Style="{StaticResource Hint}" Text="Optional, e.g. 8080, 5432, 3000:80 (laptop:VM). Apps on this laptop then reach the VM's services (e.g. Docker containers) as localhost:8080; the local network does not. TCP only."/>
      </StackPanel>
    </Grid>

    <Expander Header="Advanced" Margin="0,14,0,0">
      <Grid Margin="0,8,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="160"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Style="{StaticResource Label}" Text="Install" VerticalAlignment="Top"/>
        <StackPanel Grid.Row="0" Grid.Column="1">
          <WrapPanel>
            <CheckBox x:Name="ToolDocker" Content="Docker" Margin="0,0,18,0"/>
            <CheckBox x:Name="ToolClaudeCode" Content="Claude Code" Margin="0,0,18,0"/>
            <CheckBox x:Name="ToolCodex" Content="Codex" Margin="0,0,18,0"/>
            <CheckBox x:Name="ToolDesktop" Content="Desktop (XFCE)" Margin="0,0,18,0"/>
          </WrapPanel>
          <TextBlock Style="{StaticResource Hint}" Text="Installed from the official sources after the first boot (a few minutes more). Desktop: a light graphical desktop with Firefox, opened with the Desktop button (Remote Desktop); about 1 GB."/>
        </StackPanel>
        <TextBlock Grid.Row="2" Style="{StaticResource Label}" Text="Stored in" VerticalAlignment="Top"/>
        <StackPanel Grid.Row="2" Grid.Column="1">
          <RadioButton x:Name="LocHomeBox" GroupName="Loc"/>
          <RadioButton x:Name="LocProgramBox" GroupName="Loc" Margin="0,4,0,0"/>
          <TextBlock Style="{StaticResource Hint}" Text="Where the VM's disk (a few GB), key and settings live. Terrarium finds VMs in both places."/>
        </StackPanel>
        <TextBlock Grid.Row="4" Style="{StaticResource Label}" Text="Extra packages"/>
        <StackPanel Grid.Row="4" Grid.Column="1">
          <TextBox x:Name="PkgBox"/>
          <TextBlock Style="{StaticResource Hint}" Text="Debian packages, separated by spaces, e.g. nodejs npm python3-pip"/>
        </StackPanel>
        <TextBlock Grid.Row="6" Style="{StaticResource Label}" Text="Setup script"/>
        <StackPanel Grid.Row="6" Grid.Column="1">
          <DockPanel>
            <Button x:Name="BtnScript" DockPanel.Dock="Right" Content="Browse..." Margin="6,0,0,0"/>
            <TextBox x:Name="ScriptBox"/>
          </DockPanel>
          <TextBlock Style="{StaticResource Hint}" Text="Optional bash script, run once as root at the end of the first boot."/>
        </StackPanel>
        <TextBlock Grid.Row="8" Style="{StaticResource Label}" Text="Time zone"/>
        <StackPanel Grid.Row="8" Grid.Column="1">
          <TextBox x:Name="TzBox"/>
          <TextBlock Style="{StaticResource Hint}" Text="Empty: same as Windows. Otherwise e.g. Europe/Warsaw"/>
        </StackPanel>
        <TextBlock Grid.Row="10" Style="{StaticResource Label}" Text="Keyboard"/>
        <StackPanel Grid.Row="10" Grid.Column="1">
          <TextBox x:Name="KbBox"/>
          <TextBlock Style="{StaticResource Hint}" Text="Empty: same as Windows. Only matters on the VM's screen, not in the terminal."/>
        </StackPanel>
      </Grid>
    </Expander>

    <TextBlock x:Name="ErrorText" Foreground="#C62828" TextWrapping="Wrap" Margin="0,12,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="BtnOk" Content="Create VM" IsDefault="True" Margin="0,0,8,0" Background="#1F6FEB" Foreground="White" FontWeight="SemiBold"/>
      <Button x:Name="BtnCancel" Content="Cancel" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VM settings" Width="560" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13" Background="White">
  <Window.Resources>
    <Style TargetType="TextBlock" x:Key="Label">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Hint">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>
    <Style TargetType="ComboBox"><Setter Property="Padding" Value="6,3"/></Style>
    <Style TargetType="Button"><Setter Property="Padding" Value="12,4"/></Style>
  </Window.Resources>
  <StackPanel Margin="20,16,20,16">
    <TextBlock x:Name="TitleText" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="150"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Style="{StaticResource Label}" Text="Memory (MB)"/>
      <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal">
        <TextBlock Text="at least" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <ComboBox x:Name="MinMemBox" Width="90" IsEditable="True"/>
        <TextBlock Text="at most" VerticalAlignment="Center" Margin="14,0,6,0"/>
        <ComboBox x:Name="MaxMemBox" Width="90" IsEditable="True"/>
      </StackPanel>
      <TextBlock Grid.Row="2" Style="{StaticResource Label}" Text="Processors"/>
      <StackPanel Grid.Row="2" Grid.Column="1">
        <ComboBox x:Name="CpuBox" Width="60" HorizontalAlignment="Left"/>
        <TextBlock x:Name="CpuHint" Style="{StaticResource Hint}" Text="Stop the VM to change this." Visibility="Collapsed"/>
      </StackPanel>
      <TextBlock Grid.Row="4" Style="{StaticResource Label}" Text="Startup"/>
      <CheckBox Grid.Row="4" Grid.Column="1" x:Name="AutoBox" Content="Start automatically with Windows" VerticalAlignment="Center"/>
      <TextBlock Grid.Row="6" Style="{StaticResource Label}" Text="Network" VerticalAlignment="Top"/>
      <StackPanel Grid.Row="6" Grid.Column="1">
        <RadioButton x:Name="StrictBox" GroupName="Iso" Content="Strict (recommended): internet only"/>
        <RadioButton x:Name="OpenBox" GroupName="Iso" Content="Open: may also reach the local network" Margin="0,4,0,0"/>
      </StackPanel>
      <TextBlock Grid.Row="8" Style="{StaticResource Label}" Text="Shared folder" VerticalAlignment="Top" Margin="0,4,10,0"/>
      <StackPanel Grid.Row="8" Grid.Column="1">
        <DockPanel>
          <Button x:Name="BtnBrowse" DockPanel.Dock="Right" Content="Browse..." Margin="6,0,0,0"/>
          <TextBox x:Name="FolderBox" Padding="4,3"/>
        </DockPanel>
        <CheckBox x:Name="ReadOnlyBox" Content="The VM may only read this folder" Margin="0,6,0,0"/>
        <TextBlock x:Name="FolderHint" Style="{StaticResource Hint}" Text="The files stay where they are; the VM just sees the new folder as ~/shared."/>
      </StackPanel>
      <TextBlock Grid.Row="10" Style="{StaticResource Label}" Text="Ports to this laptop" VerticalAlignment="Top" Margin="0,4,10,0"/>
      <StackPanel Grid.Row="10" Grid.Column="1">
        <TextBox x:Name="PortsBox" Padding="4,3"/>
        <TextBlock Style="{StaticResource Hint}" Text="e.g. 8080, 5432, 3000:80 (laptop:VM). Apps on this laptop reach them as localhost:8080; the local network does not. Empty: none."/>
      </StackPanel>
    </Grid>
    <Expander Header="Advanced" Margin="0,14,0,0">
      <Grid Margin="0,8,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="150"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="10"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Style="{StaticResource Label}" Text="Install" VerticalAlignment="Top"/>
        <StackPanel Grid.Row="0" Grid.Column="1">
          <WrapPanel>
            <CheckBox x:Name="ToolDocker" Content="Docker" Margin="0,0,18,4"/>
            <CheckBox x:Name="ToolClaudeCode" Content="Claude Code" Margin="0,0,18,4"/>
            <CheckBox x:Name="ToolCodex" Content="Codex" Margin="0,0,18,4"/>
            <CheckBox x:Name="ToolDesktop" Content="Desktop (XFCE)" Margin="0,0,18,4"/>
          </WrapPanel>
          <TextBlock x:Name="ToolHint" Style="{StaticResource Hint}" Text="Tick what to add; it is installed when you click Apply (a few minutes)."/>
        </StackPanel>
        <TextBlock Grid.Row="2" Style="{StaticResource Label}" Text="Stored in" VerticalAlignment="Top"/>
        <StackPanel Grid.Row="2" Grid.Column="1">
          <RadioButton x:Name="LocHomeBox" GroupName="Loc"/>
          <RadioButton x:Name="LocProgramBox" GroupName="Loc" Margin="0,4,0,0"/>
          <TextBlock Style="{StaticResource Hint}" Text="Choosing the other place moves the VM's disk, checkpoints and key there. It works while the VM runs; the shared folder stays."/>
        </StackPanel>
      </Grid>
    </Expander>
    <TextBlock x:Name="ErrorText" Foreground="#C62828" TextWrapping="Wrap" Margin="0,12,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="BtnOk" Content="Apply" IsDefault="True" Margin="0,0,8,0" Background="#1F6FEB" Foreground="White" FontWeight="SemiBold"/>
      <Button x:Name="BtnCancel" Content="Cancel" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

function New-Window([string]$Xaml) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
    return [Windows.Markup.XamlReader]::Load($reader)
}

function New-Brush([string]$Hex) {
    $b = (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex)
    $b.Freeze()
    return $b
}

# ---------------------------------------------------------------------------------------------
# Main window and state
# ---------------------------------------------------------------------------------------------

$win = New-Window $mainXaml
$ui = @{}
foreach ($n in 'VersionText', 'Banner', 'BtnFix', 'BtnRecheck', 'BannerTitle', 'BannerDetail', 'BusyText', 'BusyBar',
    'BtnNew', 'BtnStart', 'BtnStop', 'BtnTerminal', 'TerminalChoice', 'BtnDesktop', 'BtnFolder', 'BtnScreen', 'BtnTest', 'BtnDiagnose', 'BtnSettings', 'BtnRemove',
    'VmList', 'EmptyText', 'BtnCopyLog', 'BtnOpenLog', 'BtnLogFolder', 'BtnClearLog', 'LogList') {
    $ui[$n] = $win.FindName($n)
}

$script:Version = & (Get-Module AiCage) { $script:AicVersion }
$script:Root = (Get-AicConfig).Root
$script:HomeRoot = $script:Root
$script:ProgramRoot = $AicToolRoot.TrimEnd('\')
$ui.VersionText.Text = "version $script:Version  -  data in $script:HomeRoot"

$script:LevelBrush = @{
    Info = New-Brush '#1F2937'; Step = New-Brush '#0B5CAD'; Ok = New-Brush '#1E7B34'; Warn = New-Brush '#9A6700'
    Error = New-Brush '#C62828'; Cmd = New-Brush '#4B6478'; Guest = New-Brush '#8A8F98'; Debug = New-Brush '#8A8F98'
}
$script:HealthBrush = @{ ready = New-Brush '#1E7B34'; quarantined = New-Brush '#C62828'; failed = New-Brush '#C62828'; creating = New-Brush '#9A6700'
    'not responding' = New-Brush '#C62828'; 'memory full' = New-Brush '#9A6700' }
$script:LogItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LogList.ItemsSource = $script:LogItems
$script:VmItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.VmList.ItemsSource = $script:VmItems

$script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:Op = $null            # the running background operation
$script:HostOk = $false
$script:HostFixes = @()
$script:LastRefresh = [datetime]::MinValue
$script:VmSignature = $null

function Add-LogLine([string]$Level, [string]$Message) {
    $prefix = @{ Info = ''; Step = '==> '; Ok = 'ok  '; Warn = '!!  '; Error = 'XX  '; Cmd = '  > '; Guest = '  | '; Debug = '    ' }[$Level]
    if ($null -eq $prefix) { $prefix = '' }
    $brush = $script:LevelBrush[$Level]
    if (-not $brush) { $brush = $script:LevelBrush.Info }
    $item = [pscustomobject]@{ Text = ('{0}  {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $prefix, $Message); Brush = $brush }
    $script:LogItems.Add($item)
    if ($script:LogItems.Count -gt 6000) { for ($i = 0; $i -lt 1000; $i++) { $script:LogItems.RemoveAt(0) } }
    $ui.LogList.ScrollIntoView($item)
}

# Log lines from commands run in this (UI) runspace, e.g. Connect-AicVm.
Register-AicLogSink -Sink { param($l, $m) Add-LogLine $l $m }

# ---------------------------------------------------------------------------------------------
# Background worker: one runspace, one operation at a time
# ---------------------------------------------------------------------------------------------

$script:Worker = [runspacefactory]::CreateRunspace()
$script:Worker.ApartmentState = 'STA'
$script:Worker.Open()
$script:Worker.SessionStateProxy.SetVariable('AicGuiQueue', $script:Queue)
foreach ($v in 'AicLoader', 'AicToolRoot', 'AicModuleText') { $script:Worker.SessionStateProxy.SetVariable($v, (Get-Variable -Name $v -ValueOnly)) }

function Start-Op {
    # $Script runs in the worker; $Arg is passed to it as its only argument. $OnDone runs here
    # afterwards with ($ok, $output, $errorMessage).
    param([string]$Title, [string]$Script, $Arg, [scriptblock]$OnDone)
    if ($script:Op) { return }
    $ps = [powershell]::Create()
    $ps.Runspace = $script:Worker
    $prelude = @'
$ErrorActionPreference = 'Stop'
if (-not (Get-Module AiCage)) {
    . ([scriptblock]::Create($AicLoader))
    Register-AicLogSink -Sink { param($l, $m) $AicGuiQueue.Enqueue(@($l, $m)) }
}
'@
    [void]$ps.AddScript($prelude + "`n& {`n" + $Script + "`n} @args")
    if ($null -ne $Arg) { [void]$ps.AddArgument($Arg) }
    $script:Op = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Title = $Title; OnDone = $OnDone; Started = Get-Date }
    Update-Buttons
}

function Complete-Op {
    $op = $script:Op
    $ok = $true; $out = $null; $err = $null
    try {
        $out = $op.Ps.EndInvoke($op.Handle)
        if ($op.Ps.Streams.Error.Count -gt 0) {
            foreach ($e in $op.Ps.Streams.Error) { Add-LogLine 'Error' "$e" }
        }
    } catch {
        $ok = $false
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $err = $inner.Message
    }
    $op.Ps.Dispose()
    $script:Op = $null
    Update-Buttons
    if ($op.OnDone) {
        try { & $op.OnDone $ok $out $err } catch { Add-LogLine 'Error' "GUI: $($_.Exception.Message)" }
    } elseif (-not $ok) {
        Add-LogLine 'Error' "$($op.Title) failed: $err"
        [System.Windows.MessageBox]::Show("$($op.Title) failed:`n`n$err`n`nThe log below shows the details.", 'Terrarium', 'OK', 'Error') | Out-Null
    }
    Update-VmList
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $item = $null
    $n = 0
    while ($n -lt 400 -and $script:Queue.TryDequeue([ref]$item)) { Add-LogLine $item[0] $item[1]; $n++ }
    if ($script:Op) {
        $t = (Get-Date) - $script:Op.Started
        $ui.BusyText.Text = '{0}...  {1}:{2:00}' -f $script:Op.Title, [math]::Floor($t.TotalMinutes), $t.Seconds
        if ($script:Op.Handle.IsCompleted -and $script:Queue.IsEmpty) { Complete-Op }
    } elseif (((Get-Date) - $script:LastRefresh).TotalSeconds -ge 5) {
        Update-VmList
    }
})

# ---------------------------------------------------------------------------------------------
# VM list
# ---------------------------------------------------------------------------------------------

function Get-SelectedVm { return $ui.VmList.SelectedItem }

function Get-VmHealth($Vm) {
    # Status from Terrarium, sharpened by what Hyper-V sees right now. No heartbeat long after
    # the start: the VM is stuck (SSH and its screen do not react) - Diagnose tells more.
    $h = "$($Vm.Status)"
    if ($h -ne 'ready' -or $Vm.State -ne 'Running') { return $h }
    if ($Vm.Heartbeat -in 'LostCommunication', 'NoContact', 'Error' -and $Vm.Uptime -and $Vm.Uptime.TotalMinutes -gt 3) { return 'not responding' }
    if ($Vm.MemoryMaxMB -and $Vm.MemoryDemandMB -ge 0.95 * $Vm.MemoryMaxMB) { return 'memory full' }
    return $h
}

function Update-VmList {
    $script:LastRefresh = Get-Date
    $vms = @()
    if ($script:HostOk) {
        try { $vms = @(Get-AicVm) } catch { }
    }
    $sig = ($vms | ForEach-Object { '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}' -f $_.Name, $_.State, $_.Status, $_.MemoryMB, $_.MemoryMinMB, $_.MemoryMaxMB, $_.Cpu, $_.AutoStart, $_.Isolation, $_.SharedFolder, $_.SharedReadOnly,
        (Get-VmHealth $_), ($_.Ports -join ','), ($_.Tools -join ',') }) -join ';'
    if ($sig -eq $script:VmSignature) { Update-Buttons; return }
    $script:VmSignature = $sig
    $selected = Get-SelectedVm
    $selName = if ($selected) { $selected.Name } else { $null }
    $script:VmItems.Clear()
    foreach ($v in $vms) {
        $health = Get-VmHealth $v
        $brush = $script:HealthBrush[$health]
        if (-not $brush) { $brush = $script:LevelBrush.Info }
        $mem = if ($v.State -eq 'Running') { "$($v.MemoryMB) MB" } else { '-' }
        $item = [pscustomobject]@{
            Name = $v.Name; State = $v.State; Health = $health; HealthBrush = $brush; Ip = $v.Ip
            Memory = "$mem  ($($v.MemoryMinMB)-$($v.MemoryMaxMB))"; Cpu = $v.Cpu
            AutoStart = $(if ($v.AutoStart) { 'yes' } else { 'no' }); Isolation = $v.Isolation; SharedFolder = $v.SharedFolder
            Ports = (@($v.Ports | ForEach-Object { $h, $g = $_.Split(':'); if ($h -eq $g) { $h } else { "$h>$g" } }) -join ', ')
            StoredIn = $(if ($v.Location -eq 'Program') { "program folder" } else { "user folder" }); Raw = $v
        }
        $script:VmItems.Add($item)
        if ($item.Name -eq $selName) { $ui.VmList.SelectedItem = $item }
    }
    if (-not $ui.VmList.SelectedItem -and $script:VmItems.Count -gt 0) { $ui.VmList.SelectedIndex = 0 }
    $ui.EmptyText.Visibility = if ($script:VmItems.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-Buttons
}

function Update-Buttons {
    $busy = [bool]$script:Op
    $v = Get-SelectedVm
    $running = $v -and $v.State -eq 'Running'
    $off = $v -and $v.State -eq 'Off'
    $ui.BtnNew.IsEnabled = -not $busy -and $script:HostOk
    $ui.BtnStart.IsEnabled = -not $busy -and $v -and -not $running
    $ui.BtnStop.IsEnabled = -not $busy -and $running
    $ui.BtnTerminal.IsEnabled = $running
    $ui.BtnDesktop.IsEnabled = $running -and @($v.Raw.Tools) -contains 'Desktop'
    $ui.BtnFolder.IsEnabled = [bool]$v
    $ui.BtnScreen.IsEnabled = $v -and -not $off
    $ui.BtnTest.IsEnabled = -not $busy -and $running
    $ui.BtnDiagnose.IsEnabled = -not $busy -and $v -and -not $off
    $ui.BtnSettings.IsEnabled = -not $busy -and $v
    $ui.BtnRemove.IsEnabled = -not $busy -and $v
    $ui.BtnFix.IsEnabled = -not $busy
    $ui.BtnRecheck.IsEnabled = -not $busy
    $ui.BusyBar.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    if (-not $busy) { $ui.BusyText.Text = '' }
}

# ---------------------------------------------------------------------------------------------
# Laptop check banner
# ---------------------------------------------------------------------------------------------

function Set-Banner([string]$Kind, [string]$Title, [string]$Detail) {
    $colors = @{ ok = @('#E8F5E9', '#B7DFB9'); warn = @('#FFF8E1', '#F2D27A'); fail = @('#FDECEA', '#F5B5AE'); info = @('#EEF2F7', '#D0D7E2') }[$Kind]
    $ui.Banner.Background = New-Brush $colors[0]
    $ui.Banner.BorderBrush = New-Brush $colors[1]
    $ui.BannerTitle.Text = $Title
    $ui.BannerDetail.Text = $Detail
    $ui.BannerDetail.Visibility = if ($Detail) { 'Visible' } else { 'Collapsed' }
}

function Start-HostCheck {
    Set-Banner info 'Checking this laptop...' ''
    Start-Op -Title 'Checking this laptop' -Script 'Test-AicHost' -OnDone {
        param($ok, $out, $err)
        if (-not $ok) { Set-Banner fail 'The laptop check failed' $err; return }
        $res = @($out)
        $fails = @($res | Where-Object { $_.Status -eq 'FAIL' })
        $warns = @($res | Where-Object { $_.Status -eq 'WARN' })
        $script:HostFixes = @($res | Where-Object { $_.Fix } | ForEach-Object { $_ })
        $hv = @($res | Where-Object { $_.Check -like 'Hyper-V*' -or $_.Check -eq 'Hypervisor running' -or $_.Check -eq 'Administrator' } | Where-Object { $_.Status -eq 'FAIL' })
        $script:HostOk = $hv.Count -eq 0
        $lines = @($fails + $warns | ForEach-Object { "- $($_.Check): $($_.Detail)" }) -join "`n"
        if ($fails.Count) { Set-Banner fail "This laptop is not ready: $($fails.Count) problem(s)" $lines }
        elseif ($warns.Count) { Set-Banner warn 'This laptop is ready, with notes' $lines }
        else { Set-Banner ok 'This laptop is ready for Terrarium' '' }
        $ui.BtnFix.Visibility = if ($script:HostFixes.Count) { 'Visible' } else { 'Collapsed' }
        Update-VmList
    }
}

$ui.BtnRecheck.Add_Click({ Start-HostCheck })

$ui.BtnFix.Add_Click({
    if (-not $script:HostFixes.Count) { return }
    $list = ($script:HostFixes | ForEach-Object { "- $($_.Check): $($_.Detail)" }) -join "`n"
    $answer = [System.Windows.MessageBox]::Show("Terrarium will fix:`n`n$list`n`nContinue?", 'Fix problems', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $cmds = @($script:HostFixes | ForEach-Object { $_.Fix })
    Start-Op -Title 'Fixing' -Arg $cmds -Script @'
param($cmds)
foreach ($c in $cmds) { $AicGuiQueue.Enqueue(@('Step', "Running: $c")); Invoke-Expression $c }
'@ -OnDone {
        param($ok, $out, $err)
        if (-not $ok) { [System.Windows.MessageBox]::Show("Fixing failed:`n`n$err", 'Terrarium', 'OK', 'Error') | Out-Null }
        if ($script:HostFixes | Where-Object { $_.Fix -like 'Enable-AicHyperV*' }) {
            [System.Windows.MessageBox]::Show('Hyper-V was turned on. Restart Windows, then start Terrarium again.', 'Terrarium', 'OK', 'Information') | Out-Null
        }
        Start-HostCheck
    }
})

# ---------------------------------------------------------------------------------------------
# New VM dialog
# ---------------------------------------------------------------------------------------------

function Set-Combo($Box, [object[]]$Values, $Selected) {
    $Box.Items.Clear()
    foreach ($v in $Values) { [void]$Box.Items.Add("$v") }
    $Box.Text = "$Selected"
}

function Get-IntOrNull([string]$Text) {
    $n = 0
    if ([int]::TryParse(($Text -replace '\s', ''), [ref]$n)) { return $n }
    return $null
}

$script:HostCpus = 4
$script:ToolNames = @('Docker', 'ClaudeCode', 'Codex', 'Desktop')
try { $script:HostCpus = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors } catch { }

function Show-NewVmDialog {
    # Handlers use $script:Dlg: event handlers run in this script's scope, so state kept there is
    # reliable (GetNewClosure would move $script: variables into a separate module scope).
    $d = New-Window $newXaml
    $d.Owner = $win
    $c = @{ Window = $d; Result = $null; FolderTouched = $false }
    foreach ($n in 'NameBox', 'BtnBrowse', 'FolderBox', 'ReadOnlyBox', 'UserBox', 'PassBox', 'MinMemBox', 'MaxMemBox', 'CpuBox',
        'DiskBox', 'AutoBox', 'StrictBox', 'OpenBox', 'PortsBox', 'LocHomeBox', 'LocProgramBox', 'ToolDocker', 'ToolClaudeCode', 'ToolCodex', 'ToolDesktop', 'PkgBox', 'BtnScript', 'ScriptBox', 'TzBox', 'KbBox', 'ErrorText', 'BtnOk', 'BtnCancel') {
        $c[$n] = $d.FindName($n)
    }
    $c.Existing = @($script:VmItems | ForEach-Object { $_.Name })
    $i = 1; while ($c.Existing -contains "agent$i") { $i++ }
    $script:Dlg = $c
    $c.LocHomeBox.Content = "Your user folder:  $script:HomeRoot"
    $c.LocProgramBox.Content = "Program folder:  $script:ProgramRoot"
    $c.LocHomeBox.IsChecked = $true
    if ($script:ProgramRoot -ieq $script:HomeRoot) { $c.LocProgramBox.Visibility = 'Collapsed' }
    $c.SharedRoot = Join-Path $script:HomeRoot 'data\shared'
    $c.NameBox.Text = "agent$i"
    $c.FolderBox.Text = Join-Path $c.SharedRoot $c.NameBox.Text
    $onLoc = {
        $k = $script:Dlg
        $root = if ($k.LocProgramBox.IsChecked) { $script:ProgramRoot } else { $script:HomeRoot }
        $k.SharedRoot = Join-Path $root 'data\shared'
        if (-not $k.FolderTouched) { $k.FolderBox.Text = Join-Path $k.SharedRoot $k.NameBox.Text.Trim().ToLower() }
    }
    $c.LocHomeBox.Add_Checked($onLoc)
    $c.LocProgramBox.Add_Checked($onLoc)
    $c.UserBox.Text = 'ai'
    $c.PassBox.Text = 'ai'
    Set-Combo $c.MinMemBox @(512, 1024, 2048, 4096) 1024
    Set-Combo $c.MaxMemBox @(1024, 2048, 3072, 4096, 6144, 8192) 2048
    Set-Combo $c.CpuBox @(1..[math]::Max(1, [math]::Min(16, $script:HostCpus))) ([math]::Min(2, $script:HostCpus))
    Set-Combo $c.DiskBox @(20, 30, 50, 100) 30
    $c.AutoBox.IsChecked = $true
    $c.StrictBox.IsChecked = $true

    $c.NameBox.Add_TextChanged({
        $k = $script:Dlg
        if (-not $k.FolderTouched) { $k.FolderBox.Text = Join-Path $k.SharedRoot $k.NameBox.Text.Trim().ToLower() }
    })
    $c.FolderBox.Add_PreviewKeyDown({ $script:Dlg.FolderTouched = $true })
    $c.BtnBrowse.Add_Click({
        $k = $script:Dlg
        $f = New-Object System.Windows.Forms.FolderBrowserDialog
        $f.Description = 'Folder the VM may see as ~/shared'
        if (Test-Path -LiteralPath $k.FolderBox.Text) { $f.SelectedPath = $k.FolderBox.Text }
        if ($f.ShowDialog() -eq 'OK') { $k.FolderBox.Text = $f.SelectedPath; $k.FolderTouched = $true }
    })
    $c.BtnScript.Add_Click({
        $f = New-Object System.Windows.Forms.OpenFileDialog
        $f.Filter = 'Shell scripts (*.sh)|*.sh|All files (*.*)|*.*'
        if ($f.ShowDialog() -eq 'OK') { $script:Dlg.ScriptBox.Text = $f.FileName }
    })
    $c.BtnOk.Add_Click({
        $k = $script:Dlg
        $errs = @()
        $name = $k.NameBox.Text.Trim().ToLower()
        if ($name -notmatch '^[a-z][a-z0-9-]{0,14}[a-z0-9]$') { $errs += 'Name: 2-16 characters, lowercase letters, digits and dashes, starting with a letter.' }
        elseif ($k.Existing -contains $name) { $errs += "A VM named '$name' already exists." }
        $user = $k.UserBox.Text.Trim()
        if ($user -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { $errs += 'Linux user: lowercase letters, digits, dashes, underscores.' }
        if ($user -in 'root', 'daemon', 'bin', 'sys', 'nobody', 'admin') { $errs += "Linux user '$user' is reserved." }
        if (-not $k.PassBox.Text) { $errs += 'Password must not be empty.' }
        $min = Get-IntOrNull $k.MinMemBox.Text; $max = Get-IntOrNull $k.MaxMemBox.Text
        if (-not $min -or -not $max -or $min -lt 128 -or $max -lt 256) { $errs += 'Memory: enter numbers in MB (at least 128 / 256).' }
        elseif ($min -gt $max) { $errs += 'Memory: "at least" must not be more than "at most".' }
        $disk = Get-IntOrNull $k.DiskBox.Text
        if (-not $disk -or $disk -lt 4) { $errs += 'Disk: a number of GB, at least 4.' }
        $folder = $k.FolderBox.Text.Trim()
        if (-not $folder) { $errs += 'Choose a shared folder.' }
        $scriptPath = $k.ScriptBox.Text.Trim()
        if ($scriptPath -and -not (Test-Path -LiteralPath $scriptPath)) { $errs += 'Setup script: file not found.' }
        $ports = @()
        try { $ports = @(ConvertTo-AicPortList $k.PortsBox.Text) } catch { $errs += $_.Exception.Message }
        if ($errs.Count) {
            $k.ErrorText.Text = $errs -join "`n"
            $k.ErrorText.Visibility = 'Visible'
            return
        }
        $p = @{
            Name = $name; User = $user; PasswordPlain = $k.PassBox.Text
            MemoryMinMB = $min; MemoryMaxMB = $max; MemoryStartupMB = [math]::Min([math]::Max(1024, $min), $max)
            Cpu = [int]$k.CpuBox.Text; DiskGB = $disk; SharedFolder = $folder; SharedReadOnly = [bool]$k.ReadOnlyBox.IsChecked
            AutoStart = [bool]$k.AutoBox.IsChecked; Isolation = $(if ($k.OpenBox.IsChecked) { 'Open' } else { 'Strict' })
            Location = $(if ($k.LocProgramBox.IsChecked) { 'Program' } else { 'Home' })
        }
        $pk = @($k.PkgBox.Text -split '[\s,]+' | Where-Object { $_ })
        if ($pk.Count) { $p.Packages = $pk }
        $tl = @($script:ToolNames | Where-Object { $k["Tool$_"].IsChecked })
        if ($tl.Count) { $p.Tools = $tl }
        if ($ports.Count) { $p.Ports = $ports }
        if ($scriptPath) { $p.SetupScriptPath = $scriptPath }
        if ($k.TzBox.Text.Trim()) { $p.TimeZone = $k.TzBox.Text.Trim() }
        if ($k.KbBox.Text.Trim()) { $p.Keyboard = $k.KbBox.Text.Trim() }
        $k.Result = $p
        $k.Window.DialogResult = $true
    })

    [void]$d.ShowDialog()
    return $c.Result
}

function Show-QuarantineNotice([string]$Name) {
    $vm = $null
    try { $vm = Get-AicVm -Name $Name } catch { }
    if ($vm -and $vm.Status -eq 'quarantined') {
        [System.Windows.MessageBox]::Show("$Name can reach something it must not, and repairing did not help.`n`nTerrarium disconnected its network to keep your laptop safe. The VM keeps running. The log shows what is open. After fixing that, click 'Test and secure' again - the network comes back when all tests pass.", 'Terrarium - VM quarantined', 'OK', 'Warning') | Out-Null
    }
}

$ui.BtnNew.Add_Click({
    $p = Show-NewVmDialog
    if (-not $p) { return }
    $script:LastTarget = $p.Name
    Start-Op -Title "Creating $($p.Name)" -Arg $p -Script @'
param($p)
$p.Password = ConvertTo-SecureString $p.PasswordPlain -AsPlainText -Force
$p.Remove('PasswordPlain')
New-AicVm @p | Out-Null
'@ -OnDone {
        param($ok, $out, $err)
        if ($ok) { Show-QuarantineNotice $script:LastTarget; return }
        [System.Windows.MessageBox]::Show("Creating the VM failed:`n`n$err`n`nThe log shows the details. Remove the half-made VM with the Remove button, then try again.", 'Terrarium', 'OK', 'Error') | Out-Null
    }
})

# ---------------------------------------------------------------------------------------------
# Settings dialog
# ---------------------------------------------------------------------------------------------

function Show-SettingsDialog($Raw) {
    $d = New-Window $settingsXaml
    $d.Owner = $win
    $c = @{ Window = $d; Result = $null; Raw = $Raw }
    foreach ($n in 'TitleText', 'MinMemBox', 'MaxMemBox', 'CpuBox', 'CpuHint', 'AutoBox', 'StrictBox', 'OpenBox', 'FolderBox', 'BtnBrowse', 'ReadOnlyBox',
        'FolderHint', 'PortsBox', 'ToolDocker', 'ToolClaudeCode', 'ToolCodex', 'ToolDesktop', 'ToolHint', 'LocHomeBox', 'LocProgramBox', 'ErrorText', 'BtnOk', 'BtnCancel') { $c[$n] = $d.FindName($n) }
    $script:Dlg = $c
    $c.TitleText.Text = "Settings of $($Raw.Name)"
    Set-Combo $c.MinMemBox @(512, 1024, 2048, 4096) $Raw.MemoryMinMB
    Set-Combo $c.MaxMemBox @(1024, 2048, 3072, 4096, 6144, 8192) $Raw.MemoryMaxMB
    Set-Combo $c.CpuBox @(1..[math]::Max(1, [math]::Min(16, $script:HostCpus))) $Raw.Cpu
    if ($Raw.State -ne 'Off') { $c.CpuBox.IsEnabled = $false; $c.CpuHint.Visibility = 'Visible' }
    $c.AutoBox.IsChecked = [bool]$Raw.AutoStart
    if ($Raw.Isolation -eq 'Open') { $c.OpenBox.IsChecked = $true } else { $c.StrictBox.IsChecked = $true }
    $c.FolderBox.Text = $Raw.SharedFolder
    $c.ReadOnlyBox.IsChecked = [bool]$Raw.SharedReadOnly
    if ($Raw.State -ne 'Running') { $c.ReadOnlyBox.IsEnabled = $false }
    $c.BtnBrowse.Add_Click({
        $k = $script:Dlg
        $f = New-Object System.Windows.Forms.FolderBrowserDialog
        $f.Description = 'Folder the VM may see as ~/shared'
        if (Test-Path -LiteralPath $k.FolderBox.Text) { $f.SelectedPath = $k.FolderBox.Text }
        if ($f.ShowDialog() -eq 'OK') { $k.FolderBox.Text = $f.SelectedPath }
    })
    if ($Raw.State -ne 'Running') { $c.FolderHint.Text += ' Start the VM to switch read-only on or off.' }
    $c.LocHomeBox.Content = "Your user folder:  $script:HomeRoot"
    $c.LocProgramBox.Content = "Program folder:  $script:ProgramRoot"
    if ($Raw.Location -eq 'Program') { $c.LocProgramBox.IsChecked = $true } else { $c.LocHomeBox.IsChecked = $true }
    if ($script:ProgramRoot -ieq $script:HomeRoot) { $c.LocProgramBox.Visibility = 'Collapsed' }
    $c.PortsBox.Text = @($Raw.Ports) -join ', '
    # Installed programs stay ticked and greyed; the rest can be added (over SSH, so running only).
    foreach ($t in $script:ToolNames) {
        $box = $c["Tool$t"]
        if (@($Raw.Tools) -contains $t) { $box.IsChecked = $true; $box.IsEnabled = $false; $box.Content = "$($box.Content) (installed)" }
        elseif ($Raw.State -ne 'Running') { $box.IsEnabled = $false }
    }
    if ($Raw.State -ne 'Running') { $c.ToolHint.Text = 'Start the VM to install programs.' }

    $c.BtnOk.Add_Click({
        $k = $script:Dlg; $r = $k.Raw
        $ports = $null
        try { $ports = @(ConvertTo-AicPortList $k.PortsBox.Text) } catch { $k.ErrorText.Text = $_.Exception.Message; $k.ErrorText.Visibility = 'Visible'; return }
        $min = Get-IntOrNull $k.MinMemBox.Text; $max = Get-IntOrNull $k.MaxMemBox.Text
        if (-not $min -or -not $max -or $min -gt $max -or $min -lt 128) {
            $k.ErrorText.Text = 'Memory: numbers in MB, "at least" not more than "at most".'; $k.ErrorText.Visibility = 'Visible'; return
        }
        $p = @{ Name = $r.Name }
        if ($min -ne $r.MemoryMinMB) { $p.MemoryMinMB = $min }
        if ($max -ne $r.MemoryMaxMB) { $p.MemoryMaxMB = $max }
        if ($k.CpuBox.IsEnabled -and [int]$k.CpuBox.Text -ne $r.Cpu) { $p.Cpu = [int]$k.CpuBox.Text }
        if ([bool]$k.AutoBox.IsChecked -ne [bool]$r.AutoStart) { $p.AutoStart = [bool]$k.AutoBox.IsChecked }
        $iso = if ($k.OpenBox.IsChecked) { 'Open' } else { 'Strict' }
        if ($iso -ne $r.Isolation) { $p.Isolation = $iso }
        $folder = $k.FolderBox.Text.Trim()
        if (-not $folder) { $k.ErrorText.Text = 'Choose a shared folder.'; $k.ErrorText.Visibility = 'Visible'; return }
        if ($folder -ne $r.SharedFolder) { $p.SharedFolder = $folder }
        if ([bool]$k.ReadOnlyBox.IsChecked -ne [bool]$r.SharedReadOnly) { $p.SharedReadOnly = [bool]$k.ReadOnlyBox.IsChecked }
        if (($ports -join ',') -ne (@($r.Ports) -join ',')) { $p.Ports = $ports }
        $install = @($script:ToolNames | Where-Object { $k["Tool$_"].IsEnabled -and $k["Tool$_"].IsChecked })
        if ($install.Count) { $p.Install = $install }
        $loc = if ($k.LocProgramBox.IsChecked) { 'Program' } else { 'Home' }
        if ($loc -ne $r.Location) { $p.Location = $loc }
        $k.Result = $p
        $k.Window.DialogResult = $true
    })
    [void]$d.ShowDialog()
    return $c.Result
}

$ui.BtnSettings.Add_Click({
    $v = Get-SelectedVm
    if (-not $v) { return }
    $p = Show-SettingsDialog $v.Raw
    if (-not $p -or $p.Count -le 1) { return }
    $title = if ($p.Location -and $p.Count -eq 2) { "Moving $($p.Name)" } elseif ($p.Install) { "Installing in $($p.Name)" } else { "Changing $($p.Name)" }
    Start-Op -Title $title -Arg $p -Script @'
param($p)
$to = $p.Location
$install = $p.Install
$p.Remove('Location'); $p.Remove('Install')
if ($p.Count -gt 1) { Set-AicVm @p -Confirm:$false | Out-Null }
if ($install) { Install-AicTool -Name $p.Name -Tool $install }
if ($to) { Move-AicVm -Name $p.Name -To $to }
'@
})

# ---------------------------------------------------------------------------------------------
# Other actions
# ---------------------------------------------------------------------------------------------

$ui.BtnStart.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    Start-Op -Title "Starting $($v.Name)" -Arg $v.Name -Script 'param($n) Start-AicVm -Name $n -Wait'
})

$ui.BtnStop.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    Start-Op -Title "Stopping $($v.Name)" -Arg $v.Name -Script 'param($n) Stop-AicVm -Name $n'
})

$ui.BtnTest.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    $script:LastTarget = $v.Name
    Start-Op -Title "Testing $($v.Name)" -Arg $v.Name -Script 'param($n) Test-AicVm -Name $n | Out-Null' -OnDone {
        param($ok, $out, $err)
        if (-not $ok) { [System.Windows.MessageBox]::Show("The test could not run:`n`n$err", 'Terrarium', 'OK', 'Error') | Out-Null; return }
        $script:VmSignature = $null
        Update-VmList
        Show-QuarantineNotice $script:LastTarget
    }
})

# Diagnose: why the VM does not answer. A stuck VM can only be reset; after that, Diagnose
# reads the VM's log of the stuck boot.
function Start-Diagnose([string]$Name) {
    Start-Op -Title "Diagnosing $Name" -Arg $Name -Script 'param($n) Debug-AicVm -Name $n' -OnDone {
        param($ok, $out, $err)
        if (-not $ok) { [System.Windows.MessageBox]::Show("Diagnose could not run:`n`n$err", 'Terrarium', 'OK', 'Error') | Out-Null; return }
        $r = @($out)[-1]
        $found = if ($r.Problems.Count) { ($r.Problems | ForEach-Object { "- $_" }) -join "`n" } else { 'Nothing found - the log below shows what was checked.' }
        if ($r.Running -and -not $r.Responding) {
            $a = [System.Windows.MessageBox]::Show("$($r.Name) does not answer.`n`n$found`n`nRestart it now? This is like pressing its power button: whatever runs in the VM is stopped without saving. Afterwards, Diagnose again reads the VM's log of the stuck boot.", 'Terrarium - Diagnose', 'YesNo', 'Warning')
            if ($a -eq 'Yes') { Start-Op -Title "Restarting $($r.Name)" -Arg $r.Name -Script 'param($n) Restart-AicVm -Name $n -Force' }
        } else {
            $icon = if ($r.Problems.Count) { 'Warning' } else { 'Information' }
            [System.Windows.MessageBox]::Show("$($r.Name):`n`n$found", 'Terrarium - Diagnose', 'OK', $icon) | Out-Null
        }
    }
}

$ui.BtnDiagnose.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    Start-Diagnose $v.Name
})

function Open-Vm($Vm, [string]$With) {
    try { Connect-AicVm -Name $Vm.Name -With $With }
    catch {
        Add-LogLine 'Error' "$($With): $($_.Exception.Message)"
        if ($_.Exception.Message -like '*does not answer*' -and -not $script:Op) {
            $a = [System.Windows.MessageBox]::Show("$($_.Exception.Message)`n`nFind out why now (Diagnose)?", 'Terrarium', 'YesNo', 'Warning')
            if ($a -eq 'Yes') { Start-Diagnose $Vm.Name }
        }
    }
}

$ui.BtnDesktop.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    Open-Vm $v 'Desktop'
})

$ui.BtnRemove.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    $msg = "Delete the VM '$($v.Name)'?`n`nIts disk, checkpoints and settings are deleted and cannot be restored.`nThe files in the shared folder are kept:`n$($v.SharedFolder)"
    if ([System.Windows.MessageBox]::Show($msg, 'Remove VM', 'YesNo', 'Warning') -ne 'Yes') { return }
    Start-Op -Title "Removing $($v.Name)" -Arg $v.Name -Script 'param($n) Remove-AicVm -Name $n -Force'
})

# The Terminal button shows the program's name; the small arrow next to it switches.
function Set-TerminalProgram([string]$Choice) {
    if ($Choice -ne 'PuTTY') { $Choice = 'Terminal' }
    $script:TerminalProgram = $Choice
    $ui.BtnTerminal.Content = $Choice
    foreach ($it in $ui.TerminalChoice.ContextMenu.Items) { $it.IsChecked = ($it.Tag -eq $Choice) }
}
Set-TerminalProgram (Get-AicSetting -Name TerminalProgram -Default 'Terminal')
$ui.TerminalChoice.Add_Click({
    $m = $ui.TerminalChoice.ContextMenu
    $m.PlacementTarget = $ui.BtnTerminal
    $m.Placement = 'Bottom'
    $m.IsOpen = $true
})
foreach ($it in $ui.TerminalChoice.ContextMenu.Items) {
    $it.Add_Click({
        param($sender)
        Set-TerminalProgram $sender.Tag
        try { Set-AicSetting -Name TerminalProgram -Value $script:TerminalProgram } catch { Add-LogLine 'Error' "Could not save the choice: $($_.Exception.Message)" }
        if ($script:TerminalProgram -eq 'PuTTY' -and -not (Get-AicPuttyExe)) { Add-LogLine 'Warn' 'PuTTY is not installed on this PC (or not found). Install it from putty.org.' }
    })
}

$ui.BtnTerminal.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    Open-Vm $v $script:TerminalProgram
})

$ui.BtnFolder.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    if (Test-Path -LiteralPath $v.SharedFolder) { Start-Process explorer.exe -ArgumentList "`"$($v.SharedFolder)`"" }
    else { Add-LogLine 'Warn' "Shared folder not found: $($v.SharedFolder)" }
})

$ui.BtnScreen.Add_Click({
    $v = Get-SelectedVm; if (-not $v) { return }
    try { Start-Process vmconnect.exe -ArgumentList 'localhost', $v.Name } catch { Add-LogLine 'Error' "Screen: $($_.Exception.Message)" }
})

$ui.VmList.Add_SelectionChanged({ Update-Buttons })
$ui.VmList.Add_MouseDoubleClick({
    $v = Get-SelectedVm
    if ($v -and $v.State -eq 'Running') { Open-Vm $v $script:TerminalProgram }
})

$ui.BtnCopyLog.Add_Click({ [System.Windows.Clipboard]::SetText((($script:LogItems | ForEach-Object { $_.Text }) -join "`r`n")) })
$ui.BtnClearLog.Add_Click({ $script:LogItems.Clear() })
$ui.BtnLogFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$(Join-Path $script:Root 'logs')`"" })
$ui.BtnOpenLog.Add_Click({
    $f = Get-ChildItem -LiteralPath (Join-Path $script:Root 'logs') -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { Start-Process notepad.exe -ArgumentList "`"$($f.FullName)`"" }
})

$win.Add_Closing({
    param($src, $e)
    if ($script:Op) {
        $a = [System.Windows.MessageBox]::Show("'$($script:Op.Title)' is still running. Closing now may leave it half done.`n`nClose anyway?", 'Terrarium', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { $e.Cancel = $true }
    }
})

# ---------------------------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------------------------

try {
    Add-LogLine 'Info' "Terrarium $script:Version - tool folder $script:Root"
    Update-VmList
    $win.Add_ContentRendered({ Start-HostCheck })
    $timer.Start()
    [void]$win.ShowDialog()
} catch {
    Show-Fatal "Terrarium stopped: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
} finally {
    $timer.Stop()
    try { $script:Worker.Close() } catch { }
}
