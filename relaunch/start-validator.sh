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
DYNAMIC_PORT_RANGE="${DYNAMIC_PORT_RANGE:-8002-8020}"
RPC_BIND_ADDRESS="${RPC_BIND_ADDRESS:-0.0.0.0}"
FAUCET_PORT="${FAUCET_PORT:-9900}"
ENABLE_FAUCET="${ENABLE_FAUCET:-true}"

# --- low-power / snapshot tuning ------------------------------------------ #
export RUST_LOG="${RUST_LOG:-info}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-2}"
LIMIT_LEDGER_SIZE="${LIMIT_LEDGER_SIZE:-50000000}"
FULL_SNAPSHOT_INTERVAL_SLOTS="${FULL_SNAPSHOT_INTERVAL_SLOTS:-25000}"
MAX_GENESIS_ARCHIVE_UNPACKED_SIZE="${MAX_GENESIS_ARCHIVE_UNPACKED_SIZE:-1073741824}"

log()  { printf '\033[1;36m[validator]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[validator][error]\033[0m %s\n' "$*" >&2; exit 1; }

resolve_bin() {
  local n="$1"
  [[ -x "$REPO_DIR/target/release/$n" ]]          && { echo "$REPO_DIR/target/release/$n"; return; }
  [[ -x "$REPO_DIR/dev-bins/target/release/$n" ]] && { echo "$REPO_DIR/dev-bins/target/release/$n"; return; }
  command -v "$n" 2>/dev/null || true
}
AGAVE_VALIDATOR="$(resolve_bin agave-validator)"
SOLANA_KEYGEN="$(resolve_bin solana-keygen)"
SOLANA_FAUCET="$(resolve_bin solana-faucet)"

[[ -n "$AGAVE_VALIDATOR" ]] || die "agave-validator not found (build it: cargo build --release -p agave-validator)"
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

cleanup() { log "shutting down"; [[ -n "$FAUCET_PID" ]] && kill "$FAUCET_PID" 2>/dev/null || true; }
trap cleanup INT TERM EXIT

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
  --no-wait-for-vote-to-start-leader
  --no-os-network-limits-test
  --enable-rpc-transaction-history
  --full-snapshot-interval-slots "$FULL_SNAPSHOT_INTERVAL_SLOTS"
  --no-incremental-snapshots
  --limit-ledger-size "$LIMIT_LEDGER_SIZE"
  --max-genesis-archive-unpacked-size "$MAX_GENESIS_ARCHIVE_UNPACKED_SIZE"
)
[[ -n "$FAUCET_PID" ]] && VALIDATOR_ARGS+=(--rpc-faucet-address "127.0.0.1:$FAUCET_PORT")

# extra ad-hoc args, e.g. VALIDATOR_ARGS_EXTRA="--rpc-pubsub-enable-block-subscription"
[[ -n "${VALIDATOR_ARGS_EXTRA:-}" ]] && VALIDATOR_ARGS+=($VALIDATOR_ARGS_EXTRA)

log "exec agave-validator ${VALIDATOR_ARGS[*]}"
exec "$AGAVE_VALIDATOR" "${VALIDATOR_ARGS[@]}"
