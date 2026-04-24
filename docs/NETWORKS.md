# Networks

## mainnet

Real BSV mainnet. **Still maturing in Teranode** — not yet production-validated upstream. `setup.sh` requires an `I understand` confirmation.

- `minminingtxfee = 0.00000100` BSV/KB (mainnet fee floor).
- `p2p_dht_mode = off` (default for all networks — see README § DHT mode).
- Block size / peer defaults: inherited from upstream. Not overridden here.
- **Budget 256 GB RAM, 2 TB+ SSD, 16+ cores.** 128 GB is the floor; below that you OOM during sync.
- Full mode is the point — listen-only mainnet is mostly a curiosity.

## testnet

Standard BSV testnet. Good for realistic integration testing.

- 32 GB RAM recommended (16 GB minimum), 300 GB SSD, 8+ cores.
- Distinct from **teratestnet** (below).

## teratestnet

Shared Teranode training-wheels network run by the BSV Association. Lower block ceiling and a published UTXO snapshot make it the fastest way to get a working node for testing without syncing the real chain.

- `blockmaxsize = excessiveblocksize = 1 GB` (enforced smaller than real testnet so the shared network stays approachable).
- `minminingtxfee = 0`.
- 32 GB RAM recommended, 100 GB SSD, 8+ cores.
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
