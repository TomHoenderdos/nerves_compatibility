defmodule NccWorker.Portability.ReviewedScripts do
  @moduledoc """
  The rebar3 releases whose `rebar.config.script` was reviewed for a
  differential build (`NccWorker.Portability.Differential`, review N1 and
  N2): a plain-arguments read Mix's evaluation of such a script makes takes
  the differential route only when every scripted release of the run's lock
  is one of these, by Hex name, version and the sha256 of every script file
  of its verified tarball (`rebar.config.script` and every `*.script`, the
  set exactly). The read cannot be told apart by release (the trace names no
  script), so one release that is not on the list refuses the read. Nothing
  here runs a script.

  Each entry was read whole. What a Mix user's plain arguments can reach
  (`[<install>/bin/mix, Task | Args]`, `["--no-halt", "+iex", "-S", "mix" |
  ...]`, or any other shape), and what else the script does:

    * gproc 0.3.1 to 1.3.0 (`rebar.config.script` in two versions, the
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

  # Script files shared by several releases.
  @gproc_config_old "fe25e3030b70ad885ae89d2390ba3c1b742ade8fae3042911d70aa93403d99f2"
  @gproc_config "bf4bc215b10cc661de6c35a5d257b1fd76378b48d40bab2202f8014293fa5621"
  @gproc_edown_old "26d51e06e522622059f7b2c48d0d6ecc8fe3a53fc26f50ed01567d29c1b66ed2"
  @gproc_edown "04ab798fb3d6b53a6fd91d4114319cf3d08a0db88c2e620568972b071e573cc2"
  @gproc_remove "38ca93e84f11c717b11bc67f8c2eac23e118afda56ac37492ba1be3bc5785088"
  @gproc_app_src "35edb4115b4a43cff9ca220cb0402af1181e8633389aed86ec78259e84b4816c"
  @chatterbox "1c03a915c8cefc5b41dbb7082c3c152b3faa494df28de593ba03682bf9146677"
  @tls "b8f2cca4a553c556905a511a0b1b9b27e3f9948f436bd1dc88650097884a140c"
  @setup "fb636a8ab54045500f349f05b82446727312b733a9d0d317b210d734c19cb357"
  @exometer "62b7031d79ddccc7d7093deee040c37135458c743bb764de7d1cd06ddc39f289"

  defp gproc(config, edown),
    do: %{
      "rebar.config.script" => config,
      "priv/check_edown.script" => edown,
      "priv/remove_deps.script" => @gproc_remove
    }

  defp gproc(config, edown, app_src),
    do: Map.put(gproc(config, edown), "src/gproc.app.src.script", app_src)

  @doc "Every reviewed release: `{hex_name, version} => %{script_path => sha256}`."
  @spec table() :: %{{String.t(), String.t()} => %{String.t() => String.t()}}
  def table do
    %{
      {"gproc", "0.3.1"} => gproc(@gproc_config_old, @gproc_edown_old),
      {"gproc", "0.5.0"} => gproc(@gproc_config_old, @gproc_edown),
      {"gproc", "0.6.1"} => gproc(@gproc_config_old, @gproc_edown),
      {"gproc", "0.8.0"} => gproc(@gproc_config, @gproc_edown),
      {"gproc", "0.9.1"} => gproc(@gproc_config, @gproc_edown),
      {"gproc", "1.0.0"} => gproc(@gproc_config, @gproc_edown),
      {"gproc", "1.2.0"} => gproc(@gproc_config, @gproc_edown, @gproc_app_src),
      {"gproc", "1.3.0"} => gproc(@gproc_config, @gproc_edown, @gproc_app_src),
      {"ts_chatterbox", "0.11.0"} => %{"rebar.config.script" => @chatterbox},
      {"ts_chatterbox", "0.16.0"} => %{"rebar.config.script" => @chatterbox},
      {"tls_certificate_check", "1.36.0"} => %{"rebar.config.script" => @tls},
      {"setup", "2.1.0"} => %{"rebar.config.script" => @setup},
      {"setup", "2.2.1"} => %{"rebar.config.script" => @setup},
      {"exometer_core", "1.7.1"} => %{"rebar.config.script" => @exometer},
      {"exometer_core", "2.0.0"} => %{"rebar.config.script" => @exometer}
    }
  end

  @doc """
  Whether `name` `version` with exactly these script files (`scripts/1`)
  is a reviewed release.
  """
  @spec reviewed?(String.t(), String.t(), %{String.t() => String.t()}) :: boolean()
  def reviewed?(name, version, scripts), do: Map.get(table(), {name, version}) == scripts

  @doc """
  The script files of a Hex tarball's contents, `%{path => sha256}`:
  `rebar.config.script` and every `*.script`, as regular files under safe
  relative paths. `:error` for a tarball that cannot be read.
  """
  @spec scripts(binary()) :: {:ok, %{String.t() => String.t()}} | :error
  def scripts(bytes) when is_binary(bytes) do
    with {:ok, tar} <- Rebar.contents_tar(bytes),
         {:ok, entries} when length(entries) <= @max_files <-
           :erl_tar.extract({:binary, tar}, [:memory]) do
      scripts =
        for {name, body} <- entries,
            path = List.to_string(name),
            script?(path),
            into: %{},
            do: {path, :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)}

      {:ok, scripts}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def scripts(_bytes), do: :error

  defp script?(path),
    do: path == "rebar.config.script" or String.ends_with?(path, ".script")
end
