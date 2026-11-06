defmodule NccWorker.Portability.Events do
  @moduledoc """
  Stage 2 of the compile-time trace (precompiled portability spec, R1 step
  4): what one user-extent event means for the window it fell in. Each event
  is ignored, observed, refused, or could not be judged.

  In P1 the config and Elixir-version channels are observed only (R5 and the
  Elixir-patch rule come in P2); everything else is allowed by a narrow rule
  or refused:

    * OS identity: `system_info(otp_release)` is allowed, and `os:type/0`,
      `os:version/0` or `system_info(os_type)` when the first frame after
      the wrappers is a path module. Every other key refuses.
    * Environment, programs, network, crypto and native loading refuse.
    * Integrity (the trace API, `erts_internal` trace BIFs, `system_flag`,
      reading another process's stack, mailbox or dictionary, unsticking a
      module, the tracer's own API) refuses everywhere, `mix.exs` included.
      A module reloaded under the trace drops its patterns, which the
      tracer's integrity check reports for the window instead.
    * Install locations: `lib_dir`/`priv_dir` of a closure app or an
      OTP/Elixir app; nothing else.
    * Reads: `Context.readable?/2` of the real path, relative paths and
      `get_cwd` against the window's dependency (`Context.cwd/2`).
    * Writes: only under the window's own `ebin` (`Context.writable?/3`); a
      rename's source too, a copy's source must be readable. Any symlink or
      hard link refuses, even inside `ebin`: the judge resolves paths after
      the build, so a link there can stand for a read of any target.
    * A user `set_cwd` refuses: it changes what every later relative path
      names.
    * A call into a natively built dependency refuses in the package's
      window and outside every window, and is observed in another
      dependency's window (R3 decides there).
    * A host read whose first user frame is in a closure dependency's
      `mix.exs` goes to R4 (`MixExsSlice`): allowed ones are observed as
      `mix_exs_allowed`. Integrity, writes, links, `set_cwd`, native
      loading and running a program (`os:cmd`, `open_port`, and so
      `System.cmd`/`Port.open`) never go to R4: they are not observations a
      slice can follow, and refuse directly. Looking a program up
      (`os:find_executable`) is an observation and does go to R4.
    * Our generated project's own `mix.exs` (owner `:wrapper`) is ignored.

  Fail closed: an event whose stack the tracer could not judge (extent
  `unjudged`), whose extent or channel this module does not know, or whose
  shape is not an event's, could not be judged (`{:unjudged, reason}`), never
  allowed. That check comes before every rule, the `:wrapper` owner's
  included: an unjudged event is never ignored, wherever it is attributed.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.Portability.{Context, MixExsSlice}

  @path_modules ~w(filename Elixir.Path file filelib code Elixir.Code)
  @host_channels ~w(env programs network crypto native)
  # Host reads R4 may allow when made from a dependency's mix.exs. Of the
  # `programs` channel only the lookup: running a program (`os:cmd`,
  # `open_port`, so `System.cmd` and `Port.open`) does things the trace
  # cannot follow, so it refuses directly.
  @slice_channels ~w(os_identity env network crypto install file_read)
  @slice_programs ~w(os:find_executable/1 os:find_executable/2)
  @extents ~w(frame dispatcher truncated lineage)
  @links ~w(file:make_symlink/2 file:make_link/2 prim_file:make_symlink/2 prim_file:make_link/2)
  @max_mix_exs_bytes 1024 * 1024

  @type decision ::
          :ignore
          | {:observe, String.t(), map()}
          | {:refuse, String.t()}
          | {:unjudged, String.t()}

  @typedoc "Per `mix.exs` real path, its `MixExsSlice.analyse/1` result."
  @type slices :: %{String.t() => {:ok, MixExsSlice.t()} | {:refuse, String.t()}}

  @doc """
  Decides one event for `owner` (`Context.owner/2`, or a child VM's app).
  `slices` holds `mix_exs_slices/2`'s analyses; a `mix.exs` missing from it
  is read and analysed here.
  """
  @spec decide(term(), Context.t(), term(), slices()) :: decision()
  def decide(event, ctx, owner, slices \\ %{}) do
    case shape(event) do
      :ok -> owned(event, ctx, owner, slices)
      {:unjudged, _why} = unjudged -> unjudged
    end
  end

  @doc """
  The R4 analyses of every closure dependency's `mix.exs` that one of
  `owned_events` (`{owner, event}`) has its first user frame in, each file
  read and analysed once.
  """
  @spec mix_exs_slices(Context.t(), [{term(), map()}]) :: slices()
  def mix_exs_slices(ctx, owned_events) do
    owned_events
    |> Enum.map(fn {owner, event} -> Context.mix_exs(ctx, event, owner) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(&{&1, analyse(&1)})
  end

  defp shape(%{"channel" => channel, "mfa" => mfa, "arg" => arg, "extent" => extent})
       when is_binary(channel) and is_binary(mfa) and is_map(arg) do
    cond do
      extent == "unjudged" -> unjudged("unjudged stack: #{mfa}")
      extent not in @extents -> unjudged("unknown stack extent #{inspect(extent)}: #{mfa}")
      true -> :ok
    end
  end

  defp shape(%{"mfa" => mfa}) when is_binary(mfa), do: unjudged("malformed event: #{mfa}")
  defp shape(_event), do: unjudged("malformed event")

  defp unjudged(why), do: {:unjudged, "#{Reasons.could_not_judge()} (#{why})"}

  defp owned(_event, _ctx, :wrapper, _slices), do: :ignore

  defp owned(%{"channel" => channel, "mfa" => mfa} = event, ctx, owner, slices) do
    case channel(channel, event, ctx, owner) do
      {:refuse, _} = refusal when channel in @slice_channels ->
        in_mix_exs(event, ctx, owner, slices, refusal)

      {:refuse, _} = refusal when channel == "programs" and mfa in @slice_programs ->
        in_mix_exs(event, ctx, owner, slices, refusal)

      other ->
        other
    end
  end

  defp channel("os_identity", event, _ctx, _owner), do: os_identity(event)

  defp channel(channel, event, _ctx, _owner) when channel in @host_channels,
    do: {:refuse, host_read(event, event["arg"]["path"])}

  defp channel("integrity", event, _ctx, _owner),
    do: {:refuse, "compile-time tracing or system flag: " <> event["mfa"]}

  defp channel("cwd", event, _ctx, _owner), do: {:refuse, host_read(event, event["arg"]["path"])}

  defp channel("elixir_version", event, _ctx, _owner),
    do: {:observe, "elixir_version", summary(event)}

  defp channel("config", event, _ctx, _owner), do: {:observe, "config_reads", summary(event)}
  defp channel("install", event, ctx, _owner), do: install(event, ctx)
  defp channel("file_read", event, ctx, owner), do: file_read(event, ctx, owner)
  defp channel("file_write", event, ctx, owner), do: file_write(event, ctx, owner)
  defp channel("native_closure", event, ctx, owner), do: native_closure(event, ctx, owner)

  defp channel(other, event, _ctx, _owner),
    do: unjudged("unknown channel #{other}: #{event["mfa"]}")

  defp os_identity(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => "otp_release"}}),
    do: :ignore

  defp os_identity(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => "os_type"}} = e),
    do: path_handling(e)

  defp os_identity(%{"mfa" => "erlang:system_info/1"} = e), do: {:refuse, host_read(e)}
  defp os_identity(e), do: path_handling(e)

  defp path_handling(%{"first" => %{"module" => module}}) when module in @path_modules,
    do: :ignore

  defp path_handling(e), do: {:refuse, host_read(e)}

  defp install(%{"arg" => %{"what" => what, "app" => app} = arg} = e, ctx)
       when what in ["lib_dir", "priv_dir"] and is_binary(app) do
    if arg["toolchain_app"] == true or Context.dep?(ctx, app),
      do: :ignore,
      else: {:refuse, host_read(e)}
  end

  defp install(e, _ctx), do: {:refuse, host_read(e)}

  defp file_read(%{"arg" => %{"cwd" => true}} = e, ctx, owner) do
    case Context.cwd(ctx, owner) do
      nil -> {:refuse, host_read(e)}
      cwd -> readable(e, ctx, cwd, owner)
    end
  end

  defp file_read(%{"arg" => %{"path" => path}} = e, ctx, owner) when is_binary(path),
    do: readable(e, ctx, path, owner)

  defp file_read(e, _ctx, _owner), do: {:refuse, host_read(e)}

  defp readable(e, ctx, path, owner) do
    if Context.readable?(ctx, Context.resolve(ctx, path, owner)),
      do: :ignore,
      else: {:refuse, host_read(e, path)}
  end

  defp file_write(%{"mfa" => mfa, "arg" => arg}, _ctx, _owner) when mfa in @links,
    do: {:refuse, "compile-time write outside ebin: #{mfa} #{show(arg["path"])} (a link)"}

  defp file_write(%{"arg" => arg} = e, ctx, owner) do
    targets = [arg["path"] | if(arg["from_kind"] == "write", do: [arg["from"]], else: [])]

    # Filtered, not found: a missing (`nil`) target is itself the bad one.
    case Enum.reject(targets, &Context.writable?(ctx, &1, owner)) do
      [] -> copy_source(e, ctx, owner)
      [bad | _] -> {:refuse, "compile-time write outside ebin: #{e["mfa"]} #{show(bad)}"}
    end
  end

  defp copy_source(%{"arg" => %{"from_kind" => "read", "from" => from}} = e, ctx, owner),
    do: file_read(%{e | "arg" => %{"path" => from}}, ctx, owner)

  defp copy_source(%{"arg" => %{"from_kind" => kind}} = e, _ctx, _owner)
       when kind not in [nil, "write"],
       do: unjudged("unknown write source #{inspect(kind)}: #{e["mfa"]}")

  defp copy_source(_event, _ctx, _owner), do: :ignore

  # Observed only in another dependency's window, where R3 judges it.
  defp native_closure(event, ctx, owner) do
    if is_binary(owner) and owner != ctx.package,
      do: {:observe, "native_calls", summary(event)},
      else: {:refuse, "calls natively built dependency at compile time: " <> event["mfa"]}
  end

  defp in_mix_exs(event, ctx, owner, slices, refusal) do
    with path when is_binary(path) <- Context.mix_exs(ctx, event, owner),
         line when is_integer(line) and line > 0 <- get_in(event, ["user", "line"]) do
      slice = Map.get_lazy(slices, path, fn -> analyse(path) end)
      sliced(event, path, line, slice)
    else
      _ -> refusal
    end
  end

  defp sliced(event, path, line, {:ok, analysis}) do
    case MixExsSlice.judge(analysis, line) do
      :ok -> {:observe, "mix_exs_allowed", summary(event)}
      {:refuse, why} -> sliced(event, path, line, {:refuse, why})
    end
  end

  defp sliced(event, path, line, {:refuse, why}),
    do: {:refuse, "compile-time host read in mix.exs: #{event["mfa"]} #{why} (#{path}:#{line})"}

  defp analyse(path) do
    case read_bounded(path) do
      {:ok, source} -> MixExsSlice.analyse(source)
      {:error, reason} -> {:refuse, "mix.exs unreadable (#{inspect(reason)})"}
    end
  end

  # A closure dependency's own mix.exs, at a real path the Context resolved;
  # read only up to a bound (MixExsSlice refuses anything larger anyway).
  # sobelow_skip ["Traversal.FileModule"]
  defp read_bounded(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_mix_exs_bytes)) do
      {:ok, source} when is_binary(source) -> {:ok, source}
      {:ok, :eof} -> {:ok, ""}
      {:ok, other} -> {:error, other}
      {:error, reason} -> {:error, reason}
    end
  end

  defp host_read(event, path \\ nil) do
    "compile-time host read: " <> event["mfa"] <> path_part(path) <> where(event)
  end

  defp path_part(nil), do: ""
  defp path_part(path), do: " " <> show(path)

  defp show(path) when is_binary(path), do: path
  defp show(path), do: inspect(path)

  defp where(%{"user" => %{"module" => module, "function" => fun, "arity" => arity} = user})
       when is_binary(module),
       do: " in #{display(module)}.#{fun}/#{arity} (#{user["file"]}:#{user["line"]})"

  defp where(event),
    do: " (#{event["extent"]} stack, first frame #{first_module(event)})"

  defp first_module(%{"first" => %{"module" => module}}), do: module
  defp first_module(_event), do: "none"

  defp display("Elixir." <> name), do: name
  defp display(name), do: name

  defp summary(event) do
    user = if is_map(event["user"]), do: event["user"], else: %{}

    %{
      "mfa" => event["mfa"],
      "arg" => event["arg"],
      "module" => user["module"],
      "file" => user["file"],
      "line" => user["line"]
    }
  end
end
