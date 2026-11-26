defmodule Portal.Workers.PinRefeed do
  @moduledoc """
  Oban worker (queue `:intake`, the web host) that feeds the stored project
  locks of one Nerves system again at one new release (stream S11,
  `Portal.Pins.Refeed`): `Portal.Pins.from_lock/2` with `system_release:`
  and `dry_run: false`, so every native set of each lock is queued as a
  pinned firmware build at that release, with the feed's own `cap`,
  `judged`, `served` and `queued_dup` skips. On the web host, because a
  lock fed with `deterministic: true` reads the rendered manifests.

  Before it feeds, the release must be one the worker builds: its own
  `nerves` requirement accepts the worker's Nerves
  (`Compatibility.Nerves.buildable?/1`), else the job is cancelled
  (`:not_nerves_2`); and its `catalog_system_abi` row must hold its OTP,
  which `Portal.Workers.SystemAbiObserve` reads within hours of a release,
  else the job snoozes an hour, at most 24 times, then is cancelled
  (`:system_abi_unknown`). A registry that does not answer snoozes too.

  At most 20 locks a perform, oldest feed first; it snoozes a minute
  while more remain. Each lock fed is recorded (`Portal.Pins.Locks.refed/3`),
  so a retry feeds only the rest.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:system, :version], states: :all]

  require Ash.Query
  require Logger

  alias Portal.Pins.{Locks, Refeed}

  @batch 20
  @abi_waits 24
  @abi_snooze 3600

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"system" => system, "version" => version}, attempt: attempt}) do
    case check(system, version) do
      :ok -> feed(system, version)
      {:wait, _why} when attempt <= @abi_waits -> {:snooze, @abi_snooze}
      {:wait, why} -> {:cancel, why}
      {:cancel, why} -> {:cancel, why}
    end
  end

  defp check(system, version) do
    with {:ok, releases} <- Refeed.hex().releases(system, []),
         %{deps: deps} <- Enum.find(releases, &(&1.version == version)),
         true <- buildable?(deps) || :not_nerves_2,
         true <- abi_known?(system, version) || :abi do
      :ok
    else
      {:error, :hex_registry_unavailable} -> {:wait, :registry_unavailable}
      :abi -> {:wait, :system_abi_unknown}
      :not_nerves_2 -> {:cancel, :not_nerves_2}
      _ -> {:cancel, :unknown_release}
    end
  end

  defp buildable?(deps) do
    Enum.any?(
      deps,
      &(&1.package == "nerves" and Compatibility.Nerves.buildable?(&1.requirement))
    )
  end

  defp abi_known?(system, version) do
    Portal.Catalog.SystemAbi
    |> Ash.Query.filter(system_pkg == ^system and version == ^version)
    |> Ash.Query.select([:otp])
    |> Ash.read_one!(domain: Portal.Catalog)
    |> case do
      %{otp: otp} when is_binary(otp) -> true
      _ -> false
    end
  end

  defp feed(system, version) do
    locks = Locks.pending(system, version, @batch)

    Enum.each(locks, fn lock ->
      opts =
        [system: system, system_release: version, dry_run: false, hex: Refeed.hex()] ++
          if(lock.toolchain, do: [toolchain: lock.toolchain], else: []) ++
          if(lock.deterministic, do: [deterministic: true], else: [])

      case Portal.Pins.from_lock(lock.content, opts) do
        {:ok, report} ->
          Logger.info(
            "Pin re-feed #{system} #{version} lock #{String.slice(lock.sha256, 0, 12)}: " <>
              "#{report.counts["queue"]} queued, #{inspect(Map.delete(report.counts, "queue"))}"
          )

        {:error, reason} ->
          Logger.warning(
            "Pin re-feed #{system} #{version} lock #{String.slice(lock.sha256, 0, 12)}: " <>
              inspect(reason)
          )
      end

      :ok = Locks.refed(lock.sha256, system, version)
    end)

    if length(locks) == @batch, do: {:snooze, 60}, else: :ok
  end
end
