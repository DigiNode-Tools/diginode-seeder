# DigiNode Seeder

Run a DNS seeder for DigiByte on your own server, with one command.

A DNS seeder helps new DigiByte nodes find the network. When a node starts for the first time, it asks the seeders built into DigiByte Core for the addresses of other nodes. A seeder constantly checks the network and hands out nodes that are up and on the right chain.

DigiNode Seeder sets up a **mainnet** seeder, a **testnet** seeder (DigiByte Core v9, testnet26), or both on the same server, with only one IP address.

It's part of [DigiNode Tools](https://diginode.tools). Guide: [Running a DigiByte Seeder](https://diginode.tools/running-a-digibyte-seeder/).

## What you need

- A server (VPS) with its own public IP address, running **Debian 12 or 13**, or **Ubuntu 22.04 or 24.04**. 1 GB of memory is plenty.
- **UDP port 53** open to the internet. Check your server provider's firewall too.
- A domain you control, where you can add DNS records.
- Nothing else using port 53 on the server.

## Set up

Log in to your server with SSH and run:

```bash
curl -sSL https://seedsetup.diginode.tools | sudo bash
```

It asks which seeders to run and what to call them:

- **Seed names**, such as `seed.example.com` (mainnet) and `testnetseed.example.com` (testnet).
- **A nameserver name** for the server, such as `dnsseed.example.com`.
- **A contact email**, shown in the seeds' DNS records.

Then it builds the seeder, starts everything, waits until the seeders find nodes, and shows the DNS records to add:

```
dnsseed.example.com       A     203.0.113.10
dnsseed.example.com       AAAA  2001:db8::10        (if the server has IPv6)
seed.example.com          NS    dnsseed.example.com
testnetseed.example.com   NS    dnsseed.example.com
```

On Cloudflare, set the nameserver's records to **DNS only** (grey cloud). Once the records are live, `dig seed.example.com` should return a list of node addresses.

## Update, check, remove

Run the same command again at any time. It keeps your settings, updates the seeder, and only restarts what changed.

```bash
curl -sSL https://seedsetup.diginode.tools | sudo bash -s -- --status        # is everything working?
curl -sSL https://seedsetup.diginode.tools | sudo bash -s -- --reconfigure   # change names or seeders
curl -sSL https://seedsetup.diginode.tools | sudo bash -s -- --uninstall     # stop and remove
```

For automation, every answer can be given as an option:

```bash
curl -sSL https://seedsetup.diginode.tools | sudo bash -s -- --yes \
  --mainnet seed.example.com --testnet testnetseed.example.com \
  --ns dnsseed.example.com --email you@example.com
```

## How it works

```
                        port 53                      local only
Internet ──DNS──▶  dnsdist ──seed.example.com────────▶ mainnet seeder (127.0.0.1:5301)
                     │    └─testnetseed.example.com──▶ testnet seeder (127.0.0.1:5302)
                     └── any other name: refused
```

- **One IP, several seeders.** Each seeder needs to answer DNS on port 53, and only one program can use a port. [dnsdist](https://dnsdist.org) answers on port 53 and passes each seed name to its own seeder. Everything else is refused, so the server can't be used as an open DNS server, and each address is rate-limited. Seeders only answer over UDP (their answers always fit), so questions over TCP are refused.
- **The seeder** is [DigiNode-Tools/digibyte-seeder](https://github.com/DigiNode-Tools/digibyte-seeder), DigiByte's seeder with DigiByte Core v9 testnet support and options for future network changes. It's built from source on your server.
- **Each seeder is a locked-down systemd service** (`diginode-seeder@digibyte-mainnet`, `diginode-seeder@digibyte-testnet`) running as its own user. It starts at boot and restarts if it stops. Its crawl data stays between restarts.
- Seeders answer both plain (`seed.example.com`) and filtered (`x9.seed.example.com`) queries. DigiByte Core asks for the filtered form first.

| Where | What |
|---|---|
| `/etc/diginode-seeder/` | Your settings and one `.conf` per seeder |
| `/opt/diginode-seeder/` | The seeder's source and program |
| `/var/lib/diginode-seeder/` | Each seeder's crawl data |
| `/etc/dnsdist/dnsdist.conf` | Written by the setup (an existing one is backed up first) |

Logs: `journalctl -u diginode-seeder@digibyte-mainnet`.

## Getting your seeder into DigiByte Core

Nodes only ask the seeders listed in DigiByte Core's `src/kernel/chainparams.cpp`. Once your seeder has run reliably for a while, you can ask for it to be added: see the [DigiByte Core repository](https://github.com/DigiByte-Core/digibyte). The network only needs a handful of seeders, and it's best if each person runs no more than one mainnet and one testnet seeder.

## Licence

DigiNode Seeder is licensed under the [PolyForm Perimeter License 1.0.0](LICENCE.md). The seeder it builds keeps its own licence terms.
