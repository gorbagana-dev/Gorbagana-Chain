<p align="center">
  <a href="https://www.gorbagana.wtf">
    <img alt="Gorbagana" src="https://www.gorbagana.wtf/images/gorbagio-g.avif" width="320" />
  </a>
</p>

<h1 align="center">THE TRASH CHAIN</h1>

<p align="center">
  <a href="https://www.gorbagana.wtf/#what-is-gor">Website</a> ·
  <a href="https://docs.gorbagana.wtf/">Docs</a> ·
  <a href="https://docs.gorbagana.wtf/">Explorer &amp; Tools</a>
</p>

# What is Gorbagana?

Gorbagana is a high-performance blockchain network forked from Solana's
codebase, designed to combine meme-culture energy with serious infrastructure
capabilities — it's all trash!

Most chains are centralized, have insider MEV, and are exploitable to an extent.
Gorbagana flips the idea of a "trash chain" on its head: it **embraces
centralization transparently** and gives the power back to the community to use
it for games, fun experiments, and fair on-chain mechanics.

## The technical trash

Built on Solana's proven architecture, Gorbagana inherits:

- **Proof of History (PoH)** — a cryptographic clock for transaction ordering
- **Tower BFT** — Byzantine Fault Tolerance optimized for PoH
- **Turbine** — block propagation protocol for fast network communication
- **Gulf Stream** — mempool-less transaction forwarding
- **Sealevel** — parallel smart-contract runtime for high throughput
- **Pipelining** — transaction processing across validation stages

## Key network characteristics

- **Native currency:** `$GOR`
- **Speed:** sub-second finality with high throughput
- **Smart contracts:** full compatibility with the Solana Program Library (SPL) — soon the Trash Program Library (TPL)
- **Block time:** lower than Solana, produced by a single network validator
- **Fees:** minimal transaction costs paid in `$GOR`

## Current state

Gorbagana currently runs on **Testnet v1** — a stable, production-ready test
environment processing real transactions — while the team prepares **Testnet v2
(Devnet)** and finally **Mainnet**. See the
[Network History](https://docs.gorbagana.wtf/) for the full timeline.

# Building

## 1. Install rustc, cargo and rustfmt

```bash
curl https://sh.rustup.rs -sSf | sh
source $HOME/.cargo/env
rustup component add rustfmt
```

The `rust-toolchain.toml` file pins a specific rust version; cargo will install
it automatically if needed.

On Ubuntu you may also need:

```bash
sudo apt-get update
sudo apt-get install libssl-dev libudev-dev pkg-config zlib1g-dev llvm clang cmake make libprotobuf-dev protobuf-compiler libclang-dev
```

On Fedora:

```bash
sudo dnf install openssl-devel systemd-devel pkg-config zlib-devel llvm clang cmake make protobuf-devel protobuf-compiler perl-core libclang-dev
```

## 2. Get the source and build

```bash
git clone https://github.com/gorbagana-dev/Gorbagana-Chain.git
cd Gorbagana-Chain
./cargo build --release
```

> [!NOTE]
> A plain `./cargo build` produces a debug binary that is **not suitable for
> running a real validator**. Use `--release` for test/production nodes.

## 3. Grant XDP capabilities (Linux only)

XDP transmit is enabled on Linux by default and needs extra capabilities:

```bash
sudo setcap 'cap_net_admin,cap_net_raw+eip' <path-to-agave-validator-binary>
```

# Running a single validator (trash node)

To relaunch Gorbagana as a single validator that carries over full account state
at slot 0 with zero inflation, see [`relaunch/README.md`](relaunch/README.md).

# Community

- Website: https://www.gorbagana.wtf/#what-is-gor
- Documentation: https://docs.gorbagana.wtf/

# License

Apache-2.0. See [LICENSE](LICENSE).
