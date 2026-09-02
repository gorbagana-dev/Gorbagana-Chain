#!/usr/bin/env python3
"""
Convert an `agave-ledger-tool accounts --output json --encoding base64` dump
(taken from the old Gorbagana snapshot) into `solana-genesis`
`--primordial-accounts-file` YAML chunks for a fresh, slot-0 relaunch.

Design goals (see relaunch/README.md for the full rationale):

  * Preserve real user state: wallets (SOL), SPL-Token / Token-2022 accounts,
    mints, Metaplex metadata, name-service entries, and every program-owned PDA
    keep their exact lamports + data.
  * Guarantee single-validator liveness: drop the old Stake and Vote accounts so
    the only activated stake on the new chain is the new bootstrap validator.
  * Stay compatible with the current (4.2.x) runtime: let `solana-genesis`
    create the native builtins, sysvars and a fresh feature set instead of
    importing stale ones (old feature accounts carry activation slots ~79.8M,
    which would read as "not yet activated" on a slot-0 chain).
  * Avoid program conflicts: the curated program set that the genesis step
    installs from real .so files is skipped here; any *other* user-deployed
    program is imported, with its ProgramData deploy-slot rewritten to 0 so it
    is invokable from slot 1 (otherwise it would look "deployed in the future").

Output YAML entry shape consumed by genesis' `load_genesis_accounts`:

    "<pubkey>":
      balance: <lamports u64>
      owner: "<owner pubkey>"
      data: "<base64>"        # or "~" for an empty account
      executable: <bool>
"""

from __future__ import annotations

import argparse
import base64
import os
import sys
from typing import Iterator, Optional, Tuple

# ---- Well-known program ids -------------------------------------------------

SYSTEM_PROGRAM = "11111111111111111111111111111111"
NATIVE_LOADER = "NativeLoader1111111111111111111111111111111"
STAKE_PROGRAM = "Stake11111111111111111111111111111111111111"
VOTE_PROGRAM = "Vote111111111111111111111111111111111111111"
FEATURE_PROGRAM = "Feature111111111111111111111111111111111111"
SYSVAR_OWNER = "Sysvar1111111111111111111111111111111111111"
STAKE_CONFIG = "StakeConfig11111111111111111111111111111111"

BPF_LOADER_UPGRADEABLE = "BPFLoaderUpgradeab1e11111111111111111111111"
BPF_LOADER_2 = "BPFLoader2111111111111111111111111111111111"
BPF_LOADER_1 = "BPFLoader1111111111111111111111111111111111"
LOADER_V4 = "LoaderV411111111111111111111111111111111111"

LOADER_OWNERS = {BPF_LOADER_UPGRADEABLE, BPF_LOADER_2, BPF_LOADER_1, LOADER_V4}

# Owners whose accounts are recreated by genesis (builtins / consensus / feature
# gates / sysvars) and must NOT be imported.
SKIP_OWNERS = {
    NATIVE_LOADER,
    STAKE_PROGRAM,
    VOTE_PROGRAM,
    FEATURE_PROGRAM,
    SYSVAR_OWNER,
}

# Individual addresses recreated by genesis regardless of owner.
SKIP_PUBKEYS = {STAKE_CONFIG}

# bincode discriminant (u32 LE) for UpgradeableLoaderState::ProgramData
PROGRAMDATA_DISCRIMINATOR = (3).to_bytes(4, "little")
# ...::Program
PROGRAM_DISCRIMINATOR = (2).to_bytes(4, "little")
# ProgramData header: [u32 disc][u64 slot][Option<Pubkey>]; slot is bytes 4..12.
PROGRAMDATA_SLOT_OFFSET = 4

_B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(data: bytes) -> str:
    n = int.from_bytes(data, "big")
    out = ""
    while n > 0:
        n, rem = divmod(n, 58)
        out = _B58_ALPHABET[rem] + out
    pad = 0
    for b in data:
        if b == 0:
            pad += 1
        else:
            break
    return ("1" * pad) + out


# ---- JSON input iteration ---------------------------------------------------


def iter_accounts(path: str) -> Iterator[dict]:
    """Yield each element of the top-level "accounts" array.

    Uses ijson for constant-memory streaming when available, otherwise falls
    back to a full json.load (needs ~2-3x the file size in RAM).
    """
    try:
        import ijson  # type: ignore

        with open(path, "rb") as fh:
            yield from ijson.items(fh, "accounts.item")
        return
    except ImportError:
        pass

    import json

    with open(path, "r") as fh:
        doc = json.load(fh)
    yield from doc.get("accounts", [])


def account_fields(entry: dict) -> Tuple[str, int, str, bool, bytes]:
    pubkey = entry["pubkey"]
    acct = entry["account"]
    lamports = int(acct["lamports"])
    owner = acct["owner"]
    executable = bool(acct["executable"])
    data_field = acct.get("data")
    raw = b""
    if isinstance(data_field, list) and data_field and data_field[0]:
        raw = base64.b64decode(data_field[0])
    elif isinstance(data_field, str) and data_field:
        raw = base64.b64decode(data_field)
    return pubkey, lamports, owner, executable, raw


def load_install_ids(path: Optional[str]) -> set:
    if not path:
        return set()
    ids = set()
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                ids.add(line)
    return ids


def patch_programdata_slot(raw: bytes) -> Tuple[bytes, bool]:
    """Rewrite a ProgramData account's deploy slot to 0 so it is usable at slot 1+."""
    if len(raw) >= PROGRAMDATA_SLOT_OFFSET + 8 and raw[:4] == PROGRAMDATA_DISCRIMINATOR:
        patched = (
            raw[:PROGRAMDATA_SLOT_OFFSET]
            + (0).to_bytes(8, "little")
            + raw[PROGRAMDATA_SLOT_OFFSET + 8 :]
        )
        return patched, True
    return raw, False


def yaml_escape(s: str) -> str:
    # base58 / base64 never contain quotes or backslashes; still be safe.
    return s.replace("\\", "\\\\").replace('"', '\\"')


class ChunkWriter:
    def __init__(self, out_dir: str, prefix: str, chunk_size: int):
        self.out_dir = out_dir
        self.prefix = prefix
        self.chunk_size = chunk_size
        self.index = 0
        self.count_in_chunk = 0
        self.fh = None
        self.files: list[str] = []

    def _open_new(self):
        if self.fh:
            self.fh.close()
        name = os.path.join(self.out_dir, f"{self.prefix}-{self.index:04d}.yml")
        self.fh = open(name, "w")
        self.fh.write("---\n")
        self.files.append(name)
        self.index += 1
        self.count_in_chunk = 0

    def write(self, pubkey: str, lamports: int, owner: str, executable: bool, data_b64: str):
        if self.fh is None or self.count_in_chunk >= self.chunk_size:
            self._open_new()
        self.fh.write(f'"{yaml_escape(pubkey)}":\n')
        self.fh.write(f"  balance: {lamports}\n")
        self.fh.write(f'  owner: "{yaml_escape(owner)}"\n')
        self.fh.write(f'  data: "{data_b64}"\n')
        self.fh.write(f"  executable: {'true' if executable else 'false'}\n")
        self.count_in_chunk += 1

    def close(self):
        if self.fh:
            self.fh.close()
            self.fh = None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("accounts_json", help="agave-ledger-tool accounts --output json dump")
    ap.add_argument("--out-dir", required=True, help="directory to write primordial-*.yml chunks")
    ap.add_argument("--prefix", default="primordial", help="chunk filename prefix")
    ap.add_argument("--chunk-size", type=int, default=20000, help="accounts per YAML chunk")
    ap.add_argument(
        "--install-program-ids-file",
        help="file with program ids (one per line) that genesis installs; "
        "these programs + their ProgramData are skipped here to avoid conflicts",
    )
    ap.add_argument(
        "--keep-stake-vote",
        action="store_true",
        help="import old Stake/Vote accounts too (NOT recommended for single-node: "
        "breaks finalization unless the bootstrap stake exceeds 2x the old stake)",
    )
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    install_ids = load_install_ids(args.install_program_ids_file)

    skip_owners = set(SKIP_OWNERS)
    if args.keep_stake_vote:
        skip_owners.discard(STAKE_PROGRAM)
        skip_owners.discard(VOTE_PROGRAM)

    # ---- Pass 1: map install-program ids -> their ProgramData address --------
    install_programdata = set()
    for entry in iter_accounts(args.accounts_json):
        pubkey, _lamports, owner, _exe, raw = account_fields(entry)
        if (
            owner == BPF_LOADER_UPGRADEABLE
            and pubkey in install_ids
            and len(raw) >= 36
            and raw[:4] == PROGRAM_DISCRIMINATOR
        ):
            install_programdata.add(b58encode(raw[4:36]))

    # ---- Pass 2: emit primordial chunks -------------------------------------
    writer = ChunkWriter(args.out_dir, args.prefix, args.chunk_size)
    stats = {
        "seen": 0,
        "imported": 0,
        "lamports_imported": 0,
        "skip_owner": 0,
        "skip_install_program": 0,
        "skip_install_programdata": 0,
        "skip_pubkey": 0,
        "programdata_patched": 0,
        "wallets": 0,
        "token_accounts": 0,
        "programs_imported": 0,
    }

    for entry in iter_accounts(args.accounts_json):
        stats["seen"] += 1
        pubkey, lamports, owner, executable, raw = account_fields(entry)

        if owner in skip_owners:
            stats["skip_owner"] += 1
            continue
        if pubkey in SKIP_PUBKEYS:
            stats["skip_pubkey"] += 1
            continue
        if pubkey in install_ids:
            stats["skip_install_program"] += 1
            continue
        if pubkey in install_programdata:
            stats["skip_install_programdata"] += 1
            continue

        if owner in LOADER_OWNERS:
            raw, patched = patch_programdata_slot(raw)
            if patched:
                stats["programdata_patched"] += 1
            stats["programs_imported"] += 1
        elif owner == SYSTEM_PROGRAM:
            stats["wallets"] += 1

        data_b64 = base64.b64encode(raw).decode() if raw else "~"
        writer.write(pubkey, lamports, owner, executable, data_b64)
        stats["imported"] += 1
        stats["lamports_imported"] += lamports

    writer.close()

    sol = stats["lamports_imported"] / 1_000_000_000
    print("=== primordial conversion summary ===", file=sys.stderr)
    for k in (
        "seen",
        "imported",
        "wallets",
        "programs_imported",
        "programdata_patched",
        "skip_owner",
        "skip_install_program",
        "skip_install_programdata",
        "skip_pubkey",
    ):
        print(f"  {k:26s}: {stats[k]}", file=sys.stderr)
    print(f"  {'lamports_imported':26s}: {stats['lamports_imported']} ({sol:.6f} SOL)", file=sys.stderr)
    print(f"  {'chunk_files':26s}: {len(writer.files)} -> {args.out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
