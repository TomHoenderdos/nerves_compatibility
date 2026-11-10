defmodule Portal.Reports.Quotas do
  @moduledoc """
  Per-UTC-day caps on report-triggered builds: `global` (default 50 a day),
  `package:<name>` (3) and `reporter:<reporter key>` (5).

  A reservation is one conditional upsert per key,

      INSERT INTO precompiled_report_quotas (key, day, used) VALUES ($1, $2, 1)
      ON CONFLICT (key, day) DO UPDATE SET used = used + 1
      WHERE used < $cap RETURNING used

  which Postgres runs under the row's lock, so concurrent jobs can never take
  a key past its cap. The row's `id` and `inserted_at` come from the column
  defaults.

  `reserve/2` runs inside the caller's transaction and does not roll back
  itself. A reservation is released only by rolling that transaction back:
  on `{:error, :cap}` the caller rolls back, and the keys reserved before the
  refused one are released with it; a caller that reserved and then decides
  not to queue (or fails to insert the job) rolls back the same way. Once the
  transaction commits the reservation stays taken for the day, even if the
  build later fails or never runs, so the caps err on the conservative side.
  """

  import Ecto.Query, only: [from: 2]

  alias Portal.Repo

  @defaults %{global: 50, package: 3, reporter: 5}

  @reserve_sql """
  INSERT INTO precompiled_report_quotas AS q (key, day, used) VALUES ($1, $2, 1)
  ON CONFLICT (key, day) DO UPDATE SET used = q.used + 1
  WHERE q.used < $3
  RETURNING q.used
  """

  @doc "The configured caps, over the defaults."
  @spec caps() :: %{global: pos_integer(), package: pos_integer(), reporter: pos_integer()}
  def caps do
    config = Application.get_env(:portal, __MODULE__, [])
    Map.new(@defaults, fn {k, v} -> {k, Keyword.get(config, k, v)} end)
  end

  @doc """
  Takes one from every key's budget for `day`, or none (see the moduledoc).

  The keys are reserved in sorted order, whatever order they are given in, so
  concurrent transactions lock shared keys in one order and cannot deadlock.
  A cap that is not a positive integer (a cap of 0 included) refuses the
  whole reservation with `{:error, :cap}` before anything is taken.
  """
  @spec reserve([{String.t(), pos_integer()}], Date.t()) :: :ok | {:error, :cap}
  def reserve(keys, %Date{} = day) when is_list(keys) do
    keys = Enum.sort_by(keys, fn {key, _cap} when is_binary(key) -> key end)

    if Enum.all?(keys, fn {_key, cap} -> is_integer(cap) and cap > 0 end),
      do: reserve_sorted(keys, day),
      else: {:error, :cap}
  end

  defp reserve_sorted(keys, day) do
    Enum.reduce_while(keys, :ok, fn {key, cap}, :ok ->
      case Repo.query!(@reserve_sql, [key, day, cap]) do
        %{num_rows: 1} -> {:cont, :ok}
        %{num_rows: 0} -> {:halt, {:error, :cap}}
      end
    end)
  end

  @doc "Deletes the counters of every day before `day`; how many went."
  @spec prune(Date.t()) :: non_neg_integer()
  def prune(%Date{} = day) do
    {n, _} = Repo.delete_all(from(q in "precompiled_report_quotas", where: q.day < ^day))
    n
  end
end
