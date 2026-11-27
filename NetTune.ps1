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
      - DNS -> tests the current one against Cloudflare, Google, Quad9 and OpenDNS and applies the
        fastest, only if it is clearly better (DNS does NOT change in-game ping, only how fast names resolve)

    TCP Optimizer-style tweaks (skip them with -NoTcp). The README says what each one really changes:
      - TCP globals: heuristics off, auto-tuning normal, timestamps off, initial RTO 2000,
        max SYN retransmissions 2, non-SACK RTT resiliency off. CUBIC, ECN and MinRto are left alone.
      - Offloads: RSS on, RSC off, packet coalescing off, checksum offload on, LSO off
      - Registry: Tcpip (DefaultTTL, MaxUserPort, TcpTimedWaitDelay), Nagle per adapter,
        MMCSS (NetworkThrottlingIndex, SystemResponsiveness = 10), ServiceProvider priorities,
        Psched, QoS, IE max connections, LargeSystemCache = 0. Takes effect after a restart.

    MTU (skip it with -NoMtu): finds the largest MTU of the current network with "Don't Fragment"
    pings to 1.1.1.1, 8.8.8.8 and 9.9.9.9 and sets it only if it is below 1500.

.PARAMETER Mode
    Test   : only measures and shows the adapter state (no admin needed, changes nothing). Default.
    Apply  : measures, backs up, applies the tweaks, measures again and compares. Needs admin
             (except with -WhatIf, the dry run).
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

.PARAMETER NoTcp
    In Apply mode, skips the TCP Optimizer-style tweaks (TCP globals, offloads, registry, Nagle).

.PARAMETER NoMtu
    Skips the MTU test (and, in Apply, setting the MTU).

.PARAMETER AfterRestart
    With -Mode Test. Started once by the scheduled task that Apply creates when you answer "y" to
    "Restart now?": waits for the network, lets startup programs settle, tests and compares with the
    "before" test saved by Apply. You do not need to use it yourself.

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

    [switch]$NoTcp,

    [switch]$NoMtu,

    # Used by the one-time scheduled task after the restart that Apply offers.
    [switch]$AfterRestart,

    [switch]$Ascii
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Load the network modules now with WhatIf off: loaded later under -WhatIf, NetTCPIP prints
# "What if: New Alias gip" while it defines its aliases.
$savedWhatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module NetAdapter, NetTCPIP, DnsClient -ErrorAction SilentlyContinue
$WhatIfPreference = $savedWhatIf

$Version   = '1.7.1'
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

# Rules for the adapters' advanced properties, by RegistryKeyword: the DisplayName changes with the
# Windows language, the keyword does not. Want = the registry value for "off" / "lowest" (0 in all of
# these drivers: Intel, Realtek, MediaTek...).
$Rules = @(
    @{ Label = 'Adapter power saving';      Keyword = '^\*?(PowerSavingMode|PowerSaveMode|PowerSaving|LowPowerEnable|PSMode)$';            Want = '0' }
    @{ Label = 'Roaming aggressiveness';    Keyword = '^\*?(RoamAggressiveness|RoamingAggressiveness|RoamNeedIndicateTh)$';               Want = '0' }
    @{ Label = 'Energy-Efficient Ethernet'; Keyword = '^\*?(EEE|AdvancedEEE|EEELinkAdvertisement|EnableGreenEthernet|GreenEthernet)$';    Want = '0' }
    @{ Label = 'USB selective suspend';     Keyword = '^\*?SelectiveSuspend$';                                                            Want = '0' }
)

# Standard keywords: if the driver does not expose them, Windows cannot change that offload.
$KwLso      = '^\*Lso(V1IPv4|V2IPv4|V2IPv6)$'
$KwChecksum = '^\*(IP|TCP|UDP)ChecksumOffloadIPv[46]$'
$ChecksumProps = [ordered]@{
    IpIPv4Enabled = 'IP IPv4'; TcpIPv4Enabled = 'TCP IPv4'; TcpIPv6Enabled = 'TCP IPv6'; UdpIPv4Enabled = 'UDP IPv4'; UdpIPv6Enabled = 'UDP IPv6'
}

# ---------------------------------------------------------------- TCP Optimizer-style tweaks (-NoTcp skips them)
# Global TCP settings, in the template Windows uses for internet traffic. Heuristics first: changed
# after auto-tuning, they can override it. Congestion provider (CUBIC), ECN and MinRto are left alone
# (MinRto is read-only on Windows 10/11). Chimney, NetDMA and DCA are obsolete and not included.
$TcpTemplate = 'Internet'
$TcpGlobalTweaks = @(
    @{ Name = 'ScalingHeuristics';     Label = 'Scaling heuristics';         Want = 'Disabled'; Netsh = 'heuristics' }
    @{ Name = 'AutoTuningLevelLocal';  Label = 'Receive window auto-tuning'; Want = 'Normal';   Netsh = 'autotuninglevel' }
    @{ Name = 'Timestamps';            Label = 'Timestamps';                 Want = 'Disabled'; Netsh = 'timestamps' }
    @{ Name = 'InitialRtoMs';          Label = 'Initial RTO (ms)';           Want = 2000;       Netsh = 'initialRto' }
    @{ Name = 'MaxSynRetransmissions'; Label = 'Max SYN retransmissions';    Want = 2;          Netsh = 'maxsynretransmissions' }
    @{ Name = 'NonSackRttResiliency';  Label = 'Non-SACK RTT resiliency';    Want = 'Disabled'; Netsh = 'nonsackrttresiliency' }
)
$OffloadGlobalTweaks = @(
    @{ Name = 'ReceiveSideScaling';       Label = 'RSS (global)';      Want = 'Enabled';  Netsh = 'rss' }
    @{ Name = 'ReceiveSegmentCoalescing'; Label = 'RSC (global)';      Want = 'Disabled'; Netsh = 'rsc' }
    @{ Name = 'PacketCoalescingFilter';   Label = 'Packet coalescing'; Want = 'Disabled'; Netsh = $null }
)

# Registry (HKLM). Takes effect after a restart.
$TcpipKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
$MmcssKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$SvcProvKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider'
$IeFeatKey = 'HKLM:\SOFTWARE\Microsoft\Internet Explorer\Main\FeatureControl'
$RegTweaks = @(
    @{ Label = 'DefaultTTL';             Path = $TcpipKey;   Name = 'DefaultTTL';             Type = 'DWord';  Value = 64 }
    @{ Label = 'MaxUserPort';            Path = $TcpipKey;   Name = 'MaxUserPort';            Type = 'DWord';  Value = 65534 }
    @{ Label = 'TcpTimedWaitDelay';      Path = $TcpipKey;   Name = 'TcpTimedWaitDelay';      Type = 'DWord';  Value = 30 }
    # 0xffffffff = network throttling off. As a signed DWORD that is -1.
    @{ Label = 'NetworkThrottlingIndex'; Path = $MmcssKey;   Name = 'NetworkThrottlingIndex'; Type = 'DWord';  Value = -1; Hex = $true }
    # 10, not 0: Microsoft documents that below 10 Windows uses 20.
    @{ Label = 'SystemResponsiveness';   Path = $MmcssKey;   Name = 'SystemResponsiveness';   Type = 'DWord';  Value = 10 }
    @{ Label = 'LocalPriority';          Path = $SvcProvKey; Name = 'LocalPriority';          Type = 'DWord';  Value = 4 }
    @{ Label = 'HostsPriority';          Path = $SvcProvKey; Name = 'HostsPriority';          Type = 'DWord';  Value = 5 }
    @{ Label = 'DnsPriority';            Path = $SvcProvKey; Name = 'DnsPriority';            Type = 'DWord';  Value = 6 }
    @{ Label = 'NetbtPriority';          Path = $SvcProvKey; Name = 'NetbtPriority';          Type = 'DWord';  Value = 7 }
    @{ Label = 'Psched NonBestEffortLimit'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'; Name = 'NonBestEffortLimit'; Type = 'DWord'; Value = 0 }
    @{ Label = 'QoS "Do not use NLA"';   Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS'; Name = 'Do not use NLA'; Type = 'String'; Value = '1' }
    @{ Label = 'MaxConn/1.0 explorer';   Path = "$IeFeatKey\FEATURE_MAXCONNECTIONSPER1_0SERVER"; Name = 'explorer.exe'; Type = 'DWord'; Value = 10 }
    @{ Label = 'MaxConn/1.0 iexplore';   Path = "$IeFeatKey\FEATURE_MAXCONNECTIONSPER1_0SERVER"; Name = 'iexplore.exe'; Type = 'DWord'; Value = 10 }
    @{ Label = 'MaxConn/1.1 explorer';   Path = "$IeFeatKey\FEATURE_MAXCONNECTIONSPERSERVER";    Name = 'explorer.exe'; Type = 'DWord'; Value = 10 }
    @{ Label = 'MaxConn/1.1 iexplore';   Path = "$IeFeatKey\FEATURE_MAXCONNECTIONSPERSERVER";    Name = 'iexplore.exe'; Type = 'DWord'; Value = 10 }
    @{ Label = 'LargeSystemCache';       Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; Name = 'LargeSystemCache'; Type = 'DWord'; Value = 0 }
)
# Nagle, in Tcpip\Parameters\Interfaces\{InterfaceGuid} of each physical adapter.
$NagleTweaks = @(
    @{ Name = 'TcpAckFrequency'; Type = 'DWord'; Value = 1 }
    @{ Name = 'TCPNoDelay';      Type = 'DWord'; Value = 1 }
    @{ Name = 'TcpDelAckTicks';  Type = 'DWord'; Value = 0 }
)

# ---------------------------------------------------------------- MTU test (-NoMtu skips it)
$MtuTargets    = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
$MtuMinPayload = 1172   # MTU 1200 (payload + 20 IP + 8 ICMP)

# ---------------------------------------------------------------- scheduled tasks
# Nagle keeper: Wi-Fi keeps the TCP/IP settings of the current network in the adapter's key and
# Windows rebuilds that key when it connects to another network, which wipes the Nagle values.
# This SYSTEM task writes them again on every "network connected" event (no window).
$NagleTask   = @{ Path = '\NetTune\'; Name = 'NetTune Nagle keeper' }
# After restart: runs "-Mode Test -AfterRestart" once at the next logon, then deletes itself.
$AfterTask   = @{ Path = '\NetTune\'; Name = 'NetTune after restart' }
$PendingFile = Join-Path $LogDir 'pending-after-restart.json'

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
$script:RegChanged   = $false
$script:RestartNow   = $false
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

function Write-Fail([string]$Label, [string]$Text) {
    # A change that did not stick (read back after applying).
    Write-Seg "    $($G.Bad) " Red
    Write-Seg $Label White
    Write-Host "  $Text" -ForegroundColor Red
}

function Write-Unsupported([string]$Label, [string]$Text = 'not supported on this Windows') {
    # Read-only on this Windows build / driver: reported, and the script goes on.
    Write-Seg "    $($G.Warn) " Yellow
    Write-Seg $Label White
    Write-Host "  $Text" -ForegroundColor Yellow
}

$script:StatusOn = $false

function Write-Status([string]$Text) {
    # One gray line that updates in place, so long phases visibly move. [Console]::Write does not
    # go into the log (Start-Transcript), which keeps the log clean. Nothing if output is redirected.
    try { if ([Console]::IsOutputRedirected) { return } } catch { return }
    $w = 100
    try { $w = [math]::Max(20, [Console]::WindowWidth - 1) } catch { }
    if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w - 1) + $G.Ell }
    $old = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = 'DarkGray'
        [Console]::Write("`r" + $Text.PadRight($w))
    } finally { [Console]::ForegroundColor = $old }
    $script:StatusOn = $true
}

function Clear-Status {
    if (-not $script:StatusOn) { return }
    $w = 100
    try { $w = [math]::Max(20, [Console]::WindowWidth - 1) } catch { }
    try { [Console]::Write("`r" + (' ' * $w) + "`r") } catch { }
    $script:StatusOn = $false
}

function Write-Section([string]$Text, [string]$Note = '') {
    Write-Host ''
    Write-Seg "  $($G.Node) " Cyan
    Write-Seg $Text White
    if ($Note) { Write-Seg "  $Note" DarkGray }
    Write-Host ''
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
        Test   = @('TEST',   $(if ($AfterRestart) { 'After the restart: compares with the test before Apply.' } else { 'Measures and shows the state. Changes nothing.' }), 'Cyan')
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
            Write-Status "    waiting for the router to answer... $s s / $TimeoutSec s"
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
        Clear-Status
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
            Write-Status '    fetching the Steam relay list...'
            $live = Get-SteamRelayRegions
            Clear-Status
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
    Write-Status "    1/3  resolving $($cands.Count) server names..."
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
            Write-Status "    2/3  pinging $($icmpIps.Count) servers at once, round $round of 3..."
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
                $rName = @($cands | Where-Object { $_.Ip -eq $ip } | ForEach-Object { $_.Region } | Select-Object -First 1)
                Write-Status ("    3/3  TCP connect {0}/{1}  {2}" -f $done, (2 * $tcpIps.Count), ($rName -join ''))
                $ms = Measure-TcpOnce $ip 443 700
                if ($null -ne $ms -and (-not $best.ContainsKey($ip) -or $ms -lt $best[$ip])) { $best[$ip] = $ms }
            }
        }
    }
    Write-Progress -Id 3 -Activity $activity -Completed
    Clear-Status

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
                                Min = $null; Media = $null; Max = $null; Jitter = $null; 'Picos>100' = $null; 'Perda%' = 100
                                Samples = @() }

    $address = Resolve-HostV4 $Target.Host
    if (-not $address) { return $empty }
    $useTcp = ($Target.Method -eq 'tcp')

    $ping = New-Object System.Net.NetworkInformation.Ping
    $rtts = New-Object System.Collections.Generic.List[double]
    # Every sample in order, with its time (ms since the start; Rtt = $null if lost), to find periodic spikes.
    $samples = New-Object System.Collections.Generic.List[object]
    $clockT = [Diagnostics.Stopwatch]::StartNew()
    $lost = 0
    try {
        if ($useTcp) { [void](Measure-TcpOnce $address 443 1000) }   # warm-up
        for ($i = 0; $i -lt $Pings; $i++) {
            $pct = [int](100 * (($Index - 1) * $Pings + $i) / ($Total * $Pings))
            $where = if ($Target.Region) { $Target.Region } else { $address }
            Write-Progress -Id 1 -Activity 'Connection test' -Status ("{0}/{1}  {2}  ({3})   {4} {5}/{6}" -f $Index, $Total, $Label, $where, $(if ($useTcp) { 'tcp' } else { 'ping' }), ($i + 1), $Pings) -PercentComplete $pct
            $t = $clockT.Elapsed.TotalMilliseconds
            $rtt = $null
            if ($useTcp) {
                $ms = Measure-TcpOnce $address 443 1000
                if ($null -ne $ms) { $rtt = [math]::Round($ms, 1) }
            } else {
                try {
                    $reply = $ping.Send($address, 1000)
                    if ($reply.Status -eq 'Success') { $rtt = [double]$reply.RoundtripTime }
                } catch { }
            }
            if ($null -ne $rtt) { $rtts.Add($rtt) } else { $lost++ }
            $samples.Add([pscustomobject]@{ T = $t; Rtt = $rtt })
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
        Samples     = $samples.ToArray()
    }
}

function Find-PeriodicSpikes($Samples) {
    # Spikes that come back at regular intervals (for example every 3 s). Returns the period in
    # seconds, or $null. A spike = lost packet or a ping 30 ms (and 3x) above the median.
    $all = @($Samples)
    $ok = @($all | Where-Object { $null -ne $_.Rtt } | ForEach-Object { [double]$_.Rtt })
    if ($ok.Count -lt 10) { return $null }
    $median = Get-Median $ok
    $limit = [math]::Max($median + 30, $median * 3)

    $events = New-Object System.Collections.Generic.List[double]
    $spikeCount = 0
    $lastSpike = [double]::MinValue
    foreach ($s in $all) {
        if ($null -ne $s.Rtt -and $s.Rtt -lt $limit) { continue }
        $spikeCount++
        # Spikes less than 1.5 s after the previous one belong to the same burst (one event).
        if ($s.T - $lastSpike -gt 1500) { $events.Add([double]$s.T) }
        $lastSpike = [double]$s.T
    }
    # Needs at least 4 events, and spikes must be the exception (otherwise it is just an unstable link).
    if ($events.Count -lt 4 -or $spikeCount -gt 0.3 * $all.Count) { return $null }

    $gaps = @(for ($i = 1; $i -lt $events.Count; $i++) { $events[$i] - $events[$i - 1] })
    $avg = ($gaps | Measure-Object -Average).Average
    $var = 0.0
    foreach ($gap in $gaps) { $var += [math]::Pow($gap - $avg, 2) }
    $sd = [math]::Sqrt($var / $gaps.Count)
    # Regular = the gaps vary at most 20% around the average.
    if ($avg -lt 2000 -or $sd / $avg -gt 0.2) { return $null }
    return [math]::Round($avg / 1000, 1)
}

function Test-ActiveIsWifi {
    # Is the adapter carrying the internet traffic a Wi-Fi one?
    $route = Get-ActiveRoute
    if (-not $route) { return $false }
    $a = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $a) { return $false }
    return ([string]$a.PhysicalMediaType -match '802\.11') -or ($a.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11')
}

function Get-PendingTweakCount {
    # Same count as Show-AdapterState, without the output (6>$null hides Write-Host).
    return [int](Show-AdapterState 6>$null)
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
        $swR = [Diagnostics.Stopwatch]::StartNew()
        $script:GameTargets = @(Select-GameTargets)
        if ($script:GameTargets.Count -gt 0) {
            Write-Info ("Regions picked in {0:0.0} s: {1}" -f $swR.Elapsed.TotalSeconds,
                (@($script:GameTargets | ForEach-Object { "$($_.Label) $($G.Arrow) $($_.Region)" }) -join "  $($G.Dot)  "))
        }
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
                if ((Get-PendingTweakCount) -gt 0) {
                    Write-Info  'The problem is local (adapter, driver or Wi-Fi), not your ISP or the game.' 4
                } else {
                    # The adapter is already tuned: what is left is the Wi-Fi itself or the router.
                    $onWifi = Test-ActiveIsWifi
                    if ($onWifi) {
                        Write-Info 'The adapter settings are already optimized, so the spikes come from the Wi-Fi or the router' 4
                        Write-Info 'itself: interference, other devices using the network, or a router that got stuck.' 4
                    } else {
                        Write-Info 'The adapter settings are already optimized, so the spikes come from the router or the network' 4
                        Write-Info 'itself: other devices using the network, or a router that got stuck.' 4
                    }
                    Write-Info 'What to try:' 4
                    if ($onWifi) { Write-Info 'Test with a network cable: if the spikes go away, the Wi-Fi is the cause.' 6 }
                    Write-Info 'Close downloads and updates in the background (Steam, Windows Update, OneDrive, other devices).' 6
                    Write-Info 'Restart the router: unplug it from power for 30 s, then test again.' 6
                }
            }
        }

        $period = Find-PeriodicSpikes $router.Samples
        if ($period) {
            Write-Warn2 "The router spikes repeat at regular intervals (about every $period s)."
            Write-Info  'That pattern usually means the router is stuck on something: restart it (unplug it from power for 30 s).' 4
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
    $kept   = $null   # public DNS already in use and kept
    $curLocal  =@($rows | Where-Object { $_.IsCurrent -and $_.IsLocal })
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
        $kept = $winner.Preset
    } elseif ($curPreset -and $curPreset.Score - $winner.Score -lt $margin) {
        # Already on a public DNS and the difference is small: not worth switching between public ones.
        Write-Ok "You already use $($curPreset.Preset) and $($winner.Preset) is only $(Format-Num ($curPreset.Score - $winner.Score)) ms better. Leaving it as is."
        $kept = $curPreset.Preset
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

    # The IPv4 already is Cloudflare but the IPv6 may still be the router's / ISP's: Apply sets it too.
    $v6Fix = $null
    if ($kept -eq 'Cloudflare') {
        $route = Get-ActiveRoute
        if ($route) {
            $want6 = @($DnsPresets.Cloudflare | Where-Object { $_ -match ':' })
            $now6 = @(Get-AdapterDnsList $route.InterfaceIndex 'IPv6')
            $act = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
            if ($act -and (Test-AdapterIPv6 $act) -and -not (Test-SameList $now6 $want6)) {
                $v6Fix = 'Cloudflare'
                $nowText = if ($now6.Count -gt 0) { ($now6 | Select-Object -First 2) -join ', ' } else { 'automatic' }
                Write-Warn2 "The IPv6 DNS is not Cloudflare yet (now: $nowText)."
                Write-Info "Apply sets it too: $($want6 -join ', ')" 4
            }
        }
    }
    Write-Info 'Note: DNS speeds up opening sites and connecting to services. It does not change in-game ping.'

    return [pscustomobject]@{ Choice = $choice; V6Fix = $v6Fix }
}

function Test-AdapterIPv6($Adapter) {
    # Is IPv6 enabled on the adapter? If it cannot be read, assume yes.
    try { return [bool](Get-NetAdapterBinding -Name $Adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop).Enabled } catch { return $true }
}

# ---------------------------------------------------------------- tcp, offloads and registry

function Invoke-Netsh([string[]]$Arguments) {
    # Runs netsh quietly. Its text is in the Windows language, so only the exit code is used.
    try { & netsh @Arguments 2>&1 | Out-Null } catch { }
    return ($LASTEXITCODE -eq 0)
}

function Get-TcpGlobalValue([string]$Name) {
    # Value in the TCP template Windows uses for internet traffic. $null if it cannot be read
    # (some fields are only visible to administrators).
    try {
        $s = Get-NetTCPSetting -SettingName $TcpTemplate -ErrorAction Stop | Select-Object -First 1
        $v = $s.$Name
        if ($null -eq $v -or [string]$v -eq '') { return $null }
        return [string]$v
    } catch { return $null }
}

function Get-OffloadGlobalValue([string]$Name) {
    try {
        $v = (Get-NetOffloadGlobalSetting -ErrorAction Stop).$Name
        if ($null -eq $v -or [string]$v -eq '') { return $null }
        return [string]$v
    } catch { return $null }
}

function Get-GlobalValue([string]$Kind, [string]$Name) {
    if ($Kind -eq 'tcp') { return Get-TcpGlobalValue $Name }
    return Get-OffloadGlobalValue $Name
}

function Set-GlobalValue([string]$Kind, $Tweak, $Value) {
    # PowerShell cmdlet first; if the value did not change, netsh. The caller reads the value back.
    $p = @{ $Tweak.Name = $Value }
    try {
        if ($Kind -eq 'tcp') { Set-NetTCPSetting -SettingName $TcpTemplate @p -Confirm:$false -ErrorAction Stop }
        else { Set-NetOffloadGlobalSetting @p -Confirm:$false -ErrorAction Stop }
    } catch { }
    if ((Get-GlobalValue $Kind $Tweak.Name) -ne [string]$Value -and $Tweak.Netsh) {
        $v = ([string]$Value).ToLower()
        if ($Tweak.Netsh -eq 'heuristics') { [void](Invoke-Netsh @('int', 'tcp', 'set', 'heuristics', $v)) }
        else { [void](Invoke-Netsh @('int', 'tcp', 'set', 'global', "$($Tweak.Netsh)=$v")) }
    }
}

function Write-GlobalState([string]$Kind, $Tweak, [bool]$Active) {
    # One CURRENT STATE line. Returns 1 if Apply would change it.
    $v = Get-GlobalValue $Kind $Tweak.Name
    $want = [string]$Tweak.Want
    if ($null -eq $v) {
        $why = if (Test-IsAdmin) { 'cannot be read on this Windows' } else { 'unknown (readable as admin only)' }
        Write-KV $Tweak.Label $why
        return 0
    }
    if ($v -eq $want) { Write-KV $Tweak.Label $v 'ok'; return 0 }
    if (-not $Active) { Write-KV $Tweak.Label $v; return 0 }
    Write-KV $Tweak.Label $v 'warn' $want
    return 1
}

function Invoke-GlobalTweak([string]$Kind, $Tweak, $BackupList) {
    $want = [string]$Tweak.Want
    $cur = Get-GlobalValue $Kind $Tweak.Name
    if ($null -eq $cur) {
        if (Test-IsAdmin) { Write-Unsupported $Tweak.Label 'cannot be read on this Windows, left as is' }
        else { Write-Unsupported $Tweak.Label 'readable as admin only, left as is' }
        return
    }
    if ($cur -eq $want) { Write-Info "$($Tweak.Label): already $want" 4; return }
    if (-not $PSCmdlet.ShouldProcess($Tweak.Label, "$cur -> $want")) { Write-Change $Tweak.Label $cur $want; return }

    # Into the backup before changing it: if something fails halfway, Revert still knows the old value.
    $BackupList.Add([ordered]@{ Name = $Tweak.Name; Old = $cur })
    Set-GlobalValue $Kind $Tweak $Tweak.Want
    $now = Get-GlobalValue $Kind $Tweak.Name
    if ($now -eq $want) { Write-Change $Tweak.Label $cur $want }
    elseif ($now -eq $cur) { Write-Unsupported $Tweak.Label 'not supported on this Windows (read-only)' }
    else { Write-Fail $Tweak.Label "was not applied (now: $now)" }
}

function Restore-GlobalTweak([string]$Kind, $Tweak, $Old) {
    $cur = Get-GlobalValue $Kind $Tweak.Name
    if ($cur -eq [string]$Old) { Write-Info "$($Tweak.Label): already $Old" 4; return }
    if (-not $PSCmdlet.ShouldProcess($Tweak.Label, "-> $Old")) { return }
    Set-GlobalValue $Kind $Tweak $Old
    $now = Get-GlobalValue $Kind $Tweak.Name
    if ($now -eq [string]$Old) { Write-Change $Tweak.Label $cur $Old }
    elseif ($now -eq $cur) { Write-Unsupported $Tweak.Label 'not supported on this Windows (read-only)' }
    else { Write-Fail $Tweak.Label "was not restored (now: $now)" }
}

function Get-RegState([string]$Path, [string]$Name) {
    # Whether the key and the value exist, and the value with its type.
    $st = [pscustomobject]@{ KeyExists = $false; Exists = $false; Value = $null; Kind = $null }
    $key = $null
    try { $key = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $st }
    $st.KeyExists = $true
    if (@($key.GetValueNames()) -contains $Name) {
        $st.Exists = $true
        $st.Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        $st.Kind = [string]$key.GetValueKind($Name)
    }
    return $st
}

function Test-RegWanted($Tweak, $State) {
    if (-not $State.Exists) { return $false }
    if ($Tweak.Type -eq 'String') { return ([string]$State.Value -eq [string]$Tweak.Value) }
    try { return ([int64]$State.Value -eq [int64]$Tweak.Value) } catch { return $false }
}

function Format-RegValue($Tweak, $Value) {
    if ($null -eq $Value) { return 'not set' }
    if ($Tweak.ContainsKey('Hex') -and $Tweak.Hex) {
        try { return ('0x{0:x8}' -f [int]$Value) } catch { }
    }
    return [string]$Value
}

function Write-RegState($Tweak, [string]$Path, [string]$Label, [bool]$Active) {
    # One CURRENT STATE line. Returns 1 if Apply would change it.
    $st = Get-RegState $Path $Tweak.Name
    $v = Format-RegValue $Tweak $st.Value
    if (Test-RegWanted $Tweak $st) { Write-KV $Label $v 'ok'; return 0 }
    if (-not $Active) { Write-KV $Label $v; return 0 }
    Write-KV $Label $v 'warn' (Format-RegValue $Tweak $Tweak.Value)
    return 1
}

function Invoke-RegTweak($Tweak, [string]$Path, [string]$Label, $BackupList) {
    # Writes one value, saving the old one first (or that the value / its key did not exist,
    # so Revert deletes instead of writing). Confirms by reading it back.
    $st = Get-RegState $Path $Tweak.Name
    $to = Format-RegValue $Tweak $Tweak.Value
    if (Test-RegWanted $Tweak $st) { Write-Info "${Label}: already $to" 4; return }
    $from = Format-RegValue $Tweak $st.Value
    if (-not $PSCmdlet.ShouldProcess($Label, "$from -> $to")) { Write-Change $Label $from $to 'restart the PC'; return }

    $BackupList.Add([ordered]@{ Path = $Path; Name = $Tweak.Name; KeyExisted = $st.KeyExists; Existed = $st.Exists; Value = $st.Value; Kind = $st.Kind })
    $err = $null
    try {
        if (-not $st.KeyExists) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Tweak.Name -PropertyType $Tweak.Type -Value $Tweak.Value -Force -ErrorAction Stop | Out-Null
    } catch { $err = $_.Exception.Message }

    if (Test-RegWanted $Tweak (Get-RegState $Path $Tweak.Name)) {
        Write-Change $Label $from $to 'restart the PC'
        $script:RebootNeeded = $true
        $script:RegChanged = $true
    } elseif ($err) {
        Write-Fail $Label "could not write it: $err"
    } else {
        Write-Fail $Label 'was not applied'
    }
}

function Restore-RegValue($Entry) {
    $label = [string]$Entry.Name
    $to = if ($Entry.Existed) { [string]$Entry.Value } else { 'not set (deleted)' }
    if (-not $PSCmdlet.ShouldProcess("$($Entry.Path)\$($Entry.Name)", "-> $to")) { return }
    try {
        if ($Entry.Existed) {
            $kind = if ($Entry.Kind) { [string]$Entry.Kind } else { 'DWord' }
            New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -PropertyType $kind -Value $Entry.Value -Force -ErrorAction Stop | Out-Null
        } else {
            if ((Get-RegState $Entry.Path $Entry.Name).Exists) {
                Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction Stop
            }
            # The key was created by Apply: delete it too if it was left empty.
            if (-not $Entry.KeyExisted) {
                $k = Get-Item -LiteralPath $Entry.Path -ErrorAction SilentlyContinue
                if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $Entry.Path -ErrorAction Stop }
            }
        }
    } catch {
        Write-Fail $label $_.Exception.Message
        return
    }
    $st = Get-RegState $Entry.Path $Entry.Name
    $ok = if ($Entry.Existed) { $st.Exists -and ([string]$st.Value -eq [string]$Entry.Value) } else { -not $st.Exists }
    if ($ok) {
        Write-Change $label 'tweaked' $to 'restart the PC'
        $script:RebootNeeded = $true
    } else {
        Write-Fail $label "was not restored (now: $(if ($st.Exists) { $st.Value } else { 'not set' }))"
    }
}

function Test-HasKeyword($Props, [string]$Pattern) {
    # Does the driver expose this standard keyword? If not, Windows cannot change the option.
    return (@($Props | Where-Object { $_.RegistryKeyword -match $Pattern }).Count -gt 0)
}

function Get-RssState([string]$Name) {
    try { return [bool](Get-NetAdapterRss -Name $Name -ErrorAction Stop).Enabled } catch { return $null }
}

function Get-LsoState([string]$Name) {
    try {
        $l = Get-NetAdapterLso -Name $Name -ErrorAction Stop
        return [pscustomobject]@{ V1IPv4 = [bool]$l.V1IPv4Enabled; IPv4 = [bool]$l.IPv4Enabled; IPv6 = [bool]$l.IPv6Enabled }
    } catch { return $null }
}

function Test-LsoOn($Lso) { return ($Lso.V1IPv4 -or $Lso.IPv4 -or $Lso.IPv6) }

function Get-ChecksumState([string]$Name) {
    try {
        $c = Get-NetAdapterChecksumOffload -Name $Name -ErrorAction Stop
        $o = [ordered]@{}
        foreach ($p in $ChecksumProps.Keys) { $o[$p] = [string]$c.$p }
        return $o
    } catch { return $null }
}

function Get-ChecksumOff($Ck) {
    # Names of the checksum offloads that are off ('TCP IPv6', ...).
    return @($ChecksumProps.Keys | Where-Object { $Ck[$_] -eq 'Disabled' } | ForEach-Object { $ChecksumProps[$_] })
}

# ---------------------------------------------------------------- mtu

function Send-DfPing([string]$Ip, [int]$Size, [int]$Tries = 3) {
    # One ping with "Don't Fragment". 'ok' = it fits, 'big' = PacketTooBig, 'timeout' = no answer
    # after $Tries attempts (other errors count as no answer too).
    $ping = New-Object System.Net.NetworkInformation.Ping
    $opt = New-Object System.Net.NetworkInformation.PingOptions(64, $true)
    $buf = New-Object byte[] $Size
    try {
        for ($i = 0; $i -lt $Tries; $i++) {
            $status = ''
            try { $status = [string]$ping.Send($Ip, 1500, $buf, $opt).Status } catch { }
            if ($status -eq 'Success') { return 'ok' }
            if ($status -eq 'PacketTooBig') { return 'big' }
            Start-Sleep -Milliseconds 100
        }
        return 'timeout'
    } finally {
        $ping.Dispose()
    }
}

$script:MtuStatus = ''

function Test-PayloadFits([string]$Ip, [int]$Size, $State) {
    $State.Step++
    Write-Status "$($script:MtuStatus)  search step $($State.Step): $Size bytes (MTU $($Size + 28))..."
    $r = Send-DfPing $Ip $Size 3
    # Small packets get through (checked first), so a big one that is never answered was dropped:
    # some networks drop oversized packets instead of answering "too big".
    if ($r -eq 'timeout') { $State.Silent = $true }
    return ($r -eq 'ok')
}

function Measure-PathMtu([string]$Ip, [int]$MaxPayload) {
    # Binary search of the largest payload that gets through without fragmenting, then confirmed.
    # Status: ok | blocked (ICMP blocked) | below (path MTU under 1200) | unconfirmed.
    $r = [pscustomobject]@{ Ip = $Ip; Payload = $null; Mtu = $null; Status = 'ok'; Silent = $false }
    $state = @{ Silent = $false; Step = 0 }
    Write-Status "$($script:MtuStatus)  small ping (is ICMP allowed?)..."
    if ((Send-DfPing $Ip 64 3) -ne 'ok') { $r.Status = 'blocked'; return $r }

    $lo = $MtuMinPayload
    $hi = $MaxPayload
    if (Test-PayloadFits $Ip $hi $state) {
        $best = $hi
    } elseif (-not (Test-PayloadFits $Ip $lo $state)) {
        $r.Status = 'below'
        $r.Silent = $state.Silent
        return $r
    } else {
        # Invariant: $lo fits, $hi does not.
        while ($hi - $lo -gt 1) {
            $mid = [int][math]::Floor(($lo + $hi) / 2)
            if (Test-PayloadFits $Ip $mid $state) { $lo = $mid } else { $hi = $mid }
        }
        $best = $lo
    }

    # Confirm: the size found passes 5 out of 5 and one byte more always fails.
    $pass = 0
    for ($k = 0; $k -lt 5; $k++) {
        Write-Status "$($script:MtuStatus)  confirming $best bytes: ping $($k + 1)/5..."
        if ((Send-DfPing $Ip $best 3) -eq 'ok') { $pass++ }
    }
    $nextOk = $false
    if ($best -lt $MaxPayload) {
        for ($k = 0; $k -lt 3; $k++) {
            Write-Status "$($script:MtuStatus)  checking that $($best + 1) bytes fails: $($k + 1)/3..."
            if ((Send-DfPing $Ip ($best + 1) 1) -eq 'ok') { $nextOk = $true; break }
        }
    }
    $r.Payload = $best
    $r.Mtu = $best + 28
    $r.Silent = $state.Silent
    if ($pass -lt 5 -or $nextOk) { $r.Status = 'unconfirmed' }
    return $r
}

function Write-MtuRow($R) {
    Write-Seg ('  ' + $R.Ip.PadRight(14)) White
    switch ($R.Status) {
        'blocked' {
            Write-Seg ('-'.PadLeft(8) + '-'.PadLeft(7)) DarkGray
            Write-Host "    $($G.Bad) no reply even to small pings (ICMP blocked)" -ForegroundColor Red
        }
        'below' {
            Write-Seg ('-'.PadLeft(8) + '<1200'.PadLeft(7)) Yellow
            Write-Host "    $($G.Warn) not even 1200 gets through" -ForegroundColor Yellow
        }
        default {
            $color = if ($R.Status -eq 'ok') { 'White' } else { 'DarkGray' }
            Write-Seg ([string]$R.Payload).PadLeft(8) $color
            Write-Seg ([string]$R.Mtu).PadLeft(7) $color
            $notes = @()
            if ($R.Status -eq 'unconfirmed') { $notes += 'not confirmed (unstable), ignored' }
            if ($R.Silent) { $notes += 'big packets dropped silently' }
            if ($notes.Count -eq 0) { Write-Host "    $($G.Ok) confirmed" -ForegroundColor Green }
            else { Write-Host ("    $($G.Warn) " + ($notes -join ', ')) -ForegroundColor Yellow }
        }
    }
}

function Get-InterfaceMtu([int]$Index, [string]$Family) {
    try { return [int](Get-NetIPInterface -InterfaceIndex $Index -AddressFamily $Family -ErrorAction Stop).NlMtu } catch { return $null }
}

function Set-InterfaceMtu([string]$Alias, [string]$Family, [int]$Mtu, [string]$Store) {
    $proto = if ($Family -eq 'IPv4') { 'ipv4' } else { 'ipv6' }
    return (Invoke-Netsh @('interface', $proto, 'set', 'subinterface', $Alias, "mtu=$Mtu", "store=$Store"))
}

function Invoke-MtuTest($Backup, [bool]$CanRaise) {
    # Finds the largest MTU of the current network. It leaves the MTU as it was: Apply sets the
    # result afterwards (Set-ActiveMtu). Returns $null, or an object with Mtu ($null = do not change).
    Write-Title 'MTU test'
    $route = Get-ActiveRoute
    $ad = $null
    if ($route) { $ad = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue }
    if (-not $ad) { Write-Warn2 'No active connection: skipping the MTU test.'; return $null }

    $idx  = [int]$route.InterfaceIndex
    $cur4 = Get-InterfaceMtu $idx 'IPv4'
    $cur6 = Get-InterfaceMtu $idx 'IPv6'
    $cur6Text = if ($null -ne $cur6) { [string]$cur6 } else { 'off' }
    Write-Info "Adapter: $($ad.Name)  $($G.Dot)  current MTU: IPv4 $cur4, IPv6 $cur6Text"
    Write-Info "Ping with Don't Fragment to $($MtuTargets -join ', ')  $($G.Dot)  MTU 1200-1500"

    $res = [pscustomobject]@{ Mtu = $null; Alias = $ad.Name; Index = $idx; Guid = [string]$ad.InterfaceGuid; Cur4 = $cur4; Cur6 = $cur6 }
    if ($null -eq $cur4) { Write-Warn2 'Could not read the current MTU: skipping the MTU test.'; return $res }

    $maxPayload = 1472
    $raised = $false
    try {
        if ($cur4 -lt 1500) {
            if ($CanRaise) {
                # Below 1500 Windows itself blocks the bigger packets, so the test could never find more.
                if ($Backup -and -not $Backup.Mtu) {
                    $Backup.Mtu = [ordered]@{ InterfaceGuid = $res.Guid; Alias = $res.Alias; IPv4 = $cur4; IPv6 = $cur6 }
                }
                if ((Set-InterfaceMtu $ad.Name 'IPv4' 1500 'active') -and (Get-InterfaceMtu $idx 'IPv4') -eq 1500) {
                    $raised = $true
                    Write-Info 'MTU raised to 1500 for the test only (otherwise Windows blocks the bigger packets).'
                } else {
                    $maxPayload = $cur4 - 28
                    Write-Warn2 "Could not raise the MTU to 1500 for the test: testing up to $cur4 only."
                }
            } else {
                $maxPayload = $cur4 - 28
                Write-Info "The current MTU ($cur4) caps the test. Apply raises it to 1500 for a moment to test higher."
            }
        }
        if ($maxPayload -lt $MtuMinPayload) {
            Write-Warn2 "The current MTU ($cur4) is below 1200: left as is."
            return $res
        }

        Write-Host ''
        Write-Seg '  '
        Write-Seg 'Target'.PadRight(14) DarkGray
        Write-Seg 'Payload'.PadLeft(8) DarkGray
        Write-Seg 'MTU'.PadLeft(7) DarkGray
        Write-Host '    Note' -ForegroundColor DarkGray
        Write-Host ('  ' + ($G.H * 76)) -ForegroundColor DarkGray

        # Each row appears as soon as its target is done; meanwhile a status line shows each step.
        $rows = @()
        $i = 0
        foreach ($ip in $MtuTargets) {
            Write-Progress -Id 5 -Activity 'MTU test' -Status "$ip ($($i + 1)/$($MtuTargets.Count))" -PercentComplete ([int](100 * $i / $MtuTargets.Count))
            $script:MtuStatus = "    $($i + 1)/$($MtuTargets.Count)  $ip"
            $r = Measure-PathMtu $ip $maxPayload
            Clear-Status
            Write-MtuRow $r
            $rows += $r
            $i++
        }
        Write-Progress -Id 5 -Activity 'MTU test' -Completed
        Write-Host ''
        Write-Host "  Payload = largest ping that gets through without fragmenting  $($G.Dot)  MTU = payload + 28" -ForegroundColor DarkGray

        $good = @($rows | Where-Object { $_.Status -eq 'ok' })
        Write-Host ''
        if (@($rows | Where-Object { $_.Status -eq 'blocked' }).Count -eq $rows.Count) {
            Write-Warn2 'ICMP is blocked on this network (even small pings get no reply), so the MTU cannot be measured. Left as is.'
            return $res
        }
        if (@($rows | Where-Object { $_.Status -eq 'below' }).Count -gt 0) {
            Write-Warn2 'The path MTU is below 1200, which is unusual (VPN or a misconfigured router?). Left as is.'
            return $res
        }
        if ($good.Count -eq 0) {
            Write-Warn2 'The results could not be confirmed (unstable connection). MTU left as is; try again later.'
            return $res
        }
        if (@($rows | Where-Object { $_.Silent }).Count -gt 0) {
            Write-Info 'This network drops oversized packets without answering "too big": those were treated as too big.'
        }
        if ($good.Count -lt $rows.Count) { Write-Info "Some targets gave no usable result: using the other $($good.Count)." }

        $mtu = [int](($good | Measure-Object -Property Mtu -Minimum).Minimum)
        if ($mtu -ge 1500) {
            $res.Mtu = 1500
            Write-Ok 'MTU 1500 is already the maximum on this network.'
        } elseif ($maxPayload -lt 1472 -and $mtu -ge $cur4) {
            # Capped test: everything up to the current MTU gets through, but higher was not tested.
            Write-Ok "Packets up to the current MTU ($cur4) get through. Apply tests above it."
        } else {
            $res.Mtu = $mtu
            Write-Warn2 "Largest MTU on this network: $mtu (now $cur4)."
            Write-Info "Apply sets it on IPv4 and IPv6 (IPv6 minimum 1280)." 4
        }
        Write-Info 'The MTU depends on the network: run it again when you change networks.'
        return $res
    } finally {
        Write-Progress -Id 5 -Activity 'MTU test' -Completed
        Clear-Status
        # The test leaves nothing behind (also if it fails halfway).
        if ($raised) { [void](Set-InterfaceMtu $ad.Name 'IPv4' $cur4 'active') }
    }
}

function Set-ActiveMtu($Res, $Backup) {
    $want = @{ IPv4 = [int]$Res.Mtu; IPv6 = [int][math]::Max(1280, [int]$Res.Mtu) }
    $cur  = @{ IPv4 = $Res.Cur4; IPv6 = $Res.Cur6 }
    Write-Section "MTU ($($Res.Alias))"
    $todo = @(@('IPv4', 'IPv6') | Where-Object { $null -ne $cur[$_] -and $cur[$_] -ne $want[$_] })
    if ($todo.Count -eq 0) { Write-Info "MTU: already $($want.IPv4)" 4; return }
    foreach ($fam in $todo) {
        $label = "MTU $fam"
        if (-not $PSCmdlet.ShouldProcess($Res.Alias, "$label $($cur[$fam]) -> $($want[$fam])")) {
            Write-Change $label ([string]$cur[$fam]) ([string]$want[$fam])
            continue
        }
        if (-not $Backup.Mtu) {
            $Backup.Mtu = [ordered]@{ InterfaceGuid = $Res.Guid; Alias = $Res.Alias; IPv4 = $Res.Cur4; IPv6 = $Res.Cur6 }
        }
        [void](Set-InterfaceMtu $Res.Alias $fam $want[$fam] 'persistent')
        $now = Get-InterfaceMtu $Res.Index $fam
        if ($now -eq $want[$fam]) { Write-Change $label ([string]$cur[$fam]) ([string]$want[$fam]) }
        else { Write-Fail $label "was not applied (now: $now)" }
    }
}

# ---------------------------------------------------------------- nagle on wi-fi

function Test-WirelessAdapter($Adapter) {
    return ([string]$Adapter.PhysicalMediaType -match '802\.11') -or ($Adapter.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11')
}

function ConvertFrom-NetworkKeyName([string]$Name) {
    # Wi-Fi keeps one TCP/IP subkey per network, named after the SSID in hex with the two digits of
    # each byte swapped ("65F6461666F6E656..." = "Vodafone..."). Returns the SSID, or the raw name.
    if ($Name -notmatch '^[0-9A-Fa-f]+$' -or $Name.Length % 2 -ne 0) { return $Name }
    try {
        $bytes = New-Object byte[] ($Name.Length / 2)
        for ($i = 0; $i -lt $Name.Length; $i += 2) { $bytes[$i / 2] = [Convert]::ToByte("$($Name[$i + 1])$($Name[$i])", 16) }
        $s = [Text.Encoding]::UTF8.GetString($bytes)
        if ($s -notmatch '[\x00-\x1F]') { return $s }
    } catch { }
    return $Name
}

function Get-NagleKeys($Adapter) {
    # The adapter's TCP/IP key (on Wi-Fi: the settings of the network it is connected to), plus on
    # Wi-Fi one subkey per network it has been on. Returns objects with Path and Label.
    $ifKey = "$TcpipKey\Interfaces\$($Adapter.InterfaceGuid)"
    if (-not (Test-Path -LiteralPath $ifKey)) { return @() }
    $keys = @([pscustomobject]@{ Path = $ifKey; Label = '' })
    foreach ($k in @(Get-ChildItem -LiteralPath $ifKey -ErrorAction SilentlyContinue)) {
        $keys += [pscustomobject]@{ Path = "$ifKey\$($k.PSChildName)"; Label = " (network $(ConvertFrom-NetworkKeyName $k.PSChildName))" }
    }
    return $keys
}

function Test-NagleSet([string]$Path) {
    return (@($NagleTweaks | Where-Object { -not (Test-RegWanted $_ (Get-RegState $Path $_.Name)) }).Count -eq 0)
}

function Get-NetTuneTask($Task) {
    # SilentlyContinue, not Stop + catch: a caught error still lands in the log as "TerminatingError".
    try { return (Get-ScheduledTask -TaskPath $Task.Path -TaskName $Task.Name -ErrorAction SilentlyContinue) } catch { return $null }
}

function Remove-NetTuneTask($Task) {
    # $true if the task is gone (or was not there).
    if (-not (Get-NetTuneTask $Task)) { return $true }
    try { Unregister-ScheduledTask -TaskPath $Task.Path -TaskName $Task.Name -Confirm:$false -ErrorAction Stop } catch { }
    return (-not (Get-NetTuneTask $Task))
}

function Test-NagleKeeperCovers([string[]]$Guids) {
    # The keeper lists the adapters it covers in its description.
    $t = Get-NetTuneTask $NagleTask
    if (-not $t) { return $false }
    foreach ($guid in $Guids) { if ([string]$t.Description -notmatch [regex]::Escape($guid)) { return $false } }
    return $true
}

function Register-NagleKeeper([string[]]$Guids) {
    # Script run by the task: writes the Nagle values on the adapter key and on every network
    # subkey. Twice, 30 s apart, because Windows may still be rebuilding the key when the event fires.
    $sets = ($NagleTweaks | ForEach-Object {
        "            New-ItemProperty -LiteralPath `$p -Name '$($_.Name)' -PropertyType $($_.Type) -Value $($_.Value) -Force | Out-Null"
    }) -join "`n"
    $list = ($Guids | ForEach-Object { "'$_'" }) -join ', '
    $code = @"
`$base = '$TcpipKey\Interfaces'
for (`$round = 0; `$round -lt 2; `$round++) {
    foreach (`$g in @($list)) {
        `$k = Join-Path `$base `$g
        if (-not (Test-Path -LiteralPath `$k)) { continue }
        foreach (`$p in @(`$k) + @(Get-ChildItem -LiteralPath `$k -ErrorAction SilentlyContinue | ForEach-Object { `$_.PSPath })) {
$sets
        }
    }
    if (`$round -eq 0) { Start-Sleep -Seconds 30 }
}
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $enc"

    # Trigger: "network connected" (NetworkProfile, event 10000), 10 s later; and at startup.
    $class = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
    $onNet = New-CimInstance -CimClass $class -ClientOnly
    $onNet.Enabled = $true
    $onNet.Delay = 'PT10S'
    $onNet.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
    $atBoot = New-ScheduledTaskTrigger -AtStartup

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $desc = "NetTune: writes the Nagle values (TcpAckFrequency, TCPNoDelay, TcpDelAckTicks) again when Wi-Fi connects to a network. Adapters: $($Guids -join ', '). Removed by NetTune -Mode Revert."
    Register-ScheduledTask -TaskPath $NagleTask.Path -TaskName $NagleTask.Name -Action $action -Trigger @($onNet, $atBoot) `
        -Principal $principal -Settings $settings -Description $desc -Force -ErrorAction Stop | Out-Null
}

# ---------------------------------------------------------------- after restart

function Get-NetworkIdentity {
    # Which network we are on: adapter, network profile name and gateway (no netsh: its text is localized).
    $route = Get-ActiveRoute
    if (-not $route) { return $null }
    $profileName = ''
    try { $profileName = [string](Get-NetConnectionProfile -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop | Select-Object -First 1).Name } catch { }
    $alias = [string]$route.InterfaceAlias
    if (-not $alias) { try { $alias = [string](Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop).Name } catch { } }
    return [pscustomobject]@{ InterfaceAlias = $alias; ProfileName = $profileName; Gateway = [string]$route.NextHop }
}

function Format-NetworkIdentity($Net) {
    if (-not $Net) { return 'no connection' }
    return "$($Net.InterfaceAlias) $($G.Dot) $($Net.ProfileName) $($G.Dot) gateway $($Net.Gateway)"
}

function Save-PendingState($Before, [string]$BackupPath) {
    # What the test after the restart needs: the "before" results, the same servers and the network.
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -WhatIf:$false | Out-Null }
    $state = [ordered]@{
        Created      = (Get-Date).ToString('s')
        Tool         = "NetTune $Version"
        BackupFile   = $BackupPath
        Network      = Get-NetworkIdentity
        Count        = $Count
        GameTargets  = @($script:GameTargets)
        ExtraTargets = @($ExtraTargets)
        Before       = @($Before | Where-Object { $_ } | Select-Object * -ExcludeProperty Samples)
    }
    $state | ConvertTo-Json -Depth 6 | Out-File -FilePath $PendingFile -Encoding UTF8 -WhatIf:$false
}

function Register-AfterRestartTask {
    # One-time task at the next logon of this user: highest rights (no UAC prompt), interactive
    # (the window shows up), also on battery. PowerShell stays open (-NoExit), so no time limit.
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arg = "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Test -AfterRestart"
    if ($Ascii) { $arg += ' -Ascii' }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
    $desc = "NetTune: test after the restart, runs once and deletes itself. Created $((Get-Date).ToString('s'))."
    Register-ScheduledTask -TaskPath $AfterTask.Path -TaskName $AfterTask.Name -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $desc -Force -ErrorAction Stop | Out-Null
}

function Get-TaskCreated($Task) {
    $m = [regex]::Match([string]$Task.Description, 'Created (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)')
    if ($m.Success) { return [datetime]$m.Groups[1].Value }
    return $null
}

function Clear-StalePending {
    # An after-restart run older than 24 h (no restart happened): removed without running it.
    $limit = (Get-Date).AddHours(-24)
    $stale = $false
    if (Test-Path $PendingFile) {
        $created = $null
        try { $created = [datetime](Get-Content -Path $PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json).Created } catch { }
        if (-not $created) { $created = (Get-Item $PendingFile).LastWriteTime }
        if ($created -lt $limit) { $stale = $true }
    }
    $task = Get-NetTuneTask $AfterTask
    if ($task) {
        $tc = Get-TaskCreated $task
        if ($tc -and $tc -lt $limit) { $stale = $true }
    }
    if (-not $stale) { return }
    if (-not $PSCmdlet.ShouldProcess('after-restart test older than 24 h', 'Remove the scheduled task and the state file')) { return }
    Write-Host ''
    if (Test-Path $PendingFile) { Remove-Item -Path $PendingFile -Force -ErrorAction SilentlyContinue }
    if (Remove-NetTuneTask $AfterTask) {
        Write-Info 'Removed an after-restart test older than 24 h (the PC was not restarted). Nothing was run.'
    } else {
        Write-Warn2 'An after-restart test older than 24 h is still scheduled: run NetTune as admin once to remove it.'
    }
}

function Wait-Countdown([int]$Seconds) {
    # Lets the programs that start with Windows settle down. Any key starts right away.
    $canKey = $true
    try {
        if ([Console]::IsInputRedirected) { $canKey = $false }
        else { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } }
    } catch { $canKey = $false }
    Write-Info "Waiting $Seconds s for the programs that start with Windows to settle down."
    for ($s = $Seconds; $s -gt 0; $s--) {
        $hint = if ($canKey) { '   (press any key to start now)' } else { '' }
        Write-Status "    starting in $s s$hint"
        for ($k = 0; $k -lt 10; $k++) {
            if ($canKey) {
                try {
                    if ([Console]::KeyAvailable) {
                        [void][Console]::ReadKey($true)
                        Clear-Status
                        Write-Info 'Starting now.'
                        return
                    }
                } catch { $canKey = $false }
            }
            Start-Sleep -Milliseconds 100
        }
    }
    Clear-Status
}

function Invoke-AfterRestart {
    # Returns $false if there is nothing saved (the caller then runs a normal Test).
    # 1) The task goes first, so this runs only once even if the rest fails.
    if (-not (Remove-NetTuneTask $AfterTask)) {
        Write-Host ''
        Write-Warn2 'Could not delete the scheduled task "NetTune after restart". Delete it in Task Scheduler (folder NetTune).'
    }
    $state = $null
    try {
        if (Test-Path $PendingFile) { $state = Get-Content -Path $PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    } catch {
        Write-Warn2 "Could not read logs\pending-after-restart.json: $($_.Exception.Message)"
    }
    try {
        if (-not $state) {
            Write-Host ''
            Write-Warn2 'No saved "before" test was found: running a normal test instead.'
            return $false
        }

        Write-Title 'After the restart'
        $bf = [string](Get-BackupProp $state 'BackupFile')
        $bfText = if ($bf) { "backups\$(Split-Path $bf -Leaf)" } else { '-' }
        Write-Info "Apply: $(Get-BackupProp $state 'Created')  $($G.Dot)  $(Get-BackupProp $state 'Tool')  $($G.Dot)  backup: $bfText"

        # 2) The network has to be back (at most 2 minutes).
        Write-Info 'Waiting for the network (up to 2 min)...'
        if (Wait-Network 120) { Write-Ok 'Network is back.' }
        else { Write-Warn2 'The network did not come back within 2 minutes. Testing anyway.' }

        # 3) Startup programs settle down.
        Wait-Countdown 90

        # 4) Same network as Apply? If not, the comparison means nothing (but the test still runs).
        $then = Get-BackupProp $state 'Network'
        $now = Get-NetworkIdentity
        $same = $then -and $now -and ([string]$then.Gateway -eq [string]$now.Gateway) -and
                ([string]$then.ProfileName -eq [string]$now.ProfileName) -and ([string]$then.InterfaceAlias -eq [string]$now.InterfaceAlias)
        if ($same) {
            Write-Ok "Same network as Apply: $(Format-NetworkIdentity $now)"
        } else {
            $lines = @()
            $lines += ,@($G.Bad, 'Red', 'This is NOT the network Apply ran on.')
            $lines += ,@(' ', 'Gray', "Apply: $(Format-NetworkIdentity $then)")
            $lines += ,@(' ', 'Gray', "Now:   $(Format-NetworkIdentity $now)")
            $lines += ,@($G.Warn, 'Yellow', 'The before / after comparison is NOT valid. Testing anyway.')
            Write-Box 'DIFFERENT NETWORK' $lines 'Red'
        }

        # 5) Everything applied? Then the same test, on the same servers, against the saved "before".
        $pending = Show-AdapterState
        $script:GameTargets = @(Get-BackupProp $state 'GameTargets' | Where-Object { $_ })
        $savedCount = Get-BackupProp $state 'Count'
        if ($savedCount) { $script:Count = [int]$savedCount }
        $after = Invoke-NetTest 'Test after the restart'
        $before = @(Get-BackupProp $state 'Before' | Where-Object { $_ })
        if ($before.Count -gt 0) { Show-Comparison $before $after }

        $lines = @()
        if ($before.Count -eq 0) { $lines += ,@($G.Info, 'DarkGray', 'Apply ran with -SkipTest: there is no "before" to compare with.') }
        elseif ($same) { $lines += ,@($G.Ok, 'Green', 'Before vs after includes the registry values (the PC was restarted).') }
        else { $lines += ,@($G.Warn, 'Yellow', 'Different network: the comparison is not valid.') }
        if ($pending -eq 0) { $lines += ,@($G.Ok, 'Green', 'Every tweak is in place (all marked with a check above).') }
        else { $lines += ,@($G.Warn, 'Yellow', "$pending setting(s) are not as Apply left them (marked with $($G.Warn) above).") }
        $lines += ,@($G.Info, 'DarkGray', 'This test ran once; the scheduled task is already deleted.')
        $lines += ,@($G.Arrow, 'Cyan', 'To undo everything: .\NetTune.ps1 -Mode Revert')
        Write-Box 'After the restart' $lines 'DarkCyan'
        return $true
    } finally {
        if (Test-Path $PendingFile) { Remove-Item -Path $PendingFile -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    }
}

# ---------------------------------------------------------------- adapter state

function Show-AdapterState {
    # Shows the state and returns how many tweaks Apply would still make.
    Write-Title 'Current state'
    $pending = 0
    $tcpOn = -not $NoTcp

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

    $note = if ($tcpOn) { "template $TcpTemplate" } else { '-NoTcp: left as is' }
    Write-Section 'TCP (global)' $note
    foreach ($t in $TcpGlobalTweaks) { $pending += Write-GlobalState 'tcp' $t $tcpOn }
    foreach ($n in @(@('CongestionProvider', 'Congestion provider'), @('EcnCapability', 'ECN'))) {
        $v = Get-TcpGlobalValue $n[0]
        if ($null -eq $v) { $v = 'unknown' }
        Write-KV $n[1] $v 'none' 'left as is'
    }
    foreach ($t in $OffloadGlobalTweaks) { $pending += Write-GlobalState 'offload' $t $tcpOn }

    $note = if ($tcpOn) { 'takes effect after a restart' } else { '-NoTcp: left as is' }
    Write-Section 'Registry' $note
    foreach ($t in $RegTweaks) { $pending += Write-RegState $t $t.Path $t.Label $tcpOn }

    $adapters = @(Get-TargetAdapters)
    if ($adapters.Count -eq 0) { Write-Warn2 'No physical adapter found.'; return $pending }

    foreach ($a in $adapters) {
        Write-AdapterHeader $a
        if ([string]$a.Status -eq 'Up') {
            Write-KV 'Speed' ([string]$a.LinkSpeed)
            $m4 = Get-InterfaceMtu $a.ifIndex 'IPv4'
            $m6 = Get-InterfaceMtu $a.ifIndex 'IPv6'
            $m6Text = if ($null -ne $m6) { [string]$m6 } else { 'off' }
            Write-KV 'MTU' "IPv4 $m4, IPv6 $m6Text"
        }
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

        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue)

        # Offloads (TCP Optimizer group)
        $rss = Get-RssState $a.Name
        if ($null -eq $rss) { Write-KV 'RSS' 'not supported by this adapter' }
        elseif ($rss) { Write-KV 'RSS' 'on' 'ok' }
        elseif ($tcpOn) { Write-KV 'RSS' 'off' 'warn' 'on'; $pending++ }
        else { Write-KV 'RSS' 'off' }

        try {
            $rsc = Get-NetAdapterRsc -Name $a.Name -ErrorAction Stop
            $rscText = "on (IPv4 {0}, IPv6 {1})" -f $rsc.IPv4Enabled, $rsc.IPv6Enabled
            if (-not ($rsc.IPv4Enabled -or $rsc.IPv6Enabled)) { Write-KV 'RSC' 'off' 'ok' }
            elseif ($tcpOn) { Write-KV 'RSC' $rscText 'warn' 'off'; $pending++ }
            else { Write-KV 'RSC' $rscText }
        } catch { Write-KV 'RSC' 'not supported by this adapter' }

        $lso = Get-LsoState $a.Name
        if (-not $lso) { Write-KV 'LSO' 'not supported by this adapter' }
        elseif (-not (Test-LsoOn $lso)) { Write-KV 'LSO' 'off' 'ok' }
        elseif (-not (Test-HasKeyword $props $KwLso)) { Write-KV 'LSO' 'on (fixed by the driver)' }
        elseif ($tcpOn) { Write-KV 'LSO' 'on' 'warn' 'off'; $pending++ }
        else { Write-KV 'LSO' 'on' }

        $ck = Get-ChecksumState $a.Name
        if (-not $ck) { Write-KV 'Checksum offload' 'not supported by this adapter' }
        else {
            $off = @(Get-ChecksumOff $ck)
            if ($off.Count -eq 0) { Write-KV 'Checksum offload' 'on' 'ok' }
            elseif (-not (Test-HasKeyword $props $KwChecksum)) { Write-KV 'Checksum offload' "off for $($off -join ', ') (fixed by the driver)" }
            elseif ($tcpOn) { Write-KV 'Checksum offload' "off for $($off -join ', ')" 'warn' 'on'; $pending++ }
            else { Write-KV 'Checksum offload' "off for $($off -join ', ')" }
        }

        # Nagle (registry, per adapter). On Wi-Fi the adapter key holds the current network's settings,
        # so the other networks' subkeys and the keeper task are shown too.
        $nKeys = @(Get-NagleKeys $a)
        if ($nKeys.Count -gt 0) {
            foreach ($t in $NagleTweaks) { $pending += Write-RegState $t $nKeys[0].Path $t.Name $tcpOn }
        }
        if (Test-WirelessAdapter $a) {
            $subs = @($nKeys | Select-Object -Skip 1)
            if ($subs.Count -gt 0) {
                $okN = @($subs | Where-Object { Test-NagleSet $_.Path }).Count
                $txt = "$okN of $($subs.Count) set"
                if ($okN -eq $subs.Count) { Write-KV 'Nagle, other networks' $txt 'ok' }
                elseif ($tcpOn) { Write-KV 'Nagle, other networks' $txt 'warn' 'all'; $pending++ }
                else { Write-KV 'Nagle, other networks' $txt }
            }
            if (Test-NagleKeeperCovers @([string]$a.InterfaceGuid)) {
                Write-KV 'Nagle keeper (task)' 'on, rewrites it on every network change' 'ok'
            } elseif (-not (Test-IsAdmin) -and -not (Get-NetTuneTask $NagleTask)) {
                Write-KV 'Nagle keeper (task)' 'not found (or readable as admin only)'
            } elseif ($tcpOn) {
                Write-KV 'Nagle keeper (task)' 'missing' 'warn' 'scheduled task'
                $pending++
            } else {
                Write-KV 'Nagle keeper (task)' 'missing'
            }
        }

        # Driver advanced properties, found by RegistryKeyword (DisplayName changes with the Windows language).
        foreach ($p in $props) {
            foreach ($r in $Rules) {
                if ($p.RegistryKeyword -match $r.Keyword) {
                    $valid = @($p.ValidRegistryValues | ForEach-Object { [string]$_ })
                    $cur = [string](@($p.RegistryValue)[0])
                    $i = [array]::IndexOf($valid, $r.Want)
                    if ($i -lt 0) {
                        Write-KV $p.DisplayName $p.DisplayValue
                    } elseif ($cur -eq $r.Want) {
                        Write-KV $p.DisplayName $p.DisplayValue 'ok'
                    } else {
                        Write-KV $p.DisplayName $p.DisplayValue 'warn' ([string]@($p.ValidDisplayValues)[$i])
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

function Get-StaticDns([string]$Stack, [string]$Guid) {
    # The static DNS of one family, as Windows keeps it: NameServer, or (Wi-Fi) ProfileNameServer,
    # the static DNS of the network it is connected to (Wi-Fi keeps one per network). Reading only
    # NameServer saw "empty" on Wi-Fi and Revert then set DHCP instead of the old static DNS.
    # Value '' = automatic (DHCP).
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Stack\Parameters\Interfaces\$Guid"
    foreach ($n in @('NameServer', 'ProfileNameServer')) {
        $s = Get-RegState $k $n
        if ($s.Exists -and ([string]$s.Value).Trim()) { return [pscustomobject]@{ Value = ([string]$s.Value).Trim(); Source = $n } }
    }
    return [pscustomobject]@{ Value = ''; Source = '' }
}

function Get-DnsBackup($Adapter) {
    $guid = [string]$Adapter.InterfaceGuid
    $v4 = Get-StaticDns 'Tcpip' $guid
    $v6 = Get-StaticDns 'Tcpip6' $guid
    # IPv4 / IPv6 are what Revert reads; the *Source fields only say where they came from.
    return [pscustomobject]@{ IPv4 = $v4.Value; IPv6 = $v6.Value; IPv4Source = $v4.Source; IPv6Source = $v6.Source }
}

function Save-Backup($Data) {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -WhatIf:$false | Out-Null }
    $file = Join-Path $BackupDir "backup-$Stamp.json"
    $Data | ConvertTo-Json -Depth 6 | Out-File -FilePath $file -Encoding UTF8 -WhatIf:$false
    return $file
}

function Get-BackupProp($Obj, [string]$Name) {
    # Older backups do not have the newer fields; with StrictMode they have to be read like this.
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Read-RestartAnswer {
    # "Restart now?" with No as the default. Without a console to answer, it is always No.
    try { if ([Console]::IsInputRedirected) { return $false } } catch { }
    try { $ans = Read-Host "  Restart now? (y/N)" } catch { return $false }
    return ([string]$ans -match '^\s*[yYsS]')
}

# ---------------------------------------------------------------- apply

function Invoke-Apply {
    if ($WhatIfPreference) {
        if (-not (Test-IsAdmin)) {
            Write-Host ''
            Write-Warn2 'Not running as administrator: the dry run works, but a few values are readable as admin only.'
        }
    } else {
        Assert-Admin
    }

    $before = $null
    if (-not $SkipTest) { $before = Invoke-NetTest 'Test before the tweaks' }

    [void](Show-AdapterState)

    # DNS: Auto = test and use the fastest (if worth it); Keep = do not touch; a name = force that one.
    $dnsChoice = $null
    $dnsV6Fix  = $null   # IPv4 already is this DNS, only the IPv6 is missing
    switch ($Dns) {
        'Keep'  { }
        'Auto'  {
            $bench = Invoke-DnsBenchmark
            $dnsChoice = $bench.Choice
            $dnsV6Fix  = $bench.V6Fix
        }
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
        Created       = (Get-Date).ToString('s')
        Tool          = "NetTune $Version"
        Computer      = $env:COMPUTERNAME
        WifiPowerPlan = $null
        TcpGlobal     = New-Object 'System.Collections.Generic.List[object]'
        OffloadGlobal = New-Object 'System.Collections.Generic.List[object]'
        Registry      = New-Object 'System.Collections.Generic.List[object]'
        Mtu           = $null
        NagleKeeper   = $null
        Adapters      = @()
    }
    $file = $null
    $toRestart = New-Object 'System.Collections.Generic.List[object]'
    $wifiGuids = New-Object 'System.Collections.Generic.List[string]'

    # The backup is saved in the finally block: if a tweak fails halfway, what was already changed is recorded.
    try {

    # MTU test first, while the connection is untouched. It leaves the MTU as it was; the result is set below.
    $mtuRes = $null
    if (-not $NoMtu) { $mtuRes = Invoke-MtuTest $backup (-not $WhatIfPreference) }

    Write-Title 'Applying tweaks'

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
                $now = Get-WifiPowerPlan
                if ($now -and $now.AC -eq 0 -and $now.DC -eq 0) { Write-Change 'Wi-Fi power saving' $from 'Maximum performance' }
                else { Write-Fail 'Wi-Fi power saving' 'was not applied' }
            } else {
                Write-Change 'Wi-Fi power saving' $from 'Maximum performance'
            }
        } else {
            Write-Info 'Wi-Fi power saving: already at maximum performance' 4
        }
    }

    # 1) TCP Optimizer-style globals and registry (-NoTcp skips them).
    #    Heuristics come first: changed after auto-tuning, they can override it.
    if (-not $NoTcp) {
        Write-Section 'TCP (global)' "template $TcpTemplate"
        foreach ($t in $TcpGlobalTweaks) { Invoke-GlobalTweak 'tcp' $t $backup.TcpGlobal }
        foreach ($t in $OffloadGlobalTweaks) { Invoke-GlobalTweak 'offload' $t $backup.OffloadGlobal }

        Write-Section 'Registry' 'takes effect after a restart'
        foreach ($t in $RegTweaks) { Invoke-RegTweak $t $t.Path $t.Label $backup.Registry }
    }

    foreach ($a in $adapters) {
        Write-AdapterHeader $a

        $entry = [ordered]@{
            Name                 = $a.Name
            InterfaceDescription = $a.InterfaceDescription
            InterfaceGuid        = [string]$a.InterfaceGuid
            PnPCapabilities      = $null
            Rsc                  = $null
            Rss                  = $null
            Lso                  = $null
            Checksum             = $null
            Advanced             = @()
            Dns                  = $null
        }
        # Goes into the backup right away (it is a reference, the changes below end up there).
        $backup.Adapters += $entry
        $changed = $false
        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue)

        # 2) Let Windows turn the adapter off to save power
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
                        Write-Fail 'Windows may turn it off' "PnPCapabilities ended up as '$(Format-PnPCap $now)' (expected $PnPCapOff)"
                    }
                } else {
                    Write-Change 'Windows may turn it off' (Format-PnPCap $old) (Format-PnPCap $PnPCapOff) 'restart the PC'
                }
            }
        }

        # 3) Offloads (TCP Optimizer group). All with -NoRestart: the adapter restarts once, at the end.
        if (-not $NoTcp) {
            # RSC -> off
            $rsc = $null
            try { $rsc = Get-NetAdapterRsc -Name $a.Name -ErrorAction Stop } catch { }
            if (-not $rsc) {
                Write-Info 'RSC: not supported by this adapter' 4
            } elseif (-not ($rsc.IPv4Enabled -or $rsc.IPv6Enabled)) {
                Write-Info 'RSC: already off' 4
            } elseif ($PSCmdlet.ShouldProcess($a.Name, 'Disable RSC')) {
                $entry.Rsc = [ordered]@{ IPv4 = [bool]$rsc.IPv4Enabled; IPv6 = [bool]$rsc.IPv6Enabled }
                try { Disable-NetAdapterRsc -Name $a.Name -NoRestart -ErrorAction Stop } catch { }
                $now = $null
                try { $now = Get-NetAdapterRsc -Name $a.Name -ErrorAction Stop } catch { }
                if ($now -and -not ($now.IPv4Enabled -or $now.IPv6Enabled)) { Write-Change 'RSC' 'on' 'off'; $changed = $true }
                else { Write-Unsupported 'RSC' 'the driver did not accept it' }
            } else {
                Write-Change 'RSC' 'on' 'off'
            }

            # RSS -> on
            $rss = Get-RssState $a.Name
            if ($null -eq $rss) {
                Write-Info 'RSS: not supported by this adapter' 4
            } elseif ($rss) {
                Write-Info 'RSS: already on' 4
            } elseif ($PSCmdlet.ShouldProcess($a.Name, 'Enable RSS')) {
                $entry.Rss = [ordered]@{ Enabled = $false }
                try { Enable-NetAdapterRss -Name $a.Name -NoRestart -ErrorAction Stop } catch { }
                if (Get-RssState $a.Name) { Write-Change 'RSS' 'off' 'on'; $changed = $true }
                else { Write-Unsupported 'RSS' 'the driver did not accept it' }
            } else {
                Write-Change 'RSS' 'off' 'on'
            }

            # Checksum offload -> only make sure it is on
            $ck = Get-ChecksumState $a.Name
            if (-not $ck) {
                Write-Info 'Checksum offload: not supported by this adapter' 4
            } else {
                $off = @(Get-ChecksumOff $ck)
                if ($off.Count -eq 0) {
                    Write-Info 'Checksum offload: already on' 4
                } elseif (-not (Test-HasKeyword $props $KwChecksum)) {
                    Write-Info "Checksum offload: off for $($off -join ', '), fixed by the driver (cannot be changed)" 4
                } elseif ($PSCmdlet.ShouldProcess($a.Name, 'Enable checksum offload')) {
                    $entry.Checksum = $ck
                    try { Enable-NetAdapterChecksumOffload -Name $a.Name -NoRestart -ErrorAction Stop } catch { }
                    $now = Get-ChecksumState $a.Name
                    $offNow = @()
                    if ($now) { $offNow = @(Get-ChecksumOff $now) }
                    if ($now -and $offNow.Count -eq 0) { Write-Change 'Checksum offload' "off for $($off -join ', ')" 'on'; $changed = $true }
                    elseif ($now -and $offNow.Count -lt $off.Count) { Write-Change 'Checksum offload' "off for $($off -join ', ')" "on (still off: $($offNow -join ', '))"; $changed = $true }
                    else { Write-Unsupported 'Checksum offload' 'the driver did not accept it' }
                } else {
                    Write-Change 'Checksum offload' "off for $($off -join ', ')" 'on'
                }
            }

            # LSO -> off
            $lso = Get-LsoState $a.Name
            if (-not $lso) {
                Write-Info 'LSO: not supported by this adapter' 4
            } elseif (-not (Test-LsoOn $lso)) {
                Write-Info 'LSO: already off' 4
            } elseif (-not (Test-HasKeyword $props $KwLso)) {
                Write-Info 'LSO: on, fixed by the driver (cannot be changed)' 4
            } elseif ($PSCmdlet.ShouldProcess($a.Name, 'Disable LSO')) {
                $entry.Lso = [ordered]@{ V1IPv4 = $lso.V1IPv4; IPv4 = $lso.IPv4; IPv6 = $lso.IPv6 }
                try { Disable-NetAdapterLso -Name $a.Name -NoRestart -ErrorAction Stop } catch { }
                $now = Get-LsoState $a.Name
                if ($now -and -not (Test-LsoOn $now)) { Write-Change 'LSO' 'on' 'off'; $changed = $true }
                else { Write-Unsupported 'LSO' 'the driver did not accept it' }
            } else {
                Write-Change 'LSO' 'on' 'off'
            }

            # Nagle: registry of this adapter's TCP/IP interface (also for disconnected adapters).
            # On Wi-Fi also every network subkey, and the keeper task (below) covers new networks.
            $nKeys = @(Get-NagleKeys $a)
            if ($nKeys.Count -eq 0) {
                Write-Info 'Nagle: this adapter has no TCP/IP settings key yet, skipped' 4
            } else {
                foreach ($k in $nKeys) {
                    foreach ($t in $NagleTweaks) { Invoke-RegTweak $t $k.Path "$($t.Name)$($k.Label)" $backup.Registry }
                }
            }
            if (Test-WirelessAdapter $a) { $wifiGuids.Add([string]$a.InterfaceGuid) }
        }

        # 4) Driver advanced properties, by RegistryKeyword (not DisplayName: it changes with the language).
        foreach ($p in $props) {
            $rule = $null
            foreach ($r in $Rules) { if ($p.RegistryKeyword -match $r.Keyword) { $rule = $r; break } }
            if (-not $rule) { continue }

            $valid = @($p.ValidRegistryValues | ForEach-Object { [string]$_ })
            if ($valid.Count -eq 0) { continue }
            $i = [array]::IndexOf($valid, $rule.Want)
            if ($i -lt 0) {
                Write-Warn2 "$($p.DisplayName): no 'off' value (options: $(@($p.ValidDisplayValues) -join ' | '))" 4
                continue
            }
            $target = [string]@($p.ValidDisplayValues)[$i]
            if ([string](@($p.RegistryValue)[0]) -eq $rule.Want) {
                Write-Info "$($p.DisplayName): already '$($p.DisplayValue)'" 4
                continue
            }

            $entry.Advanced += [ordered]@{
                DisplayName     = $p.DisplayName
                RegistryKeyword = $p.RegistryKeyword
                RegistryValue   = @($p.RegistryValue)
                DisplayValue    = $p.DisplayValue
            }
            if ($PSCmdlet.ShouldProcess($a.Name, "$($p.DisplayName): '$($p.DisplayValue)' -> '$target'")) {
                $err = $null
                try { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -RegistryValue $rule.Want -NoRestart -ErrorAction Stop } catch { $err = $_.Exception.Message }
                $now = $null
                try { $now = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $p.RegistryKeyword -ErrorAction Stop } catch { }
                if ($now -and [string](@($now.RegistryValue)[0]) -eq $rule.Want) {
                    Write-Change $p.DisplayName $p.DisplayValue $now.DisplayValue
                    $changed = $true
                } elseif ($err) {
                    Write-Fail $p.DisplayName $err
                } else {
                    Write-Fail $p.DisplayName 'was not applied'
                }
            } else {
                Write-Change $p.DisplayName $p.DisplayValue $target
            }
        }

        # 5) DNS: IPv4 and IPv6 set by hand, each family separately, and confirmed by reading them back.
        #    $dnsV6Fix: only the IPv6, and only on adapters whose IPv4 already is that DNS.
        $dnsPreset = if ($dnsChoice) { $dnsChoice } else { $dnsV6Fix }
        if ($dnsPreset) {
            $want4 = @($DnsPresets[$dnsPreset] | Where-Object { $_ -notmatch ':' })
            $want6 = @($DnsPresets[$dnsPreset] | Where-Object { $_ -match ':' })
            $now4  = @(Get-AdapterDnsList $a.ifIndex 'IPv4')
            $now6  = @(Get-AdapterDnsList $a.ifIndex 'IPv6')
            $v6On  = Test-AdapterIPv6 $a

            if ($dnsChoice) {
                $touch = $true
                $need4 = -not (Test-SameList $now4 $want4)
            } else {
                $touch = ($now4.Count -gt 0) -and (@($now4 | Where-Object { $want4 -notcontains $_ }).Count -eq 0)
                $need4 = $false
            }
            $need6 = $touch -and $v6On -and -not (Test-SameList $now6 $want6)
            if (-not $touch) {
                # IPv6 fix only and this adapter's IPv4 is not that DNS: leave it alone.
            } elseif (-not $need4 -and -not $need6) {
                Write-Info "DNS: already $dnsPreset" 4
            } else {
                $entry.Dns = Get-DnsBackup $a
                foreach ($fam in @(@('IPv4', $need4, $now4, $want4), @('IPv6', $need6, $now6, $want6))) {
                    if (-not $fam[1]) { continue }
                    $from = if (@($fam[2]).Count -gt 0) { (@($fam[2]) | Select-Object -First 2) -join ', ' } else { 'automatic' }
                    $to = "$dnsPreset (" + (@($fam[3]) -join ', ') + ')'
                    if ($PSCmdlet.ShouldProcess($a.Name, "DNS $($fam[0]) -> $to")) {
                        $after = @(Set-AdapterDnsFamily $a $fam[0] @($fam[3]))
                        if (Test-SameList $after @($fam[3])) {
                            Write-Change "DNS $($fam[0])" $from $to
                        } else {
                            $got = if ($after.Count -gt 0) { $after -join ', ' } else { 'automatic' }
                            Write-Fail "DNS $($fam[0])" "was not applied (now: $got)"
                        }
                    } else {
                        Write-Change "DNS $($fam[0])" $from $to
                    }
                }
            }
            if ($touch -and -not $v6On) { Write-Info 'DNS IPv6: IPv6 is disabled on this adapter, only IPv4 was needed.' 4 }
        }

        if ($changed) { $toRestart.Add($a) }
    }

    # 6) Nagle on Wi-Fi: Windows rebuilds the adapter key on every network change, wiping the values.
    #    A SYSTEM task writes them again whenever a network connects.
    if (-not $NoTcp -and $wifiGuids.Count -gt 0) {
        $guids = @($wifiGuids)
        $label = 'Nagle keeper (scheduled task)'
        Write-Section 'Nagle on Wi-Fi' 'kept on every network change'
        if (Test-NagleKeeperCovers $guids) {
            Write-Info "${label}: already in place" 4
        } elseif ($PSCmdlet.ShouldProcess("$($NagleTask.Path)$($NagleTask.Name)", 'Register the task (SYSTEM, runs when a network connects)')) {
            $existed = [bool](Get-NetTuneTask $NagleTask)
            $backup.NagleKeeper = [ordered]@{ Existed = $existed; Guids = $guids }
            $err = $null
            try { Register-NagleKeeper $guids } catch { $err = $_.Exception.Message }
            if (Test-NagleKeeperCovers $guids) {
                $from = if ($existed) { 'other adapters' } else { 'none' }
                Write-Change $label $from 'rewrites Nagle on every network change'
            } elseif ($err) {
                Write-Fail $label "could not register it: $err"
            } else {
                Write-Fail $label 'was not registered'
            }
        } else {
            Write-Change $label 'none' 'rewrites Nagle on every network change'
        }
    }

    # 7) MTU found by the test
    if ($mtuRes -and $mtuRes.Mtu) { Set-ActiveMtu $mtuRes $backup }

    # 8) Adapters restart once, all together, to apply RSC / RSS / checksum / LSO / driver options.
    $up = @($toRestart | Where-Object { [string]$_.Status -eq 'Up' })
    foreach ($a in @($toRestart | Where-Object { [string]$_.Status -ne 'Up' })) {
        Write-Info "$($a.Name): disconnected, the changes apply when you connect it." 2
    }
    if ($up.Count -gt 0 -and $PSCmdlet.ShouldProcess((@($up | ForEach-Object { $_.Name }) -join ', '), 'Restart the adapter(s) to apply')) {
        Write-Host ''
        Write-Info "Restarting $($up.Count) adapter(s) once to apply the changes (the connection drops for a few seconds)..."
        foreach ($a in $up) { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue }
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
        $lines += ,@($G.Info, 'DarkGray', 'At the end of a real Apply that needs a restart, "Restart now? (y/N)":')
        $lines += ,@(' ', 'Gray', 'y saves the "before" test to logs\pending-after-restart.json,')
        $lines += ,@(' ', 'Gray', "schedules a one-time test at your next logon ($($AfterTask.Path)$($AfterTask.Name))")
        $lines += ,@(' ', 'Gray', 'and restarts. Nothing is scheduled with -WhatIf.')
        $lines += ,@($G.Arrow, 'Cyan', 'To apply: .\NetTune.ps1 -Mode Apply')
        Write-Box 'Simulation' $lines 'DarkYellow'
        return
    }

    if ($script:ChangeCount -eq 0) {
        # Nothing changed: the network did not drop and an "after" test would only repeat the "before" one.
        Write-Host ''
        Write-Info 'Nothing was changed, so there is no "after" test.'
    } else {
        if ($dnsChoice -or $dnsV6Fix) { Clear-DnsClientCache -ErrorAction SilentlyContinue }

        Write-Host ''
        Write-Info 'Waiting for the network to come back...'
        if (-not (Wait-Network 40)) { Write-Warn2 'The network took a while to come back. Check the connection before the test.' }
        Start-Sleep -Seconds 3

        if (-not $SkipTest) {
            $after = Invoke-NetTest 'Test after the tweaks'
            if ($before) { Show-Comparison $before $after }
        }
    }

    $n = $script:ChangeCount
    $lines = @()
    if ($n -gt 0) { $lines += ,@($G.Ok, 'Green', "$n change(s) applied") }
    else          { $lines += ,@($G.Ok, 'Green', 'Nothing to change: everything was already optimized') }
    if ($file)    { $lines += ,@($G.Info, 'DarkGray', "Backup: backups\$(Split-Path $file -Leaf)") }
    $lines += ,@($G.Arrow, 'Cyan', 'To undo: .\NetTune.ps1 -Mode Revert')
    if ($script:RegChanged) {
        $lines += ,@($G.Warn, 'Yellow', 'RESTART THE PC: the registry values (Nagle, MMCSS, Tcpip,')
        $lines += ,@(' ', 'Gray', 'ServiceProvider) only take effect after a restart, and the')
        $lines += ,@(' ', 'Gray', '"after" test does not include them yet.')
        $lines += ,@($G.Arrow, 'Cyan', 'Restart and run -Mode Test to see the full effect.')
    } elseif ($script:RebootNeeded) {
        $lines += ,@($G.Warn, 'Yellow', 'RESTART THE PC for the power management change to take effect.')
        $lines += ,@(' ', 'Gray', 'The "after" test does not include that change yet.')
    }
    $lines += ,@($G.Info, 'DarkGray', 'Driver updates can restore the factory values.')
    $lines += ,@(' ', 'Gray', 'If the spikes come back, run Apply again.')
    Write-Box 'Done' $lines 'DarkGreen'

    if ($script:RebootNeeded) {
        Write-Host ''
        if (Read-RestartAnswer) {
            # Continue by itself after the restart: save the "before" test and schedule a one-time run.
            $saved = $false
            try {
                Save-PendingState $before $file
                $saved = $true
            } catch {
                Write-Warn2 "Could not save logs\pending-after-restart.json: $($_.Exception.Message)"
            }
            if ($saved) {
                $err = $null
                try { Register-AfterRestartTask } catch { $err = $_.Exception.Message }
                if (Get-NetTuneTask $AfterTask) {
                    Write-Ok 'After the restart, when you log in, NetTune opens by itself and runs the test (once).'
                    if (-not $before) { Write-Info 'Apply ran with -SkipTest, so there will be no before / after table.' 4 }
                } else {
                    Write-Warn2 "Could not schedule the test after the restart$(if ($err) { ": $err" } else { '' })."
                    Write-Info 'After restarting, run .\NetTune.ps1 -Mode Test yourself to see the full effect.' 4
                    Remove-Item -Path $PendingFile -Force -ErrorAction SilentlyContinue
                }
            }
            $script:RestartNow = $true
        }
    }
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
    $p = Get-BackupProp $data 'WifiPowerPlan'
    if ($p) {
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

    # TCP globals and offloads (1.7.0+), in the same order they were applied.
    $tg = @(Get-BackupProp $data 'TcpGlobal' | Where-Object { $_ })
    $og = @(Get-BackupProp $data 'OffloadGlobal' | Where-Object { $_ })
    if ($tg.Count + $og.Count -gt 0) {
        Write-Section 'TCP (global)'
        foreach ($e in $tg) {
            $t = $TcpGlobalTweaks | Where-Object { $_.Name -eq $e.Name } | Select-Object -First 1
            if ($t) { Restore-GlobalTweak 'tcp' $t $e.Old }
        }
        foreach ($e in $og) {
            $t = $OffloadGlobalTweaks | Where-Object { $_.Name -eq $e.Name } | Select-Object -First 1
            if ($t) { Restore-GlobalTweak 'offload' $t $e.Old }
        }
    }

    # Registry (1.7.0+), newest first: a key created by Apply is deleted once its last value goes.
    $reg = @(Get-BackupProp $data 'Registry' | Where-Object { $_ })
    if ($reg.Count -gt 0) {
        Write-Section 'Registry'
        for ($i = $reg.Count - 1; $i -ge 0; $i--) { Restore-RegValue $reg[$i] }
    }

    # Nagle keeper on Wi-Fi (1.7.0+): the task goes, and so do the values it wrote for networks
    # joined after Apply (they are not in the backup, so they did not exist before).
    $keeper = Get-BackupProp $data 'NagleKeeper'
    if ($keeper) {
        Write-Section 'Nagle on Wi-Fi'
        if (-not $keeper.Existed -and $PSCmdlet.ShouldProcess("$($NagleTask.Path)$($NagleTask.Name)", 'Remove the scheduled task')) {
            if (Remove-NetTuneTask $NagleTask) { Write-Change 'Nagle keeper (scheduled task)' 'on' 'removed' }
            else { Write-Fail 'Nagle keeper (scheduled task)' 'could not be removed' }
        }
        $known = @($reg | ForEach-Object { "$($_.Path)|$($_.Name)" })
        # Not "$g": PowerShell names ignore case, so $g would replace the $G symbol table.
        foreach ($guid in @($keeper.Guids)) {
            $ifKey = "$TcpipKey\Interfaces\$guid"
            if (-not (Test-Path -LiteralPath $ifKey)) { continue }
            $paths = @($ifKey) + @(Get-ChildItem -LiteralPath $ifKey -ErrorAction SilentlyContinue | ForEach-Object { "$ifKey\$($_.PSChildName)" })
            foreach ($p in $paths) {
                foreach ($t in $NagleTweaks) {
                    if ($known -contains "$p|$($t.Name)") { continue }
                    if (-not (Get-RegState $p $t.Name).Exists) { continue }
                    $net = if ($p -eq $ifKey) { '' } else { " (network $(ConvertFrom-NetworkKeyName (Split-Path $p -Leaf)))" }
                    if ($PSCmdlet.ShouldProcess($p, "Delete $($t.Name)")) {
                        try {
                            Remove-ItemProperty -LiteralPath $p -Name $t.Name -ErrorAction Stop
                            Write-Change "$($t.Name)$net" 'set by the keeper' 'not set (deleted)' 'restart the PC'
                            $script:RebootNeeded = $true
                        } catch { Write-Fail "$($t.Name)$net" $_.Exception.Message }
                    }
                }
            }
        }
    }

    # A pending test after the restart makes no sense once the tweaks are undone.
    if ((Get-NetTuneTask $AfterTask) -or (Test-Path $PendingFile)) {
        Write-Section 'Test after the restart'
        if ($PSCmdlet.ShouldProcess('after-restart test', 'Remove the scheduled task and the state file')) {
            if (Test-Path $PendingFile) { Remove-Item -Path $PendingFile -Force -ErrorAction SilentlyContinue }
            if (Remove-NetTuneTask $AfterTask) { Write-Change 'Pending test after the restart' 'scheduled' 'removed' }
            else { Write-Fail 'Pending test after the restart' 'the scheduled task could not be removed' }
        }
    }

    $toRestart = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in @($data.Adapters)) {
        $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $e.InterfaceGuid } | Select-Object -First 1
        if (-not $a) { $a = Get-NetAdapter -Name $e.Name -ErrorAction SilentlyContinue }
        if (-not $a) { Write-Host ''; Write-Warn2 "Adapter '$($e.Name)' not found, skipping."; continue }

        Write-AdapterHeader $a
        $changed = $false

        foreach ($adv in @(Get-BackupProp $e 'Advanced')) {
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

        $rscB = Get-BackupProp $e 'Rsc'
        if ($rscB -and $PSCmdlet.ShouldProcess($a.Name, 'Restore RSC')) {
            try {
                if ($rscB.IPv4) { Enable-NetAdapterRsc -Name $a.Name -IPv4 -NoRestart -ErrorAction Stop }
                if ($rscB.IPv6) { Enable-NetAdapterRsc -Name $a.Name -IPv6 -NoRestart -ErrorAction Stop }
                Write-Change 'RSC' 'off' 'on'
                $changed = $true
            } catch { Write-Warn2 "RSC: $($_.Exception.Message)" 4 }
        }

        $rssB = Get-BackupProp $e 'Rss'
        if ($rssB -and $PSCmdlet.ShouldProcess($a.Name, 'Restore RSS (off)')) {
            try {
                Disable-NetAdapterRss -Name $a.Name -NoRestart -ErrorAction Stop
                if ((Get-RssState $a.Name) -eq $false) { Write-Change 'RSS' 'on' 'off'; $changed = $true }
                else { Write-Fail 'RSS' 'was not restored' }
            } catch { Write-Warn2 "RSS: $($_.Exception.Message)" 4 }
        }

        $ckB = Get-BackupProp $e 'Checksum'
        if ($ckB -and $PSCmdlet.ShouldProcess($a.Name, 'Restore checksum offload')) {
            try {
                $args2 = @{}
                foreach ($k in $ChecksumProps.Keys) {
                    $v = Get-BackupProp $ckB $k
                    if ($v) { $args2[$k] = [string]$v }
                }
                Set-NetAdapterChecksumOffload -Name $a.Name @args2 -NoRestart -ErrorAction Stop
                Write-Change 'Checksum offload' 'on' 'as before'
                $changed = $true
            } catch { Write-Warn2 "Checksum offload: $($_.Exception.Message)" 4 }
        }

        $lsoB = Get-BackupProp $e 'Lso'
        if ($lsoB -and $PSCmdlet.ShouldProcess($a.Name, 'Restore LSO')) {
            try {
                $args2 = @{}
                if ($lsoB.V1IPv4) { $args2['V1IPv4'] = $true }
                if ($lsoB.IPv4)   { $args2['IPv4'] = $true }
                if ($lsoB.IPv6)   { $args2['IPv6'] = $true }
                Enable-NetAdapterLso -Name $a.Name @args2 -NoRestart -ErrorAction Stop
                $now = Get-LsoState $a.Name
                if ($now -and (Test-LsoOn $now)) { Write-Change 'LSO' 'off' 'on'; $changed = $true }
                else { Write-Fail 'LSO' 'was not restored' }
            } catch { Write-Warn2 "LSO: $($_.Exception.Message)" 4 }
        }

        # Power management: PnPCapabilities. Old backups (PowerManagement) are ignored on purpose:
        # that version never managed to change anything (Set-NetAdapterPowerManagement has no such parameter).
        $pc = Get-BackupProp $e 'PnPCapabilities'
        if ($pc) {
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

        $dnsB = Get-BackupProp $e 'Dns'
        if ($dnsB) {
            # Each family goes back to what it was: the old static list, or automatic (DHCP) if there was none.
            $old4 = @(([string]$dnsB.IPv4) -split '[,\s]+' | Where-Object { $_ })
            $old6 = @(([string]$dnsB.IPv6) -split '[,\s]+' | Where-Object { $_ })
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

        if ($changed) { $toRestart.Add($a) }
    }

    # MTU (1.7.0+)
    $mtuB = Get-BackupProp $data 'Mtu'
    if ($mtuB) {
        $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $mtuB.InterfaceGuid } | Select-Object -First 1
        if (-not $a) { $a = Get-NetAdapter -Name $mtuB.Alias -ErrorAction SilentlyContinue }
        if (-not $a) {
            Write-Host ''
            Write-Warn2 "MTU: adapter '$($mtuB.Alias)' not found, skipping."
        } else {
            Write-Section "MTU ($($a.Name))"
            foreach ($fam in @('IPv4', 'IPv6')) {
                $old = Get-BackupProp $mtuB $fam
                if ($null -eq $old) { continue }
                $now = Get-InterfaceMtu $a.ifIndex $fam
                if ($now -eq [int]$old) { Write-Info "MTU ${fam}: already $old" 4; continue }
                if ($PSCmdlet.ShouldProcess($a.Name, "MTU $fam -> $old")) {
                    [void](Set-InterfaceMtu $a.Name $fam ([int]$old) 'persistent')
                    $after = Get-InterfaceMtu $a.ifIndex $fam
                    if ($after -eq [int]$old) { Write-Change "MTU $fam" ([string]$now) ([string]$old) }
                    else { Write-Fail "MTU $fam" "was not restored (now: $after)" }
                }
            }
        }
    }

    # Adapters restart once, all together.
    $up = @($toRestart | Where-Object { [string]$_.Status -eq 'Up' })
    if ($up.Count -gt 0 -and $PSCmdlet.ShouldProcess((@($up | ForEach-Object { $_.Name }) -join ', '), 'Restart the adapter(s)')) {
        Write-Host ''
        Write-Info "Restarting $($up.Count) adapter(s) once (the connection drops for a few seconds)..."
        foreach ($a in $up) { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue }
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
        $lines += ,@($G.Warn, 'Yellow', 'RESTART THE PC for everything to go back to the original.')
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
    if ($AfterRestart -and $Mode -ne 'Test') { throw '-AfterRestart only works with -Mode Test.' }
    # A test after a restart that never happened (older than 24 h) is removed without running it.
    if (-not $AfterRestart) { Clear-StalePending }
    switch ($Mode) {
        'Test' {
            # Started by the one-time task after the restart: compare with the saved "before".
            $handled = $false
            if ($AfterRestart) { $handled = Invoke-AfterRestart }
            if (-not $handled) {
                $pending = Show-AdapterState
                [void](Invoke-NetTest 'Connection test')
                $dnsChoice = $null
                $dnsV6Fix  = $null
                if ($Dns -ne 'Keep') {
                    $bench = Invoke-DnsBenchmark
                    $dnsChoice = $bench.Choice
                    $dnsV6Fix  = $bench.V6Fix
                    if ($dnsChoice -or $dnsV6Fix) { $pending++ }
                }
                # MTU: Test mode only shows the result (it never raises the MTU, not even for a moment).
                $mtuRes = $null
                if (-not $NoMtu) {
                    $mtuRes = Invoke-MtuTest $null $false
                    if ($mtuRes -and $mtuRes.Mtu -and $mtuRes.Mtu -ne $mtuRes.Cur4) { $pending++ }
                }
                $lines = @()
                if ($dnsChoice) {
                    $lines += ,@($G.Star, 'Green', "Best DNS: $dnsChoice (Apply sets it, IPv4 and IPv6)")
                } elseif ($dnsV6Fix) {
                    $lines += ,@($G.Star, 'Green', "DNS: IPv4 already $dnsV6Fix, Apply sets the IPv6 too")
                }
                if ($mtuRes -and $mtuRes.Mtu) {
                    if ($mtuRes.Mtu -ne $mtuRes.Cur4) { $lines += ,@($G.Star, 'Green', "MTU: $($mtuRes.Mtu) on this network (now $($mtuRes.Cur4), Apply sets it)") }
                    else { $lines += ,@($G.Ok, 'Green', "MTU $($mtuRes.Mtu) is already right for this network") }
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
        try { Stop-Transcript | Out-Null } catch { }   # Stop-Transcript has no -WhatIf
    }
    Write-Host ''
    Write-Seg "  Finished in $took" DarkGray
    if ($transcript) { Write-Seg "  $($G.Dot)  log: logs\$(Split-Path $transcript -Leaf)" DarkGray }
    Write-Host ''
    Write-Host ''
    # Only after the log is closed, so it is complete.
    if ($script:RestartNow) {
        Write-Host '  Restarting the PC...' -ForegroundColor Yellow
        try { Restart-Computer -Force -ErrorAction Stop } catch { Write-Host "  Could not restart: $($_.Exception.Message)" -ForegroundColor Red }
    }
}
