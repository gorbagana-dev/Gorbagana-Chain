#!/usr/bin/env bash
#
# build-genesis.sh  --  ONE-TIME genesis builder for the Gorbagana single-node relaunch.
#
# It reconstructs the full on-chain state from the August-2026 backup snapshot
# into a brand-new genesis at slot 0:
#
#   1. dumps every account (WITH data) from the backup snapshot via agave-ledger-tool
#   2. converts them into solana-genesis primordial-accounts YAML chunks
#      (dropping builtins/stake/vote/feature/sysvars, patching program deploy-slots)
#   3. creates a fresh, slot-0, 0-inflation, single-bootstrap-validator genesis
#
# The heavy lifting happens here. Run it ONCE on a machine with enough RAM
# (>= 8 GB recommended); then copy the produced ledger to the low-power node and
# run ./start-validator.sh there.
#
# All paths/economics are overridable via environment variables (see below).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Backup must contain ledger/{genesis.bin,rocksdb,snapshots/*.tar.zst}
BACKUP_DIR="${BACKUP_DIR:-$(cd "$REPO_DIR/.." && pwd)/chain-backup-aug-2026}"
BACKUP_LEDGER="${BACKUP_LEDGER:-$BACKUP_DIR/ledger}"

OUT_DIR="${OUT_DIR:-$REPO_DIR/relaunch/build}"
LEDGER_DIR="${LEDGER_DIR:-$OUT_DIR/ledger}"
CONFIG_DIR="${CONFIG_DIR:-$OUT_DIR/config}"
WORK_LEDGER="${WORK_LEDGER:-$OUT_DIR/work-ledger}"
PRIMORDIAL_DIR="${PRIMORDIAL_DIR:-$OUT_DIR/primordial}"
ACCOUNTS_JSON="${ACCOUNTS_JSON:-$OUT_DIR/accounts-full.json}"

// !TODO: Change the code for 500M SOL stakes @genesis/src/main
CLUSTER_TYPE="${CLUSTER_TYPE:-mainnet-beta}"
BOOTSTRAP_VALIDATOR_STAKE_SOL="${BOOTSTRAP_VALIDATOR_STAKE_SOL:-500000000}"
BOOTSTRAP_VALIDATOR_LAMPORTS_SOL="${BOOTSTRAP_VALIDATOR_LAMPORTS_SOL:-500}"
FAUCET_SOL="${FAUCET_SOL:-100000000}"
TARGET_LAMPORTS_PER_SIGNATURE="${TARGET_LAMPORTS_PER_SIGNATURE:-5000}"
FEE_BURN_PERCENTAGE="${FEE_BURN_PERCENTAGE:-0}"
TICKS_PER_SLOT="${TICKS_PER_SLOT:-64}"
HASHES_PER_TICK="${HASHES_PER_TICK:-sleep}"        # 'sleep' => no PoH hashing (low CPU)
MAX_GENESIS_ARCHIVE_UNPACKED_SIZE="${MAX_GENESIS_ARCHIVE_UNPACKED_SIZE:-1073741824}"

# true => install curated $PROGRAMS_DIR/*.so instead of importing programs from the snapshot
INSTALL_PROGRAMS_FROM_SO="${INSTALL_PROGRAMS_FROM_SO:-false}"
PROGRAMS_DIR="${PROGRAMS_DIR:-$REPO_DIR/relaunch/programs}"
UPGRADE_AUTHORITY_KEYPAIR="${UPGRADE_AUTHORITY_KEYPAIR:-$CONFIG_DIR/upgrade-authority.json}"
KEEP_STAKE_VOTE="${KEEP_STAKE_VOTE:-false}"
PYTHON="${PYTHON:-python3}"

log()  { printf '\033[1;36m[build-genesis]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build-genesis][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build-genesis][error]\033[0m %s\n' "$*" >&2; exit 1; }

# solana-genesis/keygen live in the main workspace; agave-ledger-tool in dev-bins.
resolve_bin() {
  local n="$1"
  for d in "$REPO_DIR/target/release" "$REPO_DIR/dev-bins/target/release"; do
    [[ -x "$d/$1" ]] && { echo "$d/$1"; return; }
  done
  command -v "$n" 2>/dev/null || true
}

ensure_binaries() {
  SOLANA_GENESIS="$(resolve_bin solana-genesis)"
  SOLANA_KEYGEN="$(resolve_bin solana-keygen)"
  LEDGER_TOOL="$(resolve_bin agave-ledger-tool)"

  if [[ -z "$SOLANA_GENESIS" || -z "$SOLANA_KEYGEN" ]]; then
    log "building solana-genesis + solana-keygen ..."
    ( cd "$REPO_DIR" && cargo build --release -p solana-genesis -p solana-keygen ) || die "cargo build (genesis/keygen) failed"
  fi
  if [[ -z "$LEDGER_TOOL" ]]; then
    log "building agave-ledger-tool ..."
    ( cd "$REPO_DIR/dev-bins" && cargo build --release -p agave-ledger-tool ) || die "cargo build (agave-ledger-tool) failed"
  fi

  SOLANA_GENESIS="$(resolve_bin solana-genesis)"
  SOLANA_KEYGEN="$(resolve_bin solana-keygen)"
  LEDGER_TOOL="$(resolve_bin agave-ledger-tool)"
  [[ -n "$SOLANA_GENESIS" && -n "$LEDGER_TOOL" && -n "$SOLANA_KEYGEN" ]] || die "could not resolve required binaries after build"
}

gen_keypair() {
  if [[ -f "$1" ]]; then
    log "reusing $(basename "$1") -> $("$SOLANA_KEYGEN" pubkey "$1")"
  else
    "$SOLANA_KEYGEN" new --no-passphrase --silent --force --outfile "$1"
    log "generated $(basename "$1") -> $("$SOLANA_KEYGEN" pubkey "$1")"
  fi
}

ensure_keypairs() {
  mkdir -p "$CONFIG_DIR"
  IDENTITY="$CONFIG_DIR/validator-identity.json"
  VOTE="$CONFIG_DIR/validator-vote-account.json"
  STAKE="$CONFIG_DIR/validator-stake-account.json"
  FAUCET="$CONFIG_DIR/faucet-keypair.json"
  gen_keypair "$IDENTITY"
  gen_keypair "$VOTE"
  gen_keypair "$STAKE"
  gen_keypair "$FAUCET"
  [[ "$INSTALL_PROGRAMS_FROM_SO" == "true" ]] && gen_keypair "$UPGRADE_AUTHORITY_KEYPAIR"
}

dump_accounts() {
  if [[ -s "$ACCOUNTS_JSON" && "${REUSE_DUMP:-false}" == "true" ]]; then
    log "reusing existing account dump: $ACCOUNTS_JSON"; return
  fi
  [[ -f "$BACKUP_LEDGER/genesis.bin" ]] || die "backup ledger not found at $BACKUP_LEDGER (need genesis.bin)"

  local snap hi_slot
  snap="$(ls "$BACKUP_LEDGER"/snapshots/snapshot-*.tar.zst 2>/dev/null | head -1)"
  [[ -n "$snap" ]] || die "no full snapshot archive under $BACKUP_LEDGER/snapshots"

  # highest slot = incremental slot if present, else full slot
  hi_slot="$(ls "$BACKUP_LEDGER"/snapshots/incremental-snapshot-*.tar.zst 2>/dev/null \
             | sed -E 's/.*incremental-snapshot-[0-9]+-([0-9]+)-.*/\1/' | sort -n | tail -1)"
  [[ -z "$hi_slot" ]] && hi_slot="$(basename "$snap" | sed -E 's/snapshot-([0-9]+)-.*/\1/')"
  log "snapshot tip slot: $hi_slot"

  # Scratch copy so the backup stays pristine (ledger-tool writes a subdir).
  log "preparing scratch ledger copy at $WORK_LEDGER ..."
  rm -rf "$WORK_LEDGER"; mkdir -p "$WORK_LEDGER"
  cp "$BACKUP_LEDGER/genesis.bin" "$WORK_LEDGER/"
  cp -R "$BACKUP_LEDGER/snapshots" "$WORK_LEDGER/snapshots"
  [[ -d "$BACKUP_LEDGER/rocksdb" ]] && cp -R "$BACKUP_LEDGER/rocksdb" "$WORK_LEDGER/rocksdb"

  log "dumping accounts with base64 data (slow step) ..."
  "$LEDGER_TOOL" accounts --ledger "$WORK_LEDGER" --snapshots "$WORK_LEDGER/snapshots" \
    --halt-at-slot "$hi_slot" --output json --encoding base64 > "$ACCOUNTS_JSON" \
    || die "agave-ledger-tool accounts failed (likely snapshot-format incompatibility; see README)"
  log "account dump written: $ACCOUNTS_JSON ($(du -h "$ACCOUNTS_JSON" | cut -f1))"
}

# id | filename (relative to $PROGRAMS_DIR) | loader(upgradeable|bpfv2|bpf)
CURATED_PROGRAMS=(
  "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb|spl-token-2022-9.0.0.so|upgradeable"
  "Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo|spl-memo-1.0.0.so|bpf"
  "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr|spl-memo-3.0.0.so|bpfv2"
  "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL|spl-associated-token-account-1.1.2.so|bpfv2"
  "Feat1YXHhH6t1juaWF74WLcfv4XoNocjXA6sPWHNgAse|spl-feature-proposal-1.0.0.so|bpfv2"
  "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA|spl-token-3.5.0.so|bpfv2"
  "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s|mpl_token_metadata.so|upgradeable"
  "Feature111111111111111111111111111111111111|core-bpf-feature-gate-0.0.1.so|upgradeable"
  "AddressLookupTab1e1111111111111111111111111|core-bpf-address-lookup-table-3.0.0.so|upgradeable"
  "Config1111111111111111111111111111111111111|core-bpf-config-3.0.0.so|upgradeable"
  "namesLPneVptA9Z5rqUDD9tMTWEJwofgaYwp8cawRkX|names-3.0.0.so|upgradeable"
  "dbcij3LWUppWqq96dh6gJWwBifmcGfLSB5D4DuSMaqN|dynamic_bonding_curve-1.0.0.so|upgradeable"
  "cpamdpZCGKUy5JxQXB4dcpGPiikHawvSWAd6mEn1sGG|cp_amm.so|upgradeable"
  "SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf|squads_multisig_program.so|upgradeable"
  "LocpQgucEQHbqNABEYvBvwoxCPsSbG91A1QaQhQQqjn|locker.so|upgradeable"
  "dfsdo2UqvwfN8DuUVrMRNfQe11VaiNoKcMqLHVvDPzh|dynamic_fee_sharing.so|upgradeable"
  "CndyV3LdqHUfDLmE5naZjVN8rBZz4tqhdefbAnjHG3JR|mpl_candy_machine_core.so|upgradeable"
  "Guard1JwRhJkVH6XZhzoYxeBVQe872VH6QggF4BWmS9g|mpl_candy_guard.so|upgradeable"
)

INSTALL_IDS_FILE="$OUT_DIR/install-program-ids.txt"
BPF_PROGRAM_ARGS=()

build_program_args() {
  : > "$INSTALL_IDS_FILE"
  [[ "$INSTALL_PROGRAMS_FROM_SO" != "true" ]] && { log "importing ALL programs from snapshot (offline mode)"; return; }

  mkdir -p "$PROGRAMS_DIR"
  local upg_auth missing=() row id file type so
  upg_auth="$("$SOLANA_KEYGEN" pubkey "$UPGRADE_AUTHORITY_KEYPAIR")"
  for row in "${CURATED_PROGRAMS[@]}"; do
    IFS='|' read -r id file type <<< "$row"
    so="$PROGRAMS_DIR/$file"
    [[ -f "$so" ]] || { missing+=("$file ($id)"); continue; }
    echo "$id" >> "$INSTALL_IDS_FILE"
    case "$type" in
      upgradeable) BPF_PROGRAM_ARGS+=(--upgradeable-program "$id" BPFLoaderUpgradeab1e11111111111111111111111 "$so" "$UPGRADE_AUTHORITY_KEYPAIR") ;;
      bpfv2)       BPF_PROGRAM_ARGS+=(--bpf-program "$id" BPFLoader2111111111111111111111111111111111 "$so") ;;
      *)           BPF_PROGRAM_ARGS+=(--bpf-program "$id" BPFLoader1111111111111111111111111111111111 "$so") ;;
    esac
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "INSTALL_PROGRAMS_FROM_SO=true but these .so files are missing in $PROGRAMS_DIR:"
    printf '   - %s\n' "${missing[@]}" >&2
    die "add the .so files or unset INSTALL_PROGRAMS_FROM_SO to import programs from the snapshot"
  fi
  log "installing ${#CURATED_PROGRAMS[@]} curated programs from $PROGRAMS_DIR (authority $upg_auth)"
}

convert_primordial() {
  rm -rf "$PRIMORDIAL_DIR"; mkdir -p "$PRIMORDIAL_DIR"
  local args=("$SCRIPT_DIR/convert_snapshot_to_primordial.py" "$ACCOUNTS_JSON"
              --out-dir "$PRIMORDIAL_DIR" --prefix primordial)
  [[ -s "$INSTALL_IDS_FILE" ]] && args+=(--install-program-ids-file "$INSTALL_IDS_FILE")
  [[ "$KEEP_STAKE_VOTE" == "true" ]] && args+=(--keep-stake-vote)
  "$PYTHON" "${args[@]}" || die "primordial conversion failed"
}

create_genesis() {
  rm -rf "$LEDGER_DIR"; mkdir -p "$LEDGER_DIR"
  local cmd f
  cmd=(
    "$SOLANA_GENESIS"
    --ledger "$LEDGER_DIR"
    --cluster-type "$CLUSTER_TYPE"
    --hashes-per-tick "$HASHES_PER_TICK"
    --ticks-per-slot "$TICKS_PER_SLOT"
    --inflation none
    --fee-burn-percentage "$FEE_BURN_PERCENTAGE"
    --rent-burn-percentage 0
    --target-lamports-per-signature "$TARGET_LAMPORTS_PER_SIGNATURE"
    --bootstrap-validator "$IDENTITY" "$VOTE" "$STAKE"
    --bootstrap-validator-stake-lamports "$(( BOOTSTRAP_VALIDATOR_STAKE_SOL * 1000000000 ))"
    --bootstrap-validator-lamports "$(( BOOTSTRAP_VALIDATOR_LAMPORTS_SOL * 1000000000 ))"
    --faucet-pubkey "$FAUCET"
    --faucet-lamports "$(( FAUCET_SOL * 1000000000 ))"
    --max-genesis-archive-unpacked-size "$MAX_GENESIS_ARCHIVE_UNPACKED_SIZE"
  )
  for f in "$PRIMORDIAL_DIR"/primordial-*.yml; do cmd+=(--primordial-accounts-file "$f"); done
  [[ ${#BPF_PROGRAM_ARGS[@]} -gt 0 ]] && cmd+=("${BPF_PROGRAM_ARGS[@]}")

  log "creating genesis (inflation=none, cluster=$CLUSTER_TYPE, stake=${BOOTSTRAP_VALIDATOR_STAKE_SOL} SOL) ..."
  "${cmd[@]}" || die "solana-genesis failed"
}

mkdir -p "$OUT_DIR"
ensure_binaries
ensure_keypairs
dump_accounts
build_program_args
convert_primordial
create_genesis

GENESIS_HASH="$("$LEDGER_TOOL" genesis-hash --ledger "$LEDGER_DIR" 2>/dev/null || true)"
cat <<EOF

$(printf '\033[1;32m[build-genesis] SUCCESS\033[0m')
  new ledger      : $LEDGER_DIR
  bootstrap id    : $("$SOLANA_KEYGEN" pubkey "$IDENTITY")
  vote account    : $("$SOLANA_KEYGEN" pubkey "$VOTE")
  genesis hash    : ${GENESIS_HASH:-<run: agave-ledger-tool genesis-hash --ledger $LEDGER_DIR>}

Next:
  1. Copy '$LEDGER_DIR' and '$CONFIG_DIR' to the low-power node.
  2. Run:  LEDGER_DIR=$LEDGER_DIR CONFIG_DIR=$CONFIG_DIR ./start-validator.sh
  3. Verify:  agave-ledger-tool capitalization --ledger $LEDGER_DIR
EOF
