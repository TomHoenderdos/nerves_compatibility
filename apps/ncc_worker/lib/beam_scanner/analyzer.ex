defmodule BeamScanner.Analyzer do
  @moduledoc """
  Scans an OTP release directory (expects an `ebin` subdirectory) for
  indicators about startup behavior and runtime capabilities.
  """

  @type evidence :: %{beam: atom(), file: String.t(), mfa: {atom(), atom(), non_neg_integer()}}
  @type protocol_def :: %{protocol: module(), fallback_to_any: boolean(), file: String.t()}
  @type protocol_impl :: %{protocol: module(), for: term(), impl: module(), file: String.t()}
  @type file_manifest_entry :: %{
          path: String.t(),
          size: non_neg_integer(),
          sha256: String.t()
        }
  @type footprint :: %{
          file_count: non_neg_integer(),
          total_bytes: non_neg_integer(),
          ebin: %{file_count: non_neg_integer(), total_bytes: non_neg_integer()},
          priv: %{file_count: non_neg_integer(), total_bytes: non_neg_integer()},
          manifest: [file_manifest_entry()]
        }
  @type result :: %{
          start_callback?: boolean(),
          start_callback_modules: [module()],
          nif_calls?: boolean(),
          nif_evidence: [evidence()],
          shell_calls?: boolean(),
          shell_evidence: [evidence()],
          app_env_calls?: boolean(),
          app_env_evidence: [evidence()],
          os_env_calls?: boolean(),
          os_env_evidence: [evidence()],
          os_exec_calls?: boolean(),
          os_exec_evidence: [evidence()],
          halt_calls?: boolean(),
          halt_evidence: [evidence()],
          protocols_defined: [protocol_def()],
          protocol_impls: [protocol_impl()],
          languages: [atom()],
          beam_count: non_neg_integer(),
          footprint: footprint(),
          errors: [String.t()]
        }

  @nif_targets MapSet.new([{:erlang, :load_nif, 2}])

  @shell_targets MapSet.new([
                   {System, :shell, 1},
                   {System, :shell, 2},
                   {:os, :cmd, 1},
                   {:os, :cmd, 2}
                 ])

  @app_env_targets MapSet.new([
                     {Application, :get_env, 2},
                     {Application, :get_env, 3},
                     {Application, :fetch_env, 2},
                     {Application, :fetch_env!, 2},
                     {Application, :get_all_env, 1},
                     {Application, :put_env, 3},
                     {Application, :put_env, 4},
                     {Application, :delete_env, 2},
                     {:application, :get_env, 2},
                     {:application, :get_env, 3},
                     {:application, :set_env, 3},
                     {:application, :set_env, 4},
                     {:application, :unset_env, 2},
                     {:application, :get_all_env, 0},
                     {:application, :get_all_env, 1}
                   ])

  @os_env_targets MapSet.new([
                    {System, :get_env, 0},
                    {System, :get_env, 1},
                    {System, :fetch_env, 1},
                    {System, :fetch_env!, 1},
                    {System, :put_env, 1},
                    {System, :put_env, 2},
                    {System, :delete_env, 1},
                    {:os, :getenv, 0},
                    {:os, :getenv, 1},
                    {:os, :putenv, 2}
                  ])

  @os_exec_targets MapSet.new([
                     {Port, :open, 2},
                     {:erlang, :open_port, 2},
                     {System, :cmd, 2},
                     {System, :cmd, 3},
                     {:os, :cmd, 1},
                     {:os, :cmd, 2},
                     {System, :shell, 1},
                     {System, :shell, 2}
                   ])

  @halt_targets MapSet.new([
                  {System, :halt, 0},
                  {System, :halt, 1},
                  {:erlang, :halt, 0},
                  {:erlang, :halt, 1},
                  {:init, :stop, 0}
                ])

  @categories [
    {:nif, @nif_targets},
    {:shell, @shell_targets},
    {:app_env, @app_env_targets},
    {:os_env, @os_env_targets},
    {:os_exec, @os_exec_targets},
    {:halt, @halt_targets}
  ]

  @category_keys Enum.map(@categories, &elem(&1, 0))

  @doc """
  Analyze the given directory (expects an `ebin` subdir) and return
  a summary map with boolean flags and evidence for each category.
  """
  @spec analyze(Path.t()) :: result()
  def analyze(root_dir) do
    ebin_dir = Path.join(root_dir, "ebin")

    {start_modules, app_errors} = scan_app_files(ebin_dir)

    beam_paths = Path.wildcard(Path.join(ebin_dir, "*.beam"))

    {evidence_map, protocol_defs, protocol_impls, lang_set, errors} =
      beam_paths
      |> Enum.map(&scan_beam/1)
      |> Enum.reduce(
        {empty_evidence(), [], [], MapSet.new(), app_errors},
        &accumulate_beam_result/2
      )

    sorted_evidence = sort_evidence(evidence_map)
    sorted_protocol_defs = sort_protocol_defs(protocol_defs)
    sorted_protocol_impls = sort_protocol_impls(protocol_impls)
    languages = lang_set |> MapSet.to_list() |> Enum.sort()
    footprint = calculate_footprint(root_dir)

    %{
      start_callback?: start_modules != [],
      start_callback_modules: start_modules |> Enum.uniq() |> Enum.sort(),
      nif_calls?: evidence_present?(:nif, sorted_evidence),
      nif_evidence: Map.fetch!(sorted_evidence, :nif),
      shell_calls?: evidence_present?(:shell, sorted_evidence),
      shell_evidence: Map.fetch!(sorted_evidence, :shell),
      app_env_calls?: evidence_present?(:app_env, sorted_evidence),
      app_env_evidence: Map.fetch!(sorted_evidence, :app_env),
      os_env_calls?: evidence_present?(:os_env, sorted_evidence),
      os_env_evidence: Map.fetch!(sorted_evidence, :os_env),
      os_exec_calls?: evidence_present?(:os_exec, sorted_evidence),
      os_exec_evidence: Map.fetch!(sorted_evidence, :os_exec),
      halt_calls?: evidence_present?(:halt, sorted_evidence),
      halt_evidence: Map.fetch!(sorted_evidence, :halt),
      protocols_defined: sorted_protocol_defs,
      protocol_impls: sorted_protocol_impls,
      languages: languages,
      beam_count: length(beam_paths),
      footprint: footprint,
      errors: errors
    }
  end

  defp evidence_present?(key, evidence_map) do
    evidence_map
    |> Map.get(key, [])
    |> Enum.any?()
  end

  defp empty_evidence do
    Enum.reduce(@category_keys, %{}, fn key, acc -> Map.put(acc, key, []) end)
  end

  defp sort_evidence(evidence_map) do
    sort_fn = fn %{beam: beam, mfa: mfa, file: file} -> {beam, mfa, file} end

    evidence_map
    |> Enum.map(fn {k, list} -> {k, Enum.sort_by(list, sort_fn)} end)
    |> Map.new()
  end

  defp sort_protocol_defs(defs) do
    Enum.sort_by(defs, fn %{protocol: protocol, file: file} -> {protocol, file} end)
  end

  defp sort_protocol_impls(impls) do
    Enum.sort_by(impls, fn %{protocol: protocol, for: target, impl: impl, file: file} ->
      {protocol, inspect(target), impl, file}
    end)
  end

  defp scan_app_files(ebin_dir) do
    app_files = Path.wildcard(Path.join(ebin_dir, "*.app"))

    Enum.reduce(app_files, {[], []}, fn file, {mods, errors} ->
      case :file.consult(String.to_charlist(file)) do
        {:ok, [{:application, _name, properties}]} ->
          case Keyword.get(properties, :mod) do
            {module, _args} ->
              {[module | mods], errors}

            _ ->
              {mods, errors}
          end

        {:error, reason} ->
          {mods, [format_app_error(file, reason) | errors]}
      end
    end)
  end

  defp format_app_error(file, reason) do
    "Failed to read .app file #{file}: #{inspect(reason)}"
  end

  defp scan_beam(path) do
    with {:ok, {module, chunks}} <-
           :beam_lib.chunks(String.to_charlist(path), [:imports, :abstract_code, :attributes]) do
      chunk_map = Map.new(chunks)

      imports = Map.get(chunk_map, :imports, [])

      import_mfas =
        imports
        |> Enum.map(fn {m, f, a} -> {m, f, a} end)
        |> MapSet.new()

      abstract_mfas = collect_from_abstract(Map.get(chunk_map, :abstract_code))

      attrs =
        chunk_map
        |> Map.get(:attributes, [])
        |> Map.new()

      {module, path, MapSet.union(import_mfas, abstract_mfas), attrs, []}
    else
      {:error, beam, reason} ->
        {nil, path, MapSet.new(), %{}, [format_beam_error(beam, reason)]}
    end
  end

  defp collect_from_abstract({:raw_abstract_v1, forms}) when is_list(forms) do
    Enum.reduce(forms, MapSet.new(), &collect_from_form/2)
  end

  defp collect_from_abstract(_), do: MapSet.new()

  defp collect_from_form(
         {:call, _, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args} = form,
         acc
       ) do
    acc
    |> MapSet.put({mod, fun, length(args)})
    |> collect_children(form)
  end

  defp collect_from_form(term, acc), do: collect_children(term, acc)

  defp collect_children(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_from_form/2)
  end

  defp collect_children(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_from_form/2)
  end

  defp collect_children(_other, acc), do: acc

  defp accumulate_beam_result(
         {nil, _path, _mfas, _attrs, beam_errors},
         {evidence, defs, impls, langs, errors}
       ) do
    {evidence, defs, impls, langs, beam_errors ++ errors}
  end

  defp accumulate_beam_result(
         {beam_mod, path, mfas, attrs, beam_errors},
         {evidence, defs, impls, langs, errors}
       ) do
    {defs_acc, impls_acc} = maybe_add_protocols(defs, impls, beam_mod, path, attrs)
    langs_acc = maybe_add_language(langs, attrs, beam_mod)

    updated = add_category_findings(evidence, beam_mod, path, mfas)

    {updated, defs_acc, impls_acc, langs_acc, beam_errors ++ errors}
  end

  defp add_category_findings(evidence, beam_mod, path, mfas) do
    Enum.reduce(@categories, evidence, fn {key, targets}, acc ->
      maybe_add_findings(acc, key, beam_mod, path, mfas, targets)
    end)
  end

  defp maybe_add_findings(acc, key, beam_mod, path, mfas, targets) do
    matches = MapSet.intersection(mfas, targets)

    case MapSet.to_list(matches) do
      [] ->
        acc

      hits ->
        Enum.reduce(hits, acc, fn mfa, acc_inner ->
          Map.update!(acc_inner, key, fn entries ->
            [%{beam: beam_mod, file: path, mfa: mfa} | entries]
          end)
        end)
    end
  end

  defp maybe_add_protocols(defs, impls, beam_mod, path, attrs) do
    defs_acc =
      case Map.get(attrs, :__protocol__) do
        nil ->
          defs

        protocol_info ->
          fallback = Keyword.get(protocol_info, :fallback_to_any, false)
          [%{protocol: beam_mod, fallback_to_any: fallback, file: path} | defs]
      end

    impls_acc =
      case Map.get(attrs, :__impl__) do
        nil ->
          impls

        impl_info ->
          [
            %{
              protocol: Keyword.get(impl_info, :protocol),
              for: Keyword.get(impl_info, :for),
              impl: beam_mod,
              file: path
            }
            | impls
          ]
      end

    {defs_acc, impls_acc}
  end

  defp maybe_add_language(lang_set, attrs, beam_mod) do
    lang = classify_language(attrs, beam_mod)

    MapSet.put(lang_set, lang)
  end

  defp classify_language(attrs, beam_mod) do
    cond do
      Map.has_key?(attrs, :elixir_compiler_version) ->
        :elixir

      Map.has_key?(attrs, :gleam_compiler_version) ->
        :gleam

      true ->
        case source_path(attrs) do
          {:ok, source} ->
            case Path.extname(source) do
              ".ex" -> :elixir
              ".exs" -> :elixir
              ".erl" -> :erlang
              ".gleam" -> :gleam
              ".lfe" -> :lfe
              _ -> classify_from_module(beam_mod)
            end

          _ ->
            classify_from_module(beam_mod)
        end
    end
  end

  defp classify_from_module(mod) when is_atom(mod) do
    mod_str = Atom.to_string(mod)

    # Treat non-Elixir modules without compiler metadata as Erlang by default.
    cond do
      String.starts_with?(mod_str, "Elixir.") -> :elixir
      true -> :erlang
    end
  end

  defp source_path(attrs) do
    case Map.get(attrs, :source) do
      nil -> {:error, :missing}
      src when is_list(src) -> {:ok, List.to_string(src)}
      src when is_binary(src) -> {:ok, src}
      src when is_atom(src) -> {:ok, Atom.to_string(src)}
      _ -> {:error, :unknown}
    end
  end

  defp format_beam_error(beam, reason) do
    "Failed to read BEAM #{inspect(beam)}: #{inspect(reason)}"
  end

  @spec calculate_footprint(Path.t()) :: footprint()
  defp calculate_footprint(dir) do
    ebin_dir = Path.join(dir, "ebin")
    priv_dir = Path.join(dir, "priv")

    ebin_stats = dir_stats(ebin_dir)
    priv_stats = dir_stats(priv_dir)

    manifest = build_manifest(dir, ebin_dir, priv_dir)

    %{
      file_count: ebin_stats.file_count + priv_stats.file_count,
      total_bytes: ebin_stats.total_bytes + priv_stats.total_bytes,
      ebin: %{
        file_count: ebin_stats.file_count,
        total_bytes: ebin_stats.total_bytes
      },
      priv: %{
        file_count: priv_stats.file_count,
        total_bytes: priv_stats.total_bytes
      },
      manifest: manifest
    }
  end

  @spec build_manifest(Path.t(), Path.t(), Path.t()) :: [file_manifest_entry()]
  defp build_manifest(root_dir, ebin_dir, priv_dir) do
    ebin_files = collect_files_with_metadata(ebin_dir, root_dir)
    priv_files = collect_files_with_metadata(priv_dir, root_dir)

    (ebin_files ++ priv_files)
    |> Enum.sort_by(& &1.path)
  end

  defp collect_files_with_metadata(dir, root_dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn file ->
        relative_path = Path.relative_to(file, root_dir)

        case File.stat(file) do
          {:ok, %{size: size}} ->
            sha256 = compute_sha256(file)

            %{
              path: relative_path,
              size: size,
              sha256: sha256
            }

          _ ->
            %{
              path: relative_path,
              size: 0,
              sha256: ""
            }
        end
      end)
    else
      []
    end
  end

  defp compute_sha256(file) do
    case File.read(file) do
      {:ok, content} ->
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      _ ->
        ""
    end
  end

  defp dir_stats(dir) do
    if File.dir?(dir) do
      files =
        dir
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)

      total_bytes =
        files
        |> Enum.map(fn file ->
          case File.stat(file) do
            {:ok, %{size: size}} -> size
            _ -> 0
          end
        end)
        |> Enum.sum()

      %{file_count: length(files), total_bytes: total_bytes}
    else
      %{file_count: 0, total_bytes: 0}
    end
  end
end
