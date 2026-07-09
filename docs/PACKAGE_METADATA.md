# Package Metadata / Overrides

Package-specific metadata is now stored in Postgres as `Portal.Catalog.PackageOverride` rows and managed by the portal/admin surface. The legacy root `package_metadata.json` file was imported during Phase 6 and removed.

## What overrides are for

Most packages do not need overrides. Add one when you need to:

1. Override automated testing with a forced status.
2. Add user-facing notes about special requirements or caveats.
3. Allow-list or deny-list Nerves systems for a package.
4. Maintain global dependency skip rules such as packages that depend on low-level Nerves system/toolchain packages.

## Stored fields

`Portal.Catalog.PackageOverride` stores:

- `package_name` — package name. The special `__global__` row stores global rules.
- `forced_status` — one of `:pass`, `:fail`, `:error`, `:skipped`, `:unknown`, or nil.
- `allow_systems` — list of Nerves system package names to include. Empty means no allow-list.
- `deny_systems` — list of Nerves system package names to exclude.
- `skip_if_depends_on` — list of dependency package names that should cause an automatic skip. Used on the `__global__` row.
- `notes` — free-form user-facing notes.

## Legacy import

For one-time imports from an old metadata file:

```bash
mix portal.import_overrides /path/to/package_metadata.json
```

The importer maps legacy fields as follows:

| Legacy JSON | DB field |
| --- | --- |
| `packages.<name>.forced_status` | `forced_status` (`"skip"` becomes `:skipped`) |
| `packages.<name>.allowed_systems` | `allow_systems` |
| `packages.<name>.denied_systems` | `deny_systems` |
| `packages.<name>.notes` | `notes` |
| `skip_if_depends_on` | `__global__.skip_if_depends_on` |

## System name format

System names should use full package names:

- `nerves_system_rpi4`
- `nerves_system_rpi3`
- `nerves_system_x86_64`
- `nerves_system_mangopi_mq_pro`
- `nerves_system_grisp2`

## Examples

### Hardware-specific skip

```elixir
%{
  package_name: "vintage_net_wifi",
  forced_status: :skipped,
  deny_systems: ["nerves_system_grisp2"],
  notes: "This package requires WiFi hardware and cannot be verified in the containerized build."
}
```

### Manually verified package

```elixir
%{
  package_name: "special_package",
  forced_status: :pass,
  notes: "Manually verified on supported Nerves devices."
}
```

### Global dependency skip rules

```elixir
%{
  package_name: "__global__",
  skip_if_depends_on: ["nerves_system_br", "nerves_toolchain_ctng"],
  notes: "Global dependency skip rules."
}
```
