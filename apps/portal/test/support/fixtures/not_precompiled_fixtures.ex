defmodule Portal.Test.NotPrecompiledFixtures do
  @moduledoc "Packages and toolchain builds for the Not precompiled query and tab."

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Package, ToolchainBuild}

  @hackney "closure dependency observed the host: hackney (rebar3 build runs post_hooks)"
  @github "compile-time host read: os:getenv/1 (GITHUB_ACTIONS) (dispatcher stack, first frame erl_eval)"

  def hackney_reason, do: @hackney
  def github_reason, do: @github

  @doc "A package with `downloads` recent downloads, created once."
  def package!(name, downloads) do
    name
    |> package!()
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: downloads})
    |> Ash.update!(domain: Catalog)
  end

  @doc "The package `name`, created when missing."
  def package!(name) do
    case Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog) do
      nil -> Ash.create!(Package, %{name: name}, action: :create, domain: Catalog)
      existing -> existing
    end
  end

  @doc "A toolchain build of `name`; `opts`: `:status`, `:reason`, `:toolchain`, `:variant`, `:config_variant`, `:revoked`."
  def build!(name, version, opts \\ []) do
    row =
      ToolchainBuild
      |> Ash.Changeset.for_create(:create, %{
        package_id: Keyword.get_lazy(opts, :package_id, fn -> package!(name).id end),
        version: version,
        toolchain: Keyword.get(opts, :toolchain, "1.19/28"),
        builder_version: 2,
        variant: Keyword.get(opts, :variant, :with),
        config_variant: Keyword.get(opts, :config_variant, "default"),
        status: Keyword.get(opts, :status, :skipped),
        reason: Keyword.get(opts, :reason),
        finished_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Catalog)

    if Keyword.get(opts, :revoked, false),
      do: row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog),
      else: row
  end

  @doc """
  The standard set: three packages blocked by hackney, one reading
  GITHUB_ACTIONS, and builds that must not count (revoked, superseded by a
  newer pass, an older version).
  """
  def seed_not_precompiled! do
    package!("req_like", 900)
    package!("tesla_like", 500)
    package!("small_hackney", 10)
    package!("env_reader", 300)
    package!("now_passes", 1000)
    package!("revoked_one", 2000)

    build!("req_like", "1.0.0", reason: @hackney)
    build!("req_like", "1.0.0", reason: @hackney, toolchain: "1.20/29")
    build!("tesla_like", "2.0.0", reason: @hackney)
    build!("small_hackney", "0.1.0", reason: @hackney)
    # Its older version read another variable; only the newest counts.
    build!("env_reader", "0.9.0", reason: "compile-time host read: os:getenv/1 (OLD_VAR) (x)")
    build!("env_reader", "1.0.0", reason: @github)
    # Skipped once, passed at a newer version.
    build!("now_passes", "1.0.0", reason: @github)
    build!("now_passes", "1.1.0", status: :pass)
    build!("revoked_one", "1.0.0", reason: @hackney, revoked: true)
    :ok
  end
end
