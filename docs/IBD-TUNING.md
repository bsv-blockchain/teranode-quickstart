# IBD tuning — surviving Aerospike DEVICE_OVERLOAD and big-block eras

During initial block download (IBD) on mainnet/testnet, certain block eras
generate write bursts that overwhelm the local Aerospike's storage device.
This shows up as:

```text
ERROR | utxo/aerospike/spend.go | Failed to handle extra records: STORAGE_ERROR (69):
  error in aerospike increment batch records -> ... ResultCode: DEVICE_OVERLOAD ...
```

and, downstream of it, blocks that appear "stuck" for a long time while the
legacy service burns CPU. This doc explains why it happens and which knobs to
turn, in order.

All `.env` keys below are passed straight into the Teranode containers
(`env_file: .env`), so add them to `.env` and `docker compose up -d` —
datastores are not touched.

## Why it happens

- **Write amplification on big-output transactions.** Transactions with more
  than ~20,000 outputs are stored as a master record plus pagination ("child")
  records. Every spend of such an output increments a counter on its
  pagination record — a read-modify-write of a fat record. Eras full of
  consolidation / data transactions (mainnet ~755k, ~811k–830k; testnet
  stress eras) multiply this.
- **Default concurrency is sized for clustered Aerospike.** The quickstart
  runs a single Aerospike node on one (often partitioned) NVMe. Teranode's
  defaults allow 64 concurrent in-flight batch calls *per batcher type*
  (spend, store, increment, setDAH, outpoint, ...) — the aggregate can exceed
  what one device flushes, the write queue overflows past `max-write-cache`,
  and Aerospike answers `DEVICE_OVERLOAD`.
- Teranode treats `DEVICE_OVERLOAD` as retryable and retries with backoff, so
  occasional overloads are survivable — sustained overloads stall block
  processing.

## Teranode knobs (`.env`), in order of impact

```bash
# 1. Master throttle: concurrent in-flight batch sends PER batcher type
#    (spend/store/increment/setDAH/outpoint/locked/get). Default 64.
#    This is the knob that actually shapes device pressure.
utxostore_batcherMaxConcurrent=8

# 2. Spend batch payload (default 1024). Smaller batches = smoother bursts.
utxostore_spendBatcherSize=128

# 3. Increment batching for >20k-output pagination records (default 256).
#    Bigger batch = fewer round-trips; the setting's own docs prescribe
#    512-1024 for catchup through large-transaction eras.
utxostore_incrementBatcherSize=1024

# 4. Legacy-service fan-out. These multiply into errgroup limits:
#    - tx validation concurrency = legacy_spendBatcherSize x legacy_spendBatcherConcurrency
#      (default 1024 x 4 = 4096 concurrent validates)
#    - utxo creation concurrency = legacy_storeBatcherSize x legacy_storeBatcherConcurrency
#      (default 1024 x 32 = 32768 concurrent creates)
legacy_spendBatcherConcurrency=1
legacy_storeBatcherConcurrency=4
```

Notes:

- `utxostore_spendBatcherConcurrency` does **not** throttle the Aerospike
  spend path (it is consumed by blockvalidation/SQL paths) — setting it is
  harmless but won't fix overloads. `utxostore_batcherMaxConcurrent` is the
  real send-side limit.
- These throttles trade per-block speed for stability. A block that validates
  slightly slower beats one that fails into retry loops: with a clustered /
  faster storage backend, revert to defaults.

## Aerospike knobs

The quickstart ships `aerospike-tune.sh` for live (no-restart) tuning:

- **`max-write-cache`** — the write-burst absorber. `config/aerospike.conf`
  ships 2048M steady-state, and `aerospike-tune.sh catchup` raises it to 8192M;
  if overloads persist after the Teranode throttles above, double it again (RAM
  permitting). Dynamic:
  `set-config:context=namespace;id=utxo-store;max-write-cache=16G`.
- **Defrag mode** — catch-up defrag (`defrag-lwm-pct` raised, `defrag-sleep=0`)
  competes with client writes for device bandwidth. Only run it when
  `data_avail_pct` is actually dropping; with plenty of avail, steady-state
  defrag (`lwm 50`, `sleep 1000`) returns that bandwidth to spends. Check:
  `asinfo -v "namespace/utxo-store" | tr ';' '\n' | grep -E 'data_avail_pct|defrag_q'`.
- **Memory protection** — Aerospike stops accepting writes when *host* memory
  crosses `stop-writes-sys-memory-pct` (90%), regardless of its own usage.
  The per-service `MEM_LIMIT_*` caps (see `lib/mem_limits.sh`) exist to keep
  Teranode services from triggering this; don't remove them.

## Observing

```bash
# overload errors, last 30 min
docker logs --since 30m legacy 2>&1 | grep -c DEVICE_OVERLOAD

# write queue per device (non-zero = pressure building; sustained growth = overload imminent)
docker exec aerospike asinfo -v "namespace/utxo-store" | tr ';' '\n' | grep -E 'write_q|defrag_q'

# what legacy is doing per block (stage timings)
docker logs --since 10m legacy 2>&1 | grep -E 'HandleBlockDirect.*DONE|createUtxos.*DONE|PreValidateTransactions'
```

## Escalation order

1. Apply the `.env` block above, `docker compose up -d`.
2. Still overloading → `utxostore_batcherMaxConcurrent=4`.
3. Still → double `max-write-cache` (Aerospike side, dynamic).
4. Still → the device itself is the ceiling: move the UTXO namespace to a
   faster/additional NVMe (see the device comments in `config/aerospike.conf`),
   or accept slower IBD with `utxostore_spendBatcherSize=48`.
