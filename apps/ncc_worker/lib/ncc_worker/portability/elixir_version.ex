defmodule NccWorker.Portability.ElixirVersion do
  @moduledoc """
  The Elixir-version rule of the compile-time trace (precompiled portability
  spec, R1 step 4, "Elixir version"). A client takes a build made on Elixir
  x.y.N on any x.y.M with M >= N, so compile-time code may read the Elixir
  version only in a way that gives the same answer for every such patch.

  Per window (the package's, a closure dependency's, or outside every
  window), among the `elixir_version` observations package or dependency
  code makes (not the toolchain's own, `first_kind` "toolchain"; a missing
  `first_kind` counts as the package's):

    * `System.build_info/0` refuses: it carries the build's revision and
      date, not only the version;
    * `System.compiled_endianness/0` refuses: it is the byte order of the
      machine that compiled the Elixir install, not the running VM's
      (`System.endianness/0`, an `endian` compile input a client compares),
      and no client can check it;
    * every `Version.match?/2` or `Version.compare/2` call one of whose
      arguments is exactly the built version must give the same result for
      the built version and every x.y.P final release from the built patch
      up to x.y.99 (and at least the next patch); `Version.match?/3` (its
      options are not traced) never does, and neither does a call whose
      other argument is not a literal string or does not parse;
    * there must be at least as many such calls as `System.version/0` reads,
      so a read used any other way (a string compare, `String.split/2`, a
      comparison against a `Version` struct the tracer cannot render)
      refuses.

  A comparison made on a line of a dependency's `mix.exs` that
  `NccWorker.Portability.MixExsSlice.direct_version_line?/3` accepts (the
  observation's `"series"`) must also give the same result for every final
  patch x.y.0 to x.y.99: its result picks the project's configuration, so a
  requirement that cuts inside the minor refuses even above the built
  patch.

  Reviewed reads are let through (`reviewed_apps/2`, `@reviewed_reads`): a
  window whose `System.version/0` reads are exactly the reviewed sites of
  its app's release, each read once, at the reviewed file and line of a
  module body, with the reviewed frame kind, in an app whose locked release
  is the reviewed version with the reviewed outer checksum and whose source
  tree matched that verified tarball before the compile
  (`NccWorker.Portability.Trees`). Each site's reviewed comparison is
  evaluated again over the built minor's patches and pre-releases. Those
  reads and the `Version.match?/2` and `Version.compare/2` calls made at
  the same sites are dropped; every other observation of the window is
  judged as above.

  A refusal, `compile-time Elixir patch dependence: ...`, belongs to its
  window: in the package's it refuses the package, in a dependency's it
  taints that dependency (R3). Reads to judge with no usable Elixir version
  in the trace's start line are a problem ("could not be judged"), never a
  pass.
  """

  @prefix "compile-time Elixir patch dependence: "
  @judged ["Version.match?/2", "Version.compare/2"]
  @last_patch 99
  # Reads of the Elixir install itself, beyond its version: refused
  # whatever the built version is.
  @install_reads ["System.build_info/0", "System.compiled_endianness/0"]
  @no_version "no Elixir version in the trace"

  # Reviewed `System.version/0` reads, by app and release. Each release
  # passes only with exactly this outer checksum, as the lock pins it and
  # the verified tarball's tree matched before the compile. A site is the
  # file and line the trace names for the read (a module body's, its
  # `first_kind`) and the comparison the reviewed code makes of the version,
  # evaluated again over the built minor on every build. The count rule
  # above cannot take these: the version goes through `Version.parse!/1`,
  # a struct or its fields, and the same shape is not safe by itself (croma
  # 0.13.0 and serum 1.5.1 keep `Version.parse!(System.version())` in a
  # module attribute their functions bake, so their beams hold the patch).
  #
  # toolshed 0.5.0 (judge round 3): the tarball's only Elixir-version read is
  # `lib_src/core/cmd.ex:13`, `if System.version() >= "1.16" do`, in the
  # body of `defimpl Collectable, for: SanitizerStream`, choosing between
  # two `into/1` definitions. No `Version` call, no other `System.version`
  # or `build_info` anywhere in the tarball (`lib/`, `lib_src/`, `mix.exs`).
  # `Toolshed.OneBeam.include_all/0` reads `lib_src/**/*.ex` and splices
  # the AST into `Toolshed`, so the trace puts the read at
  # `lib/toolshed.ex:13` in a module body (`elixir_compiler_N`). Invariant:
  # under Erlang term order every "1.19.P" and "1.20.P" binary, pre-releases
  # included, is `>= "1.16"` (byte 3, or byte 2 for 1.20, decides it before
  # the patch is reached).
  #
  # The dependencies whose read tainted the most builds, each tarball read
  # whole (every file, `mix.exs` included) for `System.version`,
  # `System.build_info`, `System.compiled_endianness` and `Version.`; every
  # read not listed is in a function body run only at runtime, which the
  # trace would name as another site:
  #
  #   * toml 0.7.0, `lib/provider.ex:49`: `has_config_api? =
  #     Version.match?(Version.parse!(System.version()), ">= 1.9.0")` in
  #     `Toml.Provider`'s body, a local the module's three `if`s read to
  #     define `@behaviour Config.Provider` and its callbacks. Line 215 is
  #     `is_distillery_env?/0`, called from `init/1` at runtime.
  #   * dialyxir 1.4.9: `lib/dialyxir/project.ex:467`, `if System.version()
  #     |> Version.parse!() |> (&(&1.major >= 1 and &1.minor >= 15)).() do`,
  #     choosing between two `app_dep_specs/1`; `lib/mix/tasks/dialyzer.ex:350`,
  #     `if Version.match?(System.version(), ">= 1.15.0") do`, choosing
  #     between two `check_dialyzer/0`. `project.ex:250` and `:275` name PLT
  #     files at runtime.
  #   * benchee 1.5.1: `lib/benchee/benchmark/collect/memory.ex:19`, the body
  #     of `defmacrop compatible_stacktrace`, `if
  #     Version.match?(Version.parse!(System.version()), "~> 1.7") do`,
  #     choosing `__STACKTRACE__` or `System.stacktrace()`; the macro is
  #     expanded once, in `start_runner/2`, which erl_eval runs, so the trace
  #     names line 56 with a glue first frame. `lib/benchee/profile.ex:31`,
  #     `if Version.match?(System.version(), ">= 1.17.0") &&
  #     String.to_integer(System.otp_release()) >= 27 do`, adding `:tprof`
  #     to a module attribute. `mix.exs:64` is R4's (`MixExsSlice`);
  #     `lib/benchee/system.ex:85` is runtime.
  #   * timex 3.1.25, `lib/datetime/inspect.ex:15`, a file body: `if
  #     System.version |> Version.parse! |> Version.compare(Version.parse!(
  #     "1.5.0-rc.1")) == :lt do`, defining an `Inspect` implementation for
  #     `DateTime` only before Elixir 1.5.
  #   * moar 5.0.1: `lib/datetime.ex:35`, the body of `defmacrop at_time`, `if
  #     System.version() |> Version.parse!() |> Version.compare(
  #     Version.parse!("1.17.0")) == :lt do`, choosing one of two quotes; the
  #     macro is expanded once, in `at/2`, so the trace names line 70 with a
  #     glue first frame. `lib/file.ex:31`, `if Version.compare(
  #     System.version(), "1.16.0") in [:gt, :eq] do`, choosing definitions.
  #   * wallaby 0.31.0, `lib/wallaby/selenium.ex:382`: `@binread_arg if
  #     Version.parse!(System.version()).minor >= 13, do: :eof, else: :all`,
  #     the argument one function hands `IO.binread/2`.
  @reviewed_reads %{
    "toolshed" => [
      %{
        version: "0.5.0",
        checksum: "44a39f384d813d1991c4637eca23f62e9f91135e496c868c400b42ed01eb51d2",
        sites: [%{file: "lib/toolshed.ex", line: 13, kind: "user", compare: {:term, :>=, "1.16"}}]
      }
    ],
    "toml" => [
      %{
        version: "0.7.0",
        checksum: "0690246a2478c1defd100b0c9b89b4ea280a22be9a7b313a8a058a2408a2fa70",
        sites: [%{file: "lib/provider.ex", line: 49, kind: "user", compare: {:match, ">= 1.9.0"}}]
      }
    ],
    "dialyxir" => [
      %{
        version: "1.4.9",
        checksum: "1c049c22b47680f4fff78ed0b0fe377073a762e96af153fdfe28bf00131de76d",
        sites: [
          %{
            file: "lib/dialyxir/project.ex",
            line: 467,
            kind: "user",
            compare: {:fields, major: 1, minor: 15}
          },
          %{
            file: "lib/mix/tasks/dialyzer.ex",
            line: 350,
            kind: "user",
            compare: {:match, ">= 1.15.0"}
          }
        ]
      }
    ],
    "benchee" => [
      %{
        version: "1.5.1",
        checksum: "a539301f8dfd4efc5c5123bfb9d47ebde20092a863a5b5b16c2a60d2243dfce7",
        sites: [
          %{
            file: "lib/benchee/benchmark/collect/memory.ex",
            line: 56,
            kind: "glue",
            compare: {:match, "~> 1.7"}
          },
          %{
            file: "lib/benchee/profile.ex",
            line: 31,
            kind: "user",
            compare: {:match, ">= 1.17.0"}
          }
        ]
      }
    ],
    "moar" => [
      %{
        version: "5.0.1",
        checksum: "f0448ac83d02ebd46b134faa22d6102f4a963f8bf285411dec94b3863a366a78",
        sites: [
          %{file: "lib/datetime.ex", line: 70, kind: "glue", compare: {:compare, "1.17.0"}},
          %{file: "lib/file.ex", line: 31, kind: "user", compare: {:compare, "1.16.0"}}
        ]
      }
    ],
    "wallaby" => [
      %{
        version: "0.31.0",
        checksum: "a3e7a5f13c1db49d32c17dafe8d4654fe556987efd12d422673b902455871c50",
        sites: [
          %{
            file: "lib/wallaby/selenium.ex",
            line: 382,
            kind: "user",
            compare: {:fields, minor: 13}
          }
        ]
      }
    ],
    "timex" => [
      %{
        version: "3.1.25",
        checksum: "218b5ac7fd7e6a6ced68d91e9d57de3ab79c5e57b0c677ed3f024ccbb0021391",
        sites: [
          %{
            file: "lib/datetime/inspect.ex",
            line: 15,
            kind: "user",
            compare: {:compare, "1.5.0-rc.1"}
          }
        ]
      }
    ]
  }

  @type result :: %{refusals: [{term(), {:refuse, String.t()}}], problems: [String.t()]}

  @doc """
  The refusals and problems of the `elixir_version` observations in
  `decided` (`{owner, decision}`, already limited to the package's closure)
  for a trace made on Elixir `built`.
  """
  @spec judge([{term(), term()}], String.t() | nil, %{String.t() => map()}) :: result()
  def judge(decided, built, reviewed \\ %{}) do
    decided
    |> Enum.flat_map(fn
      {owner, {:observe, "elixir_version", item}} when is_map(item) ->
        if item["first_kind"] == "toolchain", do: [], else: [{owner, item}]

      _other ->
        []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> judge_windows(built, versions(built), reviewed)
  end

  @doc """
  The apps whose reviewed reads (`@reviewed_reads`) may pass, each with its
  reviewed release: the locked release in `releases` (`%{app => %{name,
  version, checksum}}`) is a reviewed version with its reviewed outer
  checksum, and the tree in `trees` (`NccWorker.Portability.Trees.snapshot/5`)
  matched that verified tarball before the compile. Anything else, none.
  """
  @spec reviewed_apps(map(), map()) :: %{String.t() => map()}
  def reviewed_apps(releases, trees) when is_map(releases) and is_map(trees) do
    for {app, reviewed} <- @reviewed_reads,
        %{version: version, checksum: sum} = release <- reviewed,
        match?(%{name: ^app, version: ^version, checksum: ^sum}, releases[app]),
        match?({:ok, %{}}, trees[app]),
        into: %{},
        do: {app, release}
  end

  def reviewed_apps(_releases, _trees), do: %{}

  # `System.build_info/0` and `System.compiled_endianness/0`
  # (`@install_reads`) refuse whatever the built version is, so a window with
  # such a read refuses even when the version is unknown; every other window
  # then cannot be judged.
  defp judge_windows(by_owner, built, versions, reviewed) do
    results =
      for {owner, items} <- Enum.sort(by_owner),
          do: {owner, window(items, owner, built, versions, reviewed)}

    %{
      refusals: for({owner, {:refuse, reason}} <- results, do: {owner, {:refuse, reason}}),
      problems: if(Enum.any?(results, &match?({_, :unjudged}, &1)), do: [@no_version], else: [])
    }
  end

  defp window(items, owner, built, versions, reviewed) do
    case Enum.find(items, &(&1["mfa"] in @install_reads)) do
      nil -> items |> unreviewed(owner, versions, reviewed) |> compared(built, versions)
      info -> {:refuse, @prefix <> info["mfa"] <> where(info)}
    end
  end

  # The window's items without its reviewed reads and the comparisons made
  # at their sites, when its `System.version/0` reads are exactly the
  # sites of its app's reviewed release, each read once and each as
  # reviewed; else all of them.
  defp unreviewed(items, owner, {:ok, versions}, reviewed) when is_binary(owner) do
    with %{sites: sites} <- Map.get(reviewed, owner),
         reads = Enum.filter(items, &(&1["mfa"] == "System.version/0")),
         true <-
           Enum.sort(Enum.map(reads, &site_key/1)) ==
             Enum.sort(Enum.map(sites, &{&1.file, &1.line})),
         true <- Enum.all?(reads, &reviewed_read?(&1, sites, versions)) do
      keys = MapSet.new(sites, &{&1.file, &1.line})

      Enum.reject(items, fn item ->
        item["mfa"] in ["System.version/0" | @judged] and MapSet.member?(keys, site_key(item))
      end)
    else
      _ -> items
    end
  end

  defp unreviewed(items, _owner, _versions, _reviewed), do: items

  defp site_key(item), do: {item["file"], item["line"]}

  defp reviewed_read?(read, sites, versions) do
    case Enum.find(sites, &({&1.file, &1.line} == site_key(read))) do
      %{kind: kind, compare: compare} ->
        read["first_kind"] == kind and module_body?(read["module"]) and
          invariant_compare?(compare, versions)

      nil ->
        false
    end
  end

  defp module_body?("elixir_compiler_" <> n) when n != "", do: String.match?(n, ~r/^[0-9]+$/)
  defp module_body?(_module), do: false

  # The reviewed comparison gives one answer over the built version and
  # every patch of its minor, with `-rc.N` and `-dev` pre-releases.
  defp invariant_compare?(compare, versions) do
    [built | _] = versions
    {:ok, %Version{major: major, minor: minor}} = Version.parse(built)

    candidates =
      for p <- 0..@last_patch,
          suffix <- ["", "-dev" | Enum.map(0..9, &"-rc.#{&1}")],
          do: "#{major}.#{minor}.#{p}#{suffix}"

    results = for v <- [built | candidates], uniq: true, do: reviewed_compare(compare, v)
    match?([{:ok, _}], results)
  end

  # What the reviewed code computes from the version `v`: a term comparison
  # of the version string, `Version.match?/2` of its struct against a
  # requirement, `Version.compare/2` of it against another version, or its
  # fields each at least a bound.
  defp reviewed_compare(compare, v) do
    {:ok, evaluate(compare, v)}
  rescue
    _ -> :error
  end

  defp evaluate({:term, :>=, literal}, v), do: v >= literal
  defp evaluate({:match, requirement}, v), do: Version.match?(Version.parse!(v), requirement)

  defp evaluate({:compare, other}, v),
    do: Version.compare(Version.parse!(v), Version.parse!(other))

  defp evaluate({:fields, bounds}, v) do
    version = Version.parse!(v)
    Enum.all?(bounds, fn {field, bound} -> Map.fetch!(version, field) >= bound end)
  end

  defp compared(_items, _built, :error), do: :unjudged

  defp compared(items, built, {:ok, versions}) do
    reads = Enum.filter(items, &(&1["mfa"] == "System.version/0"))
    calls = Enum.filter(items, &compares_built?(&1, built))

    cond do
      bad = Enum.find(calls, &(not invariant?(&1, built, versions))) ->
        {:refuse, @prefix <> bad["mfa"] <> " " <> args(bad) <> where(bad)}

      length(reads) > length(calls) ->
        {:refuse,
         @prefix <>
           "System.version/0 read without a patch-invariant Version comparison" <>
           where(hd(reads))}

      true ->
        :ok
    end
  end

  defp compares_built?(item, built), do: built in [arg(item, "left"), arg(item, "right")]

  defp invariant?(%{"mfa" => mfa} = item, built, versions) when mfa in @judged do
    left = arg(item, "left")
    right = arg(item, "right")
    versions = if item["series"] == true, do: series(built, versions), else: versions
    results = for v <- versions, do: call(mfa, swap(left, built, v), swap(right, built, v))
    Enum.all?(results, &match?({:ok, _}, &1)) and length(Enum.uniq(results)) == 1
  end

  defp invariant?(_item, _built, _versions), do: false

  defp swap(arg, built, version) when arg == built, do: version
  defp swap(arg, _built, _version), do: arg

  # A nil (non-literal) argument raises too: never invariant.
  defp call(mfa, a, b) do
    {:ok, apply_version(mfa, a, b)}
  rescue
    _ -> :error
  end

  defp apply_version("Version.match?/2", a, b), do: Version.match?(a, b)
  defp apply_version("Version.compare/2", a, b), do: Version.compare(a, b)

  # The built version itself and every final patch of its minor from its
  # own patch on (a pre-release build is also served to the final release),
  # always including at least the next patch.
  defp versions(built) when is_binary(built) do
    case Version.parse(built) do
      {:ok, %Version{major: major, minor: minor, patch: patch}} ->
        finals = for p <- patch..max(@last_patch, patch + 1)//1, do: "#{major}.#{minor}.#{p}"
        {:ok, Enum.uniq([built | finals])}

      :error ->
        :error
    end
  end

  defp versions(_built), do: :error

  # A call from a dependency's `mix.exs` (`"series"`, `Events` marks it):
  # the same answer for every final patch of the built minor, from x.y.0,
  # as well as for the versions above. The toolchain key is the minor, so a
  # requirement that cuts inside it refuses, wherever the built patch is.
  defp series(built, versions) do
    {:ok, %Version{major: major, minor: minor}} = Version.parse(built)
    Enum.uniq(versions ++ for(p <- 0..@last_patch, do: "#{major}.#{minor}.#{p}"))
  end

  defp arg(%{"arg" => %{} = arg}, side), do: unquoted(arg[side])
  defp arg(_item, _side), do: nil

  defp unquoted("\"" <> rest) when byte_size(rest) > 0 do
    if String.ends_with?(rest, "\""), do: binary_part(rest, 0, byte_size(rest) - 1)
  end

  defp unquoted(_value), do: nil

  defp args(item), do: "(#{shown(item, "left")}, #{shown(item, "right")})"

  defp shown(item, side), do: arg(item, side) || "(not a literal string)"

  defp where(%{"module" => module, "file" => file, "line" => line}) when is_binary(module),
    do: " in #{display(module)} (#{file}:#{line})"

  defp where(_item), do: ""

  defp display("Elixir." <> name), do: name
  defp display(name), do: name
end
