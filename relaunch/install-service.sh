#!/usr/bin/env bash
#
# install-service.sh  --  deploy the Gorbagana validator as a systemd service.
#
# Moves the chain off the git checkout and onto a stable layout, pins the
# single-node-locked binary, and installs a supervised unit:
#
#   /opt/gorbagana/bin/        agave-validator (locked), solana-keygen,
#                              agave-ledger-tool, start-validator.sh
#   /var/lib/gorbagana/ledger  chain state
#   /var/lib/gorbagana/config  keypairs (0700 -- these ARE the chain)
#   /etc/systemd/system/gorbagana.service
#
# Why not run from relaunch/build/ : that path is inside the repo working tree and
# is not gitignored, so `git clean -fdx` would delete the ledger AND the keypairs.
# Pinning the binary also means rebuilding the checkout cannot silently swap in an
# agave-validator built without GORB_SINGLE_NODE_IDENTITY (i.e. with no lock).
#
# Safe to re-run: it never overwrites an existing ledger/config, and it refuses to
# install a validator binary that has lost the single-node lock.
#
# Usage:  ./install-service.sh            # install (and migrate on first run)
#         ./install-service.sh --no-start # install but leave the service stopped

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

SERVICE_NAME="${SERVICE_NAME:-gorbagana}"
RUN_USER="${RUN_USER:-$(id -un)}"
BIN_DIR="${BIN_DIR:-/opt/gorbagana/bin}"
DATA_DIR="${DATA_DIR:-/var/lib/gorbagana}"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

SRC_BUILD="${SRC_BUILD:-$SCRIPT_DIR/build}"
START_SERVICE=true
[[ "${1:-}" == "--no-start" ]] && START_SERVICE=false

log()  { printf '\033[1;36m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install][error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$RUN_USER" != "root" ]] || die "refusing to run the validator as root; set RUN_USER"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found (not a systemd host?)"
[[ -f "$SCRIPT_DIR/gorbagana.service" ]] || die "missing $SCRIPT_DIR/gorbagana.service"
[[ -f "$SCRIPT_DIR/start-validator.sh" ]] || die "missing $SCRIPT_DIR/start-validator.sh"

# ---- locate the binaries ---------------------------------------------------- #
find_bin() {
  local n="$1" d
  for d in "$BIN_DIR" "$REPO_DIR/target/release" "$REPO_DIR/dev-bins/target/release"; do
    if [[ -x "$d/$n" ]]; then echo "$d/$n"; return; fi
  done
  return 1
}

VALIDATOR_BIN="$(find_bin agave-validator)" || die "agave-validator not found — run ./build-genesis.sh first"
KEYGEN_BIN="$(find_bin solana-keygen)"      || die "solana-keygen not found — run ./build-genesis.sh first"
LEDGER_TOOL_BIN="$(find_bin agave-ledger-tool || true)"

# ---- work out where the chain currently lives ------------------------------- #
if [[ -f "$DATA_DIR/config/validator-identity.json" ]]; then
  IDENTITY_SRC="$DATA_DIR/config/validator-identity.json"
elif [[ -f "$SRC_BUILD/config/validator-identity.json" ]]; then
  IDENTITY_SRC="$SRC_BUILD/config/validator-identity.json"
else
  die "no validator-identity.json in $DATA_DIR/config or $SRC_BUILD/config"
fi
IDENTITY_PUBKEY="$("$KEYGEN_BIN" pubkey "$IDENTITY_SRC")"

# ---- refuse to deploy a validator that lost the single-node lock ------------ #
# The lock is compiled in via GORB_SINGLE_NODE_IDENTITY; a plain
# `cargo build -p agave-validator` produces a binary without it, and then anyone
# with stake can affect consensus. Cheap to check, catastrophic to miss.
if [[ "${REQUIRE_SINGLE_NODE_LOCK:-true}" == "true" ]]; then
  # grep -c, not grep -q: under `set -o pipefail` a -q match exits early, `strings`
  # dies of SIGPIPE, and the pipeline reports 141 — making a locked binary look unlocked.
  lock_hits="$(strings -a "$VALIDATOR_BIN" | grep -cF "$IDENTITY_PUBKEY" || true)"
  if [[ "${lock_hits:-0}" -eq 0 ]]; then
    die "$VALIDATOR_BIN does not have identity $IDENTITY_PUBKEY baked in — the single-node
       lock is MISSING. Rebuild with:
         GORB_SINGLE_NODE_IDENTITY=$IDENTITY_PUBKEY cargo build --release -p agave-validator
       or set REQUIRE_SINGLE_NODE_LOCK=false for a deliberately permissionless chain."
  fi
  log "single-node lock verified in $(basename "$VALIDATOR_BIN") (identity $IDENTITY_PUBKEY)"
fi

# ---- stop the service before touching anything it may be using -------------- #
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  log "stopping running $SERVICE_NAME ..."
  sudo systemctl stop "$SERVICE_NAME"
fi

# ---- directories ------------------------------------------------------------ #
log "creating $BIN_DIR and $DATA_DIR ..."
sudo install -d -o "$RUN_USER" -g "$RUN_USER" -m 0755 "$BIN_DIR" "$DATA_DIR"
sudo install -d -o "$RUN_USER" -g "$RUN_USER" -m 0700 "$DATA_DIR/config"

# ---- binaries + launcher ----------------------------------------------------- #
install_bin() {
  local src="$1" dst="$BIN_DIR/$(basename "$1")"
  [[ "$src" == "$dst" ]] && return 0
  sudo install -o "$RUN_USER" -g "$RUN_USER" -m 0755 "$src" "$dst"
  log "installed $(basename "$src")"
}
install_bin "$VALIDATOR_BIN"
install_bin "$KEYGEN_BIN"
[[ -n "$LEDGER_TOOL_BIN" ]] && install_bin "$LEDGER_TOOL_BIN"
sudo install -o "$RUN_USER" -g "$RUN_USER" -m 0755 "$SCRIPT_DIR/start-validator.sh" "$BIN_DIR/start-validator.sh"
[[ -f "$SCRIPT_DIR/run.txt" ]] && sudo install -o "$RUN_USER" -g "$RUN_USER" -m 0644 "$SCRIPT_DIR/run.txt" "$BIN_DIR/run.txt"

# ---- migrate ledger + config (same filesystem => instant rename) ------------- #
migrate() {
  local what="$1" src="$SRC_BUILD/$1" dst="$DATA_DIR/$1"
  if [[ -e "$dst" ]] && [[ -n "$(ls -A "$dst" 2>/dev/null)" ]]; then
    log "$dst already populated — leaving it alone"
    return 0
  fi
  [[ -d "$src" ]] || { warn "nothing to migrate: $src does not exist"; return 0; }
  log "moving $src -> $dst"
  rmdir "$dst" 2>/dev/null || true
  mv "$src" "$dst"
}
migrate ledger
migrate config
chmod 0700 "$DATA_DIR/config"
chmod 0600 "$DATA_DIR"/config/*.json 2>/dev/null || true

# ---- systemd unit ------------------------------------------------------------ #
log "writing $UNIT_PATH ..."
sed -e "s|__USER__|$RUN_USER|g" \
    -e "s|__BIN_DIR__|$BIN_DIR|g" \
    -e "s|__DATA_DIR__|$DATA_DIR|g" \
    "$SCRIPT_DIR/gorbagana.service" | sudo tee "$UNIT_PATH" >/dev/null
sudo chmod 0644 "$UNIT_PATH"

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME" >/dev/null
log "enabled $SERVICE_NAME (starts on boot)"

if [[ "$START_SERVICE" == "true" ]]; then
  sudo systemctl start "$SERVICE_NAME"
  log "started $SERVICE_NAME"
fi

cat <<EOF

$(printf '\033[1;32m[install] DONE\033[0m')
  binaries : $BIN_DIR
  ledger   : $DATA_DIR/ledger
  keypairs : $DATA_DIR/config   (0700 -- BACK THIS UP)
  unit     : $UNIT_PATH
  identity : $IDENTITY_PUBKEY

Control it with:
  sudo systemctl status $SERVICE_NAME
  sudo systemctl stop $SERVICE_NAME
  sudo systemctl start $SERVICE_NAME
  sudo systemctl restart $SERVICE_NAME
  journalctl -u $SERVICE_NAME -f
EOF
