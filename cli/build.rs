// Version is tag-as-source: `make` derives it from `git describe` and passes it
// here as KAIROS_VERSION, so `kairos -V` matches the macOS app's bundle version
// and the git tag. A direct `cargo build` (no make) falls back to the Cargo pkg
// version — the tag is the source of truth, the Cargo version is only a floor.
fn main() {
    println!("cargo:rerun-if-env-changed=KAIROS_VERSION");
    let v = std::env::var("KAIROS_VERSION")
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rustc-env=KAIROS_VERSION={v}");
}
