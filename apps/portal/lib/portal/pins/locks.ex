defmodule Portal.Pins.Locks do
  @moduledoc """
  The project locks fed to `Portal.Pins.from_lock/2` with `dry_run: false`
  (stream S11, `catalog_pin_locks`): each once, by the sha256 of its
  content, with the options it was fed with and the release of its Nerves
  system it names. `Portal.Workers.PinRefeed` feeds them again when that
  system releases, and records the release it fed them at in `refed`.
  """

  alias Portal.Repo

  @type t :: %{
          sha256: String.t(),
          content: String.t(),
          system: String.t() | nil,
          release: String.t() | nil,
          toolchain: String.t() | nil,
          deterministic: boolean(),
          fed_at: DateTime.t(),
          refed: %{String.t() => String.t()}
        }

  @columns "sha256, content, system, release, toolchain, deterministic, fed_at, refed"

  @doc """
  Stores `content` fed with `opts` (`:system`, `:release`, `:toolchain`,
  `:deterministic`): a lock already stored keeps its row, with the newest
  options and feed time.
  """
  @spec store(String.t(), map()) :: :ok
  def store(content, opts) when is_binary(content) do
    Repo.query!(
      """
      INSERT INTO catalog_pin_locks (#{@columns})
      VALUES ($1, $2, $3, $4, $5, $6, now() AT TIME ZONE 'utc', '{}'::jsonb)
      ON CONFLICT (sha256) DO UPDATE
        SET system = EXCLUDED.system, release = EXCLUDED.release, toolchain = EXCLUDED.toolchain,
            deterministic = EXCLUDED.deterministic, fed_at = EXCLUDED.fed_at
      """,
      [
        sha256(content),
        content,
        opts[:system],
        opts[:release],
        opts[:toolchain],
        opts[:deterministic] == true
      ]
    )

    :ok
  end

  @doc "Every stored lock, oldest feed first."
  @spec all() :: [t()]
  def all, do: select("ORDER BY fed_at, sha256", [])

  @doc """
  The stored locks of `system` that were not fed again at `release` yet,
  oldest feed first, at most `limit`.
  """
  @spec pending(String.t(), String.t(), pos_integer()) :: [t()]
  def pending(system, release, limit) do
    select(
      "WHERE system = $1 AND coalesce(refed->>$1, '') <> $2 ORDER BY fed_at, sha256 LIMIT $3",
      [system, release, limit]
    )
  end

  @doc "Records that the lock `sha256` was fed again at `system`'s `release`."
  @spec refed(String.t(), String.t(), String.t()) :: :ok
  def refed(sha256, system, release) do
    Repo.query!(
      "UPDATE catalog_pin_locks SET refed = refed || jsonb_build_object($2::text, $3::text) " <>
        "WHERE sha256 = $1",
      [sha256, system, release]
    )

    :ok
  end

  # `where` is one of this module's fixed clauses.
  # sobelow_skip ["SQL.Query"]
  defp select(where, params) do
    %{rows: rows} = Repo.query!("SELECT #{@columns} FROM catalog_pin_locks " <> where, params)

    for [sha, content, system, release, toolchain, deterministic, fed_at, refed] <- rows,
        do: %{
          sha256: sha,
          content: content,
          system: system,
          release: release,
          toolchain: toolchain,
          deterministic: deterministic,
          fed_at: fed_at,
          refed: refed || %{}
        }
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
