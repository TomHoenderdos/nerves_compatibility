defmodule Portal.Pins.Refeed do
  @moduledoc """
  Feeds the stored project locks again when their Nerves system releases
  (stream S11). A pinned firmware build is built and served at its lock's
  exact system release; before this, nothing fed a lock again after the
  operator's one feed, so the projects that float to a new release missed
  every pinned build (2026-11-25, rpi4 and rpi5 2.2.3).

  `offer/1` runs in `Portal.Workers.UpdateCheck`, on its registry snapshot:
  for each system a stored lock names (`Portal.Pins.Locks`), when the
  newest stable release on Hex is newer than some stored lock's own release
  and that lock was not fed again at it, it queues one
  `Portal.Workers.PinRefeed` for the system, the release and the set of
  those locks (`pending`, a hash of their sha256s). The job is unique on
  all three in every state but cancelled and discarded (review S2): a lock
  stored after the release's job completed makes a new set and is fed
  too, and a job that was cancelled (the ABI row a day late) or ran out of
  attempts is offered again on the next check. The job checks the release,
  bounds the work and feeds.

  `NCC_PIN_REFEED=0` (`config :portal, Portal.Pins.Refeed, enabled:`) offers
  nothing, and a job already queued feeds nothing (review S1).
  """

  alias Portal.Pins.Locks
  alias Portal.Workers.PinRefeed

  @doc """
  Queues a `Portal.Workers.PinRefeed` per system with a newer release than
  its stored locks were fed at; `registry` is `Portal.HexRegistry`'s
  snapshot (`%{name, versions}` each). Returns how many it queued.
  """
  @spec offer([map()]) :: non_neg_integer()
  def offer(registry) when is_list(registry) do
    if enabled?(), do: offer_all(registry), else: 0
  end

  defp offer_all(registry) do
    by_system = Enum.group_by(Locks.heads(), & &1.system)
    versions = Map.new(registry, &{&1.name, Map.get(&1, :versions, [])})

    Enum.count(by_system, fn {system, locks} ->
      with newest when is_binary(newest) <- newest_stable(Map.get(versions, system, [])),
           [_ | _] = behind <- Enum.filter(locks, &behind?(&1, system, newest)) do
        insert(system, newest, behind)
      else
        _ -> false
      end
    end)
  end

  @doc "Whether the re-feed is on (`NCC_PIN_REFEED`, default on)."
  @spec enabled?() :: boolean()
  def enabled? do
    :portal |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true) != false
  end

  @doc false
  # The `pending` key of a job for `locks` (`%{sha256}` each).
  @spec pending([map()]) :: String.t()
  def pending(locks) do
    locks
    |> Enum.map(& &1.sha256)
    |> Enum.sort()
    |> Enum.join(",")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp behind?(lock, system, newest) do
    newer?(newest, lock.release) and Map.get(lock.refed, system) != newest
  end

  defp insert(system, version, locks) do
    case %{system: system, version: version, pending: pending(locks)}
         |> PinRefeed.new()
         |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: false}} -> true
      _ -> false
    end
  end

  defp newest_stable(versions) do
    versions
    |> Enum.map(&to_string/1)
    |> Enum.flat_map(fn v ->
      case Version.parse(v) do
        {:ok, %Version{pre: []} = parsed} -> [{parsed, v}]
        _ -> []
      end
    end)
    |> Enum.max_by(&elem(&1, 0), Version, fn -> nil end)
    |> case do
      {_parsed, v} -> v
      nil -> nil
    end
  end

  defp newer?(candidate, current) when is_binary(current) do
    case {Version.parse(candidate), Version.parse(current)} do
      {{:ok, a}, {:ok, b}} -> Version.compare(a, b) == :gt
      _ -> false
    end
  end

  defp newer?(_candidate, _current), do: false

  @doc false
  # The registry client the job reads releases from (tests).
  @spec hex() :: module()
  def hex do
    :portal |> Application.get_env(__MODULE__, []) |> Keyword.get(:hex, Portal.HexDeps)
  end
end
