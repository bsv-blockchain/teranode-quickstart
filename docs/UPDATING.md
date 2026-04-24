# Updating

```bash
./update.sh --check          # dry-run: show current vs latest
./update.sh                  # interactive
./update.sh --yes            # non-interactive
./update.sh --to v0.14.2     # pin / rollback
```

## Flow

1. Reads `TERANODE_VERSION` from `.env`.
2. Queries `api.github.com/repos/bsv-blockchain/teranode/releases/latest`.
3. If different, prints current → target, release URL, first ~20 lines of notes.
4. On confirm, `lib/env_writer.sh` rewrites only the `TERANODE_VERSION=` line in `.env`.
5. `docker compose pull` + `up -d` recreates only the Teranode services.
6. Re-enters `RUNNING` FSM state.

## Why `.env`?

It's git-ignored. Your version pin is a local install decision — it shouldn't create diffs in tracked files on every update or conflict on `git pull`.

## What it doesn't do

- No scheduled auto-updates.
- No cross-version data migration. If a release changes on-disk format, wipe and resync (upstream release notes will say so).
- Doesn't update this repo itself — `git pull` for that.
