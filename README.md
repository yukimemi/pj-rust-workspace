# pj-rust-workspace

Cargo workspace boilerplate for [kata](https://github.com/yukimemi/kata) consumers.

Compose under `pj-base` + `pj-rust`. Do NOT also apply `pj-rust-cli`
on a workspace root — its `release.yml.template` hard-codes a single
binary name (`BIN_NAME: ${{ github.event.repository.name }}`) that
doesn't fit a multi-bin workspace. Apply `pj-rust-cli` per-member
under `crates/<name>/` if any leaf crate ships standalone.

Adds three things that don't fit single-crate `pj-rust`:

- **`Cargo.toml` workspace skeleton** — `resolver = "2"`, empty
  `members = []`, shared `[workspace.package]` /
  `[workspace.dependencies]`, plus
  `[profile.dev] debug = "line-tables-only"` for the Windows MSVC
  PDB LIMIT (LNK1318) workaround.
- **`Makefile.toml` `[config]` fragment** — turns off cargo-make's
  workspace recursion. The yukimemi/* convention runs cargo at the
  workspace root with `--workspace` / `--all-targets`, so per-member
  recursion just duplicates work.
- **`release.yml`** — workspace-shaped tag-driven release pipeline.
  Cross-builds every `[[bin]]` in the workspace across the standard
  4-target matrix (linux x86_64, win x86_64, macOS x86_64 +
  aarch64), uploads them to a single GitHub Release with
  `generate_release_notes: true` (auto-summary of PRs since the
  previous tag), and `cargo publish --locked`es every workspace
  member whose `publish` field allows crates.io — in topological
  dependency order so a crate that depends on another doesn't try
  to publish before its dep is on the registry. Project-specific
  bits (bin names, publishable members, inter-crate dep order) are
  discovered from `cargo metadata` at run time so the same file
  works across every consumer with no rendering. Requires the
  `CARGO_REGISTRY_TOKEN` secret in each consumer repo; set
  `package.publish = false` on every member to skip the publish
  job entirely.

## Usage

Direct (composing pj-base + pj-rust + pj-rust-workspace yourself):

```powershell
mkdir my-workspace && cd my-workspace
kata init github.com/yukimemi/pj-rust-workspace --non-interactive
```

Via the bundle in [yukimemi/pj-presets](https://github.com/yukimemi/pj-presets)
(adds `pj-base` + `pj-rust` + `pj-rust-workspace` in one shot):

```powershell
kata init github.com/yukimemi/pj-presets:rust-workspace --non-interactive
```

After `kata init`:

1. Fill in `[workspace.package]` (`version`, `license`, `repository`,
   `authors`, …) in `Cargo.toml`.
2. Add member crates under `crates/` and list them in
   `members = ["crates/<name>", …]`.
3. Use `cargo make check` / `cargo make fmt` from pj-rust's
   `Makefile.toml` — they now operate at the workspace root.

## Related

- [`yukimemi/pj-base`](https://github.com/yukimemi/pj-base) — universal
  boilerplate (AGENTS.md, .gitignore, GHA workflows, …)
- [`yukimemi/pj-rust`](https://github.com/yukimemi/pj-rust) — Rust
  language layer (toolchain pin, rustfmt / clippy policy, base
  `Makefile.toml` task surface, `ci.yml.tera` with matrix-clippy +
  coverage)
- [`yukimemi/pj-rust-cli`](https://github.com/yukimemi/pj-rust-cli) —
  CLI-specific extras (.editorconfig, …)
- [`yukimemi/pj-presets`](https://github.com/yukimemi/pj-presets) —
  preset bundles that pull these together (`rust-cli`, `rust-lib`,
  `rust-workspace`, …)

## License

MIT.
