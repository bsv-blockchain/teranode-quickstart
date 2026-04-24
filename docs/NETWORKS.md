# Networks

## mainnet

Real BSV mainnet. **Still maturing in Teranode** — not yet production-validated upstream. `setup.sh` requires an `I understand` confirmation.

- `minminingtxfee = 0.00000100` BSV/KB (mainnet fee floor).
- `p2p_dht_mode = off` (default for all networks — see README § DHT mode).
- Block size / peer defaults: inherited from upstream. Not overridden here.
- Budget 1.5 TB+ disk, 32 GB+ RAM.
- Full mode is the point — listen-only mainnet is mostly a curiosity.

## testnet

Standard BSV testnet. Good for realistic integration testing.

- ~300 GB disk, 16 GB+ RAM.
- Not the same as **teratestnet** (the Teranode team's shared training-wheels network, 1 GB block cap). For teratestnet specifically, use [teranode-teratestnet](https://github.com/bsv-blockchain/teranode-teratestnet).

## regtest

Local-only, no external peers. Mine blocks on demand with `./cli.sh generate N`.

- ~20 GB disk, 8 GB RAM.

## Switching networks

Data volumes are network-specific — wipe before switching:

```bash
./stop.sh
./clean.sh --data-only
./setup.sh
./start.sh
```
