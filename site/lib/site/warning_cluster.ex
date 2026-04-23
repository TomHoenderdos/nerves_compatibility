defmodule Site.WarningCluster do
  @moduledoc """
  Companion to Site.FailureCluster: groups packages by non-fatal quality
  signals — things that pass compatibility checks but a Nerves user should
  be aware of (firmware reproducibility, runtime side effects, brittle
  dependencies on host shell tools, etc.).

  Each warning rule examines either a beam_scan flag or a per-system
  property (e.g. `deterministic`) and produces a list of affected
  packages. A single package may match multiple warnings.

  Source data is the parsed packages_by_version index — same as the
  dashboard tiles — so this is package-level (latest version per
  package) rather than per-system-result like FailureCluster.
  """

  @type entry :: %{
          package: String.t(),
          version: String.t(),
          link: String.t(),
          evidence: [String.t()]
        }

  @type warning :: %{
          id: atom(),
          title: String.t(),
          hint: String.t(),
          count: non_neg_integer(),
          entries: [entry()]
        }

  @doc """
  Compute the list of warnings, ranked by count desc. Empty warnings are
  dropped — if no package triggers a rule, that rule isn't shown.
  """
  @spec compute([{String.t(), map()}]) :: [warning()]
  def compute(packages) do
    rules()
    |> Enum.map(fn rule ->
      allow = MapSet.new(rule[:allow_list] || [])

      entries =
        packages
        |> Enum.flat_map(fn {name, pkg} ->
          cond do
            MapSet.member?(allow, name) -> []
            true ->
              case rule.detect.(name, pkg) do
                nil -> []
                entry -> [entry]
              end
          end
        end)
        |> Enum.sort_by(& &1.package)

      %{
        id: rule.id,
        title: rule.title,
        hint: rule.hint,
        count: length(entries),
        entries: entries
      }
    end)
    |> Enum.reject(&(&1.count == 0))
    |> Enum.sort_by(&{-&1.count, &1.title})
  end

  # Per-rule allow-lists: packages where the warning's pattern is
  # legitimate use rather than a smell. Hardcoded here for now; if the
  # lists get long they'll move into package_metadata.json.
  defp rules() do
    [
      %{
        id: :writes_to_source,
        title: "Writes to its source directory during build",
        hint:
          "The package's build step wrote files into `deps/<pkg>/` (its own source tree) rather than staying inside `MIX_BUILD_PATH`. Bad form on Nerves because those stray artifacts persist across `MIX_TARGET` switches — a NIF compiled for rpi4 stays in source and breaks the x86_64 build that follows.",
        allow_list: [],
        detect: &detect_source_changes/2
      },
      %{
        id: :non_deterministic,
        title: "Non-deterministic build",
        hint:
          "Repeated builds of this package's source produced different binaries — its compiled output isn't reproducible. Breaks firmware-image determinism (you can't audit that two builds of the same source produced the same firmware) and complicates debugging.",
        allow_list: [],
        detect: &detect_non_deterministic/2
      },
      %{
        id: :halt,
        title: "Calls :erlang.halt / System.halt",
        hint:
          "Package code calls into a function that halts the BEAM VM. On a Nerves device that means the firmware reboots — usually surprising unless this is intentionally a reboot helper.",
        allow_list: ~w(elixir iex mix nerves_runtime nerves_pack toolshed shoehorn),
        detect: detector_for_flag(:halt)
      },
      %{
        id: :shell,
        title: "Uses System.shell / :os.cmd",
        hint:
          "Spawns a shell to run commands (System.shell/:os.cmd), as opposed to executing a binary directly with Port.open/System.cmd. Brittle — the target shell may not exist or behave like the dev host — and a shell-injection surface for any user-provided arguments.",
        allow_list: ~w(elixir mix iex toolshed),
        detect: detector_for_flag(:shell)
      }
    ]
  end

  # -- detectors -----------------------------------------------------------

  defp detect_source_changes(name, pkg) do
    case pkg.source_changes do
      %{changed: true} = sc ->
        samples =
          (List.wrap(sc[:added]) ++ List.wrap(sc[:modified]))
          |> Enum.take(4)

        entry(name, pkg, evidence: samples)

      _ ->
        nil
    end
  end

  defp detect_non_deterministic(name, pkg) do
    affected_systems =
      (pkg.systems || %{})
      |> Enum.filter(fn {_key, sys} -> sys.deterministic == false end)
      |> Enum.map(fn {_key, sys} -> Site.Architecture.label(sys.system_pkg) end)
      |> Enum.sort()
      |> Enum.uniq()

    case affected_systems do
      [] -> nil
      systems -> entry(name, pkg, evidence: ["non-deterministic on: " <> Enum.join(systems, ", ")])
    end
  end

  defp detector_for_flag(flag_key) when is_atom(flag_key) do
    fn name, pkg ->
      scan = pkg.beam_scan

      cond do
        is_nil(scan) ->
          nil

        flag?(scan, flag_key) ->
          samples =
            scan
            |> Map.get(:samples, %{})
            |> Map.get(flag_key, [])
            |> Enum.take(3)

          entry(name, pkg, evidence: samples)

        true ->
          nil
      end
    end
  end

  defp flag?(%{flags: flags}, key) when is_map(flags) do
    Map.get(flags, key) == true or Map.get(flags, Atom.to_string(key)) == true
  end

  defp flag?(_, _), do: false

  defp entry(name, pkg, opts) do
    version = pkg.version || pkg.latest_version

    link =
      if version do
        "packages/#{String.replace("#{name}@#{version}", "/", "_")}.html"
      else
        "packages/#{String.replace(name, "/", "_")}.html"
      end

    %{
      package: name,
      version: version,
      link: link,
      evidence: Keyword.get(opts, :evidence, [])
    }
  end
end
