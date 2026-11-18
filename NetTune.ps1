#Requires -Version 5.1
<#
.SYNOPSIS
    NetTune - ajustes honestos de rede para jogar com ping estável (Windows 10/11).

.DESCRIPTION
    Mede a ligação (router, internet e servidores de jogos: Epic, Valve, Blizzard, Ubisoft,
    Microsoft, Embark, cada um na região mais próxima), aplica apenas ajustes com efeito real
    em latência/estabilidade e volta a medir para comparar. Antes de mudar qualquer coisa guarda
    um backup em JSON, para poderes desfazer tudo com -Mode Revert.

    No plano de energia ativo do Windows:
      - "Definições do adaptador sem fios > Modo de poupança de energia" -> Desempenho máximo (corrente e bateria)

    O que o modo Apply muda, em cada placa de rede física (Wi-Fi e Ethernet, incluindo USB):
      - "Permitir que o computador desligue este dispositivo" -> desligado
        (PnPCapabilities = 24 na chave da placa; precisa de REINICIAR O PC para fazer efeito)
      - Poupança de energia da placa Wi-Fi (Power Saving) -> desligada
      - Agressividade de roaming -> a mais baixa / desativada
      - Energy-Efficient Ethernet / Green Ethernet -> desligado
      - Suspensão seletiva USB do adaptador -> desligada
      - RSC (Receive Segment Coalescing) -> desligado
      - DNS -> testa o atual contra Cloudflare, Google, Quad9 e OpenDNS e aplica o mais rápido,
        só se for claramente melhor (o DNS NÃO muda o ping nos jogos, só a rapidez a abrir nomes)

.PARAMETER Mode
    Test   : só mede e mostra o estado das placas (não precisa de admin, não muda nada). Padrão.
    Apply  : mede, faz backup, aplica os ajustes, volta a medir e compara. Precisa de admin.
    Revert : repõe o último backup (ou o indicado em -BackupFile). Precisa de admin.

.PARAMETER Dns
    Auto (padrão): testa o DNS atual contra Cloudflare, Google, Quad9 e OpenDNS e, no Apply, muda para
    o mais rápido se ganhar pelo menos 3 ms e 15%. Keep: não testa nem mexe no DNS.
    Cloudflare, Google, Quad9 ou OpenDNS: força esse DNS no Apply, sem testar.

.PARAMETER Count
    Número de pings por alvo nos testes (padrão 50, cerca de 10 s por alvo).

.PARAMETER ExtraTargets
    Alvos extra para o teste, por exemplo o IP de um servidor de outro jogo.

.PARAMETER BackupFile
    Ficheiro de backup a usar no modo Revert. Por defeito usa o mais recente da pasta backups.

.PARAMETER SkipTest
    No modo Apply, salta os testes antes/depois.

.PARAMETER Services
    Que serviços de jogos testar: Epic, Valve, Blizzard, Ubisoft, Microsoft, Embark. Por defeito, todos.
    Para cada um, o script escolhe sozinho a região mais próxima.

.PARAMETER Ascii
    Usa só caracteres ASCII no ecrã (para consolas antigas sem fonte Unicode).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1
    Mede a ligação e mostra o estado atual das placas.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -WhatIf
    Mostra o que seria mudado, sem mudar nada.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -Dns Cloudflare
    Aplica os ajustes e define o DNS da Cloudflare.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Revert
    Desfaz tudo usando o backup mais recente.
#>
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

    # Sem ValidateSet de propósito: com "powershell -File" o "Epic,Valve" chega como um texto só.
    # A lista é separada e validada mais abaixo.
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

# Domínios do teste de DNS (o que usas a jogar: lojas, launchers, chat, streams).
$DnsTestDomains = @('google.com', 'youtube.com', 'epicgames.com', 'steampowered.com', 'battle.net',
                    'ubisoft.com', 'xboxlive.com', 'discord.com', 'twitch.tv', 'microsoft.com')

# Regras para as propriedades avançadas das placas.
# Display: regex contra o nome da propriedade (EN / PT / ES, porque o driver usa a língua do Windows).
# Want   : regex contra os valores válidos; escolhe o primeiro que bater.
# "Desligado" em EN / PT-BR / PT-PT / ES (Disabled, Desabilitado, Desativado, Desactivado, Deshabilitado...).
$OffValues = 'Disab|Desab|Deshab|Desact|Desativ|Deslig|^Off$'

$Rules = @(
    @{ Label = 'Poupança de energia da placa'
       Display = '^(Power Saving|Power Save Mode|Power Saving Mode|Modo de economia de energia|Economia de energia|Poupança de energia|Modo de poupança de energia|Ahorro de energía|Modo de ahorro de energía)$'
       Want = $OffValues }
    @{ Label = 'Agressividade de roaming'
       Display = 'Roaming Aggressiveness|Agressividade de roaming|Agresividad de itinerancia|Agresividad de roaming'
       Want = '^1\.|Lowest|Mais baix|Más baj|Disab|Desab|Deshab|Desact' }
    @{ Label = 'Energy-Efficient Ethernet'
       Display = 'Energy.Efficient Ethernet|Advanced EEE|^EEE$|Green Ethernet|Ethernet verde|Ethernet.*efici'
       Want = $OffValues }
    @{ Label = 'Suspensão seletiva USB'
       Display = 'Selective Suspend|Suspensão seletiva|Suspensión selectiva'
       Want = $OffValues }
)

# Plano de energia do Windows -> "Definições do adaptador sem fios" -> "Modo de poupança de energia".
# 0 = Desempenho máximo, 1 = Poupança baixa, 2 = Poupança média, 3 = Poupança máxima.
$WifiPowerSub   = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$WifiPowerSet   = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
$WifiPowerNames = @('Desempenho máximo', 'Poupança baixa', 'Poupança média', 'Poupança máxima')

# "Permitir que o computador desligue este dispositivo para poupar energia" vive no valor PnPCapabilities
# da chave da placa (classe de rede). 24 (0x18) = desligado. Só faz efeito depois de reiniciar o PC.
$NetClassKey    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$PnPCapOff      = 24
$script:RebootNeeded = $false
$script:ChangeCount  = 0

# ---------------------------------------------------------------- servidores de jogos
# Para cada serviço, o teste mede rapidamente todas as regiões e fica com a mais próxima de ti.
# Cada região: @(nome, host, método). icmp = ping normal; tcp = tempo de ligação TCP à porta 443
# (para quem bloqueia o ping, como a Azure). O handshake TCP demora praticamente um ida-e-volta.

function New-AzureRegions([string[]]$Names) {
    $pt = @{
        northeurope = 'Irlanda'; westeurope = 'Holanda'; francecentral = 'Paris'; uksouth = 'Londres'
        germanywestcentral = 'Frankfurt'; spaincentral = 'Madrid'; swedencentral = 'Suécia'
        eastus = 'EUA Este'; centralus = 'EUA Centro'; southcentralus = 'EUA Sul'; westus = 'EUA Oeste'
        brazilsouth = 'Brasil'; japaneast = 'Japão'; koreacentral = 'Coreia'; southeastasia = 'Singapura'; australiaeast = 'Austrália'
    }
    foreach ($n in $Names) { , @("Azure $($pt[$n])", "s8$n.blob.core.windows.net", 'tcp') }
}

$GameServices = [ordered]@{
    # Beacons de ping oficiais do Fortnite.
    Epic = @{ Name = 'Epic Games'; Regions = @(
        @('França', 'ping-fr.ds.on.epicgames.com', 'icmp'),
        @('Alemanha', 'ping-de.ds.on.epicgames.com', 'icmp'),
        @('Reino Unido', 'ping-gb.ds.on.epicgames.com', 'icmp'),
        @('EUA Este', 'ping-va.ds.on.epicgames.com', 'icmp'),
        @('EUA Centro', 'ping-oh.ds.on.epicgames.com', 'icmp'),
        @('EUA Oeste', 'ping-or.ds.on.epicgames.com', 'icmp'),
        @('Brasil', 'ping-br.ds.on.epicgames.com', 'icmp')) }

    # Relays SDR da Valve (por onde passa o tráfego do CS2, Dota 2, Deadlock...).
    # A lista vem em direto da API da Steam; esta é só a reserva se a API falhar.
    Valve = @{ Name = 'Valve / Steam'; Dynamic = 'SteamSDR'; Regions = @(
        @('Madrid', '155.133.246.34', 'icmp'),
        @('Paris', '185.25.182.18', 'icmp'),
        @('Frankfurt', '155.133.226.68', 'icmp'),
        @('Amesterdão', '155.133.248.36', 'icmp'),
        @('Londres', '162.254.196.66', 'icmp'),
        @('Estocolmo', '162.254.198.41', 'icmp'),
        @('Viena', '146.66.155.66', 'icmp'),
        @('Varsóvia', '155.133.230.100', 'icmp'),
        @('EUA Este', '162.254.192.88', 'icmp')) }

    # Servidores Battle.net (estão na Google Cloud).
    Blizzard = @{ Name = 'Blizzard'; Regions = @(
        @('Europa', 'eu.actual.battle.net', 'icmp'),
        @('EUA', 'us.actual.battle.net', 'icmp'),
        @('Coreia', 'kr.actual.battle.net', 'icmp')) }

    # Rainbow Six e outros: Azure (regiões da config do jogo) e AWS GameLift em algumas regiões.
    Ubisoft = @{ Name = 'Ubisoft'; Regions = @(
        (New-AzureRegions @('northeurope', 'westeurope', 'eastus', 'centralus', 'southcentralus', 'westus', 'brazilsouth')) +
        @(@('AWS Frankfurt', 'dynamodb.eu-central-1.amazonaws.com', 'icmp'),
          @('AWS EUA Este', 'dynamodb.us-east-1.amazonaws.com', 'icmp'))) }

    # Xbox / jogos da Microsoft: Azure.
    Microsoft = @{ Name = 'Microsoft / Xbox'; Regions = @(
        New-AzureRegions @('northeurope', 'westeurope', 'francecentral', 'uksouth', 'germanywestcentral', 'spaincentral',
                           'swedencentral', 'eastus', 'centralus', 'westus', 'brazilsouth', 'japaneast', 'koreacentral',
                           'southeastasia', 'australiaeast')) }

    # The Finals / Arc Raiders correm na Google Cloud, mas a Embark não tem endpoints públicos de ping.
    # Referência: regiões Google Cloud onde há servidores públicos que respondem (os do Battle.net).
    Embark = @{ Name = 'Embark'; Regions = @(
        @('Google Cloud Holanda', 'eu.actual.battle.net', 'icmp'),
        @('Google Cloud EUA', 'us.actual.battle.net', 'icmp'),
        @('Google Cloud Coreia', 'kr.actual.battle.net', 'icmp')) }
}
$script:GameTargets = $null

# Normalizar -Services: aceita "Epic,Valve", "epic valve" ou -Services Epic,Valve; nomes sem maiúsculas certas.
$script:ArgError = $null
$wantedServices = @($Services | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
$Services = @(foreach ($w in $wantedServices) {
    $match = @($GameServices.Keys) | Where-Object { $_ -eq $w } | Select-Object -First 1
    if ($match) { $match }
    elseif (-not $script:ArgError) {
        # Mostrado pelo tratamento de erros normal, depois do banner.
        $script:ArgError = "Serviço desconhecido em -Services: '$w'. Opções: $(@($GameServices.Keys) -join ', ')"
    }
})

# Placas que nunca tocamos (VPNs, virtuais, Bluetooth).
$ExcludeAdapters = 'Bluetooth|Virtual|\bTAP\b|Tunnel|VPN|Wintun|WireGuard|Hyper-V|Loopback|Check Point|TunnelBear'

# ---------------------------------------------------------------- aparência

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
    # Uma alteração feita (ou simulada com -WhatIf). Conta para o resumo.
    $sim = [bool]$WhatIfPreference
    if ($sim) { Write-Seg "    $($G.Sim) " Cyan } else { Write-Seg "    $($G.Ok) " Green }
    Write-Seg $Label White
    Write-Seg "  $From " DarkYellow
    Write-Seg $G.Arrow DarkGray
    Write-Seg " $To" Green
    if ($Note) { Write-Seg "  ($Note)" DarkGray }
    if ($sim)  { Write-Seg '  [simulação]' DarkCyan }
    Write-Host ''
    $script:ChangeCount++
}

function Write-KV([string]$Key, [string]$Value, [string]$State = 'none', [string]$Hint = '') {
    # Linha "chave ······ valor" com estado: ok (verde), warn (amarelo, o Apply muda), bad, none.
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
    # $Lines: lista de @(glifo, cor, texto)
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
        Test   = @('TESTE',   'Só mede e mostra o estado. Não muda nada.',            'Cyan')
        Apply  = @('APLICAR', 'Mede, faz backup, aplica os ajustes e volta a medir.', 'Green')
        Revert = @('REPOR',   'Repõe o backup e desfaz os ajustes.',                  'Magenta')
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

    foreach ($line in @(@("Ping estável para jogar $($G.Dot) Windows 10/11", 'Gray'), @($info[1], 'DarkGray'))) {
        Write-Seg "  $($G.V)  " DarkCyan
        Write-Seg ($line[0].PadRight($w - 4)) $line[1]
        Write-Host "  $($G.V)" -ForegroundColor DarkCyan
    }
    if ($WhatIfPreference) {
        Write-Seg "  $($G.V)  " DarkCyan
        Write-Seg ('Simulação (-WhatIf): nada vai ser mudado.'.PadRight($w - 4)) Yellow
        Write-Host "  $($G.V)" -ForegroundColor DarkCyan
    }
    Write-Host ("  $($G.BL)" + ($G.H * $w) + $G.BR) -ForegroundColor DarkCyan
}

function Write-AdapterHeader($Adapter) {
    $st = switch ([string]$Adapter.Status) {
        'Up'           { @('ligada', 'Green') }
        'Disconnected' { @('sem ligação', 'Yellow') }
        'Disabled'     { @('desativada', 'DarkGray') }
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

# ---------------------------------------------------------------- utilitários

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        throw 'Este modo precisa de administrador. Abre o PowerShell com "Executar como administrador" e corre outra vez.'
    }
}

function Get-TargetAdapters {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne 'Not Present' -and $_.InterfaceDescription -notmatch $ExcludeAdapters -and $_.Name -notmatch $ExcludeAdapters }
}

function Get-ActiveRoute {
    # A rota que o Windows usa MESMO para a internet. Uma placa desligada pode ter uma rota guardada,
    # por isso não chega ordenar pela métrica da rota.
    try {
        $r = @(Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop) |
            Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1
        if ($r -and $r.NextHop -and $r.NextHop -ne '0.0.0.0') { return $r }
    } catch { }

    # Plano B: só placas ligadas, métrica da rota + métrica da placa (é assim que o Windows escolhe).
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
            Write-Progress -Id 2 -Activity 'À espera que a rede volte' -Status "$s s / $TimeoutSec s" -PercentComplete ([math]::Min(100, [int](100 * $s / $TimeoutSec)))
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
        Write-Progress -Id 2 -Activity 'À espera que a rede volte' -Completed
    }
}

function Get-WifiPowerPlan {
    # Lê o "Modo de poupança de energia" do Wi-Fi no plano ativo. Devolve $null se não existir.
    try {
        $scheme = [regex]::Match((powercfg /getactivescheme | Out-String), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
        if (-not $scheme) { return $null }
        # As duas últimas linhas com 0x.. são sempre AC e DC (independente da língua do Windows).
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
    if ($LASTEXITCODE -ne 0) { throw "powercfg falhou (AC, código $LASTEXITCODE)" }
    powercfg /setdcvalueindex $Scheme $WifiPowerSub $WifiPowerSet $DC | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg falhou (DC, código $LASTEXITCODE)" }
    powercfg /setactive $Scheme | Out-Null
}

function Format-WifiPower([int]$Value) {
    if ($Value -ge 0 -and $Value -lt $WifiPowerNames.Count) { return $WifiPowerNames[$Value] }
    return "valor $Value"
}

function Get-AdapterClassKey([string]$InterfaceGuid) {
    # A subchave 00XX da classe de rede cujo NetCfgInstanceId é o InterfaceGuid da placa.
    Get-ChildItem -Path $NetClassKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        Where-Object {
            $id = Get-ItemProperty -Path $_.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue
            $id -and ([string]$id.NetCfgInstanceId -eq $InterfaceGuid)
        } |
        Select-Object -First 1
}

function Get-PnPCapabilities([string]$KeyPath) {
    # Devolve o valor (int) ou $null se a entrada não existir.
    $prop = (Get-ItemProperty -Path $KeyPath -ErrorAction Stop).PSObject.Properties['PnPCapabilities']
    if ($prop) { return [int]$prop.Value }
    return $null
}

function Format-PnPCap($Value) {
    if ($null -eq $Value) { return 'sim (PnPCapabilities não existe)' }
    if ($Value -eq $PnPCapOff) { return "não (PnPCapabilities = $Value)" }
    return "sim (PnPCapabilities = $Value)"
}

# ---------------------------------------------------------------- testes

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
    # Resolve o nome uma vez só (senão cada ping faz uma consulta DNS e uma falha de DNS conta como perda).
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
    # Tempo do handshake TCP (SYN -> SYN/ACK), em ms. $null se falhar ou passar do tempo.
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
    # Lista oficial de relays SDR da Valve (uma região por datacenter, no mundo todo).
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
    # Para cada serviço pedido, mede todas as regiões rapidamente e devolve um alvo com a mais próxima.
    $cands = New-Object System.Collections.Generic.List[object]
    foreach ($key in $GameServices.Keys) {
        if ($Services -notcontains $key) { continue }
        $svc = $GameServices[$key]
        $regions = $svc.Regions
        if ($svc.ContainsKey('Dynamic') -and $svc.Dynamic -eq 'SteamSDR') {
            $live = Get-SteamRelayRegions
            if ($live) { $regions = $live } else { Write-Warn2 'Steam: não consegui obter a lista de relays, a usar a lista interna.' }
        }
        foreach ($r in $regions) {
            $cands.Add([pscustomobject]@{ Key = $key; Service = $svc.Name; Region = $r[0]; Host = $r[1]; Method = $r[2]; Ip = $null; Best = $null })
        }
    }
    if ($cands.Count -eq 0) { return @() }
    $activity = 'A escolher a região mais próxima de cada serviço'

    # 1) Resolver todos os nomes em paralelo.
    Write-Progress -Id 3 -Activity $activity -Status 'A resolver nomes (DNS)...' -PercentComplete 5
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

    # 2) Medir cada IP único (vários serviços partilham regiões): melhor de 3 pings em paralelo,
    #    ou melhor de 2 ligações TCP uma a uma (em paralelo o tempo TCP não seria exato).
    $best = @{}
    $icmpIps = @($cands | Where-Object { $_.Ip -and $_.Method -eq 'icmp' } | ForEach-Object { $_.Ip } | Select-Object -Unique)
    $tcpIps  = @($cands | Where-Object { $_.Ip -and $_.Method -eq 'tcp' }  | ForEach-Object { $_.Ip } | Select-Object -Unique)

    if ($icmpIps.Count -gt 0) {
        for ($round = 1; $round -le 3; $round++) {
            Write-Progress -Id 3 -Activity $activity -Status "Ping a $($icmpIps.Count) servidores (ronda $round/3)..." -PercentComplete (5 + 15 * $round)
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
        [void](Measure-TcpOnce $tcpIps[0] 443 1000)   # aquecimento: a primeira ligação é sempre mais lenta
        $done = 0
        for ($round = 1; $round -le 2; $round++) {
            foreach ($ip in $tcpIps) {
                $done++
                Write-Progress -Id 3 -Activity $activity -Status "Ligação TCP a $($tcpIps.Count) servidores (ronda $round/2)..." -PercentComplete (65 + [int](35 * $done / (2 * $tcpIps.Count)))
                $ms = Measure-TcpOnce $ip 443 700
                if ($null -ne $ms -and (-not $best.ContainsKey($ip) -or $ms -lt $best[$ip])) { $best[$ip] = $ms }
            }
        }
    }
    Write-Progress -Id 3 -Activity $activity -Completed

    foreach ($c in $cands) { if ($c.Ip -and $best.ContainsKey($c.Ip)) { $c.Best = $best[$c.Ip] } }

    # 3) Um alvo por serviço, pela ordem da lista.
    foreach ($key in @($cands | ForEach-Object { $_.Key } | Select-Object -Unique)) {
        $mine = @($cands | Where-Object { $_.Key -eq $key })
        $winner = $mine | Where-Object { $null -ne $_.Best } | Sort-Object Best | Select-Object -First 1
        if ($winner) {
            New-Target $winner.Service $winner.Ip 'jogo' $winner.Method $winner.Region
        } else {
            New-Target $mine[0].Service '' 'jogo' 'icmp' 'nenhuma região respondeu'
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
        if ($useTcp) { [void](Measure-TcpOnce $address 443 1000) }   # aquecimento
        for ($i = 0; $i -lt $Pings; $i++) {
            $pct = [int](100 * (($Index - 1) * $Pings + $i) / ($Total * $Pings))
            $where = if ($Target.Region) { $Target.Region } else { $address }
            Write-Progress -Id 1 -Activity 'Teste de ligação' -Status ("{0}/{1}  {2}  ({3})   {4} {5}/{6}" -f $Index, $Total, $Label, $where, $(if ($useTcp) { 'tcp' } else { 'ping' }), ($i + 1), $Pings) -PercentComplete $pct
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

# Colunas da tabela de resultados: título, largura.
$ResultCols = @(@('Alvo', 18), @('Servidor', 24), @('Min', 5), @('Média', 8), @('Máx', 7), @('Jitter', 8), @('Picos', 7), @('Perda', 8))

function Write-ResultHeader {
    Write-Seg '  '
    foreach ($c in $ResultCols) {
        if ($c[0] -in 'Alvo', 'Servidor') { Write-Seg $c[0].PadRight($c[1]) DarkGray } else { Write-Seg $c[0].PadLeft($c[1]) DarkGray }
    }
    Write-Host '    Estado' -ForegroundColor DarkGray
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
        Write-Host "    $($G.Bad) sem resposta" -ForegroundColor Red
        return
    }

    # Limites da média conforme o tipo de alvo.
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
        'ok'   { Write-Host "    $($G.Ok) ótimo" -ForegroundColor Green }
        'warn' { Write-Host "    $($G.Warn) razoável" -ForegroundColor Yellow }
        'bad'  { Write-Host "    $($G.Bad) instável" -ForegroundColor Red }
    }
}

function Invoke-NetTest([string]$Title) {
    Write-Title $Title
    $targets = New-Object System.Collections.Generic.List[object]
    $gw = Get-DefaultGateway
    if ($gw) { $targets.Add((New-Target 'Router' $gw 'router' 'icmp' $gw)) } else { Write-Warn2 'Não encontrei o router (gateway). Estás ligado a alguma rede?' }
    $targets.Add((New-Target 'Cloudflare' '1.1.1.1' 'internet' 'icmp' '1.1.1.1'))
    $targets.Add((New-Target 'Google' '8.8.8.8' 'internet' 'icmp' '8.8.8.8'))

    # As regiões são escolhidas uma vez só: no Apply, o teste "depois" usa os mesmos servidores que o "antes".
    if ($null -eq $script:GameTargets) {
        if ($Services.Count -gt 0) {
            Write-Info "A procurar a região mais próxima de cada serviço ($($Services.Count) serviços)..."
        }
        $script:GameTargets = @(Select-GameTargets)
    }
    foreach ($t in $script:GameTargets) { $targets.Add($t) }
    foreach ($t in $ExtraTargets) { $targets.Add((New-Target 'Extra' $t 'jogo' 'icmp' $t)) }

    $secs = [math]::Ceiling($targets.Count * $Count * 0.22)
    Write-Info "$($targets.Count) alvos $($G.Dot) $Count medições cada $($G.Dot) cerca de $secs s $($G.Dot) valores em ms"
    Write-Info 'Não uses a net durante o teste (downloads, streams, jogos).'
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
        Write-Progress -Id 1 -Activity 'Teste de ligação' -Completed
    }

    Write-Host ''
    Write-Seg '  ' ; Write-Seg 'verde' Green; Write-Seg ' = bom   ' DarkGray; Write-Seg 'amarelo' Yellow; Write-Seg ' = razoável   ' DarkGray
    Write-Seg 'vermelho' Red; Write-Host ' = mau' -ForegroundColor DarkGray
    if ($script:GameTargets.Count -gt 0) {
        Write-Host "  Servidor = a região mais próxima de ti, escolhida automaticamente." -ForegroundColor DarkGray
    }
    if (@($targets | Where-Object { $_.Method -eq 'tcp' }).Count -gt 0) {
        Write-Host "  tcp = medido pelo tempo de ligação TCP (esses servidores bloqueiam o ping)." -ForegroundColor DarkGray
    }

    $router = $results | Where-Object { $_.Tipo -eq 'router' } | Select-Object -First 1
    if ($router -and $null -ne $router.Media) {
        Write-Host ''
        # Mesmos critérios da tabela, para a frase bater certo com a coluna "Estado".
        $grade = Get-WorstGrade @(
            (Get-Grade $router.Media 5 15),
            (Get-Grade $router.Jitter 5 15),
            (Get-Grade $router.'Picos>100' 0 2),
            (Get-Grade $router.'Perda%' 0 2))
        switch ($grade) {
            'ok'   { Write-Ok 'Ligação ao router estável: a parte local (placa, driver, Wi-Fi) está bem.' }
            'warn' {
                Write-Warn2 'Ligação ao router razoável: devia ser 1-5 ms e estável.'
                Write-Info  'Pode ser só um momento mau do Wi-Fi. Repete com mais pings (-Count 50) para confirmar.' 4
            }
            'bad'  {
                Write-Bad   'Ligação ao router instável: devia ser 1-5 ms e estável.'
                Write-Info  'O problema é local (placa, driver ou Wi-Fi), não a operadora nem o jogo.' 4
            }
        }
    }
    return $results
}

function Write-Delta($Before, $After, [double]$Tolerance, [string]$Suffix = '') {
    # "antes → agora  ▼Δ" com a cor da melhoria (menos é melhor). Ocupa 24 colunas.
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
    Write-Title 'Antes vs depois'
    Write-Seg '  '
    Write-Seg 'Alvo'.PadRight(18) DarkGray
    Write-Seg 'Média'.PadLeft(13) DarkGray; Write-Seg (' ' * 11)
    Write-Seg 'Jitter'.PadLeft(13) DarkGray; Write-Seg (' ' * 11)
    Write-Host 'Perda'.PadLeft(13) -ForegroundColor DarkGray
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
    Write-Seg '  '; Write-Seg "$($G.Down) desceu (melhor)" Green; Write-Seg '   '; Write-Seg "$($G.Up) subiu (pior)" Red
    Write-Host '   = igual' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- dns

function New-DnsQuery([string]$Name, [int]$Id) {
    # Pacote DNS mínimo: cabeçalho com "recursion desired" + uma pergunta do tipo A.
    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.AddRange([byte[]]@((($Id -shr 8) -band 0xFF), ($Id -band 0xFF), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
    foreach ($label in $Name.Split('.')) {
        $b = [Text.Encoding]::ASCII.GetBytes($label)
        $bytes.Add([byte]$b.Length)
        $bytes.AddRange($b)
    }
    $bytes.AddRange([byte[]]@(0, 0, 1, 0, 1))   # fim do nome, tipo A, classe IN
    return $bytes.ToArray()
}

function Measure-DnsQuery([string]$Server, [string]$Name, [int]$TimeoutMs = 1500) {
    # Envia uma consulta UDP diretamente ao servidor e mede até à resposta. $null se não responder.
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
    # Servidores DNS (IPv4) da placa que está mesmo a levar o tráfego para a internet.
    $route = Get-ActiveRoute
    if (-not $route) { return @() }
    try {
        return @((Get-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses | Where-Object { $_ })
    } catch {
        return @()
    }
}

function Test-PrivateIp([string]$Ip) {
    # Router, rede local, CGNAT ou link-local: um DNS aqui só reencaminha para outro (normalmente o da operadora).
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
    # Servidores DNS em uso numa placa, por família ('IPv4' ou 'IPv6').
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
    # Define o DNS de UMA família numa placa, explicitamente (netsh, pelo índice da placa).
    # $Servers vazio = voltar a automático (DHCP). Devolve a lista que ficou, lida outra vez.
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
    # Compara os DNS públicos (e o atual, como referência) e devolve: Choice = preset a aplicar, ou $null.
    Write-Title 'Teste de DNS'

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
        $label = if ($preset) { "Atual ($preset)" }
                 elseif ($ip -eq $gateway) { "Atual$suffix (router)" }
                 elseif ($isLocal) { "Atual$suffix (rede local)" }
                 else { "Atual$suffix (operadora)" }
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
    Write-Info "$($rows.Count) servidores $($G.Dot) $($DnsTestDomains.Count) domínios x $rounds rondas + $uncachedCount consultas sem cache cada $($G.Dot) valores em ms"
    if ($current.Count -eq 0) { Write-Warn2 'Não consegui ler o DNS atual da placa ligada; só comparo os públicos.' }

    # Os servidores são intercalados em cada consulta, para todos apanharem as mesmas condições da rede.
    $totalQ = $rows.Count * ($DnsTestDomains.Count * $rounds + $uncachedCount)
    $done = 0
    try {
        for ($round = 1; $round -le $rounds; $round++) {
            foreach ($d in $DnsTestDomains) {
                foreach ($r in $rows) {
                    $done++
                    if ($r.Dead) { continue }
                    if ($done % 4 -eq 0) { Write-Progress -Id 4 -Activity 'Teste de DNS' -Status "Ronda $round/$rounds  $($G.Dot)  $d" -PercentComplete ([int](100 * $done / $totalQ)) }
                    $res = Measure-DnsQuery $r.Ip $d
                    $r.Total++
                    if ($res -and ($res.RCode -eq 0 -or $res.RCode -eq 3)) { $r.Times.Add($res.Ms) } else { $r.Fails++ }
                    # 3 falhas sem nenhuma resposta: o servidor não chega cá (ou a rede bloqueia). Não vale esperar mais.
                    if ($r.Times.Count -eq 0 -and $r.Fails -ge 3) { $r.Dead = $true }
                }
            }
        }
        # Sem cache: nomes aleatórios obrigam o servidor a perguntar aos servidores do domínio.
        for ($u = 1; $u -le $uncachedCount; $u++) {
            foreach ($r in $rows) {
                $done++
                if ($r.Dead) { continue }
                Write-Progress -Id 4 -Activity 'Teste de DNS' -Status 'Consultas sem cache...' -PercentComplete ([int](100 * $done / $totalQ))
                $name = 'nt' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.google.com'
                $res = Measure-DnsQuery $r.Ip $name 2500
                $r.Total++
                if ($res -and ($res.RCode -eq 0 -or $res.RCode -eq 3)) { $r.Uncached.Add($res.Ms) } else { $r.Fails++ }
            }
        }
    } finally {
        Write-Progress -Id 4 -Activity 'Teste de DNS' -Completed
    }

    foreach ($r in $rows) {
        $r.Median    = Get-Median $r.Times.ToArray()
        $r.UncMedian = Get-Median $r.Uncached.ToArray()
        $r.FailPct   = if ($r.Total -gt 0) { [math]::Round(100.0 * $r.Fails / $r.Total, 1) } else { 100.0 }
    }

    # Pontuação: 70% resposta habitual + 30% sem cache. Só contam servidores fiáveis (até 10% de falhas).
    foreach ($r in $rows) {
        if ($null -ne $r.Median) {
            $unc = if ($null -ne $r.UncMedian) { $r.UncMedian } else { $r.Median }
            $r.Score = 0.7 * $r.Median + 0.3 * $unc
        }
    }
    $valid = @($rows | Where-Object { $null -ne $_.Score -and $_.FailPct -le 10 })

    # Candidatos = só DNS públicos (incluindo o atual, se já for um deles). O router / rede local não
    # pode ganhar: responde da cache dele em ~1 ms, mas isso não é comparável com um DNS a sério.
    $cands = @($valid | Where-Object { $_.Preset })
    $winner = $null
    $margin = 5
    if ($cands.Count -gt 0) {
        $bestScore = ($cands | Measure-Object -Property Score -Minimum).Minimum
        # Abaixo de 5 ms (ou 20%) a diferença é ruído: o mesmo servidor varia isso de um teste para outro.
        $margin = [math]::Max(5, 0.2 * $bestScore)
        # Em empate prefere Cloudflare, depois Google (o Quad9 e o OpenDNS filtram domínios).
        foreach ($pref in @('Cloudflare', 'Google', 'Quad9', 'OpenDNS')) {
            $w = $cands | Where-Object { $_.Preset -eq $pref -and $_.Score -le $bestScore + $margin } | Select-Object -First 1
            if ($w) { $winner = $w; break }
        }
    }

    # Tabela
    Write-Host ''
    Write-Seg '  '
    Write-Seg 'DNS'.PadRight(20) DarkGray
    Write-Seg 'Servidor'.PadRight(17) DarkGray
    Write-Seg 'Mediana'.PadLeft(8) DarkGray
    Write-Seg 'Sem cache'.PadLeft(11) DarkGray
    Write-Host 'Falhas'.PadLeft(8) -ForegroundColor DarkGray
    Write-Host ('  ' + ($G.H * 82)) -ForegroundColor DarkGray
    foreach ($r in $rows) {
        Write-Seg ('  ' + (Format-Fit $r.Label 20)) $(if ($r.IsCurrent) { 'Cyan' } else { 'White' })
        Write-Seg (Format-Fit $r.Ip 17) DarkGray
        if ($null -eq $r.Median) {
            Write-Seg ('-'.PadLeft(8) + '-'.PadLeft(11)) DarkGray
            Write-Seg '100%'.PadLeft(8) Red
            Write-Host "    $($G.Bad) não responde" -ForegroundColor Red
            continue
        }
        $gMed = Get-Grade $r.Median 20 50
        $gUnc = Get-Grade $r.UncMedian 80 200
        $gFail = Get-Grade $r.FailPct 0 5
        Write-Seg (Format-Num $r.Median).PadLeft(8) $StateColor[$gMed]
        Write-Seg (Format-Num $r.UncMedian).PadLeft(11) $StateColor[$gUnc]
        Write-Seg ((Format-Num $r.FailPct) + '%').PadLeft(8) $StateColor[$gFail]
        if ($winner -and $r.Ip -eq $winner.Ip) { Write-Host "    $($G.Star) o melhor" -ForegroundColor Green }
        elseif ($r.IsLocal) { Write-Host '    cache local, não conta' -ForegroundColor DarkGray }
        else { Write-Host '' }
    }
    Write-Host ''
    Write-Host '  Mediana = resposta habitual (com cache)  ·  Sem cache = primeira vez que um nome é pedido' -ForegroundColor DarkGray
    Write-Host '  Escolha: 70% mediana + 30% sem cache. Em empate (até 5 ms) prefere Cloudflare, depois Google.' -ForegroundColor DarkGray

    # Decisão
    $choice = $null
    $curLocal  = @($rows | Where-Object { $_.IsCurrent -and $_.IsLocal })
    $curPreset = @($valid | Where-Object { $_.IsCurrent -and $_.Preset }) | Sort-Object Score | Select-Object -First 1
    $publicRows = @($rows | Where-Object { $_.Preset })
    Write-Host ''
    if (-not $winner -and $publicRows.Count -gt 0 -and @($publicRows | Where-Object { $_.Dead }).Count -eq $publicRows.Count) {
        Write-Warn2 'Os DNS públicos não respondem nesta rede: a porta 53 deve estar bloqueada (comum em redes de escola ou empresa).'
        Write-Info  'Fica o DNS atual. Mudar agora cortava-te a internet.' 4
    } elseif (-not $winner) {
        Write-Warn2 'Nenhum DNS público respondeu bem (falhas a mais). Fica o atual.'
    } elseif ($winner.IsCurrent) {
        Write-Ok "Já usas $($winner.Preset), que é o melhor aqui. Fica como está."
    } elseif ($curPreset -and $curPreset.Score - $winner.Score -lt $margin) {
        # Já usa um DNS público e a diferença é pequena: não vale a pena trocar entre públicos.
        Write-Ok "Já usas $($curPreset.Preset) e $($winner.Preset) só é $(Format-Num ($curPreset.Score - $winner.Score)) ms melhor. Fica como está."
    } else {
        $choice = $winner.Preset
        if ($curLocal.Count -gt 0) {
            $l = $curLocal[0]
            $uncText = if ($null -ne $l.UncMedian) { "$(Format-Num $l.UncMedian) ms" } else { 'sem resposta' }
            Write-Info "O DNS atual ($($l.Ip)) é o router / rede local: só reencaminha para o DNS da operadora."
            Write-Info "A mediana baixa dele é cache local; num nome novo demorou $uncText (o $($winner.Preset) demorou $(Format-Num $winner.UncMedian) ms)." 4
        }
        Write-Warn2 "Melhor DNS: $($winner.Preset) (mediana $(Format-Num $winner.Median) ms, sem cache $(Format-Num $winner.UncMedian) ms)."
        $v4 = @($DnsPresets[$choice] | Where-Object { $_ -notmatch ':' }) -join ', '
        $v6 = @($DnsPresets[$choice] | Where-Object { $_ -match ':' }) -join ', '
        Write-Info "O Apply define em cada placa  IPv4: $v4" 4
        Write-Host "                                    IPv6: $v6" -ForegroundColor Gray
    }
    Write-Info 'Nota: o DNS acelera abrir sites e ligar aos serviços. Não muda o ping dentro do jogo.'

    return [pscustomobject]@{ Choice = $choice }
}

# ---------------------------------------------------------------- estado das placas

function Show-AdapterState {
    # Mostra o estado e devolve quantos ajustes o Apply ainda faria.
    Write-Title 'Estado atual'
    $pending = 0

    $wifiPlan = Get-WifiPowerPlan
    if ($wifiPlan) {
        Write-Seg "  $($G.Node) " Cyan
        Write-Host 'Plano de energia do Windows' -ForegroundColor White
        foreach ($pair in @(@('Wi-Fi ligado à corrente', $wifiPlan.AC), @('Wi-Fi na bateria', $wifiPlan.DC))) {
            if ($pair[1] -eq 0) {
                Write-KV $pair[0] (Format-WifiPower $pair[1]) 'ok'
            } else {
                Write-KV $pair[0] (Format-WifiPower $pair[1]) 'warn' 'Desempenho máximo'
                $pending++
            }
        }
    }

    $adapters = @(Get-TargetAdapters)
    if ($adapters.Count -eq 0) { Write-Warn2 'Nenhuma placa física encontrada.'; return $pending }

    foreach ($a in $adapters) {
        Write-AdapterHeader $a
        if ([string]$a.Status -eq 'Up') { Write-KV 'Velocidade' ([string]$a.LinkSpeed) }
        Write-KV 'Driver' ("{0} ({1})" -f $a.DriverVersion, $a.DriverDate)

        $classKey = Get-AdapterClassKey ([string]$a.InterfaceGuid)
        if ($classKey) {
            try {
                $pnp = Get-PnPCapabilities $classKey.PSPath
                if ($pnp -eq $PnPCapOff) {
                    Write-KV 'Windows pode desligá-la' (Format-PnPCap $pnp) 'ok'
                } else {
                    Write-KV 'Windows pode desligá-la' (Format-PnPCap $pnp) 'warn' 'não'
                    $pending++
                }
            } catch { }
        }

        try {
            $rsc = Get-NetAdapterRsc -Name $a.Name -ErrorAction Stop
            if ($rsc.IPv4Enabled -or $rsc.IPv6Enabled) {
                Write-KV 'RSC' ("ligado (IPv4 {0}, IPv6 {1})" -f $rsc.IPv4Enabled, $rsc.IPv6Enabled) 'warn' 'desligado'
                $pending++
            } else {
                Write-KV 'RSC' 'desligado' 'ok'
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
    Write-Seg '  '; Write-Seg "$($G.Ok) já otimizado" Green; Write-Seg '   '
    Write-Seg "$($G.Warn) o Apply muda" Yellow; Write-Host "   $($G.Arrow) valor novo" -ForegroundColor DarkGray
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
    if (-not $SkipTest) { $before = Invoke-NetTest 'Teste antes dos ajustes' }

    [void](Show-AdapterState)

    # DNS: Auto = testar e usar o mais rápido (se valer a pena); Keep = não mexer; nome = forçar esse.
    $dnsChoice = $null
    switch ($Dns) {
        'Keep'  { }
        'Auto'  { $dnsChoice = (Invoke-DnsBenchmark).Choice }
        default {
            # Forçado: confirmar primeiro que esse DNS responde nesta rede (há redes que bloqueiam DNS externo).
            $okCount = 0
            foreach ($d in @('google.com', 'microsoft.com', 'cloudflare.com')) {
                $res = Measure-DnsQuery $DnsPresets[$Dns][0] $d
                if ($res -and ($res.RCode -eq 0 -or $res.RCode -eq 3)) { $okCount++ }
            }
            if ($okCount -ge 2) {
                $dnsChoice = $Dns
            } else {
                Write-Host ''
                Write-Warn2 "O DNS $Dns ($($DnsPresets[$Dns][0])) não responde nesta rede. Não vou mudar o DNS, senão ficavas sem internet."
            }
        }
    }

    $adapters = @(Get-TargetAdapters)
    if ($adapters.Count -eq 0) { throw 'Nenhuma placa física encontrada.' }

    $backup = [ordered]@{
        Created  = (Get-Date).ToString('s')
        Tool     = "NetTune $Version"
        Computer = $env:COMPUTERNAME
        WifiPowerPlan = $null
        Adapters = @()
    }

    Write-Title 'A aplicar ajustes'
    $file = $null

    # O backup é guardado no finally: se algum ajuste der erro a meio, o que já foi mudado fica registado.
    try {

    # 0) Poupança de energia do Wi-Fi no plano de energia do Windows (AC e bateria)
    $wifiPlan = Get-WifiPowerPlan
    if ($wifiPlan) {
        Write-Seg "  $($G.Node) " Cyan
        Write-Host 'Plano de energia do Windows' -ForegroundColor White
        if ($wifiPlan.AC -ne 0 -or $wifiPlan.DC -ne 0) {
            $backup.WifiPowerPlan = [ordered]@{ Scheme = $wifiPlan.Scheme; AC = $wifiPlan.AC; DC = $wifiPlan.DC }
            $from = "corrente: $(Format-WifiPower $wifiPlan.AC), bateria: $(Format-WifiPower $wifiPlan.DC)"
            if ($PSCmdlet.ShouldProcess('Plano de energia', "Poupança do Wi-Fi: $from -> Desempenho máximo")) {
                Set-WifiPowerPlan -Scheme $wifiPlan.Scheme -AC 0 -DC 0
            }
            Write-Change 'Poupança do Wi-Fi' $from 'Desempenho máximo'
        } else {
            Write-Info 'Poupança do Wi-Fi: já em desempenho máximo' 4
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
        # Entra já no backup (é uma referência, as alterações abaixo ficam lá).
        $backup.Adapters += $entry
        $changed = $false

        # 1) Deixar o Windows desligar a placa para poupar energia
        #    -> PnPCapabilities = 24 na chave da placa (só faz efeito depois de reiniciar o PC)
        $classKey = Get-AdapterClassKey ([string]$a.InterfaceGuid)
        if (-not $classKey) {
            Write-Warn2 "Gestão de energia: não encontrei a chave da placa no registo (NetCfgInstanceId = $($a.InterfaceGuid))" 4
        } else {
            $old = $null
            $readOk = $true
            try { $old = Get-PnPCapabilities $classKey.PSPath } catch {
                $readOk = $false
                Write-Warn2 "Gestão de energia: não consegui ler PnPCapabilities: $($_.Exception.Message)" 4
            }
            if ($readOk -and $old -eq $PnPCapOff) {
                Write-Info "Windows pode desligá-la: já está em não (PnPCapabilities = $PnPCapOff)" 4
            } elseif ($readOk) {
                $existed = ($null -ne $old)
                $entry.PnPCapabilities = [ordered]@{ ClassKey = $classKey.PSChildName; Existed = $existed; Value = $old }
                $oldText = if ($existed) { [string]$old } else { 'não existia' }
                $msg = "PnPCapabilities (chave $($classKey.PSChildName)): $oldText -> $PnPCapOff"
                if ($PSCmdlet.ShouldProcess($a.Name, $msg)) {
                    try {
                        New-ItemProperty -Path $classKey.PSPath -Name PnPCapabilities -PropertyType DWord -Value $PnPCapOff -Force -ErrorAction Stop | Out-Null
                    } catch {
                        Write-Warn2 "Gestão de energia: falhou ao escrever PnPCapabilities: $($_.Exception.Message)" 4
                    }

                    # Confirmar lendo outra vez: só dizemos OK se ficou mesmo 24.
                    $now = $null
                    try { $now = Get-PnPCapabilities $classKey.PSPath } catch {
                        Write-Warn2 "Gestão de energia: não consegui confirmar o valor: $($_.Exception.Message)" 4
                    }
                    if ($now -eq $PnPCapOff) {
                        Write-Change 'Windows pode desligá-la' (Format-PnPCap $old) (Format-PnPCap $now) 'reinicia o PC'
                        $script:RebootNeeded = $true
                    } else {
                        Write-Warn2 "Gestão de energia: PnPCapabilities ficou '$(Format-PnPCap $now)' (esperado $PnPCapOff)" 4
                    }
                } else {
                    Write-Change 'Windows pode desligá-la' (Format-PnPCap $old) (Format-PnPCap $PnPCapOff) 'reinicia o PC'
                }
            }
        }

        # 2) RSC
        try {
            $rsc = Get-NetAdapterRsc -Name $a.Name -ErrorAction Stop
            if ($rsc.IPv4Enabled -or $rsc.IPv6Enabled) {
                $entry.Rsc = [ordered]@{ IPv4 = [bool]$rsc.IPv4Enabled; IPv6 = [bool]$rsc.IPv6Enabled }
                if ($PSCmdlet.ShouldProcess($a.Name, 'Desligar RSC')) {
                    Disable-NetAdapterRsc -Name $a.Name -NoRestart -ErrorAction Stop
                    $changed = $true
                }
                Write-Change 'RSC' 'ligado' 'desligado'
            } else {
                Write-Info 'RSC: já desligado' 4
            }
        } catch {
            Write-Info 'RSC: não suportado por esta placa' 4
        }

        # 3) Propriedades avançadas do driver
        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue)
        foreach ($p in $props) {
            $rule = $null
            foreach ($r in $Rules) { if ($p.DisplayName -match $r.Display) { $rule = $r; break } }
            if (-not $rule) { continue }

            $valid = @($p.ValidDisplayValues)
            if ($valid.Count -eq 0) { continue }
            $target = $valid | Where-Object { $_ -match $rule.Want } | Select-Object -First 1
            if (-not $target) {
                Write-Warn2 "$($p.DisplayName): não encontrei valor para desligar (opções: $($valid -join ' | '))" 4
                continue
            }
            if ($p.DisplayValue -eq $target) {
                Write-Info "$($p.DisplayName): já está em '$target'" 4
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

        # 4) DNS: IPv4 e IPv6 definidos à mão, cada família em separado, e confirmados lendo outra vez.
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
                Write-Info "DNS: já está em $dnsChoice" 4
            } else {
                $entry.Dns = Get-DnsBackup $a
                foreach ($fam in @(@('IPv4', $need4, $now4, $want4), @('IPv6', $need6, $now6, $want6))) {
                    if (-not $fam[1]) { continue }
                    $from = if (@($fam[2]).Count -gt 0) { (@($fam[2]) | Select-Object -First 2) -join ', ' } else { 'automático' }
                    $to = "$dnsChoice (" + (@($fam[3]) -join ', ') + ')'
                    if ($PSCmdlet.ShouldProcess($a.Name, "DNS $($fam[0]) -> $to")) {
                        $after = @(Set-AdapterDnsFamily $a $fam[0] @($fam[3]))
                        if (Test-SameList $after @($fam[3])) {
                            Write-Change "DNS $($fam[0])" $from $to
                        } else {
                            $got = if ($after.Count -gt 0) { $after -join ', ' } else { 'automático' }
                            Write-Warn2 "DNS $($fam[0]): não ficou aplicado (está: $got)" 4
                        }
                    } else {
                        Write-Change "DNS $($fam[0])" $from $to
                    }
                }
            }
            if (-not $v6On) { Write-Info 'DNS IPv6: o IPv6 está desligado nesta placa, só foi preciso o IPv4.' 4 }
        }

        # Reiniciar a placa uma vez só, para aplicar tudo
        if ($changed -and $a.Status -eq 'Up') {
            if ($PSCmdlet.ShouldProcess($a.Name, 'Reiniciar a placa para aplicar')) {
                Write-Info 'A reiniciar a placa (a ligação cai uns segundos)...' 4
                Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
            }
        } elseif ($changed) {
            Write-Info 'Placa sem ligação: as mudanças aplicam-se quando a ligares.' 4
        }
    }

    } finally {
        if (-not $WhatIfPreference) {
            $file = Save-Backup $backup
            Write-Host ''
            Write-Ok "Backup guardado: backups\$(Split-Path $file -Leaf)"
        }
    }

    if ($WhatIfPreference) {
        $n = $script:ChangeCount
        $lines = @()
        if ($n -gt 0) { $lines += ,@($G.Sim, 'Cyan', "$n alteração(ões) seriam aplicadas") }
        else          { $lines += ,@($G.Ok, 'Green', 'Nada a mudar: já está tudo otimizado') }
        $lines += ,@($G.Info, 'DarkGray', 'Nada foi mudado (-WhatIf).')
        $lines += ,@($G.Arrow, 'Cyan', 'Para aplicar: .\NetTune.ps1 -Mode Apply')
        Write-Box 'Simulação' $lines 'DarkYellow'
        return
    }

    if ($dnsChoice) { Clear-DnsClientCache -ErrorAction SilentlyContinue }

    Write-Host ''
    Write-Info 'À espera que a rede volte...'
    if (-not (Wait-Network 40)) { Write-Warn2 'A rede demorou a voltar. Verifica a ligação antes do teste.' }
    Start-Sleep -Seconds 3

    if (-not $SkipTest) {
        $after = Invoke-NetTest 'Teste depois dos ajustes'
        if ($before) { Show-Comparison $before $after }
    }

    $n = $script:ChangeCount
    $lines = @()
    if ($n -gt 0) { $lines += ,@($G.Ok, 'Green', "$n alteração(ões) aplicada(s)") }
    else          { $lines += ,@($G.Ok, 'Green', 'Nada a mudar: já estava tudo otimizado') }
    if ($file)    { $lines += ,@($G.Info, 'DarkGray', "Backup: backups\$(Split-Path $file -Leaf)") }
    $lines += ,@($G.Arrow, 'Cyan', 'Para desfazer: .\NetTune.ps1 -Mode Revert')
    if ($script:RebootNeeded) {
        $lines += ,@($G.Warn, 'Yellow', 'REINICIA O PC para a gestão de energia fazer efeito.')
        $lines += ,@(' ', 'Gray', 'O teste "depois" ainda não inclui essa mudança.')
    }
    $lines += ,@($G.Info, 'DarkGray', 'Updates do driver podem repor os valores de fábrica.')
    $lines += ,@(' ', 'Gray', 'Se os picos voltarem, corre o Apply outra vez.')
    Write-Box 'Concluído' $lines 'DarkGreen'
}

# ---------------------------------------------------------------- revert

function Invoke-Revert {
    Assert-Admin

    $file = $BackupFile
    if (-not $file) {
        $latest = Get-ChildItem -Path $BackupDir -Filter 'backup-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw "Não há backups em $BackupDir" }
        $file = $latest.FullName
    }
    if (-not (Test-Path $file)) { throw "Backup não encontrado: $file" }

    Write-Title 'A repor backup'
    $data = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $created = if ($data.PSObject.Properties['Created']) { $data.Created } else { '?' }
    $tool    = if ($data.PSObject.Properties['Tool'])    { $data.Tool }    else { '?' }
    Write-Info "Ficheiro: $(Split-Path $file -Leaf)  $($G.Dot)  criado: $created  $($G.Dot)  $tool"

    # Backups antigos (1.0.0) não têm esta propriedade; com StrictMode tem de se ver assim.
    $planProp = $data.PSObject.Properties['WifiPowerPlan']
    if ($planProp -and $planProp.Value) {
        $p = $planProp.Value
        Write-Host ''
        Write-Seg "  $($G.Node) " Cyan
        Write-Host 'Plano de energia do Windows' -ForegroundColor White
        $to = "corrente: $(Format-WifiPower $p.AC), bateria: $(Format-WifiPower $p.DC)"
        if ($PSCmdlet.ShouldProcess('Plano de energia', "Poupança do Wi-Fi -> $to")) {
            try {
                Set-WifiPowerPlan -Scheme $p.Scheme -AC $p.AC -DC $p.DC
                Write-Change 'Poupança do Wi-Fi' 'Desempenho máximo' $to
            } catch { Write-Warn2 "Plano de energia: $($_.Exception.Message)" 4 }
        }
    }

    foreach ($e in @($data.Adapters)) {
        $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $e.InterfaceGuid } | Select-Object -First 1
        if (-not $a) { $a = Get-NetAdapter -Name $e.Name -ErrorAction SilentlyContinue }
        if (-not $a) { Write-Host ''; Write-Warn2 "Placa '$($e.Name)' não encontrada, a saltar."; continue }

        Write-AdapterHeader $a
        $changed = $false

        foreach ($adv in @($e.Advanced)) {
            if (-not $adv) { continue }
            if ($PSCmdlet.ShouldProcess($a.Name, "$($adv.DisplayName) -> '$($adv.DisplayValue)'")) {
                try {
                    Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $adv.RegistryKeyword -RegistryValue @($adv.RegistryValue) -NoRestart -ErrorAction Stop
                    Write-Change $adv.DisplayName 'ajustado' $adv.DisplayValue
                    $changed = $true
                } catch {
                    Write-Warn2 "$($adv.DisplayName): $($_.Exception.Message)" 4
                }
            }
        }

        if ($e.Rsc) {
            if ($PSCmdlet.ShouldProcess($a.Name, 'Repor RSC')) {
                try {
                    if ($e.Rsc.IPv4) { Enable-NetAdapterRsc -Name $a.Name -IPv4 -NoRestart -ErrorAction Stop }
                    if ($e.Rsc.IPv6) { Enable-NetAdapterRsc -Name $a.Name -IPv6 -NoRestart -ErrorAction Stop }
                    Write-Change 'RSC' 'desligado' 'ligado'
                    $changed = $true
                } catch { Write-Warn2 "RSC: $($_.Exception.Message)" 4 }
            }
        }

        # Gestão de energia: PnPCapabilities. Backups antigos (PowerManagement) são ignorados de propósito:
        # essa versão nunca conseguiu mudar nada (o Set-NetAdapterPowerManagement não tem esse parâmetro).
        $pnpProp = $e.PSObject.Properties['PnPCapabilities']
        if ($pnpProp -and $pnpProp.Value) {
            $pc = $pnpProp.Value
            $classKey = Get-AdapterClassKey ([string]$a.InterfaceGuid)
            if (-not $classKey) {
                Write-Warn2 "Gestão de energia: não encontrei a chave da placa no registo (era a $($pc.ClassKey))" 4
            } else {
                $desc = if ($pc.Existed) { "PnPCapabilities (chave $($classKey.PSChildName)) -> $($pc.Value)" } else { "PnPCapabilities (chave $($classKey.PSChildName)) -> apagar (não existia)" }
                if ($PSCmdlet.ShouldProcess($a.Name, $desc)) {
                    try {
                        if ($pc.Existed) {
                            New-ItemProperty -Path $classKey.PSPath -Name PnPCapabilities -PropertyType DWord -Value ([int]$pc.Value) -Force -ErrorAction Stop | Out-Null
                        } elseif ($null -ne (Get-PnPCapabilities $classKey.PSPath)) {
                            Remove-ItemProperty -Path $classKey.PSPath -Name PnPCapabilities -ErrorAction Stop
                        }
                        $restored = if ($pc.Existed) { $pc.Value } else { $null }
                        Write-Change 'Windows pode desligá-la' (Format-PnPCap $PnPCapOff) (Format-PnPCap $restored) 'reinicia o PC'
                        $script:RebootNeeded = $true
                    } catch { Write-Warn2 "Gestão de energia: $($_.Exception.Message)" 4 }
                }
            }
        }

        if ($e.Dns) {
            # Cada família volta ao que era: a lista fixa antiga, ou automático (DHCP) se não havia nenhuma.
            $old4 = @(([string]$e.Dns.IPv4) -split '[,\s]+' | Where-Object { $_ })
            $old6 = @(([string]$e.Dns.IPv6) -split '[,\s]+' | Where-Object { $_ })
            foreach ($fam in @(@('IPv4', $old4), @('IPv6', $old6))) {
                $to = if (@($fam[1]).Count -gt 0) { @($fam[1]) -join ', ' } else { 'automático (DHCP)' }
                if ($PSCmdlet.ShouldProcess($a.Name, "DNS $($fam[0]) -> $to")) {
                    try {
                        $after = @(Set-AdapterDnsFamily $a $fam[0] @($fam[1]))
                        if (@($fam[1]).Count -gt 0 -and -not (Test-SameList $after @($fam[1]))) {
                            Write-Warn2 "DNS $($fam[0]): não ficou reposto (está: $($after -join ', '))" 4
                        } else {
                            Write-Change "DNS $($fam[0])" 'ajustado' $to
                        }
                    } catch { Write-Warn2 "DNS $($fam[0]): $($_.Exception.Message)" 4 }
                }
            }
        }

        if ($changed -and $a.Status -eq 'Up' -and $PSCmdlet.ShouldProcess($a.Name, 'Reiniciar a placa')) {
            Write-Info 'A reiniciar a placa (a ligação cai uns segundos)...' 4
            Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Clear-DnsClientCache -ErrorAction SilentlyContinue
    if (-not $WhatIfPreference) {
        Write-Host ''
        Write-Info 'À espera que a rede volte...'
        [void](Wait-Network 40)
    }

    $n = $script:ChangeCount
    $lines = @()
    if ($WhatIfPreference) {
        $lines += ,@($G.Sim, 'Cyan', "$n definição(ões) seriam repostas")
        $lines += ,@($G.Info, 'DarkGray', 'Nada foi mudado (-WhatIf).')
    } elseif ($n -gt 0) {
        $lines += ,@($G.Ok, 'Green', "$n definição(ões) reposta(s)")
    } else {
        $lines += ,@($G.Info, 'DarkGray', 'Este backup não tinha nada para repor.')
    }
    if ($script:RebootNeeded -and -not $WhatIfPreference) {
        $lines += ,@($G.Warn, 'Yellow', 'REINICIA O PC para a gestão de energia voltar ao original.')
    }
    Write-Box 'Backup reposto' $lines 'DarkMagenta'
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
            [void](Invoke-NetTest 'Teste de ligação')
            $dnsChoice = $null
            if ($Dns -ne 'Keep') {
                $dnsChoice = (Invoke-DnsBenchmark).Choice
                if ($dnsChoice) { $pending++ }
            }
            $lines = @()
            if ($dnsChoice) {
                $lines += ,@($G.Star, 'Green', "Melhor DNS: $dnsChoice (o Apply muda, IPv4 e IPv6)")
            }
            if ($pending -gt 0) {
                $lines += ,@($G.Warn, 'Yellow', "$pending ajuste(s) por fazer (marcados com $($G.Warn) acima)")
                $lines += ,@($G.Arrow, 'Cyan', 'Ensaio:  .\NetTune.ps1 -Mode Apply -WhatIf')
                $lines += ,@($G.Arrow, 'Cyan', 'Aplicar: .\NetTune.ps1 -Mode Apply   (como admin)')
            } else {
                $lines += ,@($G.Ok, 'Green', 'As placas já estão otimizadas. Nada a fazer.')
            }
            Write-Box 'Resumo' $lines
        }
        'Apply'  { Invoke-Apply }
        'Revert' { Invoke-Revert }
    }
} catch {
    Write-Host ''
    Write-Seg "  $($G.Bad) ERRO  " Red
    Write-Host $_.Exception.Message -ForegroundColor White
    exit 1
} finally {
    $el = $clock.Elapsed
    $took = if ($el.TotalMinutes -ge 1) { '{0}m {1:00}s' -f [int][math]::Floor($el.TotalMinutes), $el.Seconds } else { '{0}s' -f [int]$el.TotalSeconds }
    if ($transcript) {
        try { Stop-Transcript -WhatIf:$false | Out-Null } catch { }
    }
    Write-Host ''
    Write-Seg "  Terminado em $took" DarkGray
    if ($transcript) { Write-Seg "  $($G.Dot)  log: logs\$(Split-Path $transcript -Leaf)" DarkGray }
    Write-Host ''
    Write-Host ''
}
