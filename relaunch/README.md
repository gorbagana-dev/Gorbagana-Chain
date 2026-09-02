# Gorbagana single-node relaunch (full state, slot 0, 0 inflation)

Relaunch Gorbagana as a **single validator** starting at the **lowest slot (0)** with
**zero inflation**, while carrying over the **full account state** (SOL balances,
SPL-Token / Token-2022 accounts, mints, Metaplex metadata, name-service entries,
program-owned PDAs, and deployed programs) from the August-2026 backup snapshot.

```
chain-backup-aug-2026/ledger/snapshots/snapshot-79798680-*.tar.zst   (source of truth: full account data)
        │
        ▼  agave-ledger-tool accounts --output json --encoding base64
accounts-full.json
        │
        ▼  convert_snapshot_to_primordial.py   (filter + patch)
primordial/primordial-*.yml
        │
        ▼  solana-genesis  --inflation none  --bootstrap-validator ...
build/ledger  (fresh genesis @ slot 0)
        │
        ▼  start-validator.sh   (single node, low power)
running chain
```

## Why not just boot the snapshot?

Booting the snapshot preserves state perfectly but keeps the chain at slot ~79.8M.
You asked for the **lowest slot**, so we rebuild state into a brand-new genesis
at slot 0. The backup's `balances.csv` / `accounts.txt` only carry
`lamports/owner/executable` (no `data`), which would wipe every token balance and
NFT — so we pull full state from the **snapshot** instead.

## What is carried over vs. recreated

| Category | Handling |
| --- | --- |
| Wallets (System-owned) | **Imported** – exact SOL balance |
| SPL-Token / Token-2022 accounts, mints | **Imported** – exact data (balances, authorities) |
| Metaplex metadata, name service, PDAs | **Imported** – exact data |
| Deployed programs (Token, Metadata, Config, ALT, DBC, cp_amm, Squads, …) | **Imported** – exact bytecode; ProgramData deploy-slot reset to `0` |
| Native builtins (System, Vote, Stake, loaders, ComputeBudget, precompiles, ZK) | **Recreated** by genesis |
| Sysvars | **Recreated** by genesis |
| Feature accounts | **Recreated** fresh (old ones carry activation slot ~79.8M → would read as "inactive") |
| Old **Stake** + **Vote** accounts | **Dropped** – see below |

### Why old stake/vote accounts are dropped

The backup has **~500,000,447 SOL locked in 6 stake accounts** delegated to old
validators. On a single-node chain those validators never vote, so that stake
would be "offline" and the lone new validator could never reach the 2/3
supermajority needed to finalize (and the old identities would pollute the leader
schedule). We therefore drop old stake/vote accounts and give the **new bootstrap
validator** the stake (default `500,000,000 SOL`). Net effect: total supply stays
≈ 1,000,000,000 SOL and the single node has 100% of activated stake, so it always
finalizes.

> Override with `KEEP_STAKE_VOTE=true` only if you also raise
> `BOOTSTRAP_VALIDATOR_STAKE_SOL` above `2 ×` the old stake (~1,000,000,000 SOL).

### Why program deploy-slots are patched

An upgradeable program's `ProgramData` records the slot it was deployed at
(~79.8M here). A program is only invokable at `current_slot > deploy_slot`, so on
a slot-0 chain every imported program would look "deployed in the future" and be
uncallable. The converter rewrites each `ProgramData` deploy-slot to `0`
(exactly what genesis does for baked-in programs), so programs work from slot 1.

## Prerequisites

- The `chain-backup-aug-2026/` directory next to the repo (contains
  `ledger/genesis.bin`, `ledger/rocksdb`, `ledger/snapshots/*.tar.zst`).
- Rust toolchain (`rust-toolchain.toml` pins it). First build is heavy; do it on
  a capable machine, then copy the produced ledger to the low-power node.
- `python3` (no third-party packages required; `ijson` is used automatically if
  installed, for constant-memory conversion of the big dump).

## Usage

### 1. Build genesis (one-time, on a capable machine)

```bash
cd Gorbagana-Chain/relaunch
BACKUP_DIR=../../chain-backup-aug-2026 ./build-genesis.sh
```

This builds the needed binaries if missing, dumps accounts, converts them, and
writes the new ledger to `relaunch/build/ledger` plus bootstrap keypairs to
`relaunch/build/config`. It prints the new genesis hash at the end.

### 2. Run the validator (on the low-power node)

Copy `relaunch/build/ledger` and `relaunch/build/config` over, then:

```bash
cd Gorbagana-Chain/relaunch
LEDGER_DIR=./build/ledger CONFIG_DIR=./build/config ./start-validator.sh
```

RPC comes up on `http://0.0.0.0:8899`.

## Key configuration (env vars)

`build-genesis.sh`

| Var | Default | Meaning |
| --- | --- | --- |
| `BACKUP_DIR` | `../chain-backup-aug-2026` | backup location |
| `CLUSTER_TYPE` | `development` | `development` = all features active (single-node friendly) |
| `BOOTSTRAP_VALIDATOR_STAKE_SOL` | `500000000` | new validator stake (100% of activated stake) |
| `TARGET_LAMPORTS_PER_SIGNATURE` | `5000` | base fee |
| `FEE_BURN_PERCENTAGE` | `0` | 0 → single node recovers its own vote fees |
| `INSTALL_PROGRAMS_FROM_SO` | `false` | `true` = install curated programs from `.so` instead of importing from snapshot |
| `KEEP_STAKE_VOTE` | `false` | keep old stake/vote (see caveat above) |

`start-validator.sh`

| Var | Default | Meaning |
| --- | --- | --- |
| `RAYON_NUM_THREADS` | `2` | cap CPU parallelism |
| `LIMIT_LEDGER_SIZE` | `50000000` | cap on-disk ledger (shreds) |
| `FULL_SNAPSHOT_INTERVAL_SLOTS` | `25000` | infrequent snapshots to save CPU/IO |
| `RPC_PORT` | `8899` | JSON-RPC port |

## Verify after building

```bash
# total supply / capitalization of the new chain
agave-ledger-tool capitalization --ledger relaunch/build/ledger

# genesis hash (this is a NEW hash; it will differ from the old chain)
agave-ledger-tool genesis-hash --ledger relaunch/build/ledger

# once running, spot-check a known holder's SOL and a token account
solana -u http://localhost:8899 balance <PUBKEY>
solana -u http://localhost:8899 account <TOKEN_ACCOUNT_PUBKEY>
```

The conversion step also prints a summary (accounts imported, wallets, programs,
ProgramData patched, total lamports) so you can sanity-check the carried-over
supply against `chain-backup-aug-2026/ledger/balances.csv`.

## Version note

The backup snapshot was produced by `agave-ledger-tool 3.0.8`; this repo is
`4.2.x` (snapshot format `1.2.0`). The dump step (step 1) reads the old snapshot.
If a 4.2.x `agave-ledger-tool` refuses to deserialize the 3.0.8 bank snapshot,
build the matching 3.0.x `agave-ledger-tool` just for the dump (the primordial
YAML it produces is version-agnostic and feeds straight into the 4.2.x genesis).

### Build note (workspaces)

`solana-genesis` and `solana-keygen` are members of the main workspace, but
`agave-ledger-tool` lives in the separate `dev-bins` workspace and needs the
`dev-context-only-utils` feature, so it is built from there:

```bash
cargo build --release -p solana-genesis -p solana-keygen          # main workspace -> target/release
( cd dev-bins && cargo build --release -p agave-ledger-tool )     # dev-bins       -> dev-bins/target/release
```

`build-genesis.sh` already does this automatically when a binary is missing.
Build on a capable machine; the low-power node only needs `agave-validator`
plus the produced `ledger/` + `config/`.
