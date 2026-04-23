# Package Metadata Configuration

## Overview

The `package_metadata.json` file allows you to configure special handling for individual packages in the Nerves Compatibility Checker. This file lives at the root of the repository and is checked into version control, allowing the community to contribute package-specific configuration via pull requests.

## Location

```
/package_metadata.json
```

## When to Use

Most packages do not need entries in this file. Add an entry when you need to:

1. **Override automated testing** - Mark a package with a forced status (pass/fail/skip)
2. **Add usage notes** - Provide important information to users about special requirements
3. **Filter systems** - Specify which Nerves systems should or shouldn't test the package

## File Format

```json
{
  "packages": {
    "package_name": {
      "forced_status": "pass|fail|skip",
      "notes": "User-facing information about this package",
      "allowed_systems": ["system1", "system2"],
      "denied_systems": ["system3"]
    }
  }
}
```

### Fields

#### `forced_status` (optional)

One of: `"pass"`, `"fail"`, or `"skip"`

When set, automated compatibility testing is bypassed and this status is shown instead. The package page will display a notice that the status was administratively set.

**Use cases:**
- Package requires hardware not testable in containers (e.g., GPIO, WiFi)
- Package has been manually verified on Nerves
- Package is known to be incompatible and testing would waste resources

**Example:**
```json
{
  "forced_status": "skip"
}
```

#### `notes` (optional)

Free-form text displayed prominently on the package's detail page.

**Use cases:**
- Explain why a package has a forced status
- Document special requirements (e.g., "Requires WiFi hardware")
- Provide usage tips for Nerves developers
- Link to related documentation or issues

**Example:**
```json
{
  "notes": "This package requires WiFi hardware. On Nerves devices, ensure your target system has WiFi support and required firmware blobs."
}
```

#### `allowed_systems` (optional)

Array of Nerves system package names. If specified (non-empty), only these systems will be tested.

**Use cases:**
- Package only works on specific architectures
- Package requires hardware only available on certain boards

**Example:**
```json
{
  "allowed_systems": ["nerves_system_rpi4", "nerves_system_rpi3"]
}
```

#### `denied_systems` (optional)

Array of Nerves system package names. These systems will be excluded from testing.

**Use cases:**
- Package is known to fail on specific systems
- Package requires features not available on certain platforms

**Example:**
```json
{
  "denied_systems": ["nerves_system_grisp2"]
}
```

### System Name Format

System names should use the full package name format:
- `nerves_system_rpi4`
- `nerves_system_rpi3`
- `nerves_system_x86_64`
- `nerves_system_mangopi_mq_pro`
- `nerves_system_grisp2`
- etc.

Currently tested systems (default list):
- `nerves_system_rpi4`
- `nerves_system_mangopi_mq_pro`
- `nerves_system_x86_64`

## Complete Examples

### Example 1: WiFi Package (Skip Testing with Notes)

```json
{
  "packages": {
    "vintage_net_wifi": {
      "forced_status": "skip",
      "notes": "This package requires WiFi hardware and cannot be tested in a containerized environment.\n\nOn real Nerves devices:\n- Ensure your target system has WiFi support\n- Include required WiFi firmware in your project\n- Configure network settings per VintageNet documentation",
      "allowed_systems": [],
      "denied_systems": ["nerves_system_grisp2"]
    }
  }
}
```

### Example 2: Architecture-Specific Package

```json
{
  "packages": {
    "some_x86_only_package": {
      "forced_status": null,
      "notes": "This package contains x86-specific assembly code.",
      "allowed_systems": ["nerves_system_x86_64"],
      "denied_systems": []
    }
  }
}
```

### Example 3: Manually Verified Package

```json
{
  "packages": {
    "special_package": {
      "forced_status": "pass",
      "notes": "This package has been manually verified to work on Nerves. Automated testing is disabled because it requires external services that aren't available in the test environment.",
      "allowed_systems": [],
      "denied_systems": []
    }
  }
}
```

### Example 4: Deny Specific System

```json
{
  "packages": {
    "some_package": {
      "forced_status": null,
      "notes": "Known compatibility issue with GRiSP 2. See https://github.com/project/issues/123 for details.",
      "allowed_systems": [],
      "denied_systems": ["nerves_system_grisp2"]
    }
  }
}
```

## Contributing

To add or update package metadata:

1. Edit `package_metadata.json` in the repository root
2. Add your package entry following the format above
3. Provide clear notes explaining the reason for the configuration
4. Submit a pull request

Please include:
- **Why** the package needs special handling
- **What** users should know about using it on Nerves
- Links to relevant issues or documentation

## Implementation Details

### How It Works

1. **Orchestrator**: Checks `forced_status` before scheduling tests. If set, creates a forced result instead of running the worker.
2. **Runner/Worker**: Receives `systems_filter` in job payload, limiting which systems are tested.
3. **Site Generator**: Loads metadata and displays notes/forced status on package detail pages.

### Files Involved

- `/package_metadata.json` - The configuration file (this document)
- `/compat/lib/compat/package_metadata.ex` - Module that loads and parses the file
- `/orchestrator/lib/orchestrator/processor.ex` - Checks forced status and filters systems
- `/runner/lib/ncc_runner/job.ex` - Passes systems_filter to worker
- `/worker/lib/ncc_worker/worker.ex` - Filters systems based on systems_filter
- `/site/lib/site/generator.ex` - Loads metadata for display
- `/site/priv/templates/package.html.eex` - Displays notes and forced status

### Schema Validation

The file is loaded by `Compat.PackageMetadata.load/1` which:
- Returns empty metadata if file doesn't exist (graceful degradation)
- Ignores entries starting with `_` (allows schema documentation in file)
- Validates `forced_status` is one of: `pass`, `fail`, `skip`
- Defaults empty arrays for `allowed_systems` and `denied_systems`

## FAQ

**Q: What happens if I don't add a package to this file?**
A: Nothing! The vast majority of packages don't need special handling. The system works perfectly fine without any entries in `package_metadata.json`.

**Q: Can I use both `allowed_systems` and `denied_systems`?**
A: Yes, but typically you'd use one or the other:
- If `allowed_systems` is non-empty, only those systems are tested (deny list is also applied)
- If `allowed_systems` is empty (or not set), all systems are tested except those in `denied_systems`

**Q: How do I know which systems are available?**
A: Check the `discover_systems` function in `/worker/lib/ncc_worker/worker.ex` for the current list.

**Q: Will forced status packages ever be retested?**
A: No, not automatically. The forced status is permanent until someone removes or changes it in the metadata file.

**Q: Can notes contain Markdown or HTML?**
A: Currently notes are displayed as plain text with `pre-wrap` formatting (preserves line breaks). HTML will be escaped for security.

**Q: What if a package is temporarily broken?**
A: Consider using `forced_status: "skip"` with notes explaining the issue and linking to a tracking issue. This prevents wasted test runs while making the situation visible to users.
