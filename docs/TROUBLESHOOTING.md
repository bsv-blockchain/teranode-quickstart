# Troubleshooting

## Aerospike stops completing batch requests

**Status: open investigation.** The cause is not known. This section records the
symptoms, the recovery and what has been observed so far. It will change as the
investigation moves.

### Symptoms

On the Teranode side the node stops advancing:

- Block validation and catchup fail with
  `STORAGE_ERROR … error in aerospike map store batch records … MAX_RETRIES_EXCEEDED … command execution timed out on client`.
- Legacy parks the next block as a local fault on every retry.

On the Aerospike side, batch processing has stopped while requests keep arriving:

- `batch_index_complete` does not move, and neither do the errors or timeouts
  in the ticker's `batch-index: batches (…)` line.
- `batch_index_queue` shows requests waiting on every queue. The format is
  `requests:buffers` per queue, for example `201:0`.
- `batch_index_unused_buffers` is 0.
- `process_cpu_pct` is 0.
- `client_connections` keeps climbing (seen at about 20 per minute), far above
  the number of sockets the kernel actually holds open on port 3000.

`./status.sh` checks for the stall. When requests are queued and no response
buffers are free, it samples `batch_index_complete` twice, 5 s apart, and warns
if nothing completed. To check by hand:

```bash
docker exec aerospike asinfo -v statistics | tr ';' '\n' \
  | grep -E '^(batch_index_(complete|queue|unused_buffers|delay|error)|process_cpu_pct|client_connections)='
```

Run it twice a few seconds apart and compare `batch_index_complete`.

### Recovery

```bash
docker restart aerospike
```

Data persists on the Aerospike data volume. Startup takes a minute or more
because Community Edition rebuilds its index from the device. After that,
batches complete again.

Restarting the Teranode service that reports the error does **not** clear the
stall.

### What to capture before restarting

If you can, save these before you restart and attach them to an issue:

```bash
docker exec aerospike asinfo -v statistics > aerospike-stats.txt
docker logs --since 30m aerospike > aerospike.log 2>&1
docker logs --since 30m pruner   > pruner.log 2>&1
```

### What has been observed

Two teratestnet nodes running this quickstart have stalled this way, one with
16 cores and one with 128.

- **Thread count is not the cause.** `batch-index-threads` defaults to the core
  count. The 16-core node ran 16 threads and the 128-core node 128, and both
  stalled the same way.
- **Both stalls followed a large prune.** Each started within about 90 s of a
  pruner phase 2 run that deleted 450,000–660,000 records in under 2 s. In the
  pruner log, these runs show up as
  `phase 2: completed parallel pruning in …: pruned … records`.
- **Aerospike logged a burst of UDF warnings.** On the 128-core node, about 13 s
  after the prune and shortly before the last batch completed, Aerospike logged
  about 160,000 lines of `WARNING (udf): (udf_record.c:661) record not open`.
- **Not every large prune leads to a stall.** The 128-core node got through a
  597,000-record prune without stalling earlier the same day.

Why the prune is a plausible trigger: besides deleting expired records, phase 2
updates the parents that survive with batched `addDeletedChildren` UDF calls
(`stores/utxo/aerospike/pruner` in the Teranode repo). Those calls go through
the same batch-index path that stops. This is a correlation, not a confirmed
cause.

### `pruner_skipDuringCatchup`

Since Teranode v0.16.0, `pruner_skipDuringCatchup=true` makes the pruner skip
every cycle unless the FSM is in `RUNNING`. The quickstart leaves it at
Teranode's default, `false`, and does not recommend changing it as a fix for
this stall:

- It postpones the deletes rather than removing them. Teranode's settings
  reference says a node that skips a long catchup "hits one much larger DAH
  sweep on entering RUNNING". If large prunes do trigger the stall, that single
  sweep is a bigger instance of the same thing.
- The UTXO store grows for the whole catchup, because nothing is pruned.
- Teranode's guidance is that leaving it off is safe with a retention of at
  least 288 blocks, which is the quickstart default.

If a node stalls repeatedly during initial sync and you want to try it anyway,
add `pruner_skipDuringCatchup=true` to `.env` and run `./start.sh`. Expect a
long prune run when the node reaches `RUNNING`, and remove the line afterwards.
