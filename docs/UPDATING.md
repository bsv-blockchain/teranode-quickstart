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

`update.sh` itself never touches Docker — it only bumps `.env`. This keeps the version pin and the rollout as separate steps; you can `--check` or pin a tag without touching the running stack.

## Upgrading from below v0.15.7 (testnet / teratestnet)

Releases before v0.15.7 dropped bare `OP_RETURN` outputs from the UTXO set at
store time, applying pre-Genesis rules to post-Genesis outputs. Any later block
spending such an output could not resolve the outpoint, and the node stopped
advancing. v0.15.7 fixes the store-time rule, but it does **not** heal a chain
that is already wedged — the bad block is still in the local store.

A node that kept advancing needs none of this. Upgrade and carry on.

If your node stalled before you upgraded, rewind past the bad block on v0.15.9
and let it re-sync with the fix in effect:

```bash
./start.sh                                       # on v0.15.9, stack up
./rpc.sh getblockcount                           # note the stalled height
./cli.sh setfsmstate --fsmstate IDLE             # rewind refuses unless IDLE
./cli.sh rewindblockchain --target-height <h> --dry-run
./cli.sh rewindblockchain --target-height <h> --verify
./cli.sh setfsmstate --fsmstate RUNNING
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
