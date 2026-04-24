# Teranode Quickstart

A Docker-based one-command setup for running a [Teranode](https://github.com/bsv-blockchain/teranode) full node on mainnet, testnet, or regtest.

---

## What you get

Running `./setup.sh && ./start.sh` stands up:

| Service                 | Purpose                                        | Port (host)          |
|-------------------------|------------------------------------------------|----------------------|
| Teranode microservices  | blockchain, asset, propagation, rpc, etc.      | various (see below)  |
| PostgreSQL 17           | Blockchain state & indexes                     | 127.0.0.1:5432       |
| Redpanda (Kafka)        | Inter-service event streaming                  | 127.0.0.1:9092       |
| Aerospike 8.1 (EE)      | UTXO store (1 TB, eval mode)                   | 127.0.0.1:3000       |
| Prometheus              | Metrics                                        | 127.0.0.1:9090       |
| Grafana                 | Dashboards (Teranode + Aerospike)              | http://localhost:3005 |
| Kafka Console           | Topic viewer with protobuf decoding            | http://localhost:8080 |
| Nginx asset cache       | Caching reverse proxy for asset API            | 127.0.0.1:8000       |

All services are internal by default. `HOST_IP` in `.env` controls binding for **only these 3 ports**:

| Port  | Service          | Why you might expose it                         |
|-------|------------------|-------------------------------------------------|
| 8090  | asset viewer UI  | browse the chain from another host              |
| 8000  | asset-cache      | full-mode: reverse proxy points here for API    |
| 9905  | P2P              | full-mode: inbound peer connections             |

Everything else — RPC (9292), Grafana (3005), Prometheus (9090), Kafka (9092/8080), Postgres (5432), Aerospike (3000), internal gRPC (8084) — is hardcoded to `127.0.0.1`. Changing `HOST_IP=0.0.0.0` does **not** expose those; edit the compose files if you really need to.

---

## Prerequisites

- Docker + Docker Compose v2 (Docker Desktop or a recent Linux install)
- A host with enough RAM, disk, and CPU for the chosen network:

| Network  | RAM (recommended) | RAM (minimum) | Disk    | CPU cores |
|----------|-------------------|---------------|---------|-----------|
| mainnet  | **256 GB**        | 128 GB        | 2 TB+   | 16+       |
| testnet  | 32 GB             | 16 GB         | 300 GB  | 8+        |
| regtest  | 8 GB              | 4 GB          | 20 GB   | 4+        |

Mainnet is memory-hungry: Aerospike holds the full UTXO set in memory and the Teranode microservices run in parallel, so 128 GB is the floor for sustained mainnet operation and 256 GB is what you actually want. Running below the recommended tier works but you'll trade sync speed, propagation latency, and headroom during block spikes.

SSD storage is strongly recommended everywhere — HDDs will bottleneck Aerospike and Postgres.

`./lib/check_requirements.sh` verifies these before setup.

## Pruning and archival

By default, Teranode prunes spent outputs from the UTXO store **after 288 blocks** (~48 hours). This is the recommended setting and keeps Aerospike's memory + disk footprint bounded. **Do not raise the pruning depth** unless you have a specific reason — every extra block you retain grows Aerospike proportionally, and mainnet's UTXO churn is high.

If you need the full historical block data (indexers, explorers, chain analysis), enable the optional **blockpersister** service by setting `ARCHIVAL=true` in `.env` before `./start.sh`. It writes raw block data to disk and runs in parallel with the pruner — pruning behaviour is unchanged, you just gain a durable archive.

Archival mode costs significant disk space (grows with chain size — budget multiple TB on mainnet). Most operators should leave `ARCHIVAL=false` and rely on the default 288-block pruning window.

---

## Quick start

```bash
git clone https://github.com/bsv-blockchain/teranode-quickstart.git
cd teranode-quickstart
./setup.sh       # interactive: pick network + mode, generate .env + settings
./start.sh       # docker compose up with the right profiles
./status.sh      # verify everything healthy
./rpc.sh getblockcount    # chain queries via JSON-RPC
./cli.sh getfsmstate      # teranode-cli for FSM / seeder / etc.
```

To stop: `./stop.sh`. To tail logs: `./logs.sh blockchain`. To upgrade Teranode: `./update.sh`.

---

## How it's wired

**`.env` is the single source of truth for your install.** It is git-ignored, so `git pull` never creates merge conflicts on your customisations. `.env.example` (committed) shows the defaults.

Everything user-facing lives in `.env`:
- `TERANODE_VERSION` — image tag, bumped by `./update.sh`
- `TERANODE_NETWORK` — `mainnet`, `testnet`, or `regtest`
- `HOST_IP` — bind address for externally-exposed ports
- `ASSET_PUBLIC_URL`, `P2P_ADVERTISE_ADDR` — only needed for full mode
- `RPC_USER`, `RPC_PASS` — generated by `setup.sh`
- `CLIENT_NAME` — identity shown in explorer

**Per-network overrides** live in `compose/networks/<network>.env`. `start.sh` layers them on with `--env-file`, so network-specific knobs (e.g. `p2p_dht_mode=server` on mainnet) don't pollute your `.env`.

**Teranode settings are set directly as environment variables** on the Teranode containers (no mounted conf file). Keys like `clientName`, `listen_mode`, `rpc_user`, `asset_httpPublicAddress`, etc. are wired up in `docker-compose.yml` under `x-teranode-settings` and read from `.env`. `SETTINGS_CONTEXT=docker.m` picks up upstream defaults from the image's built-in `settings.conf`; env vars override them for the keys you care about.

---

## DHT mode

`p2p_dht_mode` defaults to **`off`** for all networks in this quickstart. Three modes exist:

- **`off`** — no DHT. Only connects to bootstrap + topic peers. Lightweight, no network scanning. Safe on abuse-sensitive hosts (Hetzner, OVH).
- **`client`** — queries the DHT but doesn't advertise. Still opens 100+ peer connections. Fine for dev boxes.
- **`server`** — full DHT participation: advertises, stores records, routes queries. Needed only if you're operating as a bootstrap/relay node and have configured `p2p_advertise_addresses` with a public reachable address.

Only switch to `server` if you know what you're doing. Most operators should leave this alone.

> **Warning:** `server` mode probes 100+ peers to build its routing table. Some providers (Hetzner, OVH, and similar abuse-sensitive hosts) flag this as port scanning and may issue abuse reports or suspend your server. Use `off` or `client` on those networks unless you've cleared it with the provider.

## Listen-only vs full mode

**Listen-only** is the default. Your node receives blocks and transactions from peers but doesn't serve the asset API or accept inbound P2P. No public exposure needed — works behind NAT, no firewall tweaks, no reverse proxy. Good for operators who just want an up-to-date local view of the chain.

**Full mode** is required if you want your node to participate in propagation or be discoverable by other nodes. You must:

1. Own a public endpoint (domain + TLS) that proxies to this host's port 8000 (asset cache) and can accept inbound TCP on port 9905 (P2P).
2. Configure the reverse proxy / firewall yourself. This repo is opinion-free on how — use Caddy, Cloudflare Tunnel, nginx + Let's Encrypt, a VPS with a domain, whatever fits your infrastructure.
3. Provide the resulting `ASSET_PUBLIC_URL` and `P2P_ADVERTISE_ADDR` to `setup.sh`.

After `start.sh` brings the stack up, `lib/reachability.sh` probes the declared endpoints from a throwaway container and reports pass/fail. It's a diagnostic, not a gate — you can ignore it if you know better.

> **No tunnel helpers shipped.** This quickstart does not bundle ngrok or similar. Bring your own reverse proxy / public endpoint.

---

## Commands

| Script           | Purpose                                                     |
|------------------|-------------------------------------------------------------|
| `./setup.sh`     | Interactive first-time config. Writes `.env`.               |
| `./start.sh`     | Bring the stack up for the configured network.              |
| `./stop.sh`      | Graceful shutdown (FSM → IDLE, then `docker compose down`). |
| `./restart.sh`   | stop → start.                                               |
| `./update.sh`    | Check GitHub for a newer Teranode release; bump `.env`; pull; restart. See below. |
| `./cli.sh …`     | Run `teranode-cli` inside the blockchain container (FSM state, seeder, admin). Ex: `./cli.sh getfsmstate` |
| `./rpc.sh …`     | Call JSON-RPC at localhost:9292 (chain queries, TX submission). Ex: `./rpc.sh getblockcount` |
| `./seed.sh`      | Seed UTXO state from a snapshot ZIP. Takes URL + block hash (or reads `SEED_URL` / `SEED_HASH` from `.env`). |
| `./status.sh`    | `docker compose ps` + FSM state + block count.              |
| `./logs.sh [svc]`| Tail logs for a service or all services.                    |
| `./clean.sh`     | Remove volumes / config. See flags with `./clean.sh --help`.|

---

## Updating

```bash
./update.sh --check          # dry-run: show current vs latest
./update.sh                  # interactive update
./update.sh --yes            # non-interactive (same as above + auto-confirm)
./update.sh --to v0.14.2     # pin to a specific tag (rollback)
```

The update flow:

1. Reads `TERANODE_VERSION` from `.env`.
2. Calls `https://api.github.com/repos/bsv-blockchain/teranode/releases/latest`.
3. Prints diff + release URL + first 20 lines of release notes.
4. On confirm, writes the new tag back to `.env` (git-ignored → no tracked-file diff).
5. `docker compose pull` + `docker compose up -d` recreates only containers whose image tag changed.
6. Re-enters `RUNNING` FSM state.

Because the version pin lives only in `.env` (and `.env` is git-ignored), `git pull` on this repo will never conflict with your local version choice. The committed `.env.example` tracks the maintainer-recommended default for new installs.

---

## Switching networks

Different networks can't share UTXO state. To switch:

```bash
./stop.sh
./clean.sh --data-only
./setup.sh   # pick the new network
./start.sh
```

---

## File layout

```
teranode-quickstart/
├── setup.sh, start.sh, stop.sh, restart.sh, cli.sh, rpc.sh, logs.sh, status.sh, clean.sh, update.sh, seed.sh
├── .env.example                   # committed template; copy to .env
├── docker-compose.yml             # root compose, uses ${TERANODE_VERSION} from .env
├── compose/
│   ├── docker-teranode.yml        # Teranode microservice definitions
│   ├── docker-services.yml        # postgres, kafka, aerospike, monitoring, asset-cache
│   └── networks/{mainnet,testnet,regtest}.env
├── config/
│   ├── aerospike.conf / aerospike-ee.conf / aerospike-asmt-wrapper.sh
│   ├── prometheus.yml / grafana_datasource.yaml / grafana_dashboards/
│   ├── kafka-console-config.yml / protos/
│   ├── asset-cache-nginx.conf
│   └── entrypoint.sh / wait.sh
├── lib/
│   ├── colors.sh                  # shell UI helpers
│   ├── check_requirements.sh      # Docker/Compose/RAM/disk/ports preflight
│   ├── github_release.sh          # GitHub Releases API helpers
│   ├── env_writer.sh              # idempotent KEY=VALUE upsert
│   ├── fsm.sh                     # FSM state management
│   └── reachability.sh            # post-start public-URL + P2P probe
└── docs/
    ├── NETWORKS.md                # per-network notes & caveats
    └── UPDATING.md                # detailed update flow
```

---

## RPC access

The RPC service binds to `127.0.0.1:9292` (never exposed externally by this repo). Credentials come from `.env`:

```bash
curl -u "$RPC_USER:$RPC_PASS" -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"1.0","id":"x","method":"getblockchaininfo","params":[]}' \
    http://127.0.0.1:9292/
```

For remote RPC access: put an authenticated reverse proxy in front of 9292 on another host and point it at this host's RPC port. RPC is **not** controlled by `HOST_IP` — it stays on `127.0.0.1:9292` no matter what. To change that, edit `compose/docker-teranode.yml` directly, and do so only with a trusted auth layer in front.

---

## Troubleshooting

- **`docker compose` fails with "services.blockchain refers to undefined volume teranode-data"** — you ran `docker compose` without this repo's root `docker-compose.yml`. Make sure you're in the repo root when invoking `start.sh`.
- **FSM stuck in `INIT`** — `./cli.sh setfsmstate --fsmstate RUNNING` manually. `start.sh` tries this after health checks but it can race.
- **Aerospike fails with "memory limit"** — you're on Community Edition with a large UTXO set. Switch to `AEROSPIKE_SERVICE=aerospike-ee` in `.env`.
- **Grafana shows "No data"** — Prometheus needs ~1 minute to scrape the first datapoints. If still empty, check `http://localhost:9090/targets`.
- **Port X already in use** — another process holds the port. `lsof -i :X` to find it. Edit `HOST_IP` or remap in `docker-compose.yml`.
- **Mainnet sync stuck** — mainnet Teranode is still maturing. Expect rough edges. Check the [upstream release notes](https://github.com/bsv-blockchain/teranode/releases).

For anything that smells like a Teranode bug (not a quickstart bug): open an issue at [bsv-blockchain/teranode](https://github.com/bsv-blockchain/teranode/issues).

---

## Disclaimer

Teranode is under active development. Mainnet support is not yet production-validated by the upstream project — `setup.sh` prompts for explicit confirmation before writing a mainnet config. Run mainnet nodes at your own risk. See [docs/NETWORKS.md](docs/NETWORKS.md).

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
