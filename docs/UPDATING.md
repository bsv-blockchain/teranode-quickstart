# Updating

```bash
./update.sh --check          # dry-run: show current vs latest
./update.sh                  # interactive
./update.sh --yes            # non-interactive
./update.sh --to v0.15.9     # pin / rollback
```

## Flow

1. Reads `TERANODE_VERSION` from `.env`.
2. Queries `api.github.com/repos/bsv-blockchain/teranode/releases/latest`.
3. If different, prints current tag, target tag, and release URL.
4. On confirm, `lib/env_writer.sh` rewrites only the `TERANODE_VERSION=` line in `.env`.
5. Prints next-step hint: run `./start.sh` to pull the new image and recreate the changed Teranode services. Data volumes persist; A node stopped in `IDLE` is moved to `CATCHINGBLOCKS` (`RUNNING` on v0.15.x) and promotes itself to `RUNNING` once caught up; a persisted `CATCHINGBLOCKS` or `RUNNING` state is resumed as-is.

`update.sh` never changes Docker state — it only bumps `.env`. This keeps the version pin and the rollout as separate steps; you can `--check` or pin a tag without touching the running stack.

### Leaving v0.16.0

v0.16.1 and later refuse a conflict intent that v0.16.0 left in the conflict
WAL, and block assembly does not start until it is repaired. When `.env` is on
v0.16.0 (stable or a beta) and the target is v0.16.1 or later, `update.sh` reads
the WAL before it writes `.env`, with one read-only
`docker exec aerospike asinfo -v "sets/utxo-store/utxo_conflictwal"`. It needs
block assembly stopped and Aerospike up:

```bash
docker stop blockassembly      # not ./stop.sh: that stops Aerospike too
./update.sh
./start.sh                     # starts blockassembly again
```

An empty WAL lets the update through. A WAL with records stops it with a link to
[Upgrade and repair](https://github.com/bsv-blockchain/teranode/blob/v0.16.1/docs/topics/conflict-recovery.md#upgrade-and-repair).
When it can't read the WAL (block assembly running, Aerospike down, `utxostore`
or `SETTINGS_CONTEXT` changed in `.env`, Docker missing), it refuses and says why.
`--yes` does not skip the check. If you checked the WAL yourself, set
`TERANODE_VERSION` in `.env` by hand.

## Admin API key

Newer Teranode releases refuse to start Blockchain without
`grpc_admin_api_key`, and every other service needs the same value to call it.
`./start.sh` generates one into `.env` when it is missing or blank, so an older
`.env` needs no manual step: run `./update.sh` then `./start.sh` as usual. It
never replaces a value you already set. If you rotate the key, run `./start.sh`
so every service restarts with the new value; a service left on the old key
fails its readiness check.

## RPC credentials

Teranode has no default RPC credentials: with `rpc_user`/`rpc_pass` blank,
JSON-RPC rejects every request. `setup.sh` always writes both. `./start.sh`
fills in either one when it is missing or blank, `rpc_user=teranode` and a
random `rpc_pass`, and never replaces a value you set. Read the password from
`.env`.

## Upgrading from below v0.15.7 (testnet / teratestnet)

Releases before v0.15.7 dropped bare `OP_RETURN` outputs from the UTXO set at
store time, applying pre-Genesis rules to post-Genesis outputs. Any later block
spending such an output could not resolve the outpoint, and the node stopped
advancing. v0.15.7 fixes the store-time rule, but it does **not** heal a chain
that is already wedged — the bad block is still in the local store.

A node that kept advancing needs none of this. Upgrade and carry on.

If your node stalled before you upgraded, rewind past the bad block on v0.15.9 or later
and let it re-sync with the fix in effect:

```bash
./start.sh                                       # on v0.15.9+, stack up
./rpc.sh getblockcount                           # note the stalled height
./cli.sh setfsmstate --fsmstate IDLE             # rewind refuses unless IDLE
./cli.sh rewindblockchain --target-height <h> --dry-run
./cli.sh rewindblockchain --target-height <h> --verify
./cli.sh setfsmstate --fsmstate CATCHINGBLOCKS   # RUNNING on v0.15.x
```

`<h>` is a few blocks below where the node stalled. `--dry-run` logs every
delete without touching a store — run it first and read the output. The tool
prompts before doing anything destructive; `--assume-yes` skips the prompt.
Rewinding more than 100 blocks needs `--force-deep` (coinbase-maturity risk),
and `--force-not-idle` exists but is a foot-gun: the node must be IDLE so
nothing writes underneath the rewind.

The subcommand ships in v0.15.8 and later, so run it on the upgraded image, not
the old one.

## Why `.env`?

It's git-ignored. Your version pin is a local install decision — it shouldn't create diffs in tracked files on every update or conflict on `git pull`.

## What it doesn't do

- No scheduled auto-updates.
- No cross-version data migration. If a release changes on-disk format, wipe and resync (upstream release notes will say so).
- Doesn't update this repo itself — `git pull` for that.
