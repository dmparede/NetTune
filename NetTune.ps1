<#
.SYNOPSIS
    NetTune - honest network tweaks for a stable gaming ping (Windows 10/11).

.DESCRIPTION
    Measures the connection (router, internet and game servers: Epic, Valve, Blizzard, Ubisoft,
    Microsoft, Embark, each in its closest region), applies only tweaks with a real effect on
    latency/stability and measures again to compare. Before changing anything it saves a JSON
    backup, so you can undo everything with -Mode Revert.

    In the active Windows power plan:
      - "Wireless Adapter Settings > Power Saving Mode" -> Maximum performance (plugged in and on battery)

    What Apply mode changes on each physical network adapter (Wi-Fi and Ethernet, including USB):
      - "Allow the computer to turn off this device" -> off
        (PnPCapabilities = 24 in the adapter's registry key; needs a PC RESTART to take effect)
      - Wi-Fi adapter power saving (Power Saving) -> off
      - Roaming aggressiveness -> lowest / disabled
      - Energy-Efficient Ethernet / Green Ethernet -> off
      - USB selective suspend of the adapter -> off
      - RSC (Receive Segment Coalescing) -> off
      - DNS -> tests the current one against Cloudflare, Google, Quad9 and OpenDNS and applies the
        fastest, only if it is clearly better (DNS does NOT change in-game ping, only how fast names resolve)

.PARAMETER Mode
    Test   : only measures and shows the adapter state (no admin needed, changes nothing). Default.
    Apply  : measures, backs up, applies the tweaks, measures again and compares. Needs admin.
    Revert : restores the latest backup (or the one given in -BackupFile). Needs admin.

.PARAMETER Dns
    Auto (default): tests the current DNS against Cloudflare, Google, Quad9 and OpenDNS and, in Apply,
    switches to the best one when it clearly wins. Keep: does not test or touch DNS.
    Cloudflare, Google, Quad9 or OpenDNS: forces that DNS in Apply, after checking it responds.

.PARAMETER Count
    Number of pings per target in the tests (default 50, about 10 s per target).

.PARAMETER ExtraTargets
    Extra test targets, for example the IP of another game's server.

.PARAMETER BackupFile
    Backup file to use in Revert mode. By default the most recent one in the backups folder.

.PARAMETER SkipTest
    In Apply mode, skips the before/after tests.

.PARAMETER Services
    Which game services to test: Epic, Valve, Blizzard, Ubisoft, Microsoft, Embark. All by default.
    For each one, the script picks the closest region by itself.

.PARAMETER Ascii
    Uses only ASCII characters on screen (for old consoles without a Unicode font).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1
    Measures the connection and shows the current adapter state.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -WhatIf
    Shows what would be changed, without changing anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -Dns Cloudflare
    Applies the tweaks and sets Cloudflare DNS.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Revert
    Undoes everything using the most recent backup.
#>
# #Requires has to come after the help block, otherwise Get-Help ignores the block.
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Test', 'Apply', 'Revert')]
    [string]$Mode = 'Test',

    [ValidateSet('Auto', 'Keep', 'Cloudflare', 'Google', 'Quad9', 'OpenDNS')]
    [string]$Dns = 'Auto',

    [ValidateRange(5, 1000)]
    [int]$Count = 50,

    [string[]]$ExtraTargets = @(),

    [string]$BackupFile,

    [switch]$SkipTest,

    # No ValidateSet on purpose: with "powershell -File", "Epic,Valve" arrives as a single string.
    # The list is split and validated further down.
    [string[]]$Services = @('Epic', 'Valve', 'Blizzard', 'Ubisoft', 'Microsoft', 'Embark'),

    [switch]$Ascii
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Version   = '1.6.0'
$Root      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$BackupDir = Join-Path $Root 'backups'
$LogDir    = Join-Path $Root 'logs'
$Stamp     = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

$DnsPresets = @{
    Cloudflare = @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001')
    Google     = @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844')
    Quad9      = @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9')
    OpenDNS    = @('208.67.222.222', '208.67.220.220', '2620:119:35::35', '2620:119:53::53')
}

# DNS test domains (what you use while gaming: stores, launchers, chat, streams).
$DnsTestDomains = @('google.com', 'youtube.com', 'epicgames.com', 'steampowered.com', 'battle.net',
                    'ubisoft.com', 'xboxlive.com', 'discord.com', 'twitch.tv', 'microsoft.com')

# Rules for the adapters' advanced properties.
# Display: regex against the property name (EN / PT / ES, because the driver uses the Windows language).
# Want   : regex against the valid values; the first match wins.
# "Off" in EN / PT-BR / PT-PT / ES (Disabled, Desabilitado, Desativado, Desactivado, Deshabilitado...).
$OffValues = 'Disab|Desab|Deshab|Desact|Desativ|Deslig|^Off$'

$Rules = @(
    @{ Label = 'Adapter power saving'
       Display = '^(Power Saving|Power Save Mode|Power Saving Mode|Modo de economia de energia|Economia de energia|Poupança de energia|Modo de poupança de energia|Ahorro de energía|Modo de ahorro de energía)$'
       Want = $OffValues }
    @{ Label = 'Roaming aggressiveness'
       Display = 'Roaming Aggressiveness|Agressividade de roaming|Agresividad de itinerancia|Agresividad de roaming'
       Want = '^1\.|Lowest|Mais baix|Más baj|Disab|Desab|Deshab|Desact' }
    @{ Label = 'Energy-Efficient Ethernet'
       Display = 'Energy.Efficient Ethernet|Advanced EEE|^EEE$|Green Ethernet|Ethernet verde|Ethernet.*efici'
       Want = $OffValues }
    @{ Label = 'USB selective suspend'
       Display = 'Selective Suspend|Suspensão seletiva|Suspensión selectiva'
       Want = $OffValues }
)

# Windows power plan -> "Wireless Adapter Settings" -> "Power Saving Mode".
# 0 = Maximum performance, 1 = Low power saving, 2 = Medium power saving, 3 = Maximum power saving.
$WifiPowerSub   = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$WifiPowerSet   = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
$WifiPowerNames = @('Maximum performance', 'Low power saving', 'Medium power saving', 'Maximum power saving')

# "Allow the computer to turn off this device to save power" lives in the PnPCapabilities value
# of the adapter's key (network class). 24 (0x18) = off. Only takes effect after a PC restart.
$NetClassKey    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$PnPCapOff      = 24
$script:RebootNeeded = $false
$script:ChangeCount  = 0

# ---------------------------------------------------------------- game servers
# For each service, the test quickly measures every region and keeps the one closest to you.
# Each region: @(name, host, method). icmp = normal ping; tcp = TCP connect time to port 443
# (for providers that block ping, like Azure). A TCP handshake takes almost exactly one round trip.

function New-AzureRegions([string[]]$Names) {
    $pt = @{
        northeurope = 'Ireland'; westeurope = 'Netherlands'; francecentral = 'Paris'; uksouth = 'London'
        germanywestcentral = 'Frankfurt'; spaincentral = 'Madrid'; swedencentral = 'Sweden'
        eastus = 'US East'; centralus = 'US Central'; southcentralus = 'US South'; westus = 'US West'
        brazilsouth = 'Brazil'; japaneast = 'Japan'; koreacentral = 'Korea'; southeastasia = 'Singapore'; australiaeast = 'Australia'
    }
    foreach ($n in $Names) { , @("Azure $($pt[$n])", "s8$n.blob.core.windows.net", 'tcp') }
}

$GameServices = [ordered]@{
    # Official Fortnite ping beacons.
    Epic = @{ Name = 'Epic Games'; Regions = @(
        @('France', 'ping-fr.ds.on.epicgames.com', 'icmp'),
        @('Germany', 'ping-de.ds.on.epicgames.com', 'icmp'),
        @('United Kingdom', 'ping-gb.ds.on.epicgames.com', 'icmp'),
        @('US East', 'ping-va.ds.on.epicgames.com', 'icmp'),
        @('US Central', 'ping-oh.ds.on.epicgames.com', 'icmp'),
        @('US West', 'ping-or.ds.on.epicgames.com', 'icmp'),
        @('Brazil', 'ping-br.ds.on.epicgames.com', 'icmp')) }

    # Valve SDR relays (CS2, Dota 2, Deadlock... traffic goes through them).
    # The list comes live from the Steam API; this one is only the fallback if the API fails.
    Valve = @{ Name = 'Valve / Steam'; Dynamic = 'SteamSDR'; Regions = @(
        @('Madrid', '155.133.246.34', 'icmp'),
        @('Paris', '185.25.182.18', 'icmp'),
        @('Frankfurt', '155.133.226.68', 'icmp'),
        @('Amsterdam', '155.133.248.36', 'icmp'),
        @('London', '162.254.196.66', 'icmp'),
        @('Stockholm', '162.254.198.41', 'icmp'),
        @('Vienna', '146.66.155.66', 'icmp'),
        @('Warsaw', '155.133.230.100', 'icmp'),
        @('US East', '162.254.192.88', 'icmp')) }

    # Battle.net servers (hosted on Google Cloud).
    Blizzard = @{ Name = 'Blizzard'; Regions = @(
        @('Europe', 'eu.actual.battle.net', 'icmp'),
        @('US', 'us.actual.battle.net', 'icmp'),
        @('Korea', 'kr.actual.battle.net', 'icmp')) }

    # Rainbow Six and others: Azure (regions from the game's config) and AWS GameLift in some regions.
    Ubisoft = @{ Name = 'Ubisoft'; Regions = @(
        (New-AzureRegions @('northeurope', 'westeurope', 'eastus', 'centralus', 'southcentralus', 'westus', 'brazilsouth')) +
        @(@('AWS Frankfurt', 'dynamodb.eu-central-1.amazonaws.com', 'icmp'),
          @('AWS US East', 'dynamodb.us-east-1.amazonaws.com', 'icmp'))) }

    # Xbox / Microsoft games: Azure.
    Microsoft = @{ Name = 'Microsoft / Xbox'; Regions = @(
        New-AzureRegions @('northeurope', 'westeurope', 'francecentral', 'uksouth', 'germanywestcentral', 'spaincentral',
                           'swedencentral', 'eastus', 'centralus', 'westus', 'brazilsouth', 'japaneast', 'koreacentral',
                           'southeastasia', 'australiaeast')) }

    # The Finals / Arc Raiders run on Google Cloud, but Embark has no public ping endpoints.
    # Reference: Google Cloud regions with public servers that respond (the Battle.net ones).
    Embark = @{ Name = 'Embark'; Regions = @(
        @('Google Cloud NL', 'eu.actual.battle.net', 'icmp'),
        @('Google Cloud US', 'us.actual.battle.net', 'icmp'),
        @('Google Cloud KR', 'kr.actual.battle.net', 'icmp')) }
}
$script:GameTargets = $null

# Normalize -Services: accepts "Epic,Valve", "epic valve" or -Services Epic,Valve; any letter case.
$script:ArgError = $null
$wantedServices = @($Services | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
$Services = @(foreach ($w in $wantedServices) {
    $match = @($GameServices.Keys) | Where-Object { $_ -eq $w } | Select-Object -First 1
    if ($match) { $match }
    elseif (-not $script:ArgError) {
        # Shown by the normal error handling, after the banner.
        $script:ArgError = "Unknown service in -Services: '$w'. Options: $(@($GameServices.Keys) -join ', ')"
    }
})

# Adapters we never touch (VPNs, virtual, Bluetooth).
$ExcludeAdapters = 'Bluetooth|Virtual|\bTAP\b|Tunnel|VPN|Wintun|WireGuard|Hyper-V|Loopback|Check Point|TunnelBear'

# ---------------------------------------------------------------- look and feel

$G = if ($Ascii) {
    @{ Ok = '+'; Bad = 'x'; Warn = '!'; Info = '-'; Sim = '~'; Arrow = '->'; Up = '^'; Down = 'v'
       H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; Dot = '.'; Node = '>'; Bullet = '*'; Ell = '.'; Star = '*' }
} else {
    @{ Ok = [string][char]0x2713; Bad = [string][char]0x2717; Warn = '!'; Info = [string][char]0x00B7; Sim = '~'
       Arrow = [string][char]0x2192; Up = [string][char]0x25B2; Down = [string][char]0x25BC
       H = [string][char]0x2500; V = [string][char]0x2502
       TL = [string][char]0x256D; TR = [string][char]0x256E; BL = [string][char]0x2570; BR = [string][char]0x256F
       Dot = [string][char]0x00B7; Node = [string][char]0x25C6; Bullet = [string][char]0x25CF; Ell = [string][char]0x2026
       Star = [string][char]0x2605 }
}

$StateColor = @{ ok = 'Green'; warn = 'Yellow'; bad = 'Red'; none = 'Gray' }

function Write-Seg([string]$Text, [ConsoleColor]$Color = 'Gray') {
    Write-Host $Text -NoNewline -ForegroundColor $Color
}

function Write-Title([string]$Text) {
    Write-Host ''
    $rest = [math]::Max(3, 66 - $Text.Length)
    Write-Seg "  $($G.H)$($G.H) " DarkCyan
    Write-Seg $Text.ToUpper() Cyan
    Write-Host (' ' + ($G.H * $rest)) -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Ok([string]$Text, [int]$Indent = 2)    { Write-Seg ((' ' * $Indent) + "$($G.Ok) ") Green;  Write-Host $Text -ForegroundColor White }
function Write-Info([string]$Text, [int]$Indent = 2)  { Write-Seg ((' ' * $Indent) + "$($G.Info) ") DarkGray; Write-Host $Text -ForegroundColor Gray }
function Write-Warn2([string]$Text, [int]$Indent = 2) { Write-Seg ((' ' * $Indent) + "$($G.Warn) ") Yellow; Write-Host $Text -ForegroundColor Yellow }
function Write-Bad([string]$Text, [int]$Indent = 2)   { Write-Seg ((' ' * $Indent) + "$($G.Bad) ") Red;    Write-Host $Text -ForegroundColor Red }

function Write-Change([string]$Label, [string]$From, [string]$To, [string]$Note = '') {
    # One change made (or simulated with -WhatIf). Counts towards the summary.
    $sim = [bool]$WhatIfPreference
    if ($sim) { Write-Seg "    $($G.Sim) " Cyan } else { Write-Seg "    $($G.Ok) " Green }
    Write-Seg $Label White
    Write-Seg "  $From " DarkYellow
    Write-Seg $G.Arrow DarkGray
    Write-Seg " $To" Green
    if ($Note) { Write-Seg "  ($Note)" DarkGray }
    if ($sim)  { Write-Seg '  [simulated]' DarkCyan }
    Write-Host ''
    $script:ChangeCount++
}

function Write-KV([string]$Key, [string]$Value, [string]$State = 'none', [string]$Hint = '') {
    # "key ······ value" line with a state: ok (green), warn (yellow, Apply changes it), bad, none.
    $w = 30
    if ($Key.Length -gt $w - 2) { $Key = $Key.Substring(0, $w - 3) + $G.Ell }
    Write-Seg "    $Key" Gray
    $n = [math]::Max(2, $w - $Key.Length)
    Write-Seg (' ' + ($G.Dot * ($n - 1)) + ' ') DarkGray
    switch ($State) {
        'ok'    { Write-Seg "$($G.Ok) " Green;    Write-Seg $Value White }
        'warn'  { Write-Seg "$($G.Warn) " Yellow; Write-Seg $Value Yellow }
        'bad'   { Write-Seg "$($G.Bad) " Red;     Write-Seg $Value Red }
        default { Write-Seg '  ';                 Write-Seg $Value Gray }
    }
    if ($Hint) { Write-Seg "  $($G.Arrow) $Hint" DarkGray }
    Write-Host ''
}

function Write-Box([string]$Title, [object[]]$Lines, [ConsoleColor]$Frame = 'DarkCyan') {
    # $Lines: list of @(glyph, color, text)
    $contents = @($Lines | ForEach-Object { "$($_[0]) $($_[2])" })
    $width = ($contents | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $width = [math]::Max([int]$width, $Title.Length + 2)
    Write-Host ''
    Write-Seg "  $($G.TL)$($G.H) " $Frame
    Write-Seg $Title White
    Write-Host (' ' + ($G.H * ($width - $Title.Length - 1)) + $G.TR) -ForegroundColor $Frame
    foreach ($l in $Lines) {
        $text = [string]$l[2]
        $pad = $width - ("$($l[0]) $text").Length
        Write-Seg "  $($G.V) " $Frame
        Write-Seg "$($l[0]) " $l[1]
        Write-Seg ($text + (' ' * $pad)) White
        Write-Host " $($G.V)" -ForegroundColor $Frame
    }
    Write-Host ("  $($G.BL)" + ($G.H * ($width + 2)) + $G.BR) -ForegroundColor $Frame
}

function Write-Banner {
    $info = @{
        Test   = @('TEST',   'Measures and shows the state. Changes nothing.',            'Cyan')
        Apply  = @('APPLY',  'Measures, backs up, applies the tweaks, measures again.',   'Green')
        Revert = @('REVERT', 'Restores the backup and undoes the tweaks.',                'Magenta')
    }[$Mode]
    $w = 62
    $badge = " $($info[0]) "

    Write-Host ''
    Write-Host ("  $($G.TL)" + ($G.H * $w) + $G.TR) -ForegroundColor DarkCyan

    $name = "NetTune $Version"
    Write-Seg "  $($G.V)  " DarkCyan
    Write-Seg 'Net' Cyan; Write-Seg 'Tune' White; Write-Seg " $Version" DarkGray
    Write-Seg (' ' * ($w - 4 - $name.Length - $badge.Length))
    Write-Host $badge -NoNewline -ForegroundColor Black -BackgroundColor $info[2]
    Write-Host "  $($G.V)" -ForegroundColor DarkCyan

    foreach ($line in @(@("Stable ping for gaming $($G.Dot) Windows 10/11", 'Gray'), @($info[1], 'DarkGray'))) {
        Write-Seg "  $($G.V)  " DarkCyan
        Write-Seg ($line[0].PadRight($w - 4)) $line[1]
        Write-Host "  $($G.V)" -ForegroundColor DarkCyan
    }
    if ($WhatIfPreference) {
        Write-Seg "  $($G.V)  " DarkCyan
        Write-Seg ('Simulation (-WhatIf): nothing will be changed.'.PadRight($w - 4)) Yellow
        Write-Host "  $($G.V)" -ForegroundColor DarkCyan
    }
    Write-Host ("  $($G.BL)" + ($G.H * $w) + $G.BR) -ForegroundColor DarkCyan
}

function Write-AdapterHeader($Adapter) {
    $st = switch ([string]$Adapter.Status) {
        'Up'           { @('connected', 'Green') }
        'Disconnected' { @('disconnected', 'Yellow') }
        'Disabled'     { @('disabled', 'DarkGray') }
        default        { @([string]$Adapter.Status, 'Gray') }
    }
    Write-Host ''
    Write-Seg "  $($G.Node) " Cyan
    Write-Seg $Adapter.Name White
    Write-Seg "  $($Adapter.InterfaceDescription)" DarkGray
    Write-Host "  $($G.Bullet) $($st[0])" -ForegroundColor $st[1]
}

function Format-Num($Value) {
    if ($null -eq $Value) { return '-' }
    $r = [math]::Round([double]$Value, 1)
    if ($r -eq [math]::Round($r)) { return ([math]::Round($r)).ToString() }
    return $r.ToString()
}

function Format-Fit([string]$Text, [int]$Width) {
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width - 1) + $G.Ell }
    return $Text.PadRight($Width)
}

# ---------------------------------------------------------------- utilities

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        throw 'This mode needs administrator rights. Open PowerShell with "Run as administrator" and run it again.'
    }
}

function Get-TargetAdapters {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne 'Not Present' -and $_.InterfaceDescription -notmatch $ExcludeAdapters -and $_.Name -notmatch $ExcludeAdapters }
}

function Get-ActiveRoute {
    # The route Windows ACTUALLY uses for the internet. A disconnected adapter can keep a stored
    # route, so sorting by route metric alone is not enough.
    try {
        $r = @(Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop) |
            Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1
        if ($r -and $r.NextHop -and $r.NextHop -ne '0.0.0.0') { return $r }
    } catch { }

    # Plan B: connected adapters only, route metric + interface metric (that is how Windows chooses).
    $best = $null
    $bestMetric = [int]::MaxValue
    foreach ($r in @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' })) {
        $ipif = Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $ipif -or [string]$ipif.ConnectionState -ne 'Connected') { continue }
        $m = [int]$r.RouteMetric + [int]$ipif.InterfaceMetric
        if ($m -lt $bestMetric) { $best = $r; $bestMetric = $m }
    }
    return $best
}

function Get-DefaultGateway {
    $route = Get-ActiveRoute
    if ($route) { return $route.NextHop }
    return $null
}

function Wait-Network([int]$TimeoutSec = 40) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $s = [int]$sw.Elapsed.TotalSeconds
            Write-Progress -Id 2 -Activity 'Waiting for the network to come back' -Status "$s s / $TimeoutSec s" -PercentComplete ([math]::Min(100, [int](100 * $s / $TimeoutSec)))
            $gw = Get-DefaultGateway
            if ($gw) {
                try {
                    $reply = (New-Object System.Net.NetworkInformation.Ping).Send($gw, 500)
                    if ($reply.Status -eq 'Success') { return $true }
                } catch { }
            }
            Start-Sleep -Seconds 1
        }
        return $false
    } finally {
        Write-Progress -Id 2 -Activity 'Waiting for the network to come back' -Completed
    }
}

function Get-WifiPowerPlan {
    # Reads the Wi-Fi "Power Saving Mode" from the active plan. Returns $null if it does not exist.
    try {
        $scheme = [regex]::Match((powercfg /getactivescheme | Out-String), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
        if (-not $scheme) { return $null }
        # The last two lines with 0x.. are always AC and DC (regardless of the Windows language).
        $vals = @(powercfg /q $scheme $WifiPowerSub $WifiPowerSet 2>$null |
            Where-Object { $_ -match ':\s*0x[0-9a-fA-F]+\s*$' } |
            ForEach-Object { [Convert]::ToInt32([regex]::Match($_, '0x([0-9a-fA-F]+)').Groups[1].Value, 16) })
        if ($vals.Count -lt 2) { return $null }
        return [pscustomobject]@{ Scheme = $scheme; AC = $vals[-2]; DC = $vals[-1] }
    } catch {
        return $null
    }
}

function Set-WifiPowerPlan([string]$Scheme, [int]$AC, [int]$DC) {
    powercfg /setacvalueindex $Scheme $WifiPowerSub $WifiPowerSet $AC | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg failed (AC, exit code $LASTEXITCODE)" }
    powercfg /setdcvalueindex $Scheme $WifiPowerSub $WifiPowerSet $DC | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg failed (DC, exit code $LASTEXITCODE)" }
    powercfg /setactive $Scheme | Out-Null
}

function Format-WifiPower([int]$Value) {
    if ($Value -ge 0 -and $Value -lt $WifiPowerNames.Count) { return $WifiPowerNames[$Value] }
    return "value $Value"
}

function Get-AdapterClassKey([string]$InterfaceGuid) {
    # The 00XX subkey of the network class whose NetCfgInstanceId is the adapter's InterfaceGuid.
    Get-ChildItem -Path $NetClassKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        Where-Object {
            $id = Get-ItemProperty -Path $_.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue
            $id -and ([string]$id.NetCfgInstanceId -eq $InterfaceGuid)
        } |
        Select-Object -First 1
}

function Get-PnPCapabilities([string]$KeyPath) {
    # Returns the value (int) or $null if the entry does not exist.
    $prop = (Get-ItemProperty -Path $KeyPath -ErrorAction Stop).PSObject.Properties['PnPCapabilities']
    if ($prop) { return [int]$prop.Value }
    return $null
}

function Format-PnPCap($Value) {
    if ($null -eq $Value) { return 'yes (PnPCapabilities not set)' }
    if ($Value -eq $PnPCapOff) { return "no (PnPCapabilities = $Value)" }
    return "yes (PnPCapabilities = $Value)"
}

# ---------------------------------------------------------------- tests

function Get-Grade($Value, [double]$Good, [double]$Fair) {
    if ($null -eq $Value) { return 'bad' }
    if ($Value -le $Good) { return 'ok' }
    if ($Value -le $Fair) { return 'warn' }
    return 'bad'
}

function Get-WorstGrade([string[]]$Grades) {
    if ($Grades -contains 'bad')  { return 'bad' }
    if ($Grades -contains 'warn') { return 'warn' }
    return 'ok'
}

function New-Target([string]$Label, [string]$HostName, [string]$Kind, [string]$Method = 'icmp', [string]$Region = '') {
    [pscustomobject]@{ Label = $Label; Host = $HostName; Kind = $Kind; Method = $Method; Region = $Region }
}

function Resolve-HostV4([string]$HostName) {
    # Resolve the name only once (otherwise every ping does a DNS lookup and a DNS failure counts as loss).
    if (-not $HostName) { return $null }
    $parsed = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$parsed)) { return $HostName }
    try {
        $all = @([Net.Dns]::GetHostAddresses($HostName))
        $v4 = $all | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($v4) { return $v4.IPAddressToString }
        if ($all.Count -gt 0) { return $all[0].IPAddressToString }
    } catch { }
    return $null
}

function Measure-TcpOnce([string]$Ip, [int]$Port = 443, [int]$TimeoutMs = 1000) {
    # TCP handshake time (SYN -> SYN/ACK) in ms. $null if it fails or times out.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $task = $client.ConnectAsync($Ip, $Port)
        if ($task.Wait($TimeoutMs) -and $client.Connected) { return $sw.Elapsed.TotalMilliseconds }
        return $null
    } catch {
        return $null
    } finally {
        $client.Close()
    }
}

function Get-SteamRelayRegions {
    # Official list of Valve SDR relays (one region per datacenter, worldwide).
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $json = Invoke-RestMethod -Uri 'https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=730' -TimeoutSec 8 -UseBasicParsing
        $list = foreach ($pop in $json.pops.PSObject.Properties) {
            $v = $pop.Value
            $relays = $v.PSObject.Properties['relays']
            if (-not $relays -or -not $relays.Value) { continue }
            $ip = @($relays.Value)[0].ipv4
            if (-not $ip) { continue }
            $desc = if ($v.PSObject.Properties['desc']) { [string]$v.desc } else { $pop.Name }
            , @($desc, $ip, 'icmp')
        }
        if (@($list).Count -gt 0) { return @($list) }
    } catch { }
    return $null
}

function Select-GameTargets {
    # For each requested service, quickly measures every region and returns one target with the closest.
    $cands = New-Object System.Collections.Generic.List[object]
    foreach ($key in $GameServices.Keys) {
        if ($Services -notcontains $key) { continue }
        $svc = $GameServices[$key]
        $regions = $svc.Regions
        if ($svc.ContainsKey('Dynamic') -and $svc.Dynamic -eq 'SteamSDR') {
            $live = Get-SteamRelayRegions
            if ($live) { $regions = $live } else { Write-Warn2 'Steam: could not fetch the relay list, using the built-in list.' }
        }
        foreach ($r in $regions) {
            $cands.Add([pscustomobject]@{ Key = $key; Service = $svc.Name; Region = $r[0]; Host = $r[1]; Method = $r[2]; Ip = $null; Best = $null })
        }
    }
    if ($cands.Count -eq 0) { return @() }
    $activity = 'Finding the closest region for each service'

    # 1) Resolve every name in parallel.
    Write-Progress -Id 3 -Activity $activity -Status 'Resolving names (DNS)...' -PercentComplete 5
    $dnsTasks = @{}
    foreach ($c in $cands) {
        $parsed = $null
        if ([Net.IPAddress]::TryParse($c.Host, [ref]$parsed)) { $c.Ip = $c.Host }
        elseif (-not $dnsTasks.ContainsKey($c.Host)) { $dnsTasks[$c.Host] = [Net.Dns]::GetHostAddressesAsync($c.Host) }
    }
    if ($dnsTasks.Count -gt 0) {
        try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($dnsTasks.Values), 5000) } catch { }
    }
    foreach ($c in $cands) {
        if ($c.Ip) { continue }
        $t = $dnsTasks[$c.Host]
        if ($t -and $t.Status -eq 'RanToCompletion') {
            $v4 = @($t.Result) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($v4) { $c.Ip = $v4.IPAddressToString }
        }
    }

    # 2) Measure each unique IP (several services share regions): best of 3 pings in parallel,
    #    or best of 2 TCP connects one at a time (in parallel the TCP timing would not be accurate).
    $best = @{}
    $icmpIps = @($cands | Where-Object { $_.Ip -and $_.Method -eq 'icmp' } | ForEach-Object { $_.Ip } | Select-Object -Unique)
    $tcpIps  = @($cands | Where-Object { $_.Ip -and $_.Method -eq 'tcp' }  | ForEach-Object { $_.Ip } | Select-Object -Unique)

    if ($icmpIps.Count -gt 0) {
        for ($round = 1; $round -le 3; $round++) {
            Write-Progress -Id 3 -Activity $activity -Status "Pinging $($icmpIps.Count) servers (round $round/3)..." -PercentComplete (5 + 15 * $round)
            $jobs = foreach ($ip in $icmpIps) {
                $p = New-Object System.Net.NetworkInformation.Ping
                [pscustomobject]@{ Ip = $ip; Ping = $p; Task = $p.SendPingAsync($ip, 1000) }
            }
            try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($jobs | ForEach-Object { $_.Task }), 3000) } catch { }
            foreach ($j in $jobs) {
                if ($j.Task.Status -eq 'RanToCompletion' -and $j.Task.Result.Status -eq 'Success') {
                    $ms = [double]$j.Task.Result.RoundtripTime
                    if (-not $best.ContainsKey($j.Ip) -or $ms -lt $best[$j.Ip]) { $best[$j.Ip] = $ms }
                }
                $j.Ping.Dispose()
            }
        }
    }

    if ($tcpIps.Count -gt 0) {
        [void](Measure-TcpOnce $tcpIps[0] 443 1000)   # warm-up: the first connection is always slower
        $done = 0
        for ($round = 1; $round -le 2; $round++) {
            foreach ($ip in $tcpIps) {
                $done++
                Write-Progress -Id 3 -Activity $activity -Status "TCP connect to $($tcpIps.Count) servers (round $round/2)..." -PercentComplete (65 + [int](35 * $done / (2 * $tcpIps.Count)))
                $ms = Measure-TcpOnce $ip 443 700
                if ($null -ne $ms -and (-not $best.ContainsKey($ip) -or $ms -lt $best[$ip])) { $best[$ip] = $ms }
            }
        }
    }
    Write-Progress -Id 3 -Activity $activity -Completed

    foreach ($c in $cands) { if ($c.Ip -and $best.ContainsKey($c.Ip)) { $c.Best = $best[$c.Ip] } }

    # 3) One target per service, in list order.
    foreach ($key in @($cands | ForEach-Object { $_.Key } | Select-Object -Unique)) {
        $mine = @($cands | Where-Object { $_.Key -eq $key })
        $winner = $mine | Where-Object { $null -ne $_.Best } | Sort-Object Best | Select-Object -First 1
        if ($winner) {
            New-Target $winner.Service $winner.Ip 'game' $winner.Method $winner.Region
        } else {
            New-Target $mine[0].Service '' 'game' 'icmp' 'no region responded'
        }
    }
}

function Measure-Target($Target, [int]$Pings, [int]$Index, [int]$Total) {
    $Label = $Target.Label
    $empty = [pscustomobject]@{ Alvo = $Label; Host = $Target.Host; Regiao = $Target.Region; Metodo = $Target.Method; Tipo = $Target.Kind
                                Min = $null; Media = $null; Max = $null; Jitter = $null; 'Picos>100' = $null; 'Perda%' = 100 }

    $address = Resolve-HostV4 $Target.Host
    if (-not $address) { return $empty }
    $useTcp = ($Target.Method -eq 'tcp')

    $ping = New-Object System.Net.NetworkInformation.Ping
    $rtts = New-Object System.Collections.Generic.List[double]
    $lost = 0
    try {
        if ($useTcp) { [void](Measure-TcpOnce $address 443 1000) }   # warm-up
        for ($i = 0; $i -lt $Pings; $i++) {
            $pct = [int](100 * (($Index - 1) * $Pings + $i) / ($Total * $Pings))
            $where = if ($Target.Region) { $Target.Region } else { $address }
            Write-Progress -Id 1 -Activity 'Connection test' -Status ("{0}/{1}  {2}  ({3})   {4} {5}/{6}" -f $Index, $Total, $Label, $where, $(if ($useTcp) { 'tcp' } else { 'ping' }), ($i + 1), $Pings) -PercentComplete $pct
            if ($useTcp) {
                $ms = Measure-TcpOnce $address 443 1000
                if ($null -ne $ms) { $rtts.Add([math]::Round($ms, 1)) } else { $lost++ }
            } else {
                try {
                    $reply = $ping.Send($address, 1000)
                    if ($reply.Status -eq 'Success') { $rtts.Add([double]$reply.RoundtripTime) } else { $lost++ }
                } catch {
                    $lost++
                }
            }
            Start-Sleep -Milliseconds 200
        }
    } finally {
        $ping.Dispose()
    }

    if ($rtts.Count -eq 0) { return $empty }

    $jitter = 0.0
    if ($rtts.Count -gt 1) {
        $sum = 0.0
        for ($j = 1; $j -lt $rtts.Count; $j++) { $sum += [math]::Abs($rtts[$j] - $rtts[$j - 1]) }
        $jitter = $sum / ($rtts.Count - 1)
    }
    $stats = $rtts | Measure-Object -Minimum -Maximum -Average
    $min   = $stats.Minimum
    $spikes = @($rtts | Where-Object { $_ -gt ($min + 100) }).Count

    [pscustomobject]@{
        Alvo        = $Label
        Host        = $Target.Host
        Regiao      = $Target.Region
        Metodo      = $Target.Method
        Tipo        = $Target.Kind
        Min         = [math]::Round($min, 0)
        Media       = [math]::Round($stats.Average, 1)
        Max         = [math]::Round($stats.Maximum, 0)
        Jitter      = [math]::Round($jitter, 1)
        'Picos>100' = $spikes
        'Perda%'    = [math]::Round(100.0 * $lost / $Pings, 1)
    }
}

# Results table columns: title, width.
$ResultCols = @(@('Target', 18), @('Server', 24), @('Min', 5), @('Avg', 8), @('Max', 7), @('Jitter', 8), @('Spikes', 7), @('Loss', 8))

function Write-ResultHeader {
    Write-Seg '  '
    foreach ($c in $ResultCols) {
        if ($c[0] -in 'Target', 'Server') { Write-Seg $c[0].PadRight($c[1]) DarkGray } else { Write-Seg $c[0].PadLeft($c[1]) DarkGray }
    }
    Write-Host '    Status' -ForegroundColor DarkGray
    $total = ($ResultCols | ForEach-Object { $_[1] } | Measure-Object -Sum).Sum + 16
    Write-Host ('  ' + ($G.H * $total)) -ForegroundColor DarkGray
}

function Write-ResultRow($R) {
    Write-Seg ('  ' + (Format-Fit $R.Alvo 18)) White
    $server = [string]$R.Regiao
    if ($R.Metodo -eq 'tcp') { $server = "$server $($G.Dot) tcp" }
    Write-Seg (Format-Fit $server 23) DarkGray
    Write-Seg ' '

    if ($null -eq $R.Media) {
        Write-Seg ('-'.PadLeft(5) + '-'.PadLeft(8) + '-'.PadLeft(7) + '-'.PadLeft(8) + '-'.PadLeft(7)) DarkGray
        Write-Seg '100%'.PadLeft(8) Red
        Write-Host "    $($G.Bad) no response" -ForegroundColor Red
        return
    }

    # Average limits depend on the target type.
    $lim = switch ($R.Tipo) { 'router' { @(5, 15) } 'internet' { @(40, 80) } default { @(60, 100) } }
    $gMed   = Get-Grade $R.Media $lim[0] $lim[1]
    $gMax   = Get-Grade ($R.Max - $R.Min) 30 100
    $gJit   = Get-Grade $R.Jitter 5 15
    $gPicos = Get-Grade $R.'Picos>100' 0 2
    $gPerda = Get-Grade $R.'Perda%' 0 2

    Write-Seg (Format-Num $R.Min).PadLeft(5) DarkGray
    Write-Seg (Format-Num $R.Media).PadLeft(8) $StateColor[$gMed]
    Write-Seg (Format-Num $R.Max).PadLeft(7) $StateColor[$gMax]
    Write-Seg (Format-Num $R.Jitter).PadLeft(8) $StateColor[$gJit]
    Write-Seg ([string]$R.'Picos>100').PadLeft(7) $StateColor[$gPicos]
    Write-Seg ((Format-Num $R.'Perda%') + '%').PadLeft(8) $StateColor[$gPerda]

    switch (Get-WorstGrade @($gMed, $gMax, $gJit, $gPicos, $gPerda)) {
        'ok'   { Write-Host "    $($G.Ok) great" -ForegroundColor Green }
        'warn' { Write-Host "    $($G.Warn) fair" -ForegroundColor Yellow }
        'bad'  { Write-Host "    $($G.Bad) unstable" -ForegroundColor Red }
    }
}

function Invoke-NetTest([string]$Title) {
    Write-Title $Title
    $targets = New-Object System.Collections.Generic.List[object]
    $gw = Get-DefaultGateway
    if ($gw) { $targets.Add((New-Target 'Router' $gw 'router' 'icmp' $gw)) } else { Write-Warn2 'Could not find the router (gateway). Are you connected to a network?' }
    $targets.Add((New-Target 'Cloudflare' '1.1.1.1' 'internet' 'icmp' '1.1.1.1'))
    $targets.Add((New-Target 'Google' '8.8.8.8' 'internet' 'icmp' '8.8.8.8'))

    # Regions are picked only once: in Apply, the "after" test uses the same servers as "before".
    if ($null -eq $script:GameTargets) {
        if ($Services.Count -gt 0) {
            Write-Info "Finding the closest region for each service ($($Services.Count) services)..."
        }
        $script:GameTargets = @(Select-GameTargets)
    }
    foreach ($t in $script:GameTargets) { $targets.Add($t) }
    foreach ($t in $ExtraTargets) { $targets.Add((New-Target 'Extra' $t 'game' 'icmp' $t)) }

    $secs = [math]::Ceiling($targets.Count * $Count * 0.22)
    Write-Info "$($targets.Count) targets $($G.Dot) $Count samples each $($G.Dot) about $secs s $($G.Dot) values in ms"
    Write-Info 'Do not use the network during the test (downloads, streams, games).'
    Write-Host ''
    Write-ResultHeader

    $results = @()
    $i = 0
    try {
        foreach ($t in $targets) {
            $i++
            $r = Measure-Target -Target $t -Pings $Count -Index $i -Total $targets.Count
            Write-ResultRow $r
            $results += $r
        }
    } finally {
        Write-Progress -Id 1 -Activity 'Connection test' -Completed
    }

    Write-Host ''
    Write-Seg '  ' ; Write-Seg 'green' Green; Write-Seg ' = good   ' DarkGray; Write-Seg 'yellow' Yellow; Write-Seg ' = fair   ' DarkGray
    Write-Seg 'red' Red; Write-Host ' = bad' -ForegroundColor DarkGray
    if ($script:GameTargets.Count -gt 0) {
        Write-Host "  Server = the region closest to you, picked automatically." -ForegroundColor DarkGray
    }
    if (@($targets | Where-Object { $_.Method -eq 'tcp' }).Count -gt 0) {
        Write-Host "  tcp = measured by TCP connect time (those servers block ping)." -ForegroundColor DarkGray
    }

    $router = $results | Where-Object { $_.Tipo -eq 'router' } | Select-Object -First 1
    if ($router -and $null -ne $router.Media) {
        Write-Host ''
        # Same criteria as the table, so the sentence matches the "Status" column.
        $grade = Get-WorstGrade @(
            (Get-Grade $router.Media 5 15),
            (Get-Grade $router.Jitter 5 15),
            (Get-Grade $router.'Picos>100' 0 2),
            (Get-Grade $router.'Perda%' 0 2))
        switch ($grade) {
            'ok'   { Write-Ok 'Router connection is stable: the local side (adapter, driver, Wi-Fi) is fine.' }
            'warn' {
                Write-Warn2 'Router connection is fair: it should be 1-5 ms and stable.'
                Write-Info  'It may just be a bad Wi-Fi moment. Run again with more pings (-Count 50) to confirm.' 4
            }
            'bad'  {
                Write-Bad   'Router connection is unstable: it should be 1-5 ms and stable.'
                Write-Info  'The problem is local (adapter, driver or Wi-Fi), not your ISP or the game.' 4
            }
        }
    }
    return $results
}

function Write-Delta($Before, $After, [double]$Tolerance, [string]$Suffix = '') {
    # "before → now  ▼Δ" colored by improvement (lower is better). Takes 24 columns.
    if ($null -eq $Before -or $null -eq $After) {
        Write-Seg ('-'.PadLeft(13) + (' ' * 11)) DarkGray
        return
    }
    Write-Seg ("{0}{2} {1} {3}{2}" -f (Format-Num $Before), $G.Arrow, $Suffix, (Format-Num $After)).PadLeft(13) Gray
    $d = [math]::Round([double]$After - [double]$Before, 1)
    if ([math]::Abs($d) -le $Tolerance) {
        Write-Seg '  ='.PadRight(11) DarkGray
    } elseif ($d -lt 0) {
        Write-Seg ("  $($G.Down)" + (Format-Num ([math]::Abs($d)))).PadRight(11) Green
    } else {
        Write-Seg ("  $($G.Up)" + (Format-Num $d)).PadRight(11) Red
    }
}

function Show-Comparison($Before, $After) {
    Write-Title 'Before vs after'
    Write-Seg '  '
    Write-Seg 'Target'.PadRight(18) DarkGray
    Write-Seg 'Avg'.PadLeft(13) DarkGray; Write-Seg (' ' * 11)
    Write-Seg 'Jitter'.PadLeft(13) DarkGray; Write-Seg (' ' * 11)
    Write-Host 'Loss'.PadLeft(13) -ForegroundColor DarkGray
    Write-Host ('  ' + ($G.H * 90)) -ForegroundColor DarkGray

    foreach ($b in $Before) {
        $a = $After | Where-Object { $_.Alvo -eq $b.Alvo } | Select-Object -First 1
        if (-not $a) { continue }
        Write-Seg ('  ' + (Format-Fit $b.Alvo 18)) White
        Write-Delta $b.Media  $a.Media  0.5
        Write-Delta $b.Jitter $a.Jitter 0.5
        Write-Delta $b.'Perda%' $a.'Perda%' 0 '%'
        Write-Host ''
    }
    Write-Host ''
    Write-Seg '  '; Write-Seg "$($G.Down) down (better)" Green; Write-Seg '   '; Write-Seg "$($G.Up) up (worse)" Red
    Write-Host '   = same' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- dns

function New-DnsQuery([string]$Name, [int]$Id) {
    # Minimal DNS packet: header with "recursion desired" + one type A question.
    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.AddRange([byte[]]@((($Id -shr 8) -band 0xFF), ($Id -band 0xFF), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
    foreach ($label in $Name.Split('.')) {
        $b = [Text.Encoding]::ASCII.GetBytes($label)
        $bytes.Add([byte]$b.Length)
        $bytes.AddRange($b)
    }
    $bytes.AddRange([byte[]]@(0, 0, 1, 0, 1))   # end of name, type A, class IN
    return $bytes.ToArray()
}

function Measure-DnsQuery([string]$Server, [string]$Name, [int]$TimeoutMs = 1500) {
    # Sends one UDP query straight to the server and times the reply. $null if it does not answer.
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $id = Get-Random -Minimum 1 -Maximum 65535
        $query = New-DnsQuery $Name $id
        $ep = New-Object System.Net.IPEndPoint ([Net.IPAddress]::Parse($Server)), 53
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void]$udp.Send($query, $query.Length, $ep)
        $remote = New-Object System.Net.IPEndPoint ([Net.IPAddress]::Any), 0
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $resp = $udp.Receive([ref]$remote)
            if ($resp.Length -ge 4 -and $resp[0] -eq (($id -shr 8) -band 0xFF) -and $resp[1] -eq ($id -band 0xFF)) {
                return [pscustomobject]@{ Ms = $sw.Elapsed.TotalMilliseconds; RCode = ($resp[3] -band 0x0F) }
            }
        }
        return $null
    } catch {
        return $null
    } finally {
        $udp.Close()
    }
}

function Get-Median([double[]]$Values) {
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return [double]$s[[int][math]::Floor($n / 2)] }
    return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2
}

function Get-ActiveDnsServers {
    # DNS servers (IPv4) of the adapter actually carrying the internet traffic.
    $route = Get-ActiveRoute
    if (-not $route) { return @() }
    try {
        return @((Get-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses | Where-Object { $_ })
    } catch {
        return @()
    }
}

function Test-PrivateIp([string]$Ip) {
    # Router, local network, CGNAT or link-local: a DNS here only forwards to another one (usually the ISP's).
    $addr = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$addr)) { return $false }
    if ($addr.AddressFamily -eq 'InterNetworkV6') {
        return ($addr.IsIPv6LinkLocal -or $addr.IsIPv6SiteLocal -or $Ip -match '^f[cd]')
    }
    $b = $addr.GetAddressBytes()
    return ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or
           ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or ($b[0] -eq 169 -and $b[1] -eq 254)
}

function Get-AdapterDnsList([int]$IfIndex, [string]$Family) {
    # DNS servers in use on an adapter, per family ('IPv4' or 'IPv6').
    try {
        return @((Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily $Family -ErrorAction Stop).ServerAddresses | Where-Object { $_ })
    } catch {
        return @()
    }
}

function Test-SameList([string[]]$A, [string[]]$B) {
    return (@($A) -join ',') -eq (@($B) -join ',')
}

function Set-AdapterDnsFamily($Adapter, [string]$Family, [string[]]$Servers) {
    # Sets the DNS of ONE family on an adapter, explicitly (netsh, by adapter index).
    # Empty $Servers = back to automatic (DHCP). Returns the resulting list, read back.
    $proto = if ($Family -eq 'IPv4') { 'ipv4' } else { 'ipv6' }
    $iface = "name=$($Adapter.ifIndex)"
    if (@($Servers).Count -eq 0) {
        netsh interface $proto set dnsservers $iface source=dhcp | Out-Null
    } else {
        netsh interface $proto set dnsservers $iface source=static "address=$($Servers[0])" register=primary validate=no | Out-Null
        for ($i = 1; $i -lt $Servers.Count; $i++) {
            netsh interface $proto add dnsservers $iface "address=$($Servers[$i])" "index=$($i + 1)" validate=no | Out-Null
        }
    }
    return @(Get-AdapterDnsList $Adapter.ifIndex $Family)
}

function Invoke-DnsBenchmark {
    # Compares the public DNS servers (and the current one, as a reference) and returns: Choice = preset to apply, or $null.
    Write-Title 'DNS test'

    $current = @(Get-ActiveDnsServers | Select-Object -First 2)
    $gateway = Get-DefaultGateway
    $rows = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($ip in $current) {
        $n++
        $preset = $null
        foreach ($k in $DnsPresets.Keys) { if ($DnsPresets[$k] -contains $ip) { $preset = $k } }
        $isLocal = (-not $preset) -and (Test-PrivateIp $ip)
        $suffix = if ($current.Count -gt 1) { " $n" } else { '' }
        $label = if ($preset) { "Current ($preset)" }
                 elseif ($ip -eq $gateway) { "Current$suffix (router)" }
                 elseif ($isLocal) { "Current$suffix (local)" }
                 else { "Current$suffix (ISP)" }
        $rows.Add([pscustomobject]@{ Label = $label; Ip = $ip; Preset = $preset; IsCurrent = $true; IsLocal = $isLocal
            Times = (New-Object System.Collections.Generic.List[double]); Uncached = (New-Object System.Collections.Generic.List[double])
            Fails = 0; Total = 0; Median = $null; UncMedian = $null; FailPct = 100.0; Dead = $false; Score = $null })
    }
    foreach ($k in @('Cloudflare', 'Google', 'Quad9', 'OpenDNS')) {
        $ip = $DnsPresets[$k][0]
        if ($current -contains $ip) { continue }
        $rows.Add([pscustomobject]@{ Label = $k; Ip = $ip; Preset = $k; IsCurrent = $false; IsLocal = $false
            Times = (New-Object System.Collections.Generic.List[double]); Uncached = (New-Object System.Collections.Generic.List[double])
            Fails = 0; Total = 0; Median = $null; UncMedian = $null; FailPct = 100.0; Dead = $false; Score = $null })
    }

    $rounds = 3
    $uncachedCount = 5
    Write-Info "$($rows.Count) servers $($G.Dot) $($DnsTestDomains.Count) domains x $rounds rounds + $uncachedCount uncached queries each $($G.Dot) values in ms"
    if ($current.Count -eq 0) { Write-Warn2 'Could not read the current DNS of the connected adapter; comparing the public ones only.' }

    # Servers are interleaved on every query, so they all get the same network conditions.
    $totalQ = $rows.Count * ($DnsTestDomains.Count * $rounds + $uncachedCount)
    $done = 0
    try {
        for ($round = 1; $round -le $rounds; $round++) {
            foreach ($d in $DnsTestDomains) {
                foreach ($r in $rows) {
                    $done++
                    if ($r.Dead) { continue }
                    if ($done % 4 -eq 0) { Write-Progress -Id 4 -Activity 'DNS test' -Status "Round $round/$rounds  $($G.Dot)  $d" -PercentComplete ([int](100 * $done / $totalQ)) }
                    $res = Measure-DnsQuery $r.Ip $d
                    $r.Total++
                    if ($res -and ($res.RCode -eq 0 -or $res.RCode -eq 3)) { $r.Times.Add($res.Ms) } else { $r.Fails++ }
                    # 3 failures without a single answer: the server cannot be reached (or the network blocks it). No point waiting.
                    if ($r.Times.Count -eq 0 -and $r.Fails -ge 3) { $r.Dead = $true }
                }
            }
        }
        # Uncached: random names force the server to ask the domain's own servers.
        for ($u = 1; $u -le $uncachedCount; $u++) {
            foreach ($r in $rows) {
                $done++
                if ($r.Dead) { continue }
                Write-Progress -Id 4 -Activity 'DNS test' -Status 'Uncached queries...' -PercentComplete ([int](100 * $done / $totalQ))
                $name = 'nt' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.google.com'
                $res = Measure-DnsQuery $r.Ip $name 2500
                $r.Total++
                if ($res -and ($res.RCode -eq 0 -or $res.RCode -eq 3)) { $r.Uncached.Add($res.Ms) } else { $r.Fails++ }
            }
        }
    } finally {
        Write-Progress -Id 4 -Activity 'DNS test' -Completed
    }

    foreach ($r in $rows) {
        $r.Median    = Get-Median $r.Times.ToArray()
        $r.UncMedian = Get-Median $r.Uncached.ToArray()
        $r.FailPct   = if ($r.Total -gt 0) { [math]::Round(100.0 * $r.Fails / $r.Total, 1) } else { 100.0 }
    }

    # Score: 70% usual response + 30% uncached. Only reliable servers count (up to 10% failures).
    foreach ($r in $rows) {
        if ($null -ne $r.Median) {
            $unc = if ($null -ne $r.UncMedian) { $r.UncMedian } else { $r.Median }
            $r.Score = 0.7 * $r.Median + 0.3 * $unc
        }
    }
    $valid = @($rows | Where-Object { $null -ne $_.Score -and $_.FailPct -le 10 })

    # Candidates = public DNS only (including the current one, if it already is one). The router / local
    # network cannot win: it answers from its cache in ~1 ms, which is not comparable with a real DNS.
    $cands = @($valid | Where-Object { $_.Preset })
    $winner = $null
    $margin = 5
    if ($cands.Count -gt 0) {
        $bestScore = ($cands | Measure-Object -Property Score -Minimum).Minimum
        # Below 5 ms (or 20%) the difference is noise: the same server varies that much between runs.
        $margin = [math]::Max(5, 0.2 * $bestScore)
        # On a tie prefer Cloudflare, then Google (Quad9 and OpenDNS filter domains).
        foreach ($pref in @('Cloudflare', 'Google', 'Quad9', 'OpenDNS')) {
            $w = $cands | Where-Object { $_.Preset -eq $pref -and $_.Score -le $bestScore + $margin } | Select-Object -First 1
            if ($w) { $winner = $w; break }
        }
    }

    # Table
    Write-Host ''
    Write-Seg '  '
    Write-Seg 'DNS'.PadRight(22) DarkGray
    Write-Seg 'Server'.PadRight(17) DarkGray
    Write-Seg 'Median'.PadLeft(8) DarkGray
    Write-Seg 'Uncached'.PadLeft(11) DarkGray
    Write-Host 'Fails'.PadLeft(8) -ForegroundColor DarkGray
    Write-Host ('  ' + ($G.H * 84)) -ForegroundColor DarkGray
    foreach ($r in $rows) {
        Write-Seg ('  ' + (Format-Fit $r.Label 22)) $(if ($r.IsCurrent) { 'Cyan' } else { 'White' })
        Write-Seg (Format-Fit $r.Ip 17) DarkGray
        if ($null -eq $r.Median) {
            Write-Seg ('-'.PadLeft(8) + '-'.PadLeft(11)) DarkGray
            Write-Seg '100%'.PadLeft(8) Red
            Write-Host "    $($G.Bad) no response" -ForegroundColor Red
            continue
        }
        $gMed = Get-Grade $r.Median 20 50
        $gUnc = Get-Grade $r.UncMedian 80 200
        $gFail = Get-Grade $r.FailPct 0 5
        Write-Seg (Format-Num $r.Median).PadLeft(8) $StateColor[$gMed]
        Write-Seg (Format-Num $r.UncMedian).PadLeft(11) $StateColor[$gUnc]
        Write-Seg ((Format-Num $r.FailPct) + '%').PadLeft(8) $StateColor[$gFail]
        if ($winner -and $r.Ip -eq $winner.Ip) { Write-Host "    $($G.Star) best" -ForegroundColor Green }
        elseif ($r.IsLocal) { Write-Host '    local cache, ignored' -ForegroundColor DarkGray }
        else { Write-Host '' }
    }
    Write-Host ''
    Write-Host "  Median = usual response (cached)  $($G.Dot)  Uncached = first time a name is requested" -ForegroundColor DarkGray
    Write-Host '  Choice: 70% median + 30% uncached. On a tie (up to 5 ms) prefers Cloudflare, then Google.' -ForegroundColor DarkGray

    # Decision
    $choice = $null
    $curLocal  = @($rows | Where-Object { $_.IsCurrent -and $_.IsLocal })
    $curPreset = @($valid | Where-Object { $_.IsCurrent -and $_.Preset }) | Sort-Object Score | Select-Object -First 1
    $publicRows = @($rows | Where-Object { $_.Preset })
    Write-Host ''
    if (-not $winner -and $publicRows.Count -gt 0 -and @($publicRows | Where-Object { $_.Dead }).Count -eq $publicRows.Count) {
        Write-Warn2 'Public DNS servers do not respond on this network: port 53 is probably blocked (common on school or office networks).'
        Write-Info  'Keeping the current DNS. Changing it now would cut your internet.' 4
    } elseif (-not $winner) {
        Write-Warn2 'No public DNS answered reliably (too many failures). Keeping the current one.'
    } elseif ($winner.IsCurrent) {
        Write-Ok "You already use $($winner.Preset), the best one here. Leaving it as is."
    } elseif ($curPreset -and $curPreset.Score - $winner.Score -lt $margin) {
        # Already on a public DNS and the difference is small: not worth switching between public ones.
        Write-Ok "You already use $($curPreset.Preset) and $($winner.Preset) is only $(Format-Num ($curPreset.Score - $winner.Score)) ms better. Leaving it as is."
    } else {
        $choice = $winner.Preset
        if ($curLocal.Count -gt 0) {
            $l = $curLocal[0]
            $uncText = if ($null -ne $l.UncMedian) { "$(Format-Num $l.UncMedian) ms" } else { 'no response' }
            Write-Info "The current DNS ($($l.Ip)) is the router / local network: it only forwards to your ISP's DNS."
            Write-Info "Its low median is local cache; a new name took $uncText ($($winner.Preset) took $(Format-Num $winner.UncMedian) ms)." 4
        }
        Write-Warn2 "Best DNS: $($winner.Preset) (median $(Format-Num $winner.Median) ms, uncached $(Format-Num $winner.UncMedian) ms)."
        $v4 = @($DnsPresets[$choice] | Where-Object { $_ -notmatch ':' }) -join ', '
        $v6 = @($DnsPresets[$choice] | Where-Object { $_ -match ':' }) -join ', '
        Write-Info "Apply sets on every adapter  IPv4: $v4" 4
        Write-Host "                                   IPv6: $v6" -ForegroundColor Gray
    }
    Write-Info 'Note: DNS speeds up opening sites and connecting to services. It does not change in-game ping.'

    return [pscustomobject]@{ Choice = $choice }
}

# ---------------------------------------------------------------- adapter state

function Show-AdapterState {
    # Shows the state and returns how many tweaks Apply would still make.
    Write-Title 'Current state'
    $pending = 0

    $wifiPlan = Get-WifiPowerPlan
    if ($wifiPlan) {
        Write-Seg "  $($G.Node) " Cyan
        Write-Host 'Windows power plan' -ForegroundColor White
        foreach ($pair in @(@('Wi-Fi when plugged in', $wifiPlan.AC), @('Wi-Fi on battery', $wifiPlan.DC))) {
            if ($pair[1] -eq 0) {
                Write-KV $pair[0] (Format-WifiPower $pair[1]) 'ok'
            } else {
                Write-KV $pair[0] (Format-WifiPower $pair[1]) 'warn' 'Maximum performance'
                $pending++
            }
        }
    }

    $adapters = @(Get-TargetAdapters)
    if ($adapters.Count -eq 0) { Write-Warn2 'No physical adapter found.'; return $pending }

    foreach ($a in $adapters) {
        Write-AdapterHeader $a
        if ([string]$a.Status -eq 'Up') { Write-KV 'Speed' ([string]$a.LinkSpeed) }
        Write-KV 'Driver' ("{0} ({1})" -f $a.DriverVersion, $a.DriverDate)

        $classKey = Get-AdapterClassKey ([string]$a.InterfaceGuid)
        if ($classKey) {
            try {
                $pnp = Get-PnPCapabilities $classKey.PSPath
                if ($pnp -eq $PnPCapOff) {
                    Write-KV 'Windows may turn it off' (Format-PnPCap $pnp) 'ok'
                } else {
                    Write-KV 'Windows may turn it off' (Format-PnPCap $pnp) 'warn' 'no'
                    $pending++
                }
            } catch { }
        }

        try {
            $rsc = Get-NetAdapterRsc -Name $a.Name -ErrorAction Stop
            if ($rsc.IPv4Enabled -or $rsc.IPv6Enabled) {
                Write-KV 'RSC' ("on (IPv4 {0}, IPv6 {1})" -f $rsc.IPv4Enabled, $rsc.IPv6Enabled) 'warn' 'off'
                $pending++
            } else {
                Write-KV 'RSC' 'off' 'ok'
            }
        } catch { }

        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue)
        foreach ($p in $props) {
            foreach ($r in $Rules) {
                if ($p.DisplayName -match $r.Display) {
                    $target = @($p.ValidDisplayValues) | Where-Object { $_ -match $r.Want } | Select-Object -First 1
                    if (-not $target) {
                        Write-KV $p.DisplayName $p.DisplayValue
                    } elseif ($p.DisplayValue -eq $target) {
                        Write-KV $p.DisplayName $p.DisplayValue 'ok'
                    } else {
                        Write-KV $p.DisplayName $p.DisplayValue 'warn' $target
                        $pending++
                    }
                    break
                }
            }
        }

        try {
            $dnsNow = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction Stop |
                ForEach-Object { $_.ServerAddresses }) -join ', '
            if ($dnsNow) { Write-KV 'DNS' $dnsNow }
        } catch { }
    }

    Write-Host ''
    Write-Seg '  '; Write-Seg "$($G.Ok) already optimized" Green; Write-Seg '   '
    Write-Seg "$($G.Warn) Apply changes it" Yellow; Write-Host "   $($G.Arrow) new value" -ForegroundColor DarkGray
    return $pending
}

# ---------------------------------------------------------------- backup

function Get-DnsBackup($Adapter) {
    $guid = $Adapter.InterfaceGuid
    $v4 = ''
    $v6 = ''
    try { $v4 = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -Name NameServer -ErrorAction Stop).NameServer } catch { }
    try { $v6 = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$guid" -Name NameServer -ErrorAction Stop).NameServer } catch { }
    return [pscustomobject]@{ IPv4 = [string]$v4; IPv6 = [string]$v6 }
}

function Save-Backup($Data) {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -WhatIf:$false | Out-Null }
    $file = Join-Path $BackupDir "backup-$Stamp.json"
    $Data | ConvertTo-Json -Depth 6 | Out-File -FilePath $file -Encoding UTF8
    return $file
}

# ---------------------------------------------------------------- apply

function Invoke-Apply {
    Assert-Admin

    $before = $null
    if (-not $SkipTest) { $before = Invoke-NetTest 'Test before the tweaks' }

    [void](Show-AdapterState)

    # DNS: Auto = test and use the fastest (if worth it); Keep = do not touch; a name = force that one.
    $dnsChoice = $null
    switch ($Dns) {
        'Keep'  { }
        'Auto'  { $dnsChoice = (Invoke-DnsBenchmark).Choice }
        default {
            # Forced: first check that this DNS answers on this network (some networks block external DNS).
            $okCount = 0
            foreach ($d in @('google.com', 'microsoft.com', 'cloudflare.com')) {
                $res = Measure-DnsQuery $DnsPresets[$Dns][0] $d
                if ($res -and ($res.RCode -eq 0 -or $res.RCode -eq 3)) { $okCount++ }
            }
            if ($okCount -ge 2) {
                $dnsChoice = $Dns
            } else {
                Write-Host ''
                Write-Warn2 "The $Dns DNS ($($DnsPresets[$Dns][0])) does not answer on this network. Not changing DNS, or you would lose internet."
            }
        }
    }

    $adapters = @(Get-TargetAdapters)
    if ($adapters.Count -eq 0) { throw 'No physical adapter found.' }

    $backup = [ordered]@{
        Created  = (Get-Date).ToString('s')
        Tool     = "NetTune $Version"
        Computer = $env:COMPUTERNAME
        WifiPowerPlan = $null
        Adapters = @()
    }

    Write-Title 'Applying tweaks'
    $file = $null

    # The backup is saved in the finally block: if a tweak fails halfway, what was already changed is recorded.
    try {

    # 0) Wi-Fi power saving in the Windows power plan (plugged in and on battery)
    $wifiPlan = Get-WifiPowerPlan
    if ($wifiPlan) {
        Write-Seg "  $($G.Node) " Cyan
        Write-Host 'Windows power plan' -ForegroundColor White
        if ($wifiPlan.AC -ne 0 -or $wifiPlan.DC -ne 0) {
            $backup.WifiPowerPlan = [ordered]@{ Scheme = $wifiPlan.Scheme; AC = $wifiPlan.AC; DC = $wifiPlan.DC }
            $from = "plugged in: $(Format-WifiPower $wifiPlan.AC), battery: $(Format-WifiPower $wifiPlan.DC)"
            if ($PSCmdlet.ShouldProcess('Power plan', "Wi-Fi power saving: $from -> Maximum performance")) {
                Set-WifiPowerPlan -Scheme $wifiPlan.Scheme -AC 0 -DC 0
            }
            Write-Change 'Wi-Fi power saving' $from 'Maximum performance'
        } else {
            Write-Info 'Wi-Fi power saving: already at maximum performance' 4
        }
    }

    foreach ($a in $adapters) {
        Write-AdapterHeader $a

        $entry = [ordered]@{
            Name                 = $a.Name
            InterfaceDescription = $a.InterfaceDescription
            InterfaceGuid        = [string]$a.InterfaceGuid
            PnPCapabilities      = $null
            Rsc                  = $null
            Advanced             = @()
            Dns                  = $null
        }
        # Goes into the backup right away (it is a reference, the changes below end up there).
        $backup.Adapters += $entry
        $changed = $false

        # 1) Let Windows turn the adapter off to save power
        #    -> PnPCapabilities = 24 in the adapter's key (only takes effect after a PC restart)
        $classKey = Get-AdapterClassKey ([string]$a.InterfaceGuid)
        if (-not $classKey) {
            Write-Warn2 "Power management: could not find the adapter's registry key (NetCfgInstanceId = $($a.InterfaceGuid))" 4
        } else {
            $old = $null
            $readOk = $true
            try { $old = Get-PnPCapabilities $classKey.PSPath } catch {
                $readOk = $false
                Write-Warn2 "Power management: could not read PnPCapabilities: $($_.Exception.Message)" 4
            }
            if ($readOk -and $old -eq $PnPCapOff) {
                Write-Info "Windows may turn it off: already no (PnPCapabilities = $PnPCapOff)" 4
            } elseif ($readOk) {
                $existed = ($null -ne $old)
                $entry.PnPCapabilities = [ordered]@{ ClassKey = $classKey.PSChildName; Existed = $existed; Value = $old }
                $oldText = if ($existed) { [string]$old } else { 'not set' }
                $msg = "PnPCapabilities (key $($classKey.PSChildName)): $oldText -> $PnPCapOff"
                if ($PSCmdlet.ShouldProcess($a.Name, $msg)) {
                    try {
                        New-ItemProperty -Path $classKey.PSPath -Name PnPCapabilities -PropertyType DWord -Value $PnPCapOff -Force -ErrorAction Stop | Out-Null
                    } catch {
                        Write-Warn2 "Power management: failed to write PnPCapabilities: $($_.Exception.Message)" 4
                    }

                    # Confirm by reading it back: only report OK if it really is 24.
                    $now = $null
                    try { $now = Get-PnPCapabilities $classKey.PSPath } catch {
                        Write-Warn2 "Power management: could not confirm the value: $($_.Exception.Message)" 4
                    }
                    if ($now -eq $PnPCapOff) {
                        Write-Change 'Windows may turn it off' (Format-PnPCap $old) (Format-PnPCap $now) 'restart the PC'
                        $script:RebootNeeded = $true
                    } else {
                        Write-Warn2 "Power management: PnPCapabilities ended up as '$(Format-PnPCap $now)' (expected $PnPCapOff)" 4
                    }
                } else {
                    Write-Change 'Windows may turn it off' (Format-PnPCap $old) (Format-PnPCap $PnPCapOff) 'restart the PC'
                }
            }
        }

        # 2) RSC
        try {
            $rsc = Get-NetAdapterRsc -Name $a.Name -ErrorAction Stop
            if ($rsc.IPv4Enabled -or $rsc.IPv6Enabled) {
                $entry.Rsc = [ordered]@{ IPv4 = [bool]$rsc.IPv4Enabled; IPv6 = [bool]$rsc.IPv6Enabled }
                if ($PSCmdlet.ShouldProcess($a.Name, 'Disable RSC')) {
                    Disable-NetAdapterRsc -Name $a.Name -NoRestart -ErrorAction Stop
                    $changed = $true
                }
                Write-Change 'RSC' 'on' 'off'
            } else {
                Write-Info 'RSC: already off' 4
            }
        } catch {
            Write-Info 'RSC: not supported by this adapter' 4
        }

        # 3) Driver advanced properties
        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue)
        foreach ($p in $props) {
            $rule = $null
            foreach ($r in $Rules) { if ($p.DisplayName -match $r.Display) { $rule = $r; break } }
            if (-not $rule) { continue }

            $valid = @($p.ValidDisplayValues)
            if ($valid.Count -eq 0) { continue }
            $target = $valid | Where-Object { $_ -match $rule.Want } | Select-Object -First 1
            if (-not $target) {
                Write-Warn2 "$($p.DisplayName): could not find an 'off' value (options: $($valid -join ' | '))" 4
                continue
            }
            if ($p.DisplayValue -eq $target) {
                Write-Info "$($p.DisplayName): already '$target'" 4
                continue
            }

            $entry.Advanced += [ordered]@{
                DisplayName     = $p.DisplayName
                RegistryKeyword = $p.RegistryKeyword
                RegistryValue   = @($p.RegistryValue)
                DisplayValue    = $p.DisplayValue
            }
            if ($PSCmdlet.ShouldProcess($a.Name, "$($p.DisplayName): '$($p.DisplayValue)' -> '$target'")) {
                Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -DisplayValue $target -NoRestart -ErrorAction Stop
                $changed = $true
            }
            Write-Change $p.DisplayName $p.DisplayValue $target
        }

        # 4) DNS: IPv4 and IPv6 set by hand, each family separately, and confirmed by reading them back.
        if ($dnsChoice) {
            $want4 = @($DnsPresets[$dnsChoice] | Where-Object { $_ -notmatch ':' })
            $want6 = @($DnsPresets[$dnsChoice] | Where-Object { $_ -match ':' })
            $now4  = @(Get-AdapterDnsList $a.ifIndex 'IPv4')
            $now6  = @(Get-AdapterDnsList $a.ifIndex 'IPv6')
            $v6On = $true
            try { $v6On = [bool](Get-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction Stop).Enabled } catch { }

            $need4 = -not (Test-SameList $now4 $want4)
            $need6 = $v6On -and -not (Test-SameList $now6 $want6)
            if (-not $need4 -and -not $need6) {
                Write-Info "DNS: already $dnsChoice" 4
            } else {
                $entry.Dns = Get-DnsBackup $a
                foreach ($fam in @(@('IPv4', $need4, $now4, $want4), @('IPv6', $need6, $now6, $want6))) {
                    if (-not $fam[1]) { continue }
                    $from = if (@($fam[2]).Count -gt 0) { (@($fam[2]) | Select-Object -First 2) -join ', ' } else { 'automatic' }
                    $to = "$dnsChoice (" + (@($fam[3]) -join ', ') + ')'
                    if ($PSCmdlet.ShouldProcess($a.Name, "DNS $($fam[0]) -> $to")) {
                        $after = @(Set-AdapterDnsFamily $a $fam[0] @($fam[3]))
                        if (Test-SameList $after @($fam[3])) {
                            Write-Change "DNS $($fam[0])" $from $to
                        } else {
                            $got = if ($after.Count -gt 0) { $after -join ', ' } else { 'automatic' }
                            Write-Warn2 "DNS $($fam[0]): was not applied (now: $got)" 4
                        }
                    } else {
                        Write-Change "DNS $($fam[0])" $from $to
                    }
                }
            }
            if (-not $v6On) { Write-Info 'DNS IPv6: IPv6 is disabled on this adapter, only IPv4 was needed.' 4 }
        }

        # Restart the adapter only once, to apply everything
        if ($changed -and $a.Status -eq 'Up') {
            if ($PSCmdlet.ShouldProcess($a.Name, 'Restart the adapter to apply')) {
                Write-Info 'Restarting the adapter (the connection drops for a few seconds)...' 4
                Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
            }
        } elseif ($changed) {
            Write-Info 'Adapter disconnected: the changes apply when you connect it.' 4
        }
    }

    } finally {
        if (-not $WhatIfPreference) {
            $file = Save-Backup $backup
            Write-Host ''
            Write-Ok "Backup saved: backups\$(Split-Path $file -Leaf)"
        }
    }

    if ($WhatIfPreference) {
        $n = $script:ChangeCount
        $lines = @()
        if ($n -gt 0) { $lines += ,@($G.Sim, 'Cyan', "$n change(s) would be applied") }
        else          { $lines += ,@($G.Ok, 'Green', 'Nothing to change: everything is already optimized') }
        $lines += ,@($G.Info, 'DarkGray', 'Nothing was changed (-WhatIf).')
        $lines += ,@($G.Arrow, 'Cyan', 'To apply: .\NetTune.ps1 -Mode Apply')
        Write-Box 'Simulation' $lines 'DarkYellow'
        return
    }

    if ($dnsChoice) { Clear-DnsClientCache -ErrorAction SilentlyContinue }

    Write-Host ''
    Write-Info 'Waiting for the network to come back...'
    if (-not (Wait-Network 40)) { Write-Warn2 'The network took a while to come back. Check the connection before the test.' }
    Start-Sleep -Seconds 3

    if (-not $SkipTest) {
        $after = Invoke-NetTest 'Test after the tweaks'
        if ($before) { Show-Comparison $before $after }
    }

    $n = $script:ChangeCount
    $lines = @()
    if ($n -gt 0) { $lines += ,@($G.Ok, 'Green', "$n change(s) applied") }
    else          { $lines += ,@($G.Ok, 'Green', 'Nothing to change: everything was already optimized') }
    if ($file)    { $lines += ,@($G.Info, 'DarkGray', "Backup: backups\$(Split-Path $file -Leaf)") }
    $lines += ,@($G.Arrow, 'Cyan', 'To undo: .\NetTune.ps1 -Mode Revert')
    if ($script:RebootNeeded) {
        $lines += ,@($G.Warn, 'Yellow', 'RESTART THE PC for the power management change to take effect.')
        $lines += ,@(' ', 'Gray', 'The "after" test does not include that change yet.')
    }
    $lines += ,@($G.Info, 'DarkGray', 'Driver updates can restore the factory values.')
    $lines += ,@(' ', 'Gray', 'If the spikes come back, run Apply again.')
    Write-Box 'Done' $lines 'DarkGreen'
}

# ---------------------------------------------------------------- revert

function Invoke-Revert {
    Assert-Admin

    $file = $BackupFile
    if (-not $file) {
        $latest = Get-ChildItem -Path $BackupDir -Filter 'backup-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw "No backups in $BackupDir" }
        $file = $latest.FullName
    }
    if (-not (Test-Path $file)) { throw "Backup not found: $file" }

    Write-Title 'Restoring backup'
    $data = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $created = if ($data.PSObject.Properties['Created']) { $data.Created } else { '?' }
    $tool    = if ($data.PSObject.Properties['Tool'])    { $data.Tool }    else { '?' }
    Write-Info "File: $(Split-Path $file -Leaf)  $($G.Dot)  created: $created  $($G.Dot)  $tool"

    # Old backups (1.0.0) do not have this property; with StrictMode it has to be checked like this.
    $planProp = $data.PSObject.Properties['WifiPowerPlan']
    if ($planProp -and $planProp.Value) {
        $p = $planProp.Value
        Write-Host ''
        Write-Seg "  $($G.Node) " Cyan
        Write-Host 'Windows power plan' -ForegroundColor White
        $to = "plugged in: $(Format-WifiPower $p.AC), battery: $(Format-WifiPower $p.DC)"
        if ($PSCmdlet.ShouldProcess('Power plan', "Wi-Fi power saving -> $to")) {
            try {
                Set-WifiPowerPlan -Scheme $p.Scheme -AC $p.AC -DC $p.DC
                Write-Change 'Wi-Fi power saving' 'Maximum performance' $to
            } catch { Write-Warn2 "Power plan: $($_.Exception.Message)" 4 }
        }
    }

    foreach ($e in @($data.Adapters)) {
        $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $e.InterfaceGuid } | Select-Object -First 1
        if (-not $a) { $a = Get-NetAdapter -Name $e.Name -ErrorAction SilentlyContinue }
        if (-not $a) { Write-Host ''; Write-Warn2 "Adapter '$($e.Name)' not found, skipping."; continue }

        Write-AdapterHeader $a
        $changed = $false

        foreach ($adv in @($e.Advanced)) {
            if (-not $adv) { continue }
            if ($PSCmdlet.ShouldProcess($a.Name, "$($adv.DisplayName) -> '$($adv.DisplayValue)'")) {
                try {
                    Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $adv.RegistryKeyword -RegistryValue @($adv.RegistryValue) -NoRestart -ErrorAction Stop
                    Write-Change $adv.DisplayName 'tweaked' $adv.DisplayValue
                    $changed = $true
                } catch {
                    Write-Warn2 "$($adv.DisplayName): $($_.Exception.Message)" 4
                }
            }
        }

        if ($e.Rsc) {
            if ($PSCmdlet.ShouldProcess($a.Name, 'Restore RSC')) {
                try {
                    if ($e.Rsc.IPv4) { Enable-NetAdapterRsc -Name $a.Name -IPv4 -NoRestart -ErrorAction Stop }
                    if ($e.Rsc.IPv6) { Enable-NetAdapterRsc -Name $a.Name -IPv6 -NoRestart -ErrorAction Stop }
                    Write-Change 'RSC' 'off' 'on'
                    $changed = $true
                } catch { Write-Warn2 "RSC: $($_.Exception.Message)" 4 }
            }
        }

        # Power management: PnPCapabilities. Old backups (PowerManagement) are ignored on purpose:
        # that version never managed to change anything (Set-NetAdapterPowerManagement has no such parameter).
        $pnpProp = $e.PSObject.Properties['PnPCapabilities']
        if ($pnpProp -and $pnpProp.Value) {
            $pc = $pnpProp.Value
            $classKey = Get-AdapterClassKey ([string]$a.InterfaceGuid)
            if (-not $classKey) {
                Write-Warn2 "Power management: could not find the adapter's registry key (it was $($pc.ClassKey))" 4
            } else {
                $desc = if ($pc.Existed) { "PnPCapabilities (key $($classKey.PSChildName)) -> $($pc.Value)" } else { "PnPCapabilities (key $($classKey.PSChildName)) -> delete (was not set)" }
                if ($PSCmdlet.ShouldProcess($a.Name, $desc)) {
                    try {
                        if ($pc.Existed) {
                            New-ItemProperty -Path $classKey.PSPath -Name PnPCapabilities -PropertyType DWord -Value ([int]$pc.Value) -Force -ErrorAction Stop | Out-Null
                        } elseif ($null -ne (Get-PnPCapabilities $classKey.PSPath)) {
                            Remove-ItemProperty -Path $classKey.PSPath -Name PnPCapabilities -ErrorAction Stop
                        }
                        $restored = if ($pc.Existed) { $pc.Value } else { $null }
                        Write-Change 'Windows may turn it off' (Format-PnPCap $PnPCapOff) (Format-PnPCap $restored) 'restart the PC'
                        $script:RebootNeeded = $true
                    } catch { Write-Warn2 "Power management: $($_.Exception.Message)" 4 }
                }
            }
        }

        if ($e.Dns) {
            # Each family goes back to what it was: the old static list, or automatic (DHCP) if there was none.
            $old4 = @(([string]$e.Dns.IPv4) -split '[,\s]+' | Where-Object { $_ })
            $old6 = @(([string]$e.Dns.IPv6) -split '[,\s]+' | Where-Object { $_ })
            foreach ($fam in @(@('IPv4', $old4), @('IPv6', $old6))) {
                $to = if (@($fam[1]).Count -gt 0) { @($fam[1]) -join ', ' } else { 'automatic (DHCP)' }
                if ($PSCmdlet.ShouldProcess($a.Name, "DNS $($fam[0]) -> $to")) {
                    try {
                        $after = @(Set-AdapterDnsFamily $a $fam[0] @($fam[1]))
                        if (@($fam[1]).Count -gt 0 -and -not (Test-SameList $after @($fam[1]))) {
                            Write-Warn2 "DNS $($fam[0]): was not restored (now: $($after -join ', '))" 4
                        } else {
                            Write-Change "DNS $($fam[0])" 'tweaked' $to
                        }
                    } catch { Write-Warn2 "DNS $($fam[0]): $($_.Exception.Message)" 4 }
                }
            }
        }

        if ($changed -and $a.Status -eq 'Up' -and $PSCmdlet.ShouldProcess($a.Name, 'Restart the adapter')) {
            Write-Info 'Restarting the adapter (the connection drops for a few seconds)...' 4
            Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Clear-DnsClientCache -ErrorAction SilentlyContinue
    if (-not $WhatIfPreference) {
        Write-Host ''
        Write-Info 'Waiting for the network to come back...'
        [void](Wait-Network 40)
    }

    $n = $script:ChangeCount
    $lines = @()
    if ($WhatIfPreference) {
        $lines += ,@($G.Sim, 'Cyan', "$n setting(s) would be restored")
        $lines += ,@($G.Info, 'DarkGray', 'Nothing was changed (-WhatIf).')
    } elseif ($n -gt 0) {
        $lines += ,@($G.Ok, 'Green', "$n setting(s) restored")
    } else {
        $lines += ,@($G.Info, 'DarkGray', 'This backup had nothing to restore.')
    }
    if ($script:RebootNeeded -and -not $WhatIfPreference) {
        $lines += ,@($G.Warn, 'Yellow', 'RESTART THE PC for power management to go back to the original.')
    }
    Write-Box 'Backup restored' $lines 'DarkMagenta'
}

# ---------------------------------------------------------------- main

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -WhatIf:$false | Out-Null }
$transcript = Join-Path $LogDir "nettune-$Mode-$Stamp.log"
try { Start-Transcript -Path $transcript -WhatIf:$false -ErrorAction Stop | Out-Null } catch { $transcript = $null }
$clock = [Diagnostics.Stopwatch]::StartNew()

try {
    Write-Banner
    if ($script:ArgError) { throw $script:ArgError }
    switch ($Mode) {
        'Test' {
            $pending = Show-AdapterState
            [void](Invoke-NetTest 'Connection test')
            $dnsChoice = $null
            if ($Dns -ne 'Keep') {
                $dnsChoice = (Invoke-DnsBenchmark).Choice
                if ($dnsChoice) { $pending++ }
            }
            $lines = @()
            if ($dnsChoice) {
                $lines += ,@($G.Star, 'Green', "Best DNS: $dnsChoice (Apply sets it, IPv4 and IPv6)")
            }
            if ($pending -gt 0) {
                $lines += ,@($G.Warn, 'Yellow', "$pending tweak(s) to do (marked with $($G.Warn) above)")
                $lines += ,@($G.Arrow, 'Cyan', 'Dry run: .\NetTune.ps1 -Mode Apply -WhatIf')
                $lines += ,@($G.Arrow, 'Cyan', 'Apply:   .\NetTune.ps1 -Mode Apply   (as admin)')
            } else {
                $lines += ,@($G.Ok, 'Green', 'The adapters are already optimized. Nothing to do.')
            }
            Write-Box 'Summary' $lines
        }
        'Apply'  { Invoke-Apply }
        'Revert' { Invoke-Revert }
    }
} catch {
    Write-Host ''
    Write-Seg "  $($G.Bad) ERROR  " Red
    Write-Host $_.Exception.Message -ForegroundColor White
    exit 1
} finally {
    $el = $clock.Elapsed
    $took = if ($el.TotalMinutes -ge 1) { '{0}m {1:00}s' -f [int][math]::Floor($el.TotalMinutes), $el.Seconds } else { '{0}s' -f [int]$el.TotalSeconds }
    if ($transcript) {
        try { Stop-Transcript -WhatIf:$false | Out-Null } catch { }
    }
    Write-Host ''
    Write-Seg "  Finished in $took" DarkGray
    if ($transcript) { Write-Seg "  $($G.Dot)  log: logs\$(Split-Path $transcript -Leaf)" DarkGray }
    Write-Host ''
    Write-Host ''
}
