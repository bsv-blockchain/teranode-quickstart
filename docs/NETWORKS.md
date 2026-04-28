# Networks

Per-network values written by `setup.sh` into `.env`:

| Network     | minminingtxfee     | blockmaxsize | excessiveblocksize |
|-------------|--------------------|--------------|---------------------|
| mainnet     | 0.00000100 (100 sat/kb) | 4 GiB    | 10 GiB              |
| testnet     | 0.00000001 (1 sat/kb)   | 4 GiB    | 10 GiB              |
| regtest     | 0                       | 4 GiB    | 10 GiB              |
| teratestnet | 0.00000001 (1 sat/kb)   | 1 GiB    | 1 GiB (capped)      |

`p2p_dht_mode = off` for all networks (see README § DHT mode).

## mainnet

Real BSV mainnet. **Still maturing in Teranode** — not yet production-validated upstream. `setup.sh` requires an `I understand` confirmation.

- **Budget 256 GB RAM, 2 TB+ SSD, 16+ cores.** 128 GB is the floor; below that you OOM during sync.
- Full mode is the point — listen-only mainnet is mostly a curiosity. Set `listen_mode=full` and add `p2p` to `COMPOSE_PROFILES`.

## testnet

Standard BSV testnet. Good for realistic integration testing.

- 32 GB RAM recommended (16 GB minimum), 300 GB SSD, 8+ cores.
- Distinct from **teratestnet** (below).

## teratestnet

Shared Teranode test network run by the BSV Association. A published UTXO snapshot makes it the fastest way to get a working node up for testing without syncing the real chain.

- 32 GB RAM recommended, 100 GB SSD, 8+ cores.
- Block sizes capped at 1 GiB so the shared network stays approachable.
- No DNS seeder — bootstrap via `legacy_config_ConnectPeers=57.130.17.176:38333` (see `.env.example`).
- Canonical snapshot:
  `https://svnode-snapshots.bsvb.tech/teratestnet/000000002ea94a515ad9fd40d710fd249fe8610acef7b74f459446812d565187.zip`
  Seed with: `./seed.sh 000000002ea94a515ad9fd40d710fd249fe8610acef7b74f459446812d565187`

## regtest

Local-only, no external peers. Generate blocks on demand with `./rpc.sh generate N`.

- 8 GB RAM (4 GB minimum), 20 GB disk, 4+ cores.

## Switching networks

Data volumes are network-specific — wipe before switching:

```bash
./stop.sh
./clean.sh --data-only
./setup.sh
./start.sh
```
