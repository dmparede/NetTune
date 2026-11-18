#Requires -Version 5.1
<#
.SYNOPSIS
    NetTune - ajustes honestos de rede para jogar com ping estavel (Windows 10/11).

.DESCRIPTION
    Mede a ligacao (router, internet, servidores da Epic), aplica apenas ajustes com efeito real
    em latencia/estabilidade e volta a medir para comparar. Antes de mudar qualquer coisa guarda
    um backup em JSON, para poderes desfazer tudo com -Mode Revert.

    No plano de energia ativo do Windows:
      - "Definicoes do adaptador sem fios > Modo de poupanca de energia" -> Desempenho maximo (corrente e bateria)

    O que o modo Apply muda, em cada placa de rede fisica (Wi-Fi e Ethernet, incluindo USB):
      - "Permitir que o computador desligue este dispositivo" -> desligado
      - Poupanca de energia da placa Wi-Fi (Power Saving) -> desligada
      - Agressividade de roaming -> a mais baixa / desativada
      - Energy-Efficient Ethernet / Green Ethernet -> desligado
      - Suspensao seletiva USB do adaptador -> desligada
      - RSC (Receive Segment Coalescing) -> desligado
      - DNS -> so se pedires com -Dns (o DNS NAO muda o ping nos jogos, so a rapidez a abrir nomes)

.PARAMETER Mode
    Test   : so mede e mostra o estado das placas (nao precisa de admin, nao muda nada). Padrao.
    Apply  : mede, faz backup, aplica os ajustes, volta a medir e compara. Precisa de admin.
    Revert : repoe o ultimo backup (ou o indicado em -BackupFile). Precisa de admin.

.PARAMETER Dns
    Keep (padrao), Cloudflare, Google ou Quad9. So e aplicado no modo Apply.

.PARAMETER Count
    Numero de pings por alvo nos testes (padrao 50, cerca de 10 s por alvo).

.PARAMETER ExtraTargets
    Alvos extra para o teste, por exemplo o IP de um servidor de outro jogo.

.PARAMETER BackupFile
    Ficheiro de backup a usar no modo Revert. Por defeito usa o mais recente da pasta backups.

.PARAMETER SkipTest
    No modo Apply, salta os testes antes/depois.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NetTune.ps1
    Mede a ligacao e mostra o estado atual das placas.

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

    [switch]$SkipTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Version   = '1.1.0'
$Root      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$BackupDir = Join-Path $Root 'backups'
$LogDir    = Join-Path $Root 'logs'
$Stamp     = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

$DnsPresets = @{
    Cloudflare = @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001')
    Google     = @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844')
    Quad9      = @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9')
}

# Regras para as propriedades avancadas das placas.
# Display: regex contra o nome da propriedade (EN / PT / ES, porque o driver usa a lingua do Windows).
# Want   : regex contra os valores validos; escolhe o primeiro que bater.
# "Desligado" em EN / PT-BR / PT-PT / ES (Disabled, Desabilitado, Desativado, Desactivado, Deshabilitado...).
$OffValues = 'Disab|Desab|Deshab|Desact|Desativ|Deslig|^Off$'

$Rules = @(
    @{ Label = 'Poupanca de energia da placa'
       Display = '^(Power Saving|Power Save Mode|Power Saving Mode|Modo de economia de energia|Economia de energia|Poupança de energia|Modo de poupança de energia|Ahorro de energía|Modo de ahorro de energía)$'
       Want = $OffValues }
    @{ Label = 'Agressividade de roaming'
       Display = 'Roaming Aggressiveness|Agressividade de roaming|Agresividad de itinerancia|Agresividad de roaming'
       Want = '^1\.|Lowest|Mais baix|Más baj|Disab|Desab|Deshab|Desact' }
    @{ Label = 'Energy-Efficient Ethernet'
       Display = 'Energy.Efficient Ethernet|Advanced EEE|^EEE$|Green Ethernet|Ethernet verde|Ethernet.*efici'
       Want = $OffValues }
    @{ Label = 'Suspensao seletiva USB'
       Display = 'Selective Suspend|Suspensão seletiva|Suspensión selectiva'
       Want = $OffValues }
)

# Plano de energia do Windows -> "Definicoes do adaptador sem fios" -> "Modo de poupanca de energia".
# 0 = Desempenho maximo, 1 = Poupanca baixa, 2 = Poupanca media, 3 = Poupanca maxima.
$WifiPowerSub   = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$WifiPowerSet   = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
$WifiPowerNames = @('Desempenho maximo', 'Poupanca baixa', 'Poupanca media', 'Poupanca maxima')

# Placas que nunca tocamos (VPNs, virtuais, Bluetooth).
$ExcludeAdapters = 'Bluetooth|Virtual|\bTAP\b|Tunnel|VPN|Wintun|WireGuard|Hyper-V|Loopback|Check Point|TunnelBear'

# ---------------------------------------------------------------- utilitarios

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [..] $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text){ Write-Host "  [!!] $Text" -ForegroundColor Yellow }

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
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
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
}

function Get-WifiPowerPlan {
    # Le o "Modo de poupanca de energia" do Wi-Fi no plano ativo. Devolve $null se nao existir.
    try {
        $scheme = [regex]::Match((powercfg /getactivescheme | Out-String), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
        if (-not $scheme) { return $null }
        # As duas ultimas linhas com 0x.. sao sempre AC e DC (independente da lingua do Windows).
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
    if ($LASTEXITCODE -ne 0) { throw "powercfg falhou (AC, codigo $LASTEXITCODE)" }
    powercfg /setdcvalueindex $Scheme $WifiPowerSub $WifiPowerSet $DC | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg falhou (DC, codigo $LASTEXITCODE)" }
    powercfg /setactive $Scheme | Out-Null
}

function Format-WifiPower([int]$Value) {
    if ($Value -ge 0 -and $Value -lt $WifiPowerNames.Count) { return "$Value ($($WifiPowerNames[$Value]))" }
    return [string]$Value
}

# ---------------------------------------------------------------- testes

function Measure-Target([string]$Label, [string]$HostName, [int]$Pings) {
    $empty = [pscustomobject]@{ Alvo = $Label; Host = $HostName; Min = $null; Media = $null; Max = $null; Jitter = $null; 'Picos>100' = $null; 'Perda%' = 100 }

    # Resolver o nome uma vez so (senao cada ping faz uma consulta DNS e uma falha de DNS conta como perda).
    $address = $HostName
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($HostName, [ref]$parsed)) {
        try {
            $all = @([Net.Dns]::GetHostAddresses($HostName))
            $v4 = $all | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            $address = if ($v4) { $v4.IPAddressToString } else { $all[0].IPAddressToString }
        } catch {
            Write-Warn2 "Nao consegui resolver '$HostName' (DNS)."
            return $empty
        }
    }

    $ping = New-Object System.Net.NetworkInformation.Ping
    $rtts = New-Object System.Collections.Generic.List[double]
    $lost = 0
    try {
        for ($i = 0; $i -lt $Pings; $i++) {
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
        Min         = [math]::Round($min, 0)
        Media       = [math]::Round($stats.Average, 1)
        Max         = [math]::Round($stats.Maximum, 0)
        Jitter      = [math]::Round($jitter, 1)
        'Picos>100' = $spikes
        'Perda%'    = [math]::Round(100.0 * $lost / $Pings, 1)
    }
}

function Invoke-NetTest([string]$Title) {
    Write-Title $Title
    $targets = New-Object System.Collections.Generic.List[object]
    $gw = Get-DefaultGateway
    if ($gw) { $targets.Add(@('Router', $gw)) } else { Write-Warn2 'Nao encontrei o router (gateway). Estas ligado a alguma rede?' }
    $targets.Add(@('Cloudflare', '1.1.1.1'))
    $targets.Add(@('Google', '8.8.8.8'))
    $targets.Add(@('Epic Franca', 'ping-fr.ds.on.epicgames.com'))
    $targets.Add(@('Epic Alemanha', 'ping-de.ds.on.epicgames.com'))
    $targets.Add(@('Epic Reino Unido', 'ping-gb.ds.on.epicgames.com'))
    foreach ($t in $ExtraTargets) { $targets.Add(@("Extra $t", $t)) }

    $secs = [math]::Ceiling($targets.Count * $Count * 0.2)
    Write-Info "$($targets.Count) alvos x $Count pings (cerca de $secs s). Nao uses a net durante o teste."

    $results = foreach ($t in $targets) {
        Write-Info "A medir $($t[0]) ($($t[1]))..."
        Measure-Target -Label $t[0] -HostName $t[1] -Pings $Count
    }
    $results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $router = $results | Where-Object { $_.Alvo -eq 'Router' } | Select-Object -First 1
    if ($router -and $router.Media -ne $null) {
        if ($router.Media -gt 10 -or $router.'Picos>100' -gt 0) {
            Write-Warn2 'O ping ao ROUTER devia ser 1-5 ms e estavel. Se esta alto ou com picos, o problema e local (placa/driver/Wi-Fi), nao a operadora.'
        } else {
            Write-Ok 'Ligacao ao router estavel.'
        }
    }
    return $results
}

function Show-Comparison($Before, $After) {
    Write-Title 'Antes vs depois (media / maximo / jitter / perda)'
    $rows = foreach ($b in $Before) {
        $a = $After | Where-Object { $_.Alvo -eq $b.Alvo } | Select-Object -First 1
        if (-not $a) { continue }
        [pscustomobject]@{
            Alvo          = $b.Alvo
            'Media antes' = $b.Media
            'Media agora' = $a.Media
            'Max antes'   = $b.Max
            'Max agora'   = $a.Max
            'Jitter antes'= $b.Jitter
            'Jitter agora'= $a.Jitter
            'Perda antes' = $b.'Perda%'
            'Perda agora' = $a.'Perda%'
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}

# ---------------------------------------------------------------- estado das placas

function Show-AdapterState {
    Write-Title 'Estado das placas de rede'
    $wifiPlan = Get-WifiPowerPlan
    if ($wifiPlan) {
        Write-Info ("Plano de energia, poupanca do Wi-Fi: ligado a corrente {0}, na bateria {1}" -f (Format-WifiPower $wifiPlan.AC), (Format-WifiPower $wifiPlan.DC))
    }

    $adapters = @(Get-TargetAdapters)
    if ($adapters.Count -eq 0) { Write-Warn2 'Nenhuma placa fisica encontrada.'; return }

    foreach ($a in $adapters) {
        Write-Host ''
        Write-Host ("  {0}  [{1}]  {2}" -f $a.Name, $a.Status, $a.InterfaceDescription) -ForegroundColor White
        Write-Info ("Driver {0} ({1})  Velocidade: {2}" -f $a.DriverVersion, $a.DriverDate, $a.LinkSpeed)

        try {
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
            Write-Info ("Permitir desligar para poupar energia: {0}" -f $pm.AllowComputerToTurnOffDevice)
        } catch { }

        try {
            $rsc = Get-NetAdapterRsc -Name $a.Name -ErrorAction Stop
            Write-Info ("RSC IPv4/IPv6: {0}/{1}" -f $rsc.IPv4Enabled, $rsc.IPv6Enabled)
        } catch { }

        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue)
        foreach ($p in $props) {
            foreach ($r in $Rules) {
                if ($p.DisplayName -match $r.Display) {
                    Write-Info ("{0}: {1}" -f $p.DisplayName, $p.DisplayValue)
                    break
                }
            }
        }

        try {
            $dnsNow = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction Stop |
                ForEach-Object { $_.ServerAddresses }) -join ', '
            if ($dnsNow) { Write-Info "DNS: $dnsNow" }
        } catch { }
    }
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
    if (-not $SkipTest) { $before = Invoke-NetTest 'Teste ANTES dos ajustes' }

    Show-AdapterState

    $adapters = @(Get-TargetAdapters)
    if ($adapters.Count -eq 0) { throw 'Nenhuma placa fisica encontrada.' }

    $backup = [ordered]@{
        Created  = (Get-Date).ToString('s')
        Tool     = "NetTune $Version"
        Computer = $env:COMPUTERNAME
        WifiPowerPlan = $null
        Adapters = @()
    }

    Write-Title 'A aplicar ajustes'

    # O backup e guardado no finally: se algum ajuste der erro a meio, o que ja foi mudado fica registado.
    try {

    # 0) Poupanca de energia do Wi-Fi no plano de energia do Windows (AC e bateria)
    $wifiPlan = Get-WifiPowerPlan
    if ($wifiPlan) {
        if ($wifiPlan.AC -ne 0 -or $wifiPlan.DC -ne 0) {
            $backup.WifiPowerPlan = [ordered]@{ Scheme = $wifiPlan.Scheme; AC = $wifiPlan.AC; DC = $wifiPlan.DC }
            $msg = "Poupanca do Wi-Fi no plano de energia: corrente $(Format-WifiPower $wifiPlan.AC), bateria $(Format-WifiPower $wifiPlan.DC) -> desempenho maximo"
            if ($PSCmdlet.ShouldProcess('Plano de energia', $msg)) {
                Set-WifiPowerPlan -Scheme $wifiPlan.Scheme -AC 0 -DC 0
            }
            Write-Ok $msg
        } else {
            Write-Info 'Poupanca do Wi-Fi no plano de energia: ja em desempenho maximo'
        }
    }

    foreach ($a in $adapters) {
        Write-Host ''
        Write-Host "  $($a.Name) - $($a.InterfaceDescription)" -ForegroundColor White

        $entry = [ordered]@{
            Name                 = $a.Name
            InterfaceDescription = $a.InterfaceDescription
            InterfaceGuid        = [string]$a.InterfaceGuid
            PowerManagement      = $null
            Rsc                  = $null
            Advanced             = @()
            Dns                  = $null
        }
        # Entra ja no backup (e uma referencia, as alteracoes abaixo ficam la).
        $backup.Adapters += $entry
        $changed = $false

        # 1) Deixar o Windows desligar a placa para poupar energia
        try {
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
            $current = [string]$pm.AllowComputerToTurnOffDevice
            if ($current -eq 'Enabled') {
                $entry.PowerManagement = $current
                if ($PSCmdlet.ShouldProcess($a.Name, 'Desligar "permitir que o computador desligue este dispositivo"')) {
                    Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled -NoRestart -ErrorAction Stop
                    $changed = $true
                }
                Write-Ok 'Gestao de energia do Windows desligada'
            } else {
                Write-Info "Gestao de energia do Windows: $current (nada a fazer)"
            }
        } catch {
            Write-Info 'Gestao de energia: nao suportada por esta placa'
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
                Write-Ok 'RSC desligado'
            } else {
                Write-Info 'RSC ja desligado'
            }
        } catch {
            Write-Info 'RSC: nao suportado por esta placa'
        }

        # 3) Propriedades avancadas do driver
        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue)
        foreach ($p in $props) {
            $rule = $null
            foreach ($r in $Rules) { if ($p.DisplayName -match $r.Display) { $rule = $r; break } }
            if (-not $rule) { continue }

            $valid = @($p.ValidDisplayValues)
            if ($valid.Count -eq 0) { continue }
            $target = $valid | Where-Object { $_ -match $rule.Want } | Select-Object -First 1
            if (-not $target) {
                Write-Warn2 "$($p.DisplayName): nao encontrei valor para desligar (opcoes: $($valid -join ' | '))"
                continue
            }
            if ($p.DisplayValue -eq $target) {
                Write-Info "$($p.DisplayName): ja esta em '$target'"
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
            Write-Ok "$($p.DisplayName): '$($p.DisplayValue)' -> '$target'"
        }

        # 4) DNS (opcional)
        if ($Dns -ne 'Keep') {
            $entry.Dns = Get-DnsBackup $a
            $servers = $DnsPresets[$Dns]
            if ($PSCmdlet.ShouldProcess($a.Name, "DNS -> $Dns ($($servers -join ', '))")) {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers -ErrorAction Stop
            }
            Write-Ok "DNS -> $Dns"
        }

        # Reiniciar a placa uma vez so, para aplicar tudo
        if ($changed -and $a.Status -eq 'Up') {
            if ($PSCmdlet.ShouldProcess($a.Name, 'Reiniciar a placa para aplicar')) {
                Write-Info 'A reiniciar a placa (a ligacao cai uns segundos)...'
                Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
            }
        } elseif ($changed) {
            Write-Info 'Placa desligada: as mudancas aplicam-se quando a ligares.'
        }
    }

    } finally {
        if (-not $WhatIfPreference) {
            $file = Save-Backup $backup
            Write-Ok "Backup guardado em: $file"
        }
    }

    if ($WhatIfPreference) {
        Write-Warn2 'Modo -WhatIf: nada foi mudado.'
        return
    }

    if ($Dns -ne 'Keep') { Clear-DnsClientCache -ErrorAction SilentlyContinue }

    Write-Info 'A espera que a rede volte...'
    if (-not (Wait-Network 40)) { Write-Warn2 'A rede demorou a voltar. Verifica a ligacao antes do teste.' }
    Start-Sleep -Seconds 3

    if (-not $SkipTest) {
        $after = Invoke-NetTest 'Teste DEPOIS dos ajustes'
        if ($before) { Show-Comparison $before $after }
    }

    Write-Host ''
    Write-Ok 'Feito. Para desfazer: .\NetTune.ps1 -Mode Revert'
    Write-Info 'Nota: um update do driver da placa pode repor os valores de fabrica. Se os picos voltarem, corre o Apply outra vez.'
}

# ---------------------------------------------------------------- revert

function Invoke-Revert {
    Assert-Admin

    $file = $BackupFile
    if (-not $file) {
        $latest = Get-ChildItem -Path $BackupDir -Filter 'backup-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw "Nao ha backups em $BackupDir" }
        $file = $latest.FullName
    }
    if (-not (Test-Path $file)) { throw "Backup nao encontrado: $file" }

    Write-Title "A repor backup: $(Split-Path $file -Leaf)"
    $data = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json

    # Backups antigos (1.0.0) nao tem esta propriedade; com StrictMode tem de se ver assim.
    $planProp = $data.PSObject.Properties['WifiPowerPlan']
    if ($planProp -and $planProp.Value) {
        $p = $planProp.Value
        $msg = "Poupanca do Wi-Fi no plano de energia -> corrente $(Format-WifiPower $p.AC), bateria $(Format-WifiPower $p.DC)"
        if ($PSCmdlet.ShouldProcess('Plano de energia', $msg)) {
            try {
                Set-WifiPowerPlan -Scheme $p.Scheme -AC $p.AC -DC $p.DC
                Write-Ok $msg
            } catch { Write-Warn2 "Plano de energia: $($_.Exception.Message)" }
        }
    }

    foreach ($e in @($data.Adapters)) {
        $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $e.InterfaceGuid } | Select-Object -First 1
        if (-not $a) { $a = Get-NetAdapter -Name $e.Name -ErrorAction SilentlyContinue }
        if (-not $a) { Write-Warn2 "Placa '$($e.Name)' nao encontrada, a saltar."; continue }

        Write-Host ''
        Write-Host "  $($a.Name) - $($a.InterfaceDescription)" -ForegroundColor White
        $changed = $false

        foreach ($adv in @($e.Advanced)) {
            if (-not $adv) { continue }
            if ($PSCmdlet.ShouldProcess($a.Name, "$($adv.DisplayName) -> '$($adv.DisplayValue)'")) {
                try {
                    Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $adv.RegistryKeyword -RegistryValue @($adv.RegistryValue) -NoRestart -ErrorAction Stop
                    Write-Ok "$($adv.DisplayName) -> '$($adv.DisplayValue)'"
                    $changed = $true
                } catch {
                    Write-Warn2 "$($adv.DisplayName): $($_.Exception.Message)"
                }
            }
        }

        if ($e.Rsc) {
            if ($PSCmdlet.ShouldProcess($a.Name, 'Repor RSC')) {
                try {
                    if ($e.Rsc.IPv4) { Enable-NetAdapterRsc -Name $a.Name -IPv4 -NoRestart -ErrorAction Stop }
                    if ($e.Rsc.IPv6) { Enable-NetAdapterRsc -Name $a.Name -IPv6 -NoRestart -ErrorAction Stop }
                    Write-Ok 'RSC reposto'
                    $changed = $true
                } catch { Write-Warn2 "RSC: $($_.Exception.Message)" }
            }
        }

        if ($e.PowerManagement -eq 'Enabled') {
            if ($PSCmdlet.ShouldProcess($a.Name, 'Repor gestao de energia do Windows')) {
                try {
                    Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Enabled -NoRestart -ErrorAction Stop
                    Write-Ok 'Gestao de energia do Windows reposta'
                    $changed = $true
                } catch { Write-Warn2 "Gestao de energia: $($_.Exception.Message)" }
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
                        Write-Ok "DNS reposto: $($servers -join ', ')"
                    } else {
                        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
                        Write-Ok 'DNS reposto: automatico (DHCP)'
                    }
                } catch { Write-Warn2 "DNS: $($_.Exception.Message)" }
            }
        }

        if ($changed -and $a.Status -eq 'Up' -and $PSCmdlet.ShouldProcess($a.Name, 'Reiniciar a placa')) {
            Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Clear-DnsClientCache -ErrorAction SilentlyContinue
    if (-not $WhatIfPreference) { [void](Wait-Network 40) }
    Write-Host ''
    Write-Ok 'Backup reposto.'
}

# ---------------------------------------------------------------- main

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -WhatIf:$false | Out-Null }
$transcript = Join-Path $LogDir "nettune-$Mode-$Stamp.log"
try { Start-Transcript -Path $transcript -WhatIf:$false -ErrorAction Stop | Out-Null } catch { $transcript = $null }

try {
    Write-Host "NetTune $Version - modo $Mode" -ForegroundColor Cyan
    switch ($Mode) {
        'Test'   { Show-AdapterState; [void](Invoke-NetTest 'Teste de ligacao') }
        'Apply'  { Invoke-Apply }
        'Revert' { Invoke-Revert }
    }
} catch {
    Write-Host ''
    Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($transcript) {
        try { Stop-Transcript -WhatIf:$false | Out-Null } catch { }
        Write-Host "  Log: $transcript" -ForegroundColor DarkGray
    }
}
