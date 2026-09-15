#!/usr/bin/env bash
#
# start-validator.sh  --  run the single Gorbagana relaunch validator on a low-power node.
#
# This is the lightweight RUNTIME script. It does NOT build genesis; run
# ./build-genesis.sh once (on any capable machine) to produce the ledger, copy
# the ledger + config here, then run this.
#
# Low-power notes:
#   * genesis is created with `--hashes-per-tick sleep`, so PoH does not spin the
#     CPU hashing; the node mostly idles between slots.
#   * snapshots are infrequent and incremental snapshots are off by default.
#   * thread pools are capped via RAYON_NUM_THREADS (override as you like).
#
# Everything is overridable via environment variables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# --- paths ---------------------------------------------------------------- #
LEDGER_DIR="${LEDGER_DIR:-$SCRIPT_DIR/build/ledger}"
CONFIG_DIR="${CONFIG_DIR:-$SCRIPT_DIR/build/config}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-$LEDGER_DIR/accounts}"
IDENTITY="${IDENTITY:-$CONFIG_DIR/validator-identity.json}"
VOTE_ACCOUNT="${VOTE_ACCOUNT:-$CONFIG_DIR/validator-vote-account.json}"
FAUCET_KEYPAIR="${FAUCET_KEYPAIR:-$CONFIG_DIR/faucet-keypair.json}"

# --- network -------------------------------------------------------------- #
RPC_PORT="${RPC_PORT:-8899}"
GOSSIP_PORT="${GOSSIP_PORT:-8001}"
# Half-open [min,max), and agave rejects anything narrower than
# MINIMUM_VALIDATOR_PORT_RANGE_WIDTH (26). 8002-8032 leaves a little headroom.
DYNAMIC_PORT_RANGE="${DYNAMIC_PORT_RANGE:-8002-8032}"
RPC_BIND_ADDRESS="${RPC_BIND_ADDRESS:-0.0.0.0}"
FAUCET_PORT="${FAUCET_PORT:-9900}"
ENABLE_FAUCET="${ENABLE_FAUCET:-true}"

# --- low-power / snapshot tuning ------------------------------------------ #
export RUST_LOG="${RUST_LOG:-info}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-2}"
# A SHRED COUNT, not bytes and not a time window. 50,000,000 is not a tuning choice:
# it is DEFAULT_MIN_MAX_LEDGER_SHREDS, the hard floor enforced in
# ledger/src/blockstore_cleanup_service.rs. The validator REFUSES TO START below it
# ("--limit-ledger-size value was too small"). Upstream budgets it at ~100 GB; this
# chain measures ~116 GB steady state, because every slot costs a fixed ~75 KB of
# data+code shreds regardless of content and we produce slots ~7x faster than mainnet.
# Going lower requires patching that constant and rebuilding the validator.
LIMIT_LEDGER_SIZE="${LIMIT_LEDGER_SIZE:-50000000}"    # the minimum the binary accepts
FULL_SNAPSHOT_INTERVAL_SLOTS="${FULL_SNAPSHOT_INTERVAL_SLOTS:-25000}"
MAX_GENESIS_ARCHIVE_UNPACKED_SIZE="${MAX_GENESIS_ARCHIVE_UNPACKED_SIZE:-1073741824}"

# The banking tracer writes ~1 GB event files for simulate-leader-blocks replay and
# retains ~13 GB by default. Useful for debugging block production, dead weight
# otherwise. Set true to re-enable.
ENABLE_BANKING_TRACE="${ENABLE_BANKING_TRACE:-false}"

log()  { printf '\033[1;36m[validator]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[validator][error]\033[0m %s\n' "$*" >&2; exit 1; }

# BIN_DIR lets a deployed copy (see install-service.sh) run from pinned binaries
# outside the repo, so rebuilding the checkout cannot swap the running validator --
# which matters because the single-node lock is compiled into that specific binary.
BIN_DIR="${BIN_DIR:-}"

resolve_bin() {
  local n="$1" d
  for d in ${BIN_DIR:+"$BIN_DIR"} "$REPO_DIR/target/release" "$REPO_DIR/dev-bins/target/release"; do
    if [[ -x "$d/$n" ]]; then echo "$d/$n"; return; fi
  done
  command -v "$n" 2>/dev/null || true
}
AGAVE_VALIDATOR="$(resolve_bin agave-validator)"
SOLANA_KEYGEN="$(resolve_bin solana-keygen)"
SOLANA_FAUCET="$(resolve_bin solana-faucet)"

[[ -n "$AGAVE_VALIDATOR" ]] || die "agave-validator not found. Build the single-node-locked binary via ./build-genesis.sh, or: GORB_SINGLE_NODE_IDENTITY=\$(solana-keygen pubkey $IDENTITY) cargo build --release -p agave-validator  (omit the env for a permissionless validator)"
[[ -f "$LEDGER_DIR/genesis.bin" ]] || die "no genesis at $LEDGER_DIR — run ./build-genesis.sh first (or set LEDGER_DIR)"
[[ -f "$IDENTITY" ]] || die "missing identity keypair $IDENTITY"
[[ -f "$VOTE_ACCOUNT" ]] || die "missing vote keypair $VOTE_ACCOUNT"

mkdir -p "$ACCOUNTS_DIR"

log "identity     : $("$SOLANA_KEYGEN" pubkey "$IDENTITY" 2>/dev/null || echo '?')"
log "ledger       : $LEDGER_DIR"
log "rpc          : http://$RPC_BIND_ADDRESS:$RPC_PORT"
log "RAYON_NUM_THREADS=$RAYON_NUM_THREADS  RUST_LOG=$RUST_LOG"

# --- faucet (optional) ---------------------------------------------------- #
FAUCET_PID=""
if [[ "$ENABLE_FAUCET" == "true" && -f "$FAUCET_KEYPAIR" && -n "$SOLANA_FAUCET" ]]; then
  log "starting faucet on 127.0.0.1:$FAUCET_PORT"
  "$SOLANA_FAUCET" --keypair "$FAUCET_KEYPAIR" > /tmp/gorb-faucet.log 2>&1 &
  FAUCET_PID=$!
fi

# NOTE: this script ends in `exec`, which replaces the shell and DISCARDS these traps.
# They only cover a failure between here and the exec. Cleanup of the faucet after the
# validator exits is therefore NOT the script's job:
#   - under systemd, KillMode=control-group tears down the whole cgroup (see
#     gorbagana.service), which is the reliable path and why the unit is preferred;
#   - run by hand, a faucet started here outlives the validator and must be killed
#     manually, so set ENABLE_FAUCET=false unless you actually want one.
cleanup() { log "shutting down"; [[ -n "$FAUCET_PID" ]] && kill "$FAUCET_PID" 2>/dev/null || true; }
trap cleanup INT TERM

VALIDATOR_ARGS=(
  --identity "$IDENTITY"
  --vote-account "$VOTE_ACCOUNT"
  --ledger "$LEDGER_DIR"
  --accounts "$ACCOUNTS_DIR"
  --log -
  --full-rpc-api
  --rpc-port "$RPC_PORT"
  --rpc-bind-address "$RPC_BIND_ADDRESS"
  --gossip-port "$GOSSIP_PORT"
  --dynamic-port-range "$DYNAMIC_PORT_RANGE"
  --allow-private-addr
  # --allow-private-addr declares .requires("no_xdp"), so this is mandatory, not optional.
  # XDP transmit also wants CAP_NET_ADMIN and a dedicated CPU core; a single-node chain
  # has no use for it, so fall back to plain UDP sockets.
  --no-xdp
  --no-wait-for-vote-to-start-leader
  --no-os-network-limits-test
  --enable-rpc-transaction-history
  # With --no-incremental-snapshots, --full-snapshot-interval-slots is ignored and the
  # *full* interval comes from --snapshot-interval-slots (default 200 slots = 10s here).
  --snapshot-interval-slots "$FULL_SNAPSHOT_INTERVAL_SLOTS"
  --no-incremental-snapshots
  --limit-ledger-size "$LIMIT_LEDGER_SIZE"
  --max-genesis-archive-unpacked-size "$MAX_GENESIS_ARCHIVE_UNPACKED_SIZE"
)
# Default is nproc workers + nproc/4 blocking threads. Account scans
# (getProgramAccounts) occupy the blocking pool; keep it from starving getBlock.
[[ -n "${RPC_THREADS:-}" ]] && VALIDATOR_ARGS+=(--rpc-threads "$RPC_THREADS")
[[ -n "${RPC_BLOCKING_THREADS:-}" ]] && VALIDATOR_ARGS+=(--rpc-blocking-threads "$RPC_BLOCKING_THREADS")
[[ -n "${ACCOUNTS_INDEX_SCAN_RESULTS_LIMIT_MB:-}" ]] && VALIDATOR_ARGS+=(--accounts-index-scan-results-limit-mb "$ACCOUNTS_INDEX_SCAN_RESULTS_LIMIT_MB")
if [[ "$ENABLE_BANKING_TRACE" != "true" ]]; then
  VALIDATOR_ARGS+=(--disable-banking-trace)
fi
[[ -n "$FAUCET_PID" ]] && VALIDATOR_ARGS+=(--rpc-faucet-address "127.0.0.1:$FAUCET_PORT")

# extra ad-hoc args, e.g. VALIDATOR_ARGS_EXTRA="--rpc-pubsub-enable-block-subscription"
[[ -n "${VALIDATOR_ARGS_EXTRA:-}" ]] && VALIDATOR_ARGS+=($VALIDATOR_ARGS_EXTRA)

log "exec agave-validator ${VALIDATOR_ARGS[*]}"
exec "$AGAVE_VALIDATOR" "${VALIDATOR_ARGS[@]}"
