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
- Not the same as **teratestnet** (the Teranode team's shared training-wheels network, 1 GB block cap). For teratestnet specifically, use [teranode-teratestnet](https://github.com/bsv-blockchain/teranode-teratestnet).

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
