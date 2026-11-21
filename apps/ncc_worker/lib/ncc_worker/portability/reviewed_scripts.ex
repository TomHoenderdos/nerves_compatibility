defmodule NccWorker.Portability.ReviewedScripts do
  @moduledoc """
  The rebar3 releases whose `rebar.config.script` was reviewed for a
  differential build (`NccWorker.Portability.Differential`, review N1 and
  N2): a plain-arguments read Mix's evaluation of such a script makes takes
  the differential route only when every scripted release of the run's lock
  is one of these, by Hex name, version and outer checksum (the sha256 of
  the whole Hex tarball, which the lock and the registry carry; review R5),
  so every byte is pinned: every script file and the `rebar.config` they
  read. A per-script sha256 would add nothing to that. The read cannot be
  told apart by release (the trace names no script), so one release that is
  not on the list refuses the read. Which releases are scripted at all comes
  from the tarball's member table (`script_members/1`; review N5: an
  in-memory extract drops a link member). Nothing here runs a script.

  Each entry was read whole. What a Mix user's plain arguments can reach
  (`[<install>/bin/mix, Task | Args]`, `["--no-halt", "+iex", "-S", "mix" |
  ...]`, or any other shape), and what else the script does:

    * gproc in these eight versions, and no other: 0.3.1, 0.5.0, 0.6.1,
      0.8.0, 0.9.1, 1.0.0, 1.2.0 and 1.3.0 (review R6;
      `rebar.config.script` in two versions, the
      0.8.0 one adding a shell config under `GPROC_DIST=true`;
      `priv/check_edown.script` in two versions that differ in a git URL
      alone; `priv/remove_deps.script`; from 1.2.0 a
      `src/gproc.app.src.script` rebar3 evaluates in its own VM).
      `check_edown.script` binds `Args` to the plain arguments without their
      first (`[_|A] -> A; _ -> []`, never failing) and tests only
      `lists:member("doc", Args)`. Without `"doc"` it removes `edown` from
      `deps` (`remove_deps.script`, a filter of `deps` alone); with it, it
      asks `code:lib_dir(edown)` and either adds a git `edown` to `deps` or
      prints and keeps the config. Either way only `deps` differs. A rebar3
      dependency's `deps` never reaches its own compile: Mix takes a Hex
      dependency's children from the lock, and `rebar3 bare compile` fetches
      and builds nothing (S2 review, question 2). `erl_opts`, the defines,
      `debug_info`, docs and every other key are the same for every
      argument list; the script calls nothing that changes the VM (no
      `putenv`, compiler option, application env or code path). Its env
      reads (`REBAR_DEPS`, `GPROC_DIST`) are traced compile inputs.
    * ts_chatterbox 0.11.0 and 0.16.0 (one script): reads no argument. It
      tests `erlang:function_exported(rebar3, main, 1)`, false in every Mix
      VM (Mix runs rebar3 as a program, never loads it), and then rewrites
      `deps` alone.
    * tls_certificate_check 1.36.0: reads no argument. Under Mix
      (`'Elixir.Mix'` loaded) it keeps the config, but for
      `project_plugins` by OTP release, which Mix drops
      (`Mix.Rebar.dependency_config/1`); otherwise only `deps` and
      `erl_opts` under rebar 2, which no Mix VM takes.
    * setup 2.1.0 and 2.2.1 (one script): binds `IsRebar3Bare` to
      `re:run(init:get_plain_arguments(), "rebar3bare")` and never uses
      it; the config depends only on the `TGT` env var (a traced compile
      input) and changes `edoc_opts` alone. Should `re:run/2` raise on an
      argument it cannot take as iodata, `file:script/2` returns an error
      and Mix keeps the config it handed the script, which is the script's
      own result whenever `TGT` is unset.
    * exometer_core 1.7.1 and 2.0.0 (one script): reads no argument. Its
      env reads (`EXOMETER_CORE_CONFIG_PREPROCESS`, `..._POSTPROCESS`,
      `REBAR_DEPS`) are traced compile inputs, and the scripts they would
      run are reads outside the tree, which refuse.

  Not on the list (seen behind production rows, each two rows or fewer):
  pure_erlsha2 2.2.2 (its `check_edown.script` starts crypto, public_key,
  ssl and inets under `"doc"`, an effect on the VM), chumak 1.3.0,
  oidcc_cowboy 2.0.0, jsx 2.8.3, yamerl 0.10.0, folsom 1.1.0.
  """

  alias NccWorker.Portability.Rebar

  @max_files 10_000

  @doc """
  Every reviewed release: `{hex_name, version} => outer checksum`, the
  sha256 of the Hex tarball the lock and the registry carry (review R5), so
  every byte is pinned: the scripts and the `rebar.config` they read. Each
  was taken from the release's tarball and checked against the registry.
  """
  @spec table() :: %{{String.t(), String.t()} => String.t()}
  def table do
    %{
      {"gproc", "0.3.1"} => "3c449925a5cbf57cc40d13c6c282bc1080b5ed3bad97e1acdbe969fd63a65fce",
      {"gproc", "0.5.0"} => "5bc0fa4e999a6665b92ce57a7f12d7e9d1c26bfc39b0f657994be05cd3818b18",
      {"gproc", "0.6.1"} => "5506435afbc62de6beb2ade24356a2a6c26c2046e250f845f0676589e86e96ab",
      {"gproc", "0.8.0"} => "580adafa56463b75263ef5a5df4c86af321f68694e7786cb057fd805d1e2a7de",
      {"gproc", "0.9.1"} => "905088e32e72127ed9466f0bac0d8e65704ca5e73ee5a62cb073c3117916d507",
      {"gproc", "1.0.0"} => "109f253c2787de8a371a51179d4973230cbec6239ee673fa12216a5ce7e4f902",
      {"gproc", "1.2.0"} => "70c6f8c91fa5974296cd87974949d8eab953230414f31c4a623ff75131e0827a",
      {"gproc", "1.3.0"} => "143a8ce6eb59610a351178482b629d2b052c69df84c9c50b9c13ae38354c8c14",
      {"ts_chatterbox", "0.11.0"} =>
        "722fe2bad52913ab7e87d849fc6370375f0c961ffb2f0b5e6d647c9170c382a6",
      {"ts_chatterbox", "0.16.0"} =>
        "34c145c702f3a8d22f49a189eb34579ef3db68f9a98a82d19b5cf6e390aad54f",
      {"tls_certificate_check", "1.36.0"} =>
        "e58b8626336b9cd483f0fd8346af501de648a07093b077be442f29ef6db28ef1",
      {"setup", "2.1.0"} => "efd072578f0cf85bea96caaffc7adb0992398272522660a136e10567377071c5",
      {"setup", "2.2.1"} => "f7babbd47d32ca81c4e1768ede237e1b63105214d2076fa1ba7780ab61457db4",
      {"exometer_core", "1.7.1"} =>
        "61a2ab26bc48b36a113d220b4afb06bd82bb2054d8a7f0813ff94c263b325594",
      {"exometer_core", "2.0.0"} =>
        "aea333e830a33be0d7bc60701bbdc899566de9387a4de8649412fcbd309633a4"
    }
  end

  @doc """
  Whether `name` `version` with this outer checksum (the lock's, which the
  verified tarball matched) is a reviewed release.
  """
  @spec reviewed?(String.t(), String.t(), String.t() | nil) :: boolean()
  def reviewed?(name, version, checksum) when is_binary(checksum),
    do: Map.get(table(), {name, version}) == checksum

  def reviewed?(_name, _version, _checksum), do: false

  @doc """
  What a Hex tarball's contents hold of scripts, from the member table (an
  in-memory extract drops a link member, review N5): `{:ok, :none}` without
  a `rebar.config.script`, `{:ok, :scripted}` with one when every script
  member (`rebar.config.script` and every `*.script`, a leading `./`
  dropped) is a regular file, and `{:unverified, why}` when one is not (a
  symbolic or hard link, a directory, anything else: Mix follows a link and
  evaluates its target) or the tarball cannot be read.
  """
  @spec script_members(binary()) :: {:ok, :none | :scripted} | {:unverified, String.t()}
  def script_members(bytes) when is_binary(bytes) do
    with {:ok, tar} <- Rebar.contents_tar(bytes),
         {:ok, table} when length(table) <= @max_files <-
           :erl_tar.table({:binary, tar}, [:verbose]) do
      members = for entry <- table, do: {member_name(elem(entry, 0)), elem(entry, 1)}
      scripts = Enum.filter(members, fn {path, _type} -> script?(path) end)

      case Enum.find(scripts, fn {_path, type} -> type != :regular end) do
        {path, type} ->
          {:unverified, "#{path} is a #{type} in its tarball"}

        nil when scripts == [] ->
          {:ok, :none}

        nil ->
          if List.keymember?(scripts, "rebar.config.script", 0),
            do: {:ok, :scripted},
            else: {:ok, :none}
      end
    else
      _ -> {:unverified, "tarball unreadable"}
    end
  rescue
    _ -> {:unverified, "tarball unreadable"}
  end

  def script_members(_bytes), do: {:unverified, "tarball unreadable"}

  defp member_name(name), do: name |> to_string() |> String.trim_leading("./")

  defp script?(path),
    do: path == "rebar.config.script" or String.ends_with?(path, ".script")
end
