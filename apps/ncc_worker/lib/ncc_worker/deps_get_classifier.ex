defmodule NccWorker.DepsGetClassifier do
  @moduledoc """
  Classifies a failure of `mix deps.get` for the package under test
  (`NccWorker.Project.add_package/4`'s own `deps.get`, which runs before the
  lock policy, the host compile or any firmware build) into `:transient` or
  `:deterministic`.

  A transient failure is network or registry trouble -- DNS, a refused or
  dropped connection, a timeout, a TLS handshake problem, or an HTTP 5xx/429
  from `hex.pm`/`repo.hex.pm` -- where a retry could well succeed. `NccWorker.Worker`
  keeps that an `{:error, ...}` (exit `10`), same as any other internal
  failure, so `Portal.Workers.Build` retries it.

  Everything else is deterministic for this package and version: a
  dependency's `mix.exs` raising, a version resolution conflict ("Failed to
  use ... because", "Unchecked dependencies", "could not find a version"), a
  package that does not exist, and so on. Retrying one of those three times a
  day only burns build slots on the same failure and discards the run every
  time, so `Worker` records it as a normal `result.json` verdict instead
  (`status: "error"`, exit `0`) and the portal ingests it once.

  Unrecognised output defaults to `:deterministic`: a failure this module
  cannot name must match a known transient pattern to earn a retry, which is
  the conservative direction -- the alternative is exactly the bug this module
  fixes, a deterministic failure retried forever because nothing recognised
  it.
  """

  @type verdict :: :transient | :deterministic

  # Case insensitive: Hex and Erlang's own error atoms print lowercase, but a
  # wrapping "Request failed (:nxdomain)" or similar is not guaranteed to.
  @transient_patterns [
    # DNS, refused, reset or otherwise dropped connections, and the generic
    # timeouts Erlang's ssl/inets report as `:error` tuple atoms.
    ~r/:nxdomain\b/i,
    ~r/:econnrefused\b/i,
    ~r/:econnreset\b/i,
    ~r/:ehostunreach\b/i,
    ~r/:enetunreach\b/i,
    ~r/:etimedout\b/i,
    ~r/\btimed[ _]?out\b/i,
    ~r/\btimeout\b/i,
    ~r/:closed\b/i,
    ~r/connection closed/i,
    ~r/connection refused/i,
    # Hex's own wording for a registry/network fetch that did not complete.
    ~r/failed to fetch/i,
    ~r/request failed/i,
    ~r/could not fetch/i,
    # TLS/SSL handshake and certificate trouble.
    ~r/tls_alert/i,
    ~r/\btls\b.{0,40}\berror\b/i,
    ~r/\bssl\b.{0,40}\berror\b/i,
    ~r/certificate verify failed/i,
    ~r/handshake[ _]failure/i
  ]

  # An HTTP 5xx or 429 response named on the same line as the Hex host it came
  # from: a status code alone is too easy to confuse with a version number or
  # line number elsewhere in the output.
  @hex_host ~r/(?:hex\.pm|repo\.hex\.pm)/i
  @hex_status ~r/\b(?:429|5\d\d)\b/

  @doc "Classifies a `mix deps.get` failure's combined (stdout+stderr) output."
  @spec classify(String.t()) :: verdict()
  def classify(output) when is_binary(output) do
    if transient?(output), do: :transient, else: :deterministic
  end

  defp transient?(output) do
    Enum.any?(@transient_patterns, &Regex.match?(&1, output)) or hex_http_error?(output)
  end

  defp hex_http_error?(output) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.any?(&(Regex.match?(@hex_host, &1) and Regex.match?(@hex_status, &1)))
  end
end
