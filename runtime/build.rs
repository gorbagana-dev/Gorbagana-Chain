fn main() {
    // The single-node consensus lock in `src/epoch_stakes.rs` reads the validator
    // identity from `option_env!("GORB_SINGLE_NODE_IDENTITY")` at compile time.
    // Cargo does not track `option_env!` inputs automatically, so declare it here to
    // force a rebuild whenever the locked identity changes.
    println!("cargo:rerun-if-env-changed=GORB_SINGLE_NODE_IDENTITY");
}
