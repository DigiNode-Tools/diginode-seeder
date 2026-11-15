# DigiNode Seeder

Run a DNS seeder for DigiByte on your own server, with one command.

A DNS seeder helps new DigiByte nodes find the network. When a node starts for the first time, it asks the seeders built into DigiByte Core for the addresses of other nodes. A seeder constantly checks the network and hands out nodes that are up and on the right chain.

DigiNode Seeder sets up a **mainnet** seeder, a **testnet** seeder (DigiByte Core v9, testnet26), or both on the same server, with only one IP address.

It's part of [DigiNode Tools](https://diginode.tools). Guide: [DigiNode Seeder on diginode.tools](https://diginode.tools/diginode-seeder/). Prefer to set one up by hand? See the [manual setup guide](https://diginode.tools/diginode-seeder/manual/).

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

Then it builds the seeder, starts everything, waits until the seeders find nodes, and shows the DNS records to add. Add them, press Enter, and it checks them for you, saying what's wrong if anything is:

```
dnsseed.example.com       A     203.0.113.10
dnsseed.example.com       AAAA  2001:db8::10        (if the server has IPv6)
seed.example.com          NS    dnsseed.example.com
testnetseed.example.com   NS    dnsseed.example.com
```

On Cloudflare, set the nameserver's records to **DNS only** (grey cloud). Once the records are live, `dig seed.example.com` should return a list of node addresses.

## After setup: the `diginode-seeder` command

The setup installs a `diginode-seeder` command on the server:

```bash
diginode-seeder                    # how the seeders are doing, and how to get them into DigiByte Core
diginode-seeder --dns              # check your DNS records, and explain anything that's wrong
diginode-seeder --ai-prompt        # a ready-made prompt for an AI agent to add your seed to DigiByte Core
diginode-seeder --update           # update DigiNode Seeder and the seeders (keeps your settings)
diginode-seeder --reconfigure      # change names or seeders
diginode-seeder --uninstall        # stop and remove
diginode-seeder --help             # all options
```

Updating, changing and removing need administrator rights: if you aren't logged in as root, the command asks for your password (sudo) by itself. Updating only restarts what changed. Running the setup command again also updates.

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

## The last step: get your seeder into DigiByte Core

Your seeder only helps once DigiByte Core lists it. Nodes ask only the seeds written into their own code, in [`src/kernel/chainparams.cpp`](https://github.com/DigiByte-Core/digibyte/blob/develop/src/kernel/chainparams.cpp). To be added, you open a pull request (PR) that adds one line, and the DigiByte Core developers review it. Once it's merged, it goes out with the next release, and nodes start using your seeder as they update.

The network only needs a handful of seeders, so it's best if each person runs no more than one mainnet and one testnet seeder.

### Before you ask

- **Let it run for a couple of weeks** and check now and then that it's still answering. The developers want seeds that stay up.
- **Check it from the internet**, from any computer:
  ```bash
  dig +short seed.example.com        # a list of node addresses
  dig +short x9.seed.example.com     # the same, for the filtered form nodes ask first
  ```
  On the server, `diginode-seeder` shows the same, and once your seed works it shows the exact line to add.
- **Have a GitHub account.** The line you add includes your name and GitHub handle, so the developers can reach you if your seeder ever has a problem.

### Make the pull request on GitHub's website

No need to install anything:

1. Sign in to GitHub and open [`src/kernel/chainparams.cpp` on the `develop` branch](https://github.com/DigiByte-Core/digibyte/blob/develop/src/kernel/chainparams.cpp).
2. Click the **pencil** (Edit this file). GitHub makes your own copy (a fork) of DigiByte Core.
3. Find the right list and add your line at the end of it:
   - for **mainnet**, the list under `// DigiByte MAINNET DNS Seed Server:`
   - for **testnet**, the list under `// DigiByte TESTNET DNS Seed Servers:`

   ```cpp
   vSeeds.emplace_back("seed.example.com"); // Your Name @your-github-handle
   ```
   Copy the lines above it exactly, with the same spacing and a semicolon at the end. Change nothing else.
4. Click **Commit changes…**. As the commit message, write something like `net: Add seed.example.com DNS seed`. DigiByte's rules say commit messages must not contain `@` mentions, so leave your handle out of it: it's only in the line of code. Choose **Create a new branch for this commit and start a pull request**, then **Propose changes**.
5. Check that the pull request goes **into `DigiByte-Core/digibyte`, branch `develop`**. Give it a title starting with `net:`, such as `net: Add seed.example.com DNS seed`, and a short description, for example:
   > Adds seed.example.com as a mainnet DNS seed, run by Your Name. It has been running since 1 March on its own server (set up with DigiNode Seeder) and returns about 25 nodes, for both plain and x9. queries. I'll keep it running, and I'm happy to be contacted if it ever has a problem.
6. Click **Create pull request** and follow any comments from the reviewers.

Running both seeders? Add both lines in the same pull request.

### Or from the terminal (git and the GitHub CLI)

For anyone comfortable with `git`. You need [`gh`](https://cli.github.com) signed in (`gh auth login`).

```bash
# 1. Check your seed(s) answer from the internet
dig +short seed.example.com
dig +short x9.seed.example.com

# 2. Fork DigiByte Core and clone just the develop branch
gh repo fork DigiByte-Core/digibyte --clone=false
git clone --branch develop --single-branch --depth 50 \
  https://github.com/<your-github-handle>/digibyte.git
cd digibyte
git remote add upstream https://github.com/DigiByte-Core/digibyte.git
git fetch upstream develop
git switch -c add-seed-example upstream/develop

# 3. Add your line at the end of the mainnet (or testnet) list, matching the lines above it
#      vSeeds.emplace_back("seed.example.com"); // Your Name @your-github-handle
grep -n 'vSeeds.emplace_back' src/kernel/chainparams.cpp     # find the lists
nano src/kernel/chainparams.cpp
git diff                                                      # one added line per seed, nothing else

# 4. Commit (no @ mentions in the message) and push to your fork
git commit -am "net: Add seed.example.com DNS seed"
git push -u origin add-seed-example

# 5. Open the pull request against develop
gh pr create --repo DigiByte-Core/digibyte --base develop \
  --title "net: Add seed.example.com DNS seed" \
  --body "Adds seed.example.com as a mainnet DNS seed, run by Your Name. Running since 1 March on its own server (set up with DigiNode Seeder); returns about 25 nodes for both plain and x9. queries. Happy to be contacted if it ever has a problem."
```

### Or let an AI agent do it

If you use an AI coding agent that can run commands and use GitHub (for example [Claude Code](https://claude.com/claude-code) with the GitHub CLI `gh` signed in), run `diginode-seeder --ai-prompt` on your server: it asks your name and GitHub handle and prints this prompt with everything filled in. Or paste it in yourself, with your details. It checks your seeder first, prepares the pull request, and shows it to you before anything is published:

```text
I run a DigiByte DNS seeder and want it added to DigiByte Core. Please prepare a pull request.

My details:
- Mainnet seed name: seed.example.com   (leave blank if none)
- Testnet seed name: testnetseed.example.com   (leave blank if none)
- My name as it should appear: Your Name
- My GitHub handle: your-github-handle
- Running since: 1 March 2027

Steps:
1. Check each seed name answers from the internet: `dig +short <name>` and
   `dig +short x9.<name>` should each return several IP addresses. Stop and
   tell me if either returns nothing.
2. Fork DigiByte-Core/digibyte with `gh` (if I don't already have a fork) and
   create a branch from the latest `develop`.
3. In src/kernel/chainparams.cpp, add one line at the end of the right list,
   copying the format of the lines above it exactly:
   - mainnet: the list under "// DigiByte MAINNET DNS Seed Server:"
   - testnet: the list under "// DigiByte TESTNET DNS Seed Servers:"
   vSeeds.emplace_back("<seed name>"); // <My name> @<my GitHub handle>
   Change nothing else in the file.
4. Commit with a message like "net: Add <seed name> DNS seed". The commit
   message must not contain any @ mentions (DigiByte's contribution rules).
5. Show me the diff, the PR title and the PR description, and wait for my OK.
   The title starts with "net:". The description says which seed(s) it adds,
   who runs them, since when, and that they answer plain and x9. queries
   (include the number of addresses each returned).
6. Only after I say yes: push the branch and open the pull request against
   DigiByte-Core/digibyte, base branch `develop`. Give me the link.
```

### After it's merged

Keep your seeder running and updated (run the setup command again now and then). If you ever need to stop it, open another pull request to remove your line, so nodes don't keep asking a seed that has gone.

## Licence

DigiNode Seeder is licensed under the [PolyForm Perimeter License 1.0.0](LICENCE.md). The seeder it builds keeps its own licence terms.
