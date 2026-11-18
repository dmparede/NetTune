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
| DNS → **o mais rápido**, só se for claramente melhor | Testa o teu DNS atual contra Cloudflare, Google, Quad9 e OpenDNS e muda só se ganhar pelo menos 3 ms e 15% (ver abaixo). |

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

# 3b. Aplicar sem mexer no DNS
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -Dns Keep

# 3c. Aplicar e forçar o DNS da Cloudflare (sem testar os outros)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -Dns Cloudflare

# 4. Desfazer tudo (usa o backup mais recente)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Revert
```

Outras opções:

- `-Count 100`: mais pings por alvo (o padrão é 50).
- `-Services Epic,Valve`: testa só alguns serviços de jogos (opções: `Epic`, `Valve`, `Blizzard`, `Ubisoft`, `Microsoft`, `Embark`; por defeito, todos).
- `-ExtraTargets 1.2.3.4`: junta um servidor teu ao teste (o IP de outro jogo, por exemplo).
- `-SkipTest`: aplica sem fazer os testes antes e depois.
- `-BackupFile .\backups\backup-XXXX.json`: escolhe um backup específico para o Revert.
- `-Ascii`: usa só caracteres ASCII no ecrã, se a tua consola mostrar quadrados em vez de `✓ ─ ╭`. No Windows Terminal (o padrão do Windows 11) não é preciso.

Durante o Apply, a ligação cai uns segundos enquanto as placas reiniciam.

**Reinicia o PC depois do Apply (e do Revert).** A opção "permitir que o computador desligue este dispositivo" só muda depois de reiniciar, por isso o teste "depois" que o script faz ainda não a inclui. O script avisa no fim quando é preciso reiniciar.

### Como funciona a gestão de energia

O `Set-NetAdapterPowerManagement` não tem nenhum parâmetro para esta opção, por isso o script escreve diretamente no registo. É a mesma coisa que tirar o visto na caixa do Gestor de Dispositivos:

- Chave: `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\00XX`, a subchave cujo `NetCfgInstanceId` é o GUID da placa.
- Valor: `PnPCapabilities` (DWORD) = `24`.
- O backup guarda o valor antigo, ou que não existia. O Revert repõe esse valor ou apaga a entrada.

## Como ler o ecrã

**Estado atual.** Cada placa aparece com as suas opções:

- `✓` verde: já está otimizado.
- `!` amarelo: o Apply vai mudar isto (o valor novo aparece a seguir à `→`).

No modo Test, o resumo no fim diz quantos ajustes faltam.

**Teste de ligação.** Mede o **router**, a **Cloudflare** e a **Google**, e um servidor de cada serviço de jogos (ver abaixo). As linhas vão aparecendo à medida que cada alvo termina, com uma barra de progresso. Cada valor é pintado de **verde** (bom), **amarelo** (razoável) ou **vermelho** (mau). A coluna *Estado* dá o veredicto da linha: o pior dos valores.

| Coluna | O que é | Verde | Amarelo |
|---|---|---|---|
| Servidor | A região medida. Nos jogos, é a mais próxima de ti, escolhida automaticamente | | |
| Média | Ping médio | Router ≤ 5 ms · Cloudflare/Google ≤ 40 · jogos ≤ 60 | Router ≤ 15 · ≤ 80 · ≤ 100 |
| Máx | Pior ping | Até 30 ms acima do mínimo | Até 100 ms acima |
| Jitter | O quanto o ping varia de um pacote para o outro | ≤ 5 ms | ≤ 15 ms |
| Picos | Pings que ficaram 100 ms acima do mínimo | 0 | 1-2 |
| Perda | Pacotes perdidos | 0% | ≤ 2% |

Com poucos pings (por exemplo `-Count 5`), um único pacote perdido já dá 20% e a linha fica vermelha. Para um diagnóstico a sério usa o padrão de 50.

**Antes vs depois** (no Apply). Mostra a média, o jitter e a perda com `▼` verde quando melhorou, `▲` vermelho quando piorou e `=` quando ficou igual.

**A regra de ouro:** se o ping ao **router** está alto ou tem picos, o problema está no teu PC ou no Wi-Fi, não na operadora nem no jogo. O router está ao teu lado; 1-5 ms é o normal.

## Teste de DNS

Por defeito (`-Dns Auto`), o modo Test e o Apply testam **Cloudflare**, **Google**, **Quad9** e **OpenDNS**, e mostram também o DNS que estás a usar como referência. O DNS atual é o da placa que está mesmo a levar o tráfego para a internet, a rota que o próprio Windows escolhe; uma placa desligada com uma rota antiga não conta.

- **Como mede:** o script envia consultas DNS diretamente a cada servidor (UDP, porta 53), sem passar pela cache do Windows. São 10 domínios que usas a jogar (Epic, Steam, Battle.net, Ubisoft, Xbox, Discord, Twitch...) × 3 rondas, mais 5 nomes aleatórios que obrigam o servidor a ir perguntar ao domínio. Os servidores são intercalados, para todos apanharem as mesmas condições da rede.
- **Colunas:** *Mediana* é o tempo habitual de resposta (com cache), *Sem cache* é a primeira vez que um nome é pedido, *Falhas* são as consultas sem resposta. O escolhido leva `★`.
- **O router não conta.** Se o teu DNS é o router (por exemplo `192.168.1.254`) ou outro IP da rede local, ele só reencaminha para o DNS da operadora. Responde em ~1 ms porque guarda cache na rede local, mas isso não é comparável com um DNS a sério. Aparece na tabela só como referência ("cache local, não conta").
- **Como escolhe:** pontuação = 70% mediana + 30% sem cache, só entre DNS públicos com até 10% de falhas. Diferenças até **5 ms (ou 20%)** contam como empate, porque o mesmo servidor varia isso de um teste para outro. Em empate prefere **Cloudflare**, depois Google (o Quad9 e o OpenDNS filtram domínios).
- **Quando muda:** se o teu DNS é o router ou o da operadora, muda para o escolhido. Se já usas um DNS público, só troca se o outro for melhor por mais do que a margem de empate.
- **Como aplica:** em cada placa, **IPv4 e IPv6 em separado**, definidos à mão (`netsh`, pelo índice da placa). Depois volta a ler cada família e só mostra `✓` se ficou mesmo aplicada. Se o IPv6 estiver desligado na placa, só define o IPv4.
- **Backup e Revert:** o DNS antigo de cada família fica no backup. O Revert repõe cada uma (a lista fixa antiga, ou automático/DHCP se não havia).
- **Redes que bloqueiam DNS externo** (escolas, empresas, algumas redes públicas): os DNS públicos aparecem como "não responde" e o script **não muda nada**, porque mudar cortava-te a internet. Com `-Dns Cloudflare` (forçado), o script confirma primeiro que esse DNS responde. Se não responder, recusa.
- **Honestidade:** o DNS só acelera abrir sites e ligar aos serviços (login, lojas, matchmaking). **Não muda o ping dentro do jogo.**

Opções: `-Dns Auto` (padrão), `-Dns Keep` (não testa nem mexe), `-Dns Cloudflare | Google | Quad9 | OpenDNS` (força esse, depois de confirmar que responde).

## Servidores de jogos

Para cada serviço, o script faz primeiro um teste rápido a todas as regiões (em paralelo), fica com a mais próxima de ti e só depois mede essa a sério. No Apply, o teste "depois" usa os mesmos servidores que o "antes", para a comparação ser justa.

| Serviço | O que é medido | Regiões | Quão perto do jogo real |
|---|---|---|---|
| **Epic Games** | Beacons de ping oficiais do Fortnite | França, Alemanha, Reino Unido, EUA (Este, Centro, Oeste), Brasil | Os próprios servidores de ping do jogo |
| **Valve / Steam** | Relays SDR da Valve (CS2, Dota 2, Deadlock…). A lista vem em direto da API da Steam, com uma lista interna de reserva | Todos os datacenters da Valve no mundo | É por estes relays que passa o tráfego do jogo |
| **Blizzard** | Servidores Battle.net | Europa, EUA, Coreia | Infraestrutura da Blizzard (na Google Cloud) |
| **Ubisoft** | Regiões Azure usadas pelo Rainbow Six, mais AWS (GameLift) | Azure Irlanda, Holanda, EUA ×4, Brasil · AWS Frankfurt, EUA Este | Os datacenters onde os servidores correm, não o servidor em si |
| **Microsoft / Xbox** | Regiões Azure | 15 regiões, da Europa à Ásia e Austrália | Os datacenters, não o servidor em si |
| **Embark** | The Finals / Arc Raiders correm na Google Cloud, mas a Embark não tem endpoints públicos de ping. Mede-se a região Google Cloud | Google Cloud Holanda, EUA, Coreia | Referência aproximada |

Notas:

- **`tcp` na coluna Servidor:** a Azure bloqueia o ping, por isso nesses servidores mede-se o tempo de ligação TCP (porta 443). O handshake TCP demora praticamente um ida-e-volta, por isso os números são comparáveis com o ping.
- **É uma referência, não o ping exato do jogo.** O ping dentro do jogo depende do servidor concreto do jogo. Mas, se a região mais próxima já tem picos ou perda aqui, também vai ter no jogo.
- **Riot (Valorant, LoL)** ficou de fora: os IPs públicos de ping deles já não respondem.
- Para outro jogo, junta o IP do servidor com `-ExtraTargets`.

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
