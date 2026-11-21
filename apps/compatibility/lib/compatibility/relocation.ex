defmodule Compatibility.Relocation do
  @moduledoc """
  Relocatable builds (S4): a beam that holds the builder's deps or build
  path, rewritten to a user's own paths so that it is that user's own
  compile.

  A build that bakes a path (spec R2, "bakes the build path") is compiled a
  second time at another root. `prove/4` takes the two beams and the two
  builds' paths, the slots `%{"deps" => deps_path, "build" => build_path}`
  (`Mix.Project.deps_path/0` and `build_path/0` of each compile, absolute):

    * every occurrence of a slot in the first beam is found where a rewrite
      can reach it: a binary, a charlist or an atom inside a literal of the
      literal table (`LitT`), an atom of the atom table (`AtU8`), a term of
      the attribute chunk (`Attr`) or a file name of the line table
      (`Line`). Each is recorded as an occurrence (below). A slot anywhere
      else (the string table, the code, a map key, a compressed literal
      table, a literal it cannot read) is not provable;
    * the first beam relocated to the second build's slots (`relocate/4`)
      must then be the second beam chunk for chunk: every chunk but `CInf`,
      `Dbgi` and `Docs`, which are metadata and stay as they are, as in
      every served beam. That covers what `beam_lib:strip/1` keeps (`Line`,
      `Type`, `AtU8`, `Code`, `StrT`, `ImpT`, `ExpT`, `FunT`, `LitT`,
      `Meta`) and `Attr`, `LocT` and `ExCk` as well. A path that was hashed,
      sliced, measured or used to read a file at compile time shows up as a
      difference the rewrite does not make, and is not provable;
    * a protocol that holds a slot is not provable: Mix's consolidation
      recompiles a protocol from its `Dbgi`, which is not rewritten.

  `relocate/4` is what the compiler would have written at the other paths
  (`beam_asm` and `beam_dict`, OTP 28): each changed literal is
  `term_to_binary(term, [{:minor_version, 2}, :deterministic])`, an atom is
  rewritten in place (atoms are numbered in the order the compiler met
  them, which no path changes), the line table's file names likewise; the
  module's md5 is taken again over the essential chunks (`AtU8`, `Code`,
  `StrT`, `ImpT`, `ExpT`, `FunT` with every `old_uniq` zeroed, `LitT`,
  `Meta`), each fun's `old_uniq` is its first 27 bits, and a default `vsn`
  (the old md5) becomes the new one. It refuses what a compile at the new
  paths would have written differently: two literals, atoms or file names
  that become equal (the compiler shares one), an atom over 255
  characters, a recorded occurrence the beam does not hold, and any slot
  value left in a rewritten chunk afterwards.

  An occurrence is `%{"chunk", "index", "term", "kind", "parts"}`: the
  chunk (`LitT`, `AtU8`, `Attr`, `Line`), the literal's index (from 0),
  the atom's (from 1) or the file name's (from 0), the path to the value
  inside the literal or the attribute list (element indices of tuples and
  lists, a proper list's tail at its length; a map value's index among the
  map's keys in term order), the kind (`binary`, `charlist`, `atom`) and
  the value as a template, text and slot names in turn:
  `["", "deps", "/fine/c_include"]` is `<deps>/fine/c_include`.

  The beams are untrusted. Each is read by this module's own IFF reader
  (an uncompressed beam whose chunks fill it, each once); only the
  literals and attribute terms that hold a slot value are decoded, each at
  most 4 MiB, which can make atoms: the worker runs this in a VM of its own
  run. Never raises.
  """

  @slots ["deps", "build"]
  @metadata ~w(CInf Dbgi Docs)
  @rewritten ~w(LitT AtU8 Attr Line)
  @essentials ~w(AtU8 Code StrT ImpT ExpT FunT LitT Meta)
  @max_term_bytes 4 * 1024 * 1024
  @max_occurrences 10_000
  @literal_opts [{:minor_version, 2}, :deterministic]
  @md5_limit Bitwise.bsl(1, 128)

  @type slots :: %{String.t() => String.t()}
  @type occurrence :: %{String.t() => term()}
  @type outcome :: :same | {:ok, [occurrence()]} | {:refuse, String.t()}

  @doc "The slot names: `deps` and `build`."
  @spec slots() :: [String.t()]
  def slots, do: @slots

  @doc """
  Proves `a`, built with the slots `from`, against `b`, the same source built
  with the slots `to` (see the moduledoc). `:same` when no slot needs a
  rewrite and the beams differ in metadata alone, `{:ok, occurrences}` when
  the relocated `a` is `b`.
  """
  @spec prove(binary(), slots(), binary(), slots()) :: outcome()
  def prove(a, from, b, to) do
    with :ok <- valid_slots(from),
         :ok <- valid_slots(to),
         :ok <- distinct(from, to),
         {:ok, ca} <- chunks(a),
         {:ok, cb} <- chunks(b),
         :ok <- same_ids(ca, cb),
         {:ok, occs} <- scan(ca, from),
         {:ok, moved} <- relocate_chunks(ca, occs, from, to),
         :ok <- equal_but_metadata(moved, cb),
         :ok <- not_protocol(ca, occs) do
      if occs == [], do: :same, else: {:ok, occs}
    end
  rescue
    _ -> {:refuse, "unreadable beam"}
  end

  @doc """
  Every beam of two `ebin`s (`%{file name => bytes}`) proven with `prove/4`;
  any other file must be the same bytes, and the names the same. The beams
  that need a rewrite, `%{file name => occurrences}`.
  """
  @spec prove_ebin(%{String.t() => binary()}, slots(), %{String.t() => binary()}, slots()) ::
          {:ok, %{String.t() => [occurrence()]}} | {:refuse, String.t()}
  def prove_ebin(a, from, b, to) when is_map(a) and is_map(b) do
    names = a |> Map.keys() |> Enum.sort()

    if names == b |> Map.keys() |> Enum.sort() do
      names
      |> flat_map_ok(&prove_named(&1, a, from, b, to))
      |> then(fn
        {:ok, proven} -> {:ok, Map.new(proven)}
        refuse -> refuse
      end)
    else
      {:refuse, "the second build's ebin holds other files"}
    end
  end

  def prove_ebin(_a, _from, _b, _to), do: {:refuse, "no ebin"}

  defp prove_named(name, a, from, b, to) do
    case prove_file(name, Map.fetch!(a, name), from, Map.fetch!(b, name), to) do
      :same -> {:ok, []}
      {:ok, occs} -> {:ok, [{name, occs}]}
      {:refuse, why} -> {:refuse, "#{name}: #{why}"}
    end
  end

  # `fun` over `items`, its `{:ok, list}` results joined in order; the first
  # other result is the result.
  defp flat_map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, found} -> {:cont, {:ok, acc ++ found}}
        other -> {:halt, other}
      end
    end)
  end

  # `fun` folded over `items` from `{:ok, acc}`; the first other result is
  # the result.
  defp fold_ok(items, acc, fun) do
    Enum.reduce_while(items, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        other -> {:halt, other}
      end
    end)
  end

  defp prove_file(name, a, from, b, to) do
    cond do
      Path.extname(name) == ".beam" -> prove(a, from, b, to)
      a == b -> :same
      true -> {:refuse, "differs at another root"}
    end
  end

  @doc """
  `beam` with each of `occurrences` rewritten from the slots `from` to the
  slots `to`, its md5, funs and default `vsn` taken again (see the
  moduledoc).
  """
  @spec relocate(binary(), [occurrence()], slots(), slots()) ::
          {:ok, binary()} | {:refuse, String.t()}
  def relocate(beam, occurrences, from, to) when is_list(occurrences) do
    with :ok <- valid_slots(from),
         :ok <- valid_slots(to),
         {:ok, chunks} <- chunks(beam),
         {:ok, moved} <- relocate_chunks(chunks, occurrences, from, to),
         :ok <- nothing_left(moved, from, to) do
      {:ok, form(moved)}
    end
  rescue
    _ -> {:refuse, "unreadable beam"}
  end

  def relocate(_beam, _occurrences, _from, _to), do: {:refuse, "no occurrences"}

  @doc """
  The occurrences of `slots` in `beam` (see the moduledoc), unproven: what
  `prove/4` starts from, and how the worker finds a build's holder modules
  before its second build. `{:refuse, why}` where a slot sits where no
  rewrite reaches it.
  """
  @spec occurrences(binary(), slots()) :: {:ok, [occurrence()]} | {:refuse, String.t()}
  def occurrences(beam, slots) do
    with :ok <- valid_slots(slots),
         {:ok, chunks} <- chunks(beam),
         do: scan(chunks, slots)
  rescue
    _ -> {:refuse, "unreadable beam"}
  end

  @record_keys ["build", "deps", "files", "second", "third"]
  @kinds ["binary", "charlist", "atom"]
  @max_files 10_000
  @max_record_bytes 256 * 1024
  @max_leaf_bytes 4096

  # The worker's first build: its host compile in `<work dir>/proj`, the
  # work dir `/work` in the container (`Compatibility.Builder.Argv`).
  @first %{"deps" => "/work/proj/deps", "build" => "/work/proj/_build/host"}

  # The worker's other two roots, in production: the second under
  # `/home/ncc-relocate`, the third under `/Users`, each a per-run scratch
  # dir the portal binds there for a build that may relocate
  # (`Portal.Builder`, `Compatibility.Builder.Argv`). The second is under
  # `/home/` but not under the container's `HOME` (`/home/nerves`) or any
  # other root R2 searches: a root that holds one of those cannot be told
  # from it, and the extra build would hold nothing (the umbrella
  # re-review's Q2). Frozen: client 0.9.0 holds every record to exactly
  # this layout (`pinned_problem/1`), so another layout needs another
  # record version.
  @home "/home/ncc-relocate"
  @users "/Users"

  # The second root, under a home: lower case, no space, of middle length,
  # its deps path sorting before its build path, its project dir `app`,
  # holding a dot-dir, Mix.install's `.cache/mix/installs`, `nix/store`,
  # `src`, `code`, `projects`, `@` and `~`.
  @second_cache ".cache/mix/installs/elixir-1.20.5-erts-16.4.0.2"
  @second_dirs ["nix/store/src/code/projects", "x_y@z~0.d", "app"]
  @second_deps "deps"
  @second_build "out.d/host-1"

  # The third root, under `/Users`: upper case and spaces, long and deep,
  # its build path sorting before its deps path, its project dir another
  # name, holding `Library` and `Projects` and every letter and digit.
  @third_dirs [
    "Library/Mobile Documents",
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "0123456789",
    "abcdefghijklmnopqrstuvwxyz",
    "Long Relocation.Path-0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz",
    "x",
    "Y",
    "z-0",
    "Projects",
    "The Relocated.Project-2"
  ]
  @third_deps "Deps vendored_d"
  @third_build "Build-3/Host 4"

  @doc "The worker's first root: its host compile's `deps` and `build` paths."
  @spec first_root() :: %{String.t() => String.t()}
  def first_root, do: @first

  @doc """
  The dirs the second and third roots are under in the container
  (`second_layout/2`'s and `third_layout/2`'s first argument): each a
  per-run bind of a build that may relocate.
  """
  @spec bases() :: %{second: String.t(), third: String.t()}
  def bases, do: %{second: @home, third: @users}

  @doc """
  The worker's second root for run token `n` under `home`
  (`/home/ncc-relocate` in the container, `bases/0`): `"project"`, the dir
  its project is copied to, and its `"deps"` and `"build"` paths (see the
  moduledoc).
  """
  @spec second_layout(String.t(), non_neg_integer()) :: %{String.t() => String.t()}
  def second_layout(home, n) when is_integer(n) and n >= 0 do
    project = Path.join([home, @second_cache, "ncc-relocate-#{n}" | @second_dirs])
    layout(project, @second_deps, @second_build)
  end

  @doc """
  The worker's third root for run token `n` under `users` (`/Users` in the
  container), as `second_layout/2` gives the second.
  """
  @spec third_layout(String.t(), non_neg_integer()) :: %{String.t() => String.t()}
  def third_layout(users, n) when is_integer(n) and n >= 0 do
    project = Path.join([users, "Ncc-Relocate #{n}" | @third_dirs])
    layout(project, @third_deps, @third_build)
  end

  defp layout(project, deps, build),
    do: %{
      "project" => project,
      "deps" => Path.join(project, deps),
      "build" => Path.join(project, build)
    }

  @doc """
  A record's three roots as the worker writes them in production for run
  token `n` (no `files`): `deps` and `build` the first root's, `second` and
  `third` the other two's.
  """
  @spec pinned_record(non_neg_integer()) :: map()
  def pinned_record(n) do
    Map.merge(@first, %{
      "second" => Map.take(second_layout(@home, n), ["deps", "build"]),
      "third" => Map.take(third_layout(@users, n), ["deps", "build"])
    })
  end

  @doc """
  Why a record's three roots are not the worker's own production layout,
  or nil: `pinned_record/1` for the run token its second root names. The
  portal holds every record it stores to this, and client 0.9.0 holds every
  record it applies to the same rule.
  """
  @spec pinned_problem(term()) :: String.t() | nil
  def pinned_problem(%{"deps" => _, "build" => _, "second" => %{}, "third" => %{}} = record) do
    with deps when is_binary(deps) <- get_in(record, ["second", "deps"]),
         [_, digits] <- Regex.run(~r"/ncc-relocate-([0-9]{1,20})/", deps),
         true <-
           Map.take(record, ["deps", "build", "second", "third"]) ==
             pinned_record(String.to_integer(digits)) do
      nil
    else
      _ -> "the record's roots are not the worker's"
    end
  end

  def pinned_problem(_record), do: "not a relocation record"

  @doc """
  Why a worker's `relocation` record (`NccWorker.Portability.Relocate`) is
  not one a client can apply, or nil: the build's `deps` and `build` paths
  (absolute, distinct, neither inside the other), `second` and `third`, the
  other two builds' (the same), every one of the six printable ASCII, the
  record at most 256 KiB as JSON, and `files`, a list (empty for a
  dependent that passed because a dependency was held, whose own beams need
  no rewrite) of distinct `%{"path" => "ebin/<name>.beam", "occurrences" =>
  [...]}`, each path one of `ebin_paths` (the build's own `ebin` files),
  each with at least one occurrence of a known chunk, a non-negative index,
  a term path of non-negative integers, a known kind and a template of text
  and slot names with at least one slot, every `build` slot in it followed
  by Mix's own layout under a build path (the client re-review's R5 and
  R9): nothing, `/consolidated/...`, or `/lib/<app>/` and then `ebin`,
  `priv`, `include` or `.mix`, `<app>` one of `apps` (the build's closure
  apps) when given. Reads the record alone, never a beam: the portal
  checks it at ingest on its own node, which makes no atom.
  """
  @spec record_problem(term(), [String.t()], [String.t()] | nil) :: String.t() | nil
  def record_problem(record, ebin_paths, apps \\ nil)

  def record_problem(
        %{"deps" => deps, "build" => build, "files" => files} = record,
        ebin_paths,
        apps
      )
      when is_list(files) and is_list(ebin_paths) and (is_list(apps) or is_nil(apps)) do
    cond do
      record |> Map.keys() |> Enum.sort() != @record_keys ->
        "unknown keys"

      problem =
          roots_problem(%{"deps" => deps, "build" => build}, record["second"], record["third"]) ->
        problem

      length(files) > @max_files ->
        "too many files"

      record_bytes(record) > @max_record_bytes ->
        "a record over 256 KiB"

      length(Enum.uniq_by(files, &file_path/1)) != length(files) ->
        "a file twice"

      true ->
        Enum.find_value(files, &file_problem(&1, ebin_paths, apps))
    end
  end

  def record_problem(_record, _ebin_paths, _apps), do: "not a relocation record"

  defp roots_problem(first, second, third) do
    roots = [first, second, third]

    cond do
      Enum.any?(roots, &match?({:refuse, _}, valid_slots(&1))) ->
        "bad paths"

      not Enum.all?(Enum.flat_map(roots, &Map.values/1), &printable?/1) ->
        "a path not printable ASCII"

      true ->
        nil
    end
  end

  defp printable?(path), do: is_binary(path) and path =~ ~r/\A[\x20-\x7e]+\z/

  defp record_bytes(record) do
    record |> JSON.encode!() |> byte_size()
  rescue
    _ -> @max_record_bytes + 1
  end

  defp file_path(%{"path" => path}), do: path
  defp file_path(file), do: file

  defp file_problem(
         %{"path" => "ebin/" <> name = path, "occurrences" => [_ | _] = occs},
         ebin,
         apps
       ) do
    cond do
      Path.basename(name) != name or Path.extname(name) != ".beam" ->
        "not a beam: #{inspect(path)}"

      path not in ebin ->
        "not a file of the build: #{inspect(path)}"

      length(occs) > @max_occurrences ->
        "too many occurrences"

      not Enum.all?(occs, &occurrence?/1) ->
        "a malformed occurrence in #{inspect(path)}"

      tail = Enum.find_value(occs, &build_tail(&1, apps)) ->
        "a build path followed by #{inspect(tail, limit: 3, printable_limit: 40)} in #{inspect(path)}"

      true ->
        nil
    end
  end

  defp file_problem(file, _ebin, _apps), do: "a malformed file entry #{inspect(file, limit: 3)}"

  # The text after a `build` slot that is not Mix's layout under a build
  # path, or nil.
  defp build_tail(%{"parts" => parts}, apps) do
    parts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["build", tail] -> if not mix_layout?(tail, apps), do: tail
      _ -> nil
    end)
  end

  @app_dirs ~w(ebin priv include .mix)

  # Nothing, `/consolidated/...`, or `/lib/<app>/<dir>` and below, `<dir>`
  # one of an app's own dirs and `<app>` one of `apps` when given.
  defp mix_layout?("", _apps), do: true
  defp mix_layout?("/consolidated/" <> _, _apps), do: true

  defp mix_layout?("/lib/" <> rest, apps) do
    case String.split(rest, "/", parts: 3) do
      [app, dir | _] when dir in @app_dirs and app not in ["", ".", ".."] ->
        apps == nil or app in apps

      _ ->
        false
    end
  end

  defp mix_layout?(_tail, _apps), do: false

  defp occurrence?(
         %{"chunk" => chunk, "index" => i, "term" => term, "kind" => kind, "parts" => parts} = occ
       )
       when map_size(occ) == 5 and chunk in @rewritten and is_integer(i) and i >= 0 and
              is_list(term) and kind in @kinds and is_list(parts) do
    Enum.all?(term, &(is_integer(&1) and &1 >= 0)) and template?(parts)
  end

  defp occurrence?(_occ), do: false

  # Text and slot names in turn, odd in length, at least one slot.
  defp template?([_text, _slot | _] = parts) do
    parts
    |> Enum.with_index()
    |> Enum.all?(fn {part, i} ->
      is_binary(part) and (rem(i, 2) == 0 or part in @slots)
    end) and rem(length(parts), 2) == 1
  end

  defp template?(_parts), do: false

  @doc "A template's value at `slots`."
  @spec render([String.t()], slots()) :: String.t()
  def render(parts, slots), do: render(parts, slots, [])

  defp render([text], _slots, acc), do: IO.iodata_to_binary([acc, text])

  defp render([text, slot | rest], slots, acc),
    do: render(rest, slots, [acc, text, Map.fetch!(slots, slot)])

  @doc """
  Why the beams of `ebin` (`%{file name => bytes}`, any other file left
  alone) do not show they were compiled from their package's own dir,
  `<deps>/<app>/`, or nil: each beam's `CInf` `source`, the file its
  compile read made absolute, must be a normalised path in that dir (the
  client re-review's R7). A beam with no source (a `deterministic` or
  `slim` compile) or compiled elsewhere does not show the record's deps
  path is its own, and every client 0.9.0 refuses it at install. Reads
  `CInf` without making an atom (`safe_term/1`), so the portal checks it
  at ingest.
  """
  @spec compiled_in_problem(%{String.t() => binary()}, String.t(), String.t()) ::
          String.t() | nil
  def compiled_in_problem(ebin, deps, app)
      when is_map(ebin) and is_binary(deps) and is_binary(app) do
    dir = Path.join(deps, app) <> "/"

    ebin
    |> Enum.filter(fn {name, _} -> Path.extname(name) == ".beam" end)
    |> Enum.sort()
    |> Enum.find_value(fn {name, bytes} -> source_problem(name, beam_source(bytes), dir) end)
  end

  def compiled_in_problem(_ebin, _deps, _app), do: "no ebin"

  defp source_problem(name, {:ok, source}, dir) do
    if not (String.starts_with?(source, dir) and Path.expand(source) == source),
      do: "#{name}: not compiled from #{inspect(dir)}"
  end

  defp source_problem(name, :none, dir),
    do: "#{name}: not compiled from #{inspect(dir)} (no source)"

  defp source_problem(name, :error, _dir), do: "#{name}: unreadable compile info"

  @max_cinf_bytes 1024 * 1024

  defp beam_source(bytes) do
    with {:ok, chunks} <- chunks(bytes),
         data when is_binary(data) and byte_size(data) <= @max_cinf_bytes <- chunk(chunks, "CInf"),
         {:ok, info} when is_list(info) <- safe_term(data) do
      info |> sources() |> one_source()
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp sources(info), do: for({{:atom, "source"}, value} <- info, do: value)

  defp one_source([value]), do: source_text(value)
  defp one_source([]), do: :none
  defp one_source(_values), do: :error

  defp source_text(value) when is_binary(value),
    do: if(String.valid?(value), do: {:ok, value}, else: :error)

  defp source_text(value) when is_list(value) do
    if Enum.all?(value, &(is_integer(&1) and &1 >= 0 and &1 <= 0x10FFFF)),
      do: source_text(List.to_string(value)),
      else: :error
  rescue
    _ -> :error
  end

  defp source_text(_value), do: :error

  @doc """
  An external term format binary decoded without making an atom or
  running anything: an atom is `{:atom, name}`, a string or list a list, a
  tuple a tuple, a map a list of `{key, value}` pairs. Integers, floats,
  binaries and bitstrings as they are. `:error` for anything else (a
  compressed term, a pid, a fun, trailing bytes).
  """
  @spec safe_term(binary()) :: {:ok, term()} | :error
  def safe_term(<<131, rest::binary>>) do
    case etf(rest) do
      {:ok, term, <<>>} -> {:ok, term}
      _ -> :error
    end
  end

  def safe_term(_bytes), do: :error

  defp etf(<<97, n, rest::binary>>), do: {:ok, n, rest}
  defp etf(<<98, n::signed-32, rest::binary>>), do: {:ok, n, rest}
  defp etf(<<70, f::float-64, rest::binary>>), do: {:ok, f, rest}
  defp etf(<<99, _f::binary-size(31), rest::binary>>), do: {:ok, :float, rest}

  defp etf(<<tag, len::16, name::binary-size(len), rest::binary>>) when tag in [100, 118],
    do: {:ok, {:atom, name}, rest}

  defp etf(<<tag, len, name::binary-size(len), rest::binary>>) when tag in [115, 119],
    do: {:ok, {:atom, name}, rest}

  defp etf(<<104, n, rest::binary>>), do: etf_tuple(n, rest)
  defp etf(<<105, n::32, rest::binary>>), do: etf_tuple(n, rest)
  defp etf(<<106, rest::binary>>), do: {:ok, [], rest}

  defp etf(<<107, len::16, chars::binary-size(len), rest::binary>>),
    do: {:ok, :binary.bin_to_list(chars), rest}

  defp etf(<<108, n::32, rest::binary>>) do
    with {:ok, items, rest} <- etf_many(n, rest, []),
         {:ok, tail, rest} <- etf(rest) do
      {:ok, if(tail == [], do: items, else: {:improper, items, tail}), rest}
    end
  end

  defp etf(<<109, len::32, bin::binary-size(len), rest::binary>>), do: {:ok, bin, rest}

  defp etf(<<77, len::32, bits, bin::binary-size(len), rest::binary>>),
    do: {:ok, {:bits, bits, bin}, rest}

  defp etf(<<110, n, _sign, _digits::binary-size(n), rest::binary>>), do: {:ok, :big, rest}
  defp etf(<<111, n::32, _sign, _digits::binary-size(n), rest::binary>>), do: {:ok, :big, rest}

  defp etf(<<116, n::32, rest::binary>>) do
    with {:ok, flat, rest} <- etf_many(2 * n, rest, []),
         do: {:ok, flat |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1), rest}
  end

  defp etf(_bytes), do: :error

  defp etf_tuple(n, rest) do
    with {:ok, items, rest} <- etf_many(n, rest, []), do: {:ok, List.to_tuple(items), rest}
  end

  # Each item takes at least one byte, so `n` is bounded by what is left.
  defp etf_many(0, rest, acc), do: {:ok, Enum.reverse(acc), rest}
  defp etf_many(n, rest, _acc) when n > byte_size(rest), do: :error

  defp etf_many(n, rest, acc) do
    case etf(rest) do
      {:ok, item, rest} -> etf_many(n - 1, rest, [item | acc])
      :error -> :error
    end
  end

  # --- slots -----------------------------------------------------------------

  defp valid_slots(slots) when is_map(slots) do
    if Map.keys(slots) |> Enum.sort() == Enum.sort(@slots) and
         Enum.all?(Map.values(slots), &absolute?/1) do
      [deps, build] = Enum.map(@slots, &Map.fetch!(slots, &1))

      if overlap?(deps, build), do: {:refuse, "the deps and build paths overlap"}, else: :ok
    else
      {:refuse, "slots must name an absolute deps and build path"}
    end
  end

  defp valid_slots(_slots), do: {:refuse, "slots must name an absolute deps and build path"}

  defp absolute?(path),
    do: is_binary(path) and String.valid?(path) and String.starts_with?(path, "/")

  defp overlap?(x, y), do: String.contains?(x, y) or String.contains?(y, x)

  # The two builds' paths must differ everywhere, so a value equal in both
  # beams can hold neither.
  defp distinct(from, to) do
    if Enum.any?(Map.values(from), fn f -> Enum.any?(Map.values(to), &overlap?(f, &1)) end),
      do: {:refuse, "the two builds share a path"},
      else: :ok
  end

  defp needles(slots), do: slots |> Map.values() |> Enum.uniq()

  defp contains?(data, needles) when is_binary(data), do: :binary.match(data, needles) != :nomatch

  # The template of `s`: text and slot names in turn.
  defp parts(s, slots) do
    by_value = Map.new(slots, fn {name, value} -> {value, name} end)

    {parts, last} =
      s
      |> :binary.matches(Map.keys(by_value))
      |> Enum.reduce({[], 0}, fn {pos, len}, {acc, at} ->
        text = binary_part(s, at, pos - at)
        slot = Map.fetch!(by_value, binary_part(s, pos, len))
        {[slot, text | acc], pos + len}
      end)

    Enum.reverse([binary_part(s, last, byte_size(s) - last) | parts])
  end

  # --- the IFF container -------------------------------------------------------

  defp chunks(<<"FOR1", size::32, "BEAM", rest::binary>>) when size == byte_size(rest) + 4 do
    with {:ok, chunks} <- read_chunks(rest, []),
         ids = Enum.map(chunks, &elem(&1, 0)),
         true <- ids == Enum.uniq(ids) do
      {:ok, chunks}
    else
      _ -> {:refuse, "unreadable beam"}
    end
  end

  defp chunks(<<31, 139, _::binary>>), do: {:refuse, "a compressed beam"}
  defp chunks(_bytes), do: {:refuse, "unreadable beam"}

  defp read_chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp read_chunks(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)

    case rest do
      <<_pad::binary-size(^pad), rest::binary>> -> read_chunks(rest, [{id, data} | acc])
      <<>> -> read_chunks(<<>>, [{id, data} | acc])
      _ -> :error
    end
  end

  defp read_chunks(_bytes, _acc), do: :error

  defp form(chunks) do
    body =
      for {id, data} <- chunks, into: <<>> do
        pad = rem(4 - rem(byte_size(data), 4), 4)
        <<id::binary, byte_size(data)::32, data::binary, 0::size(pad * 8)>>
      end

    <<"FOR1", byte_size(body) + 4::32, "BEAM", body::binary>>
  end

  defp same_ids(a, b) do
    if Enum.map(a, &elem(&1, 0)) == Enum.map(b, &elem(&1, 0)),
      do: :ok,
      else: {:refuse, "the second build has other chunks"}
  end

  defp equal_but_metadata(moved, b) do
    case Enum.find(moved, fn {id, data} -> id not in @metadata and data != chunk(b, id) end) do
      nil -> :ok
      {id, _} -> {:refuse, "#{id} differs at another root"}
    end
  end

  defp chunk(chunks, id) do
    case List.keyfind(chunks, id, 0) do
      {^id, data} -> data
      nil -> nil
    end
  end

  # --- finding the occurrences ---------------------------------------------------

  defp scan(chunks, slots) do
    needles = needles(slots)

    chunks
    |> flat_map_ok(fn {id, data} -> scan_chunk(id, data, chunks, slots, needles) end)
    |> then(fn
      {:ok, occs} when length(occs) > @max_occurrences -> {:refuse, "too many paths"}
      other -> other
    end)
  end

  defp scan_chunk(id, _data, _chunks, _slots, _needles) when id in @metadata, do: {:ok, []}

  defp scan_chunk("LitT", data, _chunks, slots, needles),
    do: literal_occurrences(data, slots, needles)

  defp scan_chunk("AtU8", data, chunks, slots, needles),
    do: atom_occurrences(data, chunks, slots, needles)

  defp scan_chunk("Attr", data, _chunks, slots, needles),
    do: attr_occurrences(data, slots, needles)

  defp scan_chunk("Line", data, _chunks, slots, needles),
    do: line_occurrences(data, slots, needles)

  defp scan_chunk(id, data, _chunks, _slots, needles) do
    if contains?(data, needles), do: {:refuse, "a path in #{id}"}, else: {:ok, []}
  end

  defp literal_occurrences(data, slots, needles) do
    with {:ok, entries} <- literals(data) do
      entries
      |> Enum.with_index()
      |> flat_map_ok(&literal_entry(&1, slots, needles))
    end
  end

  defp literal_entry({etf, i}, slots, needles) do
    if contains?(etf, needles),
      do: term_occurrences(etf, slots, needles, "LitT", i),
      else: {:ok, []}
  end

  defp attr_occurrences(data, slots, needles) do
    if contains?(data, needles),
      do: term_occurrences(data, slots, needles, "Attr", 0),
      else: {:ok, []}
  end

  defp term_occurrences(etf, slots, needles, chunk, index) do
    with {:ok, term} <- decode(etf),
         {:ok, [_ | _] = leaves} <- leaves(term, [], needles),
         nil <- Enum.find_value(leaves, fn {_path, _kind, value} -> leaf_problem(value) end) do
      {:ok,
       for {path, kind, value} <- leaves do
         %{
           "chunk" => chunk,
           "index" => index,
           "term" => path,
           "kind" => kind,
           "parts" => parts(value, slots)
         }
       end}
    else
      {:ok, []} -> {:refuse, "a path in #{chunk} #{index} the rewrite cannot reach"}
      {:refuse, _} = refuse -> refuse
    end
  end

  # A value that holds a path is recorded as text around slots, so it must
  # be UTF-8 (the record is JSON) and small (it goes into every manifest).
  defp leaf_problem(value) do
    cond do
      not String.valid?(value) -> {:refuse, "a path in text that is not UTF-8"}
      byte_size(value) > @max_leaf_bytes -> {:refuse, "a path in text over 4 KiB"}
      true -> nil
    end
  end

  defp decode(<<131, 80, _::binary>>), do: {:refuse, "a compressed term"}

  # Misc.BinToTerm, reviewed: only a literal or attribute term that holds a
  # slot value is decoded, at most 4 MiB and never compressed; it may make
  # atoms (the worker's own run VM) and nothing in it is ever called.
  # sobelow_skip ["Misc.BinToTerm"]
  defp decode(etf) when byte_size(etf) <= @max_term_bytes do
    {:ok, :erlang.binary_to_term(etf)}
  rescue
    ArgumentError -> {:refuse, "an unreadable term"}
  end

  defp decode(_etf), do: {:refuse, "a term over 4 MiB"}

  # `{path, kind, value}` of every binary, charlist and atom under `term`
  # that holds a slot value, in walk order.
  defp leaves(term, path, needles) when is_binary(term) do
    if contains?(term, needles), do: {:ok, [{path, "binary", term}]}, else: {:ok, []}
  end

  defp leaves(term, path, needles) when is_atom(term) do
    name = Atom.to_string(term)
    if contains?(name, needles), do: {:ok, [{path, "atom", name}]}, else: {:ok, []}
  end

  defp leaves(term, path, needles) when is_list(term) do
    case charlist(term) do
      {:ok, string} ->
        if contains?(string, needles),
          do: {:ok, [{path, "charlist", string}]},
          else: {:ok, []}

      :error ->
        {items, tail} = split_list(term, [])

        # A proper list's tail, `[]`, holds nothing.
        if(tail == [], do: items, else: items ++ [tail])
        |> Enum.with_index()
        |> all_leaves(path, needles)
    end
  end

  defp leaves(term, path, needles) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.with_index() |> all_leaves(path, needles)

  defp leaves(term, path, needles) when is_map(term) do
    pairs = ordered(term)

    if Enum.any?(pairs, fn {key, _} -> deep_contains?(key, needles) end) do
      {:refuse, "a path in a map key"}
    else
      pairs |> Enum.map(&elem(&1, 1)) |> Enum.with_index() |> all_leaves(path, needles)
    end
  end

  defp leaves(_term, _path, _needles), do: {:ok, []}

  defp all_leaves(indexed, path, needles),
    do: flat_map_ok(indexed, fn {item, i} -> leaves(item, path ++ [i], needles) end)

  defp deep_contains?(term, needles), do: match?({:ok, [_ | _]}, leaves(term, [], needles))

  # A proper, non-empty list of code points.
  defp charlist([_ | _] = list) do
    if proper?(list) and Enum.all?(list, &codepoint?/1),
      do: {:ok, List.to_string(list)},
      else: :error
  end

  defp charlist(_list), do: :error

  defp proper?([]), do: true
  defp proper?([_ | t]), do: proper?(t)
  defp proper?(_), do: false

  defp codepoint?(c), do: is_integer(c) and (c in 0..0xD7FF or c in 0xE000..0x10FFFF)

  # A list's items and its tail (`[]` for a proper list).
  defp split_list([h | t], acc), do: split_list(t, [h | acc])
  defp split_list(tail, acc), do: {Enum.reverse(acc), tail}

  # A map's pairs in term order, as `:maps.iterator(map, :ordered)` gives them.
  defp ordered(map), do: map |> :maps.iterator(:ordered) |> next([])

  defp next(iter, acc) do
    case :maps.next(iter) do
      {k, v, iter} -> next(iter, [{k, v} | acc])
      :none -> Enum.reverse(acc)
    end
  end

  # --- the literal table ---------------------------------------------------------

  # OTP 28 writes it uncompressed (a zero word, then the count); a
  # compressed one (OTP 27 and before) is not read.
  defp literals(<<0::32, count::32, rest::binary>>), do: entries(rest, count, [])
  defp literals(_data), do: {:refuse, "a compressed literal table"}

  defp entries(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp entries(<<len::32, etf::binary-size(len), rest::binary>>, n, acc) when n > 0,
    do: entries(rest, n - 1, [etf | acc])

  defp entries(_rest, _n, _acc), do: {:refuse, "unreadable literal table"}

  defp literal_chunk(entries) do
    body = for etf <- entries, into: <<>>, do: <<byte_size(etf)::32, etf::binary>>
    <<0::32, length(entries)::32, body::binary>>
  end

  # --- the atom table --------------------------------------------------------

  # `{format, atoms}`: OTP 28's long atoms (a negative count, each length a
  # compact-term `u`) or the older byte lengths.
  defp atoms(<<count::signed-32, rest::binary>>) when count < 0,
    do: read_atoms(rest, -count, :long, [])

  defp atoms(<<count::32, rest::binary>>), do: read_atoms(rest, count, :short, [])
  defp atoms(_data), do: {:refuse, "unreadable atom table"}

  defp read_atoms(<<>>, 0, format, acc), do: {:ok, {format, Enum.reverse(acc)}}

  defp read_atoms(rest, n, format, acc) when n > 0 do
    with {:ok, len, rest} <- atom_length(rest, format),
         <<name::binary-size(^len), rest::binary>> <- rest do
      read_atoms(rest, n - 1, format, [name | acc])
    else
      _ -> {:refuse, "unreadable atom table"}
    end
  end

  defp read_atoms(_rest, _n, _format, _acc), do: {:refuse, "unreadable atom table"}

  defp atom_length(<<len::8, rest::binary>>, :short), do: {:ok, len, rest}
  defp atom_length(<<len::4, 0::1, 0::3, rest::binary>>, :long), do: {:ok, len, rest}

  defp atom_length(<<hi::3, 0::1, 1::1, 0::3, lo::8, rest::binary>>, :long),
    do: {:ok, hi * 256 + lo, rest}

  defp atom_length(_rest, _format), do: :error

  defp atom_chunk({:long, names}) do
    body = for name <- names, into: <<>>, do: <<compact_u(byte_size(name))::binary, name::binary>>
    <<-length(names)::signed-32, body::binary>>
  end

  defp atom_chunk({:short, names}) do
    body = for name <- names, into: <<>>, do: <<byte_size(name)::8, name::binary>>
    <<length(names)::32, body::binary>>
  end

  # `beam_asm:encode(?tag_u, N)` for the lengths an atom can have.
  defp compact_u(n) when n < 16, do: <<n::4, 0::4>>
  defp compact_u(n) when n < 2048, do: <<div(n, 256)::3, 1::2, 0::3, rem(n, 256)::8>>

  defp atom_occurrences(data, chunks, slots, needles) do
    if contains?(data, needles),
      do: atom_paths(data, chunks, slots, needles),
      else: {:ok, []}
  end

  defp atom_paths(data, chunks, slots, needles) do
    with {:ok, {_format, names}} <- atoms(data) do
      named = names_in_code(chunks)

      names
      |> Enum.with_index(1)
      |> Enum.filter(fn {name, _} -> contains?(name, needles) end)
      |> flat_map_ok(&named_atom(&1, named, slots))
    end
  end

  defp named_atom({name, i}, named, slots) do
    cond do
      i == 1 or MapSet.member?(named, i) -> {:refuse, "a path in a module or function name"}
      problem = leaf_problem(name) -> problem
      true -> {:ok, [atom_occurrence(i, name, slots)]}
    end
  end

  defp atom_occurrence(i, name, slots),
    do: %{
      "chunk" => "AtU8",
      "index" => i,
      "term" => [],
      "kind" => "atom",
      "parts" => parts(name, slots)
    }

  # The atom indices the import, export, local and fun tables name a module
  # or a function by.
  defp names_in_code(chunks) do
    imports = for <<m::32, f::32, _a::32 <- table(chunks, "ImpT", 12)>>, i <- [m, f], do: i
    exports = for id <- ["ExpT", "LocT"], <<f::32, _::64 <- table(chunks, id, 12)>>, do: f
    funs = for <<f::32, _::binary-size(20) <- table(chunks, "FunT", 24)>>, do: f
    MapSet.new(imports ++ exports ++ funs)
  end

  defp table(chunks, id, size) do
    case chunk(chunks, id) do
      <<count::32, rest::binary>> when byte_size(rest) == count * size -> rest
      _ -> <<>>
    end
  end

  # --- the line table ----------------------------------------------------------

  # `{head, items, names}`: the five header words, the line items' bytes as
  # they are, and the file names, each a 16-bit length and UTF-8.
  defp line_table(<<0::32, _bits::32, _instrs::32, lines::32, count::32, rest::binary>> = data) do
    with {:ok, names_at} <- skip_items(rest, lines, 0),
         <<items::binary-size(^names_at), names::binary>> <- rest,
         {:ok, names} <- line_names(names, count, []) do
      {:ok, {binary_part(data, 0, 20), items, names}}
    else
      _ -> {:refuse, "unreadable line table"}
    end
  end

  defp line_table(_data), do: {:refuse, "unreadable line table"}

  # The bytes the `lines` line items take: each a compact `i` (a line), with
  # a compact `a` (a file name's index) before it when the file changes.
  defp skip_items(_rest, 0, at), do: {:ok, at}

  defp skip_items(rest, lines, at) do
    case compact(rest) do
      {:ok, tag, used} when tag in [1, 2] ->
        <<_::binary-size(^used), next::binary>> = rest
        skip_items(next, if(tag == 1, do: lines - 1, else: lines), at + used)

      _ ->
        :error
    end
  end

  # A compact term's tag and size in bytes (`beam_asm:encode/2`).
  defp compact(<<b, _::binary>>) when Bitwise.band(b, 8) == 0, do: {:ok, Bitwise.band(b, 7), 1}

  defp compact(<<b, _, _::binary>>) when Bitwise.band(b, 16) == 0,
    do: {:ok, Bitwise.band(b, 7), 2}

  defp compact(<<b, rest::binary>>) do
    case Bitwise.bsr(b, 5) do
      7 ->
        with {:ok, 0, used} <- compact(rest),
             <<len_term::binary-size(^used), _::binary>> <- rest,
             {:ok, len} <- compact_value(len_term),
             true <- byte_size(rest) >= used + len + 9 do
          {:ok, Bitwise.band(b, 7), 1 + used + len + 9}
        else
          _ -> :error
        end

      n when byte_size(rest) >= n + 2 ->
        {:ok, Bitwise.band(b, 7), n + 3}

      _ ->
        :error
    end
  end

  defp compact(_rest), do: :error

  defp compact_value(<<n::4, 0::1, _::3>>), do: {:ok, n}
  defp compact_value(<<hi::3, 0::1, 1::1, _::3, lo::8>>), do: {:ok, hi * 256 + lo}
  defp compact_value(_term), do: :error

  defp line_names(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp line_names(<<len::16, name::binary-size(len), rest::binary>>, n, acc) when n > 0,
    do: line_names(rest, n - 1, [name | acc])

  defp line_names(_rest, _n, _acc), do: :error

  defp line_chunk({head, items, names}) do
    body = for name <- names, into: <<>>, do: <<byte_size(name)::16, name::binary>>
    <<head::binary, items::binary, body::binary>>
  end

  defp line_occurrences(data, slots, needles) do
    if contains?(data, needles) do
      with {:ok, {_head, _items, names}} <- line_table(data),
           found = Enum.filter(Enum.with_index(names), &contains?(elem(&1, 0), needles)),
           nil <- Enum.find_value(found, &leaf_problem(elem(&1, 0))) do
        {:ok,
         for {name, j} <- found do
           %{
             "chunk" => "Line",
             "index" => j,
             "term" => [],
             "kind" => "binary",
             "parts" => parts(name, slots)
           }
         end}
      end
    else
      {:ok, []}
    end
  end

  # --- the rewrite ---------------------------------------------------------------

  defp relocate_chunks(chunks, occs, from, to) do
    by_chunk = Enum.group_by(occs, & &1["chunk"])

    old = md5(chunks)

    with :ok <- known_chunks(by_chunk),
         {:ok, chunks} <- rewrite(chunks, "LitT", by_chunk, &rewrite_literals(&1, &2, from, to)),
         {:ok, chunks} <- rewrite(chunks, "AtU8", by_chunk, &rewrite_atoms(&1, &2, from, to)),
         {:ok, chunks} <- rewrite(chunks, "Line", by_chunk, &rewrite_lines(&1, &2, from, to)) do
      new = md5(chunks)

      chunks
      |> put_uniq(new)
      |> rewrite_attr(Map.get(by_chunk, "Attr", []), from, to, old, new)
    end
  end

  defp known_chunks(by_chunk) do
    case Map.keys(by_chunk) -- @rewritten do
      [] -> :ok
      [id | _] -> {:refuse, "an occurrence in #{id}"}
    end
  end

  defp rewrite(chunks, id, by_chunk, fun) do
    case {Map.get(by_chunk, id, []), List.keyfind(chunks, id, 0)} do
      {[], _} ->
        {:ok, chunks}

      {_occs, nil} ->
        {:refuse, "no #{id} chunk"}

      {occs, {^id, data}} ->
        with {:ok, data} <- fun.(data, occs), do: {:ok, List.keystore(chunks, id, 0, {id, data})}
    end
  end

  defp rewrite_literals(data, occs, from, to) do
    with {:ok, entries} <- literals(data),
         {:ok, entries} <- rewrite_entries(entries, Enum.group_by(occs, & &1["index"]), from, to) do
      if length(Enum.uniq(entries)) == length(entries),
        do: {:ok, literal_chunk(entries)},
        else: {:refuse, "two literals would be one at these paths"}
    end
  end

  defp rewrite_entries(entries, by_index, from, to) do
    entries
    |> Enum.with_index()
    |> flat_map_ok(&rewrite_entry(&1, by_index, from, to))
    |> check_indices(by_index, length(entries))
  end

  defp rewrite_entry({etf, i}, by_index, from, to) do
    case Map.get(by_index, i) do
      nil ->
        {:ok, [etf]}

      occs ->
        with {:ok, term} <- rewrite_term(etf, occs, from, to),
             do: {:ok, [:erlang.term_to_binary(term, @literal_opts)]}
    end
  end

  defp check_indices({:ok, _} = ok, by_index, count) do
    if Enum.all?(Map.keys(by_index), &(is_integer(&1) and &1 >= 0 and &1 < count)),
      do: ok,
      else: {:refuse, "an occurrence past the literal table"}
  end

  defp check_indices(refuse, _by_index, _count), do: refuse

  defp rewrite_term(etf, occs, from, to) do
    with {:ok, term} <- decode(etf), do: fold_ok(occs, term, &rewrite_at(&1, &2, from, to))
  end

  defp rewrite_at(occ, term, from, to),
    do: update_in_term(term, occ["term"], &replace(&1, occ, from, to))

  # The value at `path` replaced by `fun`'s result.
  defp update_in_term(term, [], fun), do: fun.(term)

  defp update_in_term(term, [i | path], fun)
       when is_tuple(term) and is_integer(i) and i >= 0 and i < tuple_size(term) do
    with {:ok, value} <- update_in_term(elem(term, i), path, fun),
         do: {:ok, put_elem(term, i, value)}
  end

  defp update_in_term(term, [i | path], fun) when is_list(term) and is_integer(i) and i >= 0 do
    {items, tail} = split_list(term, [])

    cond do
      i < length(items) ->
        with {:ok, value} <- update_in_term(Enum.at(items, i), path, fun),
             do: {:ok, rejoin(List.replace_at(items, i, value), tail)}

      i == length(items) ->
        with {:ok, value} <- update_in_term(tail, path, fun), do: {:ok, rejoin(items, value)}

      true ->
        {:refuse, "a recorded path the literal does not have"}
    end
  end

  defp update_in_term(term, [i | path], fun) when is_map(term) and is_integer(i) and i >= 0 do
    case Enum.at(ordered(term), i) do
      {key, value} ->
        with {:ok, value} <- update_in_term(value, path, fun),
             do: {:ok, Map.put(term, key, value)}

      nil ->
        {:refuse, "a recorded path the literal does not have"}
    end
  end

  defp update_in_term(_term, _path, _fun),
    do: {:refuse, "a recorded path the literal does not have"}

  defp rejoin(items, tail), do: Enum.reduce(Enum.reverse(items), tail, &[&1 | &2])

  # The recorded value, as the beam holds it, becomes its value at `to`.
  defp replace(value, %{"kind" => kind, "parts" => parts}, from, to) when is_list(parts) do
    if as_kind(kind, render(parts, from)) == {:ok, value},
      do: as_kind(kind, render(parts, to)),
      else: {:refuse, "the beam does not hold the recorded path"}
  rescue
    _ -> {:refuse, "an unreadable occurrence"}
  end

  defp replace(_value, _occ, _from, _to), do: {:refuse, "an unreadable occurrence"}

  defp as_kind("binary", s), do: {:ok, s}
  defp as_kind("charlist", s), do: {:ok, String.to_charlist(s)}

  # DOS.StringToAtom, reviewed: an atom the beam itself holds, at the other
  # paths, which loading the relocated beam would make anyway; at most one
  # per recorded occurrence, and at most 255 characters.
  # sobelow_skip ["DOS.StringToAtom"]
  defp as_kind("atom", s) do
    if String.length(s) <= 255,
      do: {:ok, String.to_atom(s)},
      else: {:refuse, "an atom over 255 characters"}
  end

  defp as_kind(_kind, _s), do: {:refuse, "an unknown kind"}

  defp rewrite_atoms(data, occs, from, to) do
    with {:ok, {format, names}} <- atoms(data),
         {:ok, names} <- rewrite_names(names, occs, 1, from, to, 255) do
      if length(Enum.uniq(names)) == length(names),
        do: {:ok, atom_chunk({format, names})},
        else: {:refuse, "two atoms would be one at these paths"}
    end
  end

  defp rewrite_lines(data, occs, from, to) do
    with {:ok, {head, items, names}} <- line_table(data),
         {:ok, names} <- rewrite_names(names, occs, 0, from, to, nil) do
      cond do
        length(Enum.uniq(names)) != length(names) -> {:refuse, "two file names would be one"}
        Enum.any?(names, &(byte_size(&1) > 0xFFFF)) -> {:refuse, "a file name too long"}
        true -> {:ok, line_chunk({head, items, names})}
      end
    end
  end

  # The names (atoms from 1, file names from 0) with each occurrence's index
  # rewritten; an atom must stay at most `max` characters.
  defp rewrite_names(names, occs, base, from, to, max) do
    indexed = names |> Enum.with_index(base) |> Map.new(fn {n, i} -> {i, n} end)

    Enum.reduce_while(occs, {:ok, indexed}, fn occ, {:ok, acc} ->
      i = occ["index"]

      with true <- is_map_key(acc, i) and occ["term"] == [],
           true <- Map.fetch!(acc, i) == render(occ["parts"], from),
           new = render(occ["parts"], to),
           true <- max == nil or String.length(new) <= max do
        {:cont, {:ok, Map.put(acc, i, new)}}
      else
        _ -> {:halt, {:refuse, "the beam does not hold the recorded path"}}
      end
    end)
    |> then(fn
      {:ok, map} -> {:ok, map |> Enum.sort() |> Enum.map(&elem(&1, 1))}
      refuse -> refuse
    end)
  rescue
    _ -> {:refuse, "an unreadable occurrence"}
  end

  # `beam_asm:module_md5/1`: the essentials' data in their order, with
  # every fun's `old_uniq` zeroed.
  defp md5(chunks) do
    @essentials
    |> Enum.flat_map(fn id ->
      case chunk(chunks, id) do
        nil -> []
        data when id == "FunT" -> [zero_uniq(data)]
        data -> [data]
      end
    end)
    |> :erlang.md5()
  end

  defp zero_uniq(<<count::32, table::binary>>),
    do:
      <<count::32,
        for(<<keep::binary-size(20), _::32 <- table>>, into: <<>>, do: <<keep::binary, 0::32>>)::binary>>

  defp put_uniq(chunks, <<uniq::27, _::101>>) do
    case List.keyfind(chunks, "FunT", 0) do
      {"FunT", <<count::32, table::binary>>} ->
        funs =
          for <<keep::binary-size(20), _::32 <- table>>,
            into: <<>>,
            do: <<keep::binary, uniq::32>>

        List.keystore(chunks, "FunT", 0, {"FunT", <<count::32, funs::binary>>})

      nil ->
        chunks
    end
  end

  # `Attr` with its occurrences rewritten and a default `vsn` (the old md5)
  # set to the new md5. A `vsn` that is neither the old md5 nor set by the
  # module itself means the md5 is not taken as the compiler takes it.
  defp rewrite_attr(chunks, occs, from, to, old, new) do
    case List.keyfind(chunks, "Attr", 0) do
      nil when occs == [] ->
        {:ok, chunks}

      nil ->
        {:refuse, "no Attr chunk"}

      {"Attr", data} when occs == [] and old == new ->
        {:ok, List.keystore(chunks, "Attr", 0, {"Attr", data})}

      {"Attr", data} ->
        <<old_vsn::128>> = old
        <<new_vsn::128>> = new

        with {:ok, attrs} <- decode(data),
             {:ok, attrs} <- rewrite_attrs(attrs, occs, from, to),
             {:ok, attrs} <- put_vsn(attrs, old_vsn, new_vsn) do
          {:ok, List.keystore(chunks, "Attr", 0, {"Attr", :erlang.term_to_binary(attrs)})}
        end
    end
  end

  defp rewrite_attrs(attrs, occs, from, to) do
    fold_ok(occs, attrs, fn occ, attrs ->
      if occ["index"] == 0,
        do: rewrite_at(occ, attrs, from, to),
        else: {:refuse, "an occurrence past the attributes"}
    end)
  end

  defp put_vsn(attrs, old, new) when is_list(attrs) do
    case List.keyfind(attrs, :vsn, 0) do
      {:vsn, [^old]} ->
        {:ok, List.keyreplace(attrs, :vsn, 0, {:vsn, [new]})}

      {:vsn, _own} when old == new ->
        {:ok, attrs}

      {:vsn, [n]} when is_integer(n) and n >= 0 and n < @md5_limit ->
        {:refuse, "the vsn is not the md5"}

      _ ->
        {:ok, attrs}
    end
  end

  defp put_vsn(_attrs, _old, _new), do: {:refuse, "unreadable attributes"}

  # No slot value of `from` may be left in a rewritten chunk.
  defp nothing_left(chunks, from, _to) do
    needles = needles(from)

    case Enum.find(chunks, fn {id, data} -> id in @rewritten and contains?(data, needles) end) do
      nil -> :ok
      {id, _} -> {:refuse, "a builder path is left in #{id}"}
    end
  end

  # A protocol (`__protocol__/1` exported) is consolidated from its `Dbgi`.
  defp not_protocol(_chunks, []), do: :ok

  defp not_protocol(chunks, _occs) do
    with {:ok, {_format, names}} <- atoms(chunk(chunks, "AtU8") || <<>>) do
      exported =
        for <<f::32, arity::32, _label::32 <- table(chunks, "ExpT", 12)>>,
          do: {Enum.at(names, f - 1), arity}

      if {"__protocol__", 1} in exported,
        do: {:refuse, "a protocol holds the path"},
        else: :ok
    end
  end
end
