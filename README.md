# NetTune

PowerShell script for Windows 10/11 that **measures** your connection, applies **only tweaks with a real effect** on latency and stability, and measures again to show the difference. It saves a backup before changing anything, so you can always undo it.

It started from a real case: a laptop with a **MediaTek MT7925 (Wi-Fi 7)** card had 700 ms spikes in Fortnite. The culprits were the card's power saving and roaming. After the tweaks, the ping to the router went from a **144 ms average to 3 ms**.

## What it does

On each physical network adapter (Wi-Fi, Ethernet and USB adapters):

| Tweak | Why |
|---|---|
| Power plan → "Wireless Adapter Settings: Power Saving Mode" → Maximum performance | By default, on battery Windows puts Wi-Fi in medium power saving. Gaming unplugged causes spikes. |
| "Allow the computer to turn off this device" → off | Windows stops putting the adapter to sleep. Done with `PnPCapabilities = 24` in the adapter's registry key, and **only takes effect after a PC restart**. |
| Adapter power saving (Power Saving) → off | The adapter sleeps between packets and is slow to wake up, which causes spikes. |
| Roaming aggressiveness → lowest | The adapter stops scanning for other access points mid-game (each scan freezes the connection). |
| Energy-Efficient Ethernet / Green Ethernet → off | Same problem, but on the cable. |
| USB selective suspend → off | For USB Ethernet adapters. |
| RSC (Receive Segment Coalescing) → off | Merges packets to save CPU, which is good for downloads and bad for latency. |
| DNS → **the best public one**, only if it is clearly better | Tests Cloudflare, Google, Quad9 and OpenDNS and switches only when one clearly wins (see below). |

Option names vary with the driver and the Windows language. The script recognizes them in English, Portuguese and Spanish.

## What it does NOT do (on purpose)

- **TCP tweaks** (Nagle, `TcpAckFrequency`, `TCPNoDelay`): games use UDP, so these change nothing for in-game ping.
- **"NetworkThrottlingIndex" and other miracle registry tweaks**: there is no evidence they improve ping, and some make other things worse.
- **Promise that DNS lowers ping**: DNS only turns names into IPs before connecting. It plays no part during the match. Changing DNS can make sites open faster, but it does not touch ping.
- **Touch VPNs, virtual adapters or Bluetooth**: they are ignored.

## How to use

Open **PowerShell as administrator** (the blue one, Windows PowerShell 5.1) in the script's folder.

```powershell
# 1. Only measure and see the adapter state (changes nothing, no admin needed)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1

# 2. Dry run: shows what would be changed, without changing anything
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -WhatIf

# 3. Apply (measures before, backs up, applies, measures after and compares)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply

# 3b. Apply without touching DNS
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -Dns Keep

# 3c. Apply and force Cloudflare DNS (without testing the others)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Apply -Dns Cloudflare

# 4. Undo everything (uses the most recent backup)
powershell -ExecutionPolicy Bypass -File .\NetTune.ps1 -Mode Revert
```

Other options:

- `-Count 100`: more pings per target (default is 50).
- `-Services Epic,Valve`: tests only some game services (options: `Epic`, `Valve`, `Blizzard`, `Ubisoft`, `Microsoft`, `Embark`; all by default).
- `-ExtraTargets 1.2.3.4`: adds your own server to the test (another game's IP, for example).
- `-SkipTest`: applies without running the before and after tests.
- `-BackupFile .\backups\backup-XXXX.json`: picks a specific backup for Revert.
- `-Ascii`: uses only ASCII characters on screen, if your console shows boxes instead of `✓ ─ ╭`. Not needed in Windows Terminal (the Windows 11 default).

Full help: `Get-Help .\NetTune.ps1 -Full`.

During Apply, the connection drops for a few seconds while the adapters restart.

**Restart the PC after Apply (and after Revert).** The "allow the computer to turn off this device" option only changes after a restart, so the script's "after" test does not include it yet. The script tells you at the end when a restart is needed.

### How power management works

`Set-NetAdapterPowerManagement` has no parameter for this option, so the script writes to the registry directly. It is the same as unticking the box in Device Manager:

- Key: `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\00XX`, the subkey whose `NetCfgInstanceId` is the adapter's GUID.
- Value: `PnPCapabilities` (DWORD) = `24`.
- The backup stores the old value, or that it was not set. Revert restores that value or deletes the entry.

## Reading the screen

**Current state.** Each adapter is shown with its options:

- Green `✓`: already optimized.
- Yellow `!`: Apply will change this (the new value appears after the `→`).

In Test mode, the summary at the end says how many tweaks are left.

**Connection test.** Measures the **router**, **Cloudflare** and **Google**, plus one server per game service (see below). Rows appear as each target finishes, with a progress bar. Each value is colored **green** (good), **yellow** (fair) or **red** (bad). The *Status* column gives the row's verdict: the worst of its values.

| Column | What it is | Green | Yellow |
|---|---|---|---|
| Server | The region measured. For games, the one closest to you, picked automatically | | |
| Avg | Average ping | Router ≤ 5 ms · Cloudflare/Google ≤ 40 · games ≤ 60 | Router ≤ 15 · ≤ 80 · ≤ 100 |
| Max | Worst ping | Up to 30 ms above the minimum | Up to 100 ms above |
| Jitter | How much the ping varies from one packet to the next | ≤ 5 ms | ≤ 15 ms |
| Spikes | Pings 100 ms or more above the minimum | 0 | 1-2 |
| Loss | Lost packets | 0% | ≤ 2% |

With few pings (for example `-Count 5`), a single lost packet is already 20% and the row turns red. For a proper diagnosis use the default of 50.

**Before vs after** (in Apply). Shows the average, jitter and loss with a green `▼` when it improved, a red `▲` when it got worse and `=` when it stayed the same.

**The golden rule:** if the ping to the **router** is high or has spikes, the problem is your PC or the Wi-Fi, not your ISP or the game. The router is right next to you; 1-5 ms is normal.

## DNS test

By default (`-Dns Auto`), Test and Apply modes test **Cloudflare**, **Google**, **Quad9** and **OpenDNS**, and also show the DNS you are using as a reference. The current DNS is the one of the adapter actually carrying traffic to the internet, the route Windows itself picks; a disconnected adapter with an old route does not count.

- **How it measures:** the script sends DNS queries straight to each server (UDP, port 53), bypassing the Windows cache. 10 domains you use while gaming (Epic, Steam, Battle.net, Ubisoft, Xbox, Discord, Twitch...) × 3 rounds, plus 5 random names that force the server to ask the domain itself. Servers are interleaved, so they all get the same network conditions.
- **Columns:** *Median* is the usual response time (cached), *Uncached* is the first time a name is requested, *Fails* are the queries with no answer. The chosen one gets a `★`.
- **The router does not count.** If your DNS is the router (for example `192.168.1.254`) or another local network IP, it only forwards to your ISP's DNS. It answers in ~1 ms because it caches on the local network, but that is not comparable with a real DNS. It appears in the table only as a reference ("local cache, ignored").
- **How it chooses:** score = 70% median + 30% uncached, only among public DNS servers with up to 10% failures. Differences up to **5 ms (or 20%)** count as a tie, because the same server varies that much between runs. On a tie it prefers **Cloudflare**, then Google (Quad9 and OpenDNS filter domains).
- **When it switches:** if your DNS is the router or your ISP's, it switches to the chosen one. If you already use a public DNS, it only switches if the other one is better by more than the tie margin.
- **How it applies:** on each adapter, **IPv4 and IPv6 separately**, set by hand (`netsh`, by adapter index). Then it reads each family back and only shows `✓` if it was really applied. If IPv6 is disabled on the adapter, it only sets IPv4.
- **Backup and Revert:** the old DNS of each family is stored in the backup. Revert restores each one (the old static list, or automatic/DHCP if there was none).
- **Networks that block external DNS** (schools, offices, some public networks): the public DNS servers show up as "no response" and the script **changes nothing**, because changing would cut your internet. With `-Dns Cloudflare` (forced), the script first checks that DNS answers. If it does not, it refuses.
- **Honesty:** DNS only speeds up opening sites and connecting to services (login, stores, matchmaking). **It does not change in-game ping.**

Options: `-Dns Auto` (default), `-Dns Keep` (does not test or touch DNS), `-Dns Cloudflare | Google | Quad9 | OpenDNS` (forces that one, after checking it answers).

## Game servers

For each service, the script first runs a quick test on every region (in parallel), keeps the one closest to you and only then measures it properly. In Apply, the "after" test uses the same servers as "before", so the comparison is fair.

| Service | What is measured | Regions | How close to the real game |
|---|---|---|---|
| **Epic Games** | Official Fortnite ping beacons | France, Germany, United Kingdom, US (East, Central, West), Brazil | The game's own ping servers |
| **Valve / Steam** | Valve SDR relays (CS2, Dota 2, Deadlock…). The list comes live from the Steam API, with a built-in fallback list | Every Valve datacenter worldwide | Game traffic goes through these relays |
| **Blizzard** | Battle.net servers | Europe, US, Korea | Blizzard infrastructure (on Google Cloud) |
| **Ubisoft** | Azure regions used by Rainbow Six, plus AWS (GameLift) | Azure Ireland, Netherlands, US ×4, Brazil · AWS Frankfurt, US East | The datacenters where the servers run, not the server itself |
| **Microsoft / Xbox** | Azure regions | 15 regions, from Europe to Asia and Australia | The datacenters, not the server itself |
| **Embark** | The Finals / Arc Raiders run on Google Cloud, but Embark has no public ping endpoints. The Google Cloud region is measured instead | Google Cloud Netherlands, US, Korea | Rough reference |

Notes:

- **`tcp` in the Server column:** Azure blocks ping, so on those servers the TCP connect time (port 443) is measured. A TCP handshake takes almost exactly one round trip, so the numbers are comparable with ping.
- **It is a reference, not the exact in-game ping.** In-game ping depends on the specific match server. But if the closest region already shows spikes or loss here, the game will too.
- **Riot (Valorant, LoL)** is left out: their public ping IPs no longer respond.
- For another game, add its server IP with `-ExtraTargets`.

## Files

- `backups/backup-<date>.json`: the original state of every changed option (including each adapter's old `PnPCapabilities` and the Wi-Fi power plan).
- `logs/nettune-<mode>-<date>.log`: the full log of every run.

Both folders are in `.gitignore`, because they are specific to each PC.

## Notes

- An adapter driver update (Windows Update or Lenovo Vantage, for example) can restore the factory values. If the spikes come back, run `-Mode Apply` again.
- If you get an execution policy error, always use `powershell -ExecutionPolicy Bypass -File ...` as in the examples.
- Built for PowerShell 5.1 (the one that ships with Windows). It also runs on PowerShell 7.

## License

MIT
