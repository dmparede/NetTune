# NetTune

Script PowerShell para Windows 10/11 que **mede** a tua ligação, aplica **só ajustes com efeito real** na latência e estabilidade, e volta a medir para mostrar a diferença. Guarda um backup antes de mudar seja o que for, por isso dá sempre para desfazer.

Nasceu de um caso real: um portátil com placa **MediaTek MT7925 (Wi-Fi 7)** tinha picos de 700 ms no Fortnite. O culpado era a poupança de energia e o roaming da placa. Depois dos ajustes, o ping ao router passou de **144 ms de média para 3 ms**.

## O que faz

Em cada placa de rede física (Wi-Fi, Ethernet e adaptadores USB):

| Ajuste | Porquê |
|---|---|
| Plano de energia → "Adaptador sem fios: modo de poupança de energia" → Desempenho máximo | Por defeito, na bateria o Windows põe o Wi-Fi em poupança média. Jogar sem carregador dá picos. |
| "Permitir que o computador desligue este dispositivo" → desligado | O Windows deixa de pôr a placa a dormir. É feito com `PnPCapabilities = 24` na chave de registo da placa e **só faz efeito depois de reiniciar o PC**. |
| Poupança de energia da placa (Power Saving) → desligada | A placa adormece entre pacotes e demora a acordar, o que dá picos. |
| Agressividade de roaming → a mais baixa | A placa deixa de procurar outros pontos de acesso a meio do jogo (cada procura congela a ligação). |
| Energy-Efficient Ethernet / Green Ethernet → desligado | Mesmo problema, mas no cabo. |
| Suspensão seletiva USB → desligada | Para adaptadores Ethernet USB. |
| RSC (Receive Segment Coalescing) → desligado | Junta pacotes para poupar CPU, o que é bom para downloads e mau para latência. |
| DNS → **só se pedires** (`-Dns`) | Cloudflare, Google ou Quad9. |

Os nomes das opções variam conforme o driver e a língua do Windows. O script reconhece-os em inglês, português e espanhol.

## O que NÃO faz (de propósito)

- **Tweaks de TCP** (Nagle, `TcpAckFrequency`, `TCPNoDelay`): os jogos usam UDP, por isso isto não muda nada no ping in-game.
- **"NetworkThrottlingIndex" e outros tweaks de registo milagrosos**: não há prova de que melhorem o ping, e alguns pioram outras coisas.
- **Prometer que o DNS baixa o ping**: o DNS só traduz nomes em IPs antes de ligar. Durante o jogo não entra. Mudar de DNS pode tornar os sites mais rápidos a abrir, mas não mexe no ping.
- **Mexer em VPNs, placas virtuais ou Bluetooth**: são ignoradas.

## Como usar

Abre o **PowerShell como administrador** (o azul, Windows PowerShell 5.1) na pasta do script.

```powershell
# 1. Só medir e ver o estado das placas (não muda nada, não precisa de admin)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1

# 2. Ensaio: mostra o que seria mudado, sem mudar nada
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -WhatIf

# 3. Aplicar (mede antes, faz backup, aplica, mede depois e compara)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply

# 3b. Aplicar e mudar o DNS para Cloudflare
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -Dns Cloudflare

# 4. Desfazer tudo (usa o backup mais recente)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Revert
```

Outras opções:

- `-Count 100`: mais pings por alvo (o padrão é 50).
- `-ExtraTargets 1.2.3.4`: junta um servidor teu ao teste (o IP de outro jogo, por exemplo).
- `-SkipTest`: aplica sem fazer os testes antes e depois.
- `-BackupFile .\backups\backup-XXXX.json`: escolhe um backup específico para o Revert.

Durante o Apply, a ligação cai uns segundos enquanto as placas reiniciam.

**Reinicia o PC depois do Apply (e do Revert).** A opção "permitir que o computador desligue este dispositivo" só muda depois de reiniciar, por isso o teste "depois" que o script faz ainda não a inclui. O script avisa no fim quando é preciso reiniciar.

### Como funciona a gestão de energia

O `Set-NetAdapterPowerManagement` não tem nenhum parâmetro para esta opção, por isso o script escreve diretamente no registo. É a mesma coisa que tirar o visto na caixa do Gestor de Dispositivos:

- Chave: `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\00XX`, a subchave cujo `NetCfgInstanceId` é o GUID da placa.
- Valor: `PnPCapabilities` (DWORD) = `24`.
- O backup guarda o valor antigo, ou que não existia. O Revert repõe esse valor ou apaga a entrada.

## Como ler o teste

O teste faz ping ao **router**, à **Cloudflare** e à **Google**, e aos servidores da **Epic** em França, Alemanha e Reino Unido.

| Coluna | O que é | Bom |
|---|---|---|
| Media | Ping médio | Router: 1-5 ms |
| Max | Pior ping | Perto da média |
| Jitter | O quanto o ping varia de um pacote para o outro | < 5 ms |
| Picos>100 | Pings que ficaram 100 ms acima do mínimo | 0 |
| Perda% | Pacotes perdidos | 0 |

**A regra de ouro:** se o ping ao **router** está alto ou tem picos, o problema está no teu PC ou no Wi-Fi, não na operadora nem no jogo. O router está ao teu lado; 1-5 ms é o normal.

## Ficheiros

- `backups/backup-<data>.json`: o estado original de cada opção alterada (incluindo o `PnPCapabilities` antigo de cada placa e o plano de energia do Wi-Fi).
- `logs/nettune-<modo>-<data>.log`: o registo completo de cada execução.

As duas pastas estão no `.gitignore`, porque são específicas de cada PC.

## Notas

- Um update do driver da placa (Windows Update ou Lenovo Vantage, por exemplo) pode repor os valores de fábrica. Se os picos voltarem, corre o `-Mode Apply` outra vez.
- Se aparecer um erro de política de execução, usa sempre `powershell -ExecutionPolicy Bypass -File ...` como nos exemplos.
- Feito para o PowerShell 5.1 (o que vem com o Windows). Também deve correr no PowerShell 7.

## Licença

MIT
