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
  workspace recursion. The convention here runs cargo at the
  workspace root with `--workspace` / `--all-targets`, so per-member
  recursion just duplicates work.
- **`release.yml`** — workspace-shaped tag-driven release pipeline.
  Builds every `[[bin]]` in the workspace across the standard
  4-target matrix (linux musl x86_64 + aarch64, win x86_64 msvc,
  macOS aarch64), uploads them to a single GitHub Release with
  `generate_release_notes: true` (auto-summary of PRs since the
  previous tag), and runs `cargo publish --locked` against every
  workspace member whose `publish` field allows crates.io — in
  topological dependency order so a crate that depends on another
  doesn't try to publish before its dep is on the registry. Project-specific
  bits (bin names, publishable members, inter-crate dep order) are
  discovered from `cargo metadata` at run time so the same file
  works across every consumer with no rendering. Requires the
  `CARGO_REGISTRY_TOKEN` secret in each consumer repo; set
  `package.publish = false` on every member to skip the publish
  job entirely. Registered `when = "always"`: upstream improvements
  to the pipeline (action bumps, jq fixes, …) flow into every
  consumer on the next `kata apply`. Custom release-time steps
  (slack notify, binary signing, SBOM generation, …) belong in a
  **separate sibling workflow** at
  `.github/workflows/release-extras.yml` (or any name that isn't
  `release.yml`) — that file isn't kata-managed, and GHA fires
  every workflow whose `on:` matches the tag push, so the two-file
  shape behaves identically to a merged single file at run time.

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
4. If members depend on each other *and* are published, add the
   version-pin check below.

## The internal version pin, and the check for it

A published member that another member depends on carries a `version`
as well as a `path`, because crates.io needs a requirement it can
resolve for somebody who is not building from your checkout:

```toml
[workspace.dependencies]
my-core = { path = "crates/my-core", version = "0.4.2" }
```

Nothing in Cargo makes that literal follow `[workspace.package]
version`, so a release bumps both — and forgetting fails *late*. The
requirement is a caret, so a stale pin keeps resolving through every
patch release and stops only at the first bump that crosses the minor,
with `candidate versions found which didn't match`, while you are
cutting the release.

Two repos on these templates met it: one failed mid-release three
versions after its pins were last right; the other had the hazard
written down in its own `AGENTS.md` — *"which is why this is easy to
forget"* — and had drifted four releases anyway. Prose was not enough,
so assert it.

Drop this in any member's `tests/`. `cargo test` already runs in CI and
it needs no toolchain a Rust workspace does not have, and it reads the
members out of the manifest rather than naming them, so it does not
need editing when the workspace grows. It expands a `members =
["crates/*"]` glob, and it asks for a `version` only on the internal
crates that are actually publishable — a workspace-only crate may
legitimately be depended on by `path` alone:

```rust
// crates/<any-member>/tests/check_versions.rs
// needs `toml = { workspace = true }` in that member's [dev-dependencies]
use std::fs;
use std::path::{Path, PathBuf};

use toml::{Table, Value};

fn workspace_root() -> PathBuf {
    // `CARGO_MANIFEST_DIR` is `crates/<name>`, so the root is two up.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("crates/<name> always has two ancestors")
        .to_path_buf()
}

/// A whole manifest.
///
/// `Table`, not `Value`: parsing into `Value` reads a single TOML
/// *value*, so a document starting `[workspace]` comes back as a failed
/// array rather than as the file.
fn manifest(path: &Path) -> Table {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    text.parse::<Table>()
        .unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

/// The dependency tables a member can declare, at the top level.
///
/// Target-specific tables (`[target.'cfg(…)'.dependencies]`) are not
/// walked: nothing here uses one for a sibling, and the rule this
/// enforces is about where the *version* lives, which a target table
/// would inherit from `[workspace.dependencies]` just the same.
const DEP_TABLES: [&str; 3] = ["dependencies", "dev-dependencies", "build-dependencies"];

/// Whether this manifest's crate can go to crates.io.
///
/// `publish = false` — or an empty allow-list — means it cannot, and a
/// workspace-only crate like that may be depended on by `path` alone.
/// Requiring a version of one would reject a manifest that is correct.
fn is_publishable(manifest: &Table) -> bool {
    match manifest.get("package").and_then(|p| p.get("publish")) {
        None => true,
        Some(Value::Boolean(allowed)) => *allowed,
        Some(Value::Array(registries)) => !registries.is_empty(),
        Some(_) => true,
    }
}

/// The member directories, with a trailing `/*` expanded.
///
/// `members = ["crates/*"]` is valid and common, and taking it literally
/// would look for `crates/*/Cargo.toml` and fail on a workspace that has
/// done nothing wrong. Only the trailing-star form is expanded, which is
/// the one cargo documents; anything else is passed through as written.
fn member_dirs(root: &Path, members: &[Value]) -> Vec<String> {
    let mut out = Vec::new();
    for member in members {
        let member = member.as_str().expect("a member entry is a string");
        let Some(parent) = member.strip_suffix("/*") else {
            out.push(member.to_string());
            continue;
        };
        let listing = fs::read_dir(root.join(parent))
            .unwrap_or_else(|e| panic!("read {parent}/ to expand `{member}`: {e}"));
        for entry in listing.flatten() {
            if entry.path().join("Cargo.toml").is_file() {
                out.push(format!("{parent}/{}", entry.file_name().to_string_lossy()));
            }
        }
    }
    out
}

#[test]
fn internal_pins_match_the_workspace_version() {
    let root = workspace_root();
    let root_manifest = manifest(&root.join("Cargo.toml"));
    let workspace = root_manifest
        .get("workspace")
        .expect("the root manifest has a [workspace] table");

    let version = workspace
        .get("package")
        .and_then(|p| p.get("version"))
        .and_then(Value::as_str)
        .expect("[workspace.package] version is set");

    // A dependency with a `path` is one of ours — an outside crate has
    // none. Found rather than named, so a new member is covered without
    // an edit here.
    let deps = workspace
        .get("dependencies")
        .and_then(Value::as_table)
        .expect("[workspace.dependencies] exists");

    let mut checked = 0;
    for (name, dep) in deps {
        let Some(table) = dep.as_table() else {
            continue;
        };
        let Some(path) = table.get("path").and_then(Value::as_str) else {
            continue;
        };

        match table.get("version").and_then(Value::as_str) {
            Some(pinned) => {
                assert_eq!(
                    pinned, version,
                    "\n  {name} is pinned at {pinned} while the workspace is {version}.\n\
                     A release bumps `[workspace.package] version`; this does not follow it, \
                     so it has to be bumped in the same commit.\n"
                );
                checked += 1;
            }
            // No version is correct for a crate that never goes to
            // crates.io — there is no requirement for anyone to resolve.
            // Only the publishable ones are held to the rule.
            None => assert!(
                !is_publishable(&manifest(&root.join(path).join("Cargo.toml"))),
                "{name} is published but depended on by path alone. crates.io needs \
                 a requirement it can resolve for somebody who is not building from \
                 this checkout, so it needs `version = \"{version}\"` too."
            ),
        }
    }

    assert!(
        checked >= 1,
        "expected at least one internal pin to check and found none — have the \
         workspace's own crates left `[workspace.dependencies]`?"
    );
}

#[test]
fn members_inherit_the_workspace_version() {
    let root = workspace_root();
    let root_manifest = manifest(&root.join("Cargo.toml"));
    let members = root_manifest
        .get("workspace")
        .and_then(|w| w.get("members"))
        .and_then(Value::as_array)
        .expect("[workspace] members is set");
    assert!(!members.is_empty(), "no workspace members to check");

    for member in member_dirs(&root, members) {
        let path = root.join(&member).join("Cargo.toml");
        let parsed = manifest(&path);
        let package = parsed
            .get("package")
            .unwrap_or_else(|| panic!("{member} has no [package] table"));

        // `{ workspace = true }`, not a string. A hardcoded version is a
        // second place a release has to remember, and it is the case the
        // substring version of this test could not see.
        let inherits = package
            .get("version")
            .and_then(Value::as_table)
            .and_then(|t| t.get("workspace"))
            .and_then(Value::as_bool)
            == Some(true);
        assert!(
            inherits,
            "{member} sets its own version ({:?}) instead of inheriting it with \
             `version.workspace = true`",
            package.get("version")
        );

        // A sibling reached for by path in a member manifest is the shape
        // `[workspace.dependencies]` exists to replace — it puts the
        // version somewhere other than the one place.
        for table in DEP_TABLES {
            let Some(deps) = parsed.get(table).and_then(Value::as_table) else {
                continue;
            };
            for (name, dep) in deps {
                let has_path = dep.as_table().is_some_and(|t| t.contains_key("path"));
                assert!(
                    !has_path,
                    "{member} declares {name} by path under [{table}]; put it in \
                     `[workspace.dependencies]` and use `{name}.workspace = true`, \
                     so the version behind it stays in one place"
                );
            }
        }
    }
}
```

Not shipped as a `[[file]]`: the template does not know your crate
names, and a workspace root is a virtual manifest with nowhere to put a
test. Copy it into whichever member is the base one.

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
