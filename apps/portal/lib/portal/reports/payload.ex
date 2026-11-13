defmodule Portal.Reports.Payload do
  @moduledoc """
  Checks a miss report body at every level and normalises it.

  Everything the client may send is listed here; any other key, at any depth,
  refuses the report. Values are checked against narrow shapes (versions parse,
  names follow Hex rules, checksums are hex), so nothing free-form reaches the
  database except `reason`, cut at 300 characters, and `contact`.

  `format` may be any integer from 1 to `current_format/0`: a newer client
  bumps it, and the server keeps accepting every older format.

  `reason_code` comes from the client's fixed table (`known_codes/0`, the same
  list as the client's `Precompiled.Reason`). A code this server does not know
  is stored as `"unknown"`, with the `reason` text kept, so a newer client is
  never refused for it.
  """

  @current_format 1

  @known_codes ~w(hit not_in_batch not_built_version not_built_target
                  build_method_unknown build_method_override build_method_mismatch
                  malformed_entry rule8_unscannable rule8_env rule8_target build_predates
                  toolchain_elixir toolchain_otp dep_env_differs checksum_differs
                  closure_mismatch closure_checksum closure_absent closure_without
                  closure_env_absent
                  compile_env_differs excepted revoked_provenance revoked_not_in_batch
                  remove_failed deadline_passed fetch_failed verify_failed install_failed
                  internal system_version_abi toolchain_otp_minor needed_lib_missing
                  symbol_version_missing system_unknown system_bound_compile
                  env_differs env_set_at_build env_all config_unrecorded
                  config_order_differs)

  @top ~w(format client built_at elixir otp os target system system_version lines lock contact)
  @os_keys ~w(family arch)
  @line_keys ~w(name version status reason_code reason_args reason)
  @lock_keys ~w(name version checksum)

  @max_lines 500
  @max_lock 1000
  @max_args 8
  @max_arg 64
  @max_reason 300
  @max_contact 100

  @arch ~r/\A[a-z0-9_.-]{1,64}\z/
  @target ~r/\A[a-z0-9_]{1,64}\z/
  @package ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @checksum ~r/\A[0-9a-fA-F]{64}\z/
  @max_named 5
  # Not printable: controls, format characters (bidi overrides, zero-width),
  # line and paragraph separators, private use and unassigned code points.
  @unprintable ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cn}]/u
  # The client's own argument rule (`Precompiled.Reason`): names and versions.
  @arg ~r/\A[A-Za-z0-9_.+:\-]{0,64}\z/

  @type line :: %{
          name: String.t(),
          version: String.t(),
          status: :hit | :miss | :fail,
          reason_code: String.t(),
          reason_args: [String.t()],
          reason: String.t() | nil
        }
  @type normalized :: %{
          format: pos_integer(),
          client: String.t(),
          built_at: DateTime.t() | nil,
          elixir: String.t(),
          otp: 20..99,
          os: %{family: String.t(), arch: String.t()},
          target: String.t(),
          system: String.t() | nil,
          system_version: String.t() | nil,
          contact: String.t() | nil,
          lines: [line()],
          lock: [%{String.t() => String.t()}]
        }

  @doc "The newest report format this server reads."
  @spec current_format() :: pos_integer()
  def current_format, do: @current_format

  @doc "Every `reason_code` the client can send."
  @spec known_codes() :: [String.t()]
  def known_codes, do: @known_codes

  @doc """
  `{:ok, normalized}`, or `{:error, reasons}` naming each refused field.
  `:current_format` stands in for `current_format/0` (tests).
  """
  @spec validate(term(), keyword()) :: {:ok, normalized()} | {:error, [String.t()]}
  def validate(body, opts \\ [])

  def validate(%{} = body, opts) do
    current = Keyword.get(opts, :current_format, @current_format)

    {fields, errors} =
      {%{}, Enum.reverse(unknown(body, @top, ""))}
      |> field(:format, body["format"], &format(&1, current))
      |> field(:client, body["client"], &version/1)
      |> field(:built_at, body["built_at"], optional(&datetime/1))
      |> field(:elixir, body["elixir"], &version/1)
      |> field(:otp, body["otp"], &otp/1)
      |> field(:os, body["os"], &os/1)
      |> field(:target, body["target"], &matches(&1, @target))
      |> field(:system, body["system"], optional(&matches(&1, @package)))
      |> field(:system_version, body["system_version"], optional(&version/1))
      |> field(:lines, body["lines"], &lines/1)
      |> field(:lock, body["lock"], &lock/1)
      |> field(:contact, body["contact"], optional(&contact/1))

    if errors == [], do: {:ok, fields}, else: {:error, Enum.reverse(errors)}
  end

  def validate(_body, _opts), do: {:error, ["body must be a JSON object"]}

  @doc """
  SHA-256 (lowercase hex) of the normalised lines, lock and context, in a fixed
  order: two reports of the same build hash alike whoever sent them and
  whatever contact they gave. `contact` and `built_at` are left out.
  """
  @spec hash(normalized()) :: String.t()
  def hash(p) do
    material = %{
      format: p.format,
      client: p.client,
      elixir: p.elixir,
      otp: p.otp,
      os: p.os,
      target: p.target,
      system: p.system,
      system_version: p.system_version,
      lines: Enum.sort(p.lines),
      lock: Enum.sort(p.lock)
    }

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(material, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  # A check answers `{:error, why}` to be labelled with the field's name, or
  # `{:error, {:full, why}}` when `why` already names the nested field.
  defp field({fields, errors}, key, value, check) do
    case check.(value) do
      {:ok, v} -> {Map.put(fields, key, v), errors}
      {:error, {:full, why}} -> {fields, [why | errors]}
      {:error, why} -> {fields, ["#{key}: #{why}" | errors]}
    end
  end

  # Names at most `@max_named` unknown keys, each cut to 40 printable
  # characters, and counts the rest: the error never grows with the body.
  defp unknown(map, allowed, prefix) do
    {named, rest} = map |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.split(@max_named)
    named = Enum.map(named, &"#{prefix}#{echo(&1)}: unknown field")

    case length(rest) do
      0 -> named
      n -> named ++ ["#{prefix}*: and #{n} more unknown fields"]
    end
  end

  # A key with nothing printable in it still gets a label, so the error
  # never reads ": unknown field" with an empty name.
  defp echo(key) when is_binary(key) do
    case key
         |> String.replace_invalid("?")
         |> String.replace(@unprintable, "")
         |> String.slice(0, 40) do
      "" -> "(unprintable)"
      label -> label
    end
  end

  defp echo(key), do: key |> inspect(limit: 5, printable_limit: 40) |> echo()

  defp optional(check) do
    fn
      nil -> {:ok, nil}
      value -> check.(value)
    end
  end

  defp labelled({:ok, v}, _label), do: {:ok, v}
  defp labelled({:error, why}, label), do: {:error, "#{label}: #{why}"}

  # ── scalars ───────────────────────────────────────────────────────────────

  defp format(v, current) when is_integer(v) and v >= 1 and v <= current, do: {:ok, v}
  defp format(_v, current), do: {:error, "must be an integer from 1 to #{current}"}

  defp version(v) when is_binary(v) and byte_size(v) <= 64 do
    case Version.parse(v) do
      {:ok, _} -> {:ok, v}
      :error -> {:error, "not a version"}
    end
  end

  defp version(_v), do: {:error, "not a version"}

  defp otp(v) when is_integer(v) and v >= 20 and v <= 99, do: {:ok, v}
  defp otp(_v), do: {:error, "must be an integer from 20 to 99"}

  defp datetime(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, "not an ISO 8601 time"}
    end
  end

  defp datetime(_v), do: {:error, "not an ISO 8601 time"}

  defp matches(v, re) when is_binary(v) do
    if Regex.match?(re, v), do: {:ok, v}, else: {:error, "malformed"}
  end

  defp matches(_v, _re), do: {:error, "malformed"}

  defp os(%{} = os) do
    with [] <- unknown(os, @os_keys, "os."),
         {:ok, family} <- labelled(family(os["family"]), "os.family"),
         {:ok, arch} <- labelled(matches(os["arch"], @arch), "os.arch") do
      {:ok, %{family: family, arch: arch}}
    else
      [_ | _] = unknown -> {:error, {:full, Enum.join(unknown, "; ")}}
      {:error, why} -> {:error, {:full, why}}
    end
  end

  defp os(_os), do: {:error, "must be an object"}

  defp family(f) when f in ["unix", "win32"], do: {:ok, f}
  defp family(_f), do: {:error, "must be unix or win32"}

  defp contact(c) when is_binary(c) do
    cond do
      not String.valid?(c) -> {:error, "not UTF-8"}
      String.length(c) > @max_contact -> {:error, "at most #{@max_contact} characters"}
      Regex.match?(@unprintable, c) -> {:error, "unprintable characters"}
      String.trim(c) == "" -> {:ok, nil}
      true -> {:ok, String.trim(c)}
    end
  end

  defp contact(_c), do: {:error, "must be a string"}

  # ── lists ─────────────────────────────────────────────────────────────────

  defp lines(list) when is_list(list) and length(list) <= @max_lines,
    do: collect(list, "lines", &line/2)

  defp lines(list) when is_list(list), do: {:error, "at most #{@max_lines} lines"}
  defp lines(_list), do: {:error, "must be a list"}

  defp lock(list) when is_list(list) and length(list) <= @max_lock,
    do: collect(list, "lock", &lock_entry/2)

  defp lock(list) when is_list(list), do: {:error, "at most #{@max_lock} lock entries"}
  defp lock(_list), do: {:error, "must be a list"}

  defp collect(list, name, check) do
    {items, errors} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {item, i}, {ok, bad} ->
        case check.(item, "#{name}[#{i}].") do
          {:ok, v} -> {[v | ok], bad}
          {:error, why} -> {ok, [why | bad]}
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, Enum.reverse(items)}
      errors -> {:error, {:full, summarise(errors, name)}}
    end
  end

  defp summarise(errors, name) do
    {named, rest} = Enum.split(errors, @max_named)

    case length(rest) do
      0 -> Enum.join(named, "; ")
      n -> Enum.join(named ++ ["#{name}: and #{n} more refused entries"], "; ")
    end
  end

  defp line(%{} = l, prefix) do
    with [] <- unknown(l, @line_keys, prefix),
         {:ok, name} <- labelled(matches(l["name"], @package), prefix <> "name"),
         {:ok, version} <- labelled(version(l["version"]), prefix <> "version"),
         {:ok, status} <- labelled(status(l["status"]), prefix <> "status"),
         {:ok, code} <- labelled(reason_code(l["reason_code"]), prefix <> "reason_code"),
         {:ok, args} <- labelled(reason_args(l["reason_args"]), prefix <> "reason_args"),
         {:ok, reason} <- labelled(reason(l["reason"]), prefix <> "reason") do
      {:ok,
       %{
         name: name,
         version: version,
         status: status,
         reason_code: code,
         reason_args: args,
         reason: reason
       }}
    else
      [_ | _] = unknown -> {:error, Enum.join(unknown, "; ")}
      {:error, _} = error -> error
    end
  end

  defp line(_l, prefix), do: {:error, String.trim_trailing(prefix, ".") <> ": must be an object"}

  defp status("hit"), do: {:ok, :hit}
  defp status("miss"), do: {:ok, :miss}
  defp status("fail"), do: {:ok, :fail}
  defp status(_), do: {:error, "must be hit, miss or fail"}

  defp reason_code(code) when is_binary(code) and code in @known_codes, do: {:ok, code}
  defp reason_code(code) when is_binary(code), do: {:ok, "unknown"}
  defp reason_code(_code), do: {:error, "must be a string"}

  defp reason_args(nil), do: {:ok, []}

  defp reason_args(args) when is_list(args) and length(args) <= @max_args do
    if Enum.all?(args, &(is_binary(&1) and Regex.match?(@arg, &1))),
      do: {:ok, args},
      else: {:error, "each a name or version of at most #{@max_arg} characters"}
  end

  defp reason_args(_args), do: {:error, "at most #{@max_args} strings"}

  defp reason(nil), do: {:ok, nil}

  defp reason(r) when is_binary(r) do
    if String.valid?(r),
      do: {:ok, r |> String.replace(@unprintable, " ") |> String.slice(0, @max_reason)},
      else: {:error, "not UTF-8"}
  end

  defp reason(_r), do: {:error, "must be a string"}

  defp lock_entry(%{} = e, prefix) do
    with [] <- unknown(e, @lock_keys, prefix),
         {:ok, name} <- labelled(matches(e["name"], @package), prefix <> "name"),
         {:ok, version} <- labelled(version(e["version"]), prefix <> "version"),
         {:ok, checksum} <- labelled(matches(e["checksum"], @checksum), prefix <> "checksum") do
      {:ok, %{"name" => name, "version" => version, "checksum" => String.downcase(checksum)}}
    else
      [_ | _] = unknown -> {:error, Enum.join(unknown, "; ")}
      {:error, _} = error -> error
    end
  end

  defp lock_entry(_e, prefix),
    do: {:error, String.trim_trailing(prefix, ".") <> ": must be an object"}
end
