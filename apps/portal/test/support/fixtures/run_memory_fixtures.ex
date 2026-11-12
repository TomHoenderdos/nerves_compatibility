defmodule Portal.Test.RunMemoryFixtures do
  @moduledoc "Inserts `Portal.Catalog.RunMemory` rows, for the memory stats and pages."

  alias Portal.Catalog.RunMemory

  @gib 1024 * 1024 * 1024

  def insert_run_memory!(attrs) do
    defaults = %{
      run_id: "run-#{System.unique_integer([:positive])}",
      kind: :firmware,
      package: "jason",
      version: "1.0.0",
      exit_code: 0,
      memory_limit_bytes: 3 * @gib,
      peak_used_bytes: @gib,
      finished_at: DateTime.utc_now()
    }

    RunMemory
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs))
    |> Ash.create!(domain: Portal.Catalog)
  end

  def days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  @doc """
  jason: three firmware runs in the window (1 GiB, 2 GiB, no side file), one
  older than 30 days at 9 GiB, one toolchain run at 600 MiB of 2 GiB. exla:
  one firmware run at 1 GiB and one OOM kill at its 3 GiB limit. Three warm
  runs (500, 700, 900 MiB), the 900 MiB one outside the window.
  """
  def seed_run_memory! do
    insert_run_memory!(%{package: "jason", peak_used_bytes: 1 * @gib, finished_at: days_ago(3)})
    insert_run_memory!(%{package: "jason", peak_used_bytes: 2 * @gib, finished_at: days_ago(2)})
    insert_run_memory!(%{package: "jason", peak_used_bytes: nil, finished_at: days_ago(1)})
    insert_run_memory!(%{package: "jason", peak_used_bytes: 9 * @gib, finished_at: days_ago(31)})

    insert_run_memory!(%{
      package: "jason",
      kind: :toolchain,
      peak_used_bytes: 600 * 1024 * 1024,
      memory_limit_bytes: 2 * @gib,
      finished_at: days_ago(1)
    })

    insert_run_memory!(%{package: "exla", peak_used_bytes: @gib, finished_at: days_ago(5)})

    insert_run_memory!(%{
      package: "exla",
      exit_code: 137,
      oom_killed: true,
      peak_used_bytes: nil,
      finished_at: days_ago(4)
    })

    for {peak, days} <- [{500, 1}, {700, 2}, {900, 40}] do
      insert_run_memory!(%{
        kind: :warm,
        package: nil,
        version: nil,
        peak_used_bytes: peak * 1024 * 1024,
        finished_at: days_ago(days)
      })
    end

    :ok
  end
end
