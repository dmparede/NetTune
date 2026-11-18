#Requires -Version 5.1
<#
.SYNOPSIS
    NetTune - ajustes honestos de rede para jogar com ping estável (Windows 10/11).

.DESCRIPTION
    Mede a ligação (router, internet, servidores da Epic), aplica apenas ajustes com efeito real
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
      - DNS -> só se pedires com -Dns (o DNS NÃO muda o ping nos jogos, só a rapidez a abrir nomes)

.PARAMETER Mode
    Test   : só mede e mostra o estado das placas (não precisa de admin, não muda nada). Padrão.
    Apply  : mede, faz backup, aplica os ajustes, volta a medir e compara. Precisa de admin.
    Revert : repõe o último backup (ou o indicado em -BackupFile). Precisa de admin.

.PARAMETER Dns
    Keep (padrão), Cloudflare, Google ou Quad9. Só é aplicado no modo Apply.

.PARAMETER Count
    Número de pings por alvo nos testes (padrão 50, cerca de 10 s por alvo).

.PARAMETER ExtraTargets
    Alvos extra para o teste, por exemplo o IP de um servidor de outro jogo.

.PARAMETER BackupFile
    Ficheiro de backup a usar no modo Revert. Por defeito usa o mais recente da pasta backups.

.PARAMETER SkipTest
    No modo Apply, salta os testes antes/depois.

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

    [ValidateSet('Keep', 'Cloudflare', 'Google', 'Quad9')]
    [string]$Dns = 'Keep',

    [ValidateRange(5, 1000)]
    [int]$Count = 50,

    [string[]]$ExtraTargets = @(),

    [string]$BackupFile,

    [switch]$SkipTest,

    [switch]$Ascii
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Version   = '1.3.0'
$Root      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$BackupDir = Join-Path $Root 'backups'
$LogDir    = Join-Path $Root 'logs'
$Stamp     = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

$DnsPresets = @{
    Cloudflare = @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001')
    Google     = @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844')
    Quad9      = @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9')
}

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

# Placas que nunca tocamos (VPNs, virtuais, Bluetooth).
$ExcludeAdapters = 'Bluetooth|Virtual|\bTAP\b|Tunnel|VPN|Wintun|WireGuard|Hyper-V|Loopback|Check Point|TunnelBear'

# ---------------------------------------------------------------- aparência

$G = if ($Ascii) {
    @{ Ok = '+'; Bad = 'x'; Warn = '!'; Info = '-'; Sim = '~'; Arrow = '->'; Up = '^'; Down = 'v'
       H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; Dot = '.'; Node = '>'; Bullet = '*'; Ell = '.' }
} else {
    @{ Ok = [string][char]0x2713; Bad = [string][char]0x2717; Warn = '!'; Info = [string][char]0x00B7; Sim = '~'
       Arrow = [string][char]0x2192; Up = [string][char]0x25B2; Down = [string][char]0x25BC
       H = [string][char]0x2500; V = [string][char]0x2502
       TL = [string][char]0x256D; TR = [string][char]0x256E; BL = [string][char]0x2570; BR = [string][char]0x256F
       Dot = [string][char]0x00B7; Node = [string][char]0x25C6; Bullet = [string][char]0x25CF; Ell = [string][char]0x2026 }
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

function Get-DefaultGateway {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric |
        Select-Object -First 1
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

function Measure-Target([string]$Label, [string]$HostName, [int]$Pings, [string]$Kind, [int]$Index, [int]$Total) {
    $empty = [pscustomobject]@{ Alvo = $Label; Host = $HostName; Tipo = $Kind; Min = $null; Media = $null; Max = $null; Jitter = $null; 'Picos>100' = $null; 'Perda%' = 100 }

    # Resolver o nome uma vez só (senão cada ping faz uma consulta DNS e uma falha de DNS conta como perda).
    $address = $HostName
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($HostName, [ref]$parsed)) {
        try {
            $all = @([Net.Dns]::GetHostAddresses($HostName))
            $v4 = $all | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            $address = if ($v4) { $v4.IPAddressToString } else { $all[0].IPAddressToString }
        } catch {
            return $empty
        }
    }

    $ping = New-Object System.Net.NetworkInformation.Ping
    $rtts = New-Object System.Collections.Generic.List[double]
    $lost = 0
    try {
        for ($i = 0; $i -lt $Pings; $i++) {
            $pct = [int](100 * (($Index - 1) * $Pings + $i) / ($Total * $Pings))
            Write-Progress -Id 1 -Activity 'Teste de ligação' -Status ("{0}/{1}  {2}  ({3})   ping {4}/{5}" -f $Index, $Total, $Label, $address, ($i + 1), $Pings) -PercentComplete $pct
            try {
                $reply = $ping.Send($address, 1000)
                if ($reply.Status -eq 'Success') { $rtts.Add([double]$reply.RoundtripTime) } else { $lost++ }
            } catch {
                $lost++
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
        Host        = $HostName
        Tipo        = $Kind
        Min         = [math]::Round($min, 0)
        Media       = [math]::Round($stats.Average, 1)
        Max         = [math]::Round($stats.Maximum, 0)
        Jitter      = [math]::Round($jitter, 1)
        'Picos>100' = $spikes
        'Perda%'    = [math]::Round(100.0 * $lost / $Pings, 1)
    }
}

# Colunas da tabela de resultados: título, largura.
$ResultCols = @(@('Alvo', 18), @('Min', 6), @('Média', 8), @('Máx', 7), @('Jitter', 8), @('Picos', 7), @('Perda', 8))

function Write-ResultHeader {
    Write-Seg '  '
    foreach ($c in $ResultCols) {
        if ($c[0] -eq 'Alvo') { Write-Seg $c[0].PadRight($c[1]) DarkGray } else { Write-Seg $c[0].PadLeft($c[1]) DarkGray }
    }
    Write-Host '    Estado' -ForegroundColor DarkGray
    $total = ($ResultCols | ForEach-Object { $_[1] } | Measure-Object -Sum).Sum + 16
    Write-Host ('  ' + ($G.H * $total)) -ForegroundColor DarkGray
}

function Write-ResultRow($R) {
    Write-Seg ('  ' + (Format-Fit $R.Alvo 18)) White

    if ($null -eq $R.Media) {
        Write-Seg ('-'.PadLeft(6) + '-'.PadLeft(8) + '-'.PadLeft(7) + '-'.PadLeft(8) + '-'.PadLeft(7)) DarkGray
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

    Write-Seg (Format-Num $R.Min).PadLeft(6) DarkGray
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
    if ($gw) { $targets.Add(@('Router', $gw, 'router')) } else { Write-Warn2 'Não encontrei o router (gateway). Estás ligado a alguma rede?' }
    $targets.Add(@('Cloudflare', '1.1.1.1', 'internet'))
    $targets.Add(@('Google', '8.8.8.8', 'internet'))
    $targets.Add(@('Epic França', 'ping-fr.ds.on.epicgames.com', 'jogo'))
    $targets.Add(@('Epic Alemanha', 'ping-de.ds.on.epicgames.com', 'jogo'))
    $targets.Add(@('Epic Reino Unido', 'ping-gb.ds.on.epicgames.com', 'jogo'))
    foreach ($t in $ExtraTargets) { $targets.Add(@("Extra $t", $t, 'jogo')) }

    $secs = [math]::Ceiling($targets.Count * $Count * 0.2)
    Write-Info "$($targets.Count) alvos $($G.Dot) $Count pings cada $($G.Dot) cerca de $secs s $($G.Dot) valores em ms"
    Write-Info 'Não uses a net durante o teste (downloads, streams, jogos).'
    Write-Host ''
    Write-ResultHeader

    $results = @()
    $i = 0
    try {
        foreach ($t in $targets) {
            $i++
            $r = Measure-Target -Label $t[0] -HostName $t[1] -Pings $Count -Kind $t[2] -Index $i -Total $targets.Count
            Write-ResultRow $r
            $results += $r
        }
    } finally {
        Write-Progress -Id 1 -Activity 'Teste de ligação' -Completed
    }

    Write-Host ''
    Write-Seg '  ' ; Write-Seg 'verde' Green; Write-Seg ' = bom   ' DarkGray; Write-Seg 'amarelo' Yellow; Write-Seg ' = razoável   ' DarkGray
    Write-Seg 'vermelho' Red; Write-Host ' = mau' -ForegroundColor DarkGray

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

        # 4) DNS (opcional)
        if ($Dns -ne 'Keep') {
            $entry.Dns = Get-DnsBackup $a
            $servers = $DnsPresets[$Dns]
            if ($PSCmdlet.ShouldProcess($a.Name, "DNS -> $Dns ($($servers -join ', '))")) {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers -ErrorAction Stop
            }
            Write-Change 'DNS' 'atual' "$Dns ($($servers[0]), $($servers[1]))"
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

    if ($Dns -ne 'Keep') { Clear-DnsClientCache -ErrorAction SilentlyContinue }

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
            $servers = @()
            foreach ($s in @($e.Dns.IPv4, $e.Dns.IPv6)) {
                if ($s) { $servers += ($s -split '[,\s]+' | Where-Object { $_ }) }
            }
            if ($PSCmdlet.ShouldProcess($a.Name, 'Repor DNS')) {
                try {
                    if ($servers.Count -gt 0) {
                        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers -ErrorAction Stop
                        Write-Change 'DNS' 'ajustado' ($servers -join ', ')
                    } else {
                        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
                        Write-Change 'DNS' 'ajustado' 'automático (DHCP)'
                    }
                } catch { Write-Warn2 "DNS: $($_.Exception.Message)" 4 }
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
    switch ($Mode) {
        'Test' {
            $pending = Show-AdapterState
            [void](Invoke-NetTest 'Teste de ligação')
            $lines = @()
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
