defmodule Portal.Builders do
  @moduledoc """
  Ash domain for remote builders: the machines (`Builder`), their
  certificate history (`BuilderCertificate`), one-time enrolment tokens and
  the remote job queue (`Lease`). Context functions live here too; the
  resources carry only attributes and actions.
  """
  use Ash.Domain

  resources do
    resource(Portal.Builders.Builder)
    resource(Portal.Builders.BuilderCertificate)
    resource(Portal.Builders.EnrolmentToken)
    resource(Portal.Builders.Lease)
  end

  require Ash.Query
  import Ecto.Query, only: [from: 2]

  alias Portal.Builders.{Builder, BuilderCertificate, CA, EnrolmentToken, Leases}
  alias Portal.Catalog.Run
  alias Portal.Repo

  @token_ttl_hours 24
  @renew_within_days 30
  @superseded_grace_hours 24
  @touch_every_seconds 60

  @doc """
  A one-time enrolment token, shown once: `<id>.<secret>.<CA prefix>`. Only
  `sha256(secret)` is stored. A name the CA would refuse to put in a
  certificate (`Portal.Builders.CA.valid_name?/1`) is refused here, before the
  token is handed out.
  """
  @spec create_token(String.t(), String.t() | nil) ::
          {:ok, %{token: String.t(), record: EnrolmentToken.t()}} | {:error, term()}
  def create_token(name, created_by) do
    with :ok <- valid_name(name),
         {:ok, %{cert: ca}} <- ca() do
      secret = :crypto.strong_rand_bytes(32)

      with {:ok, record} <-
             EnrolmentToken
             |> Ash.Changeset.for_create(:create, %{
               token_hash: hash(secret),
               name: name,
               created_by: created_by,
               expires_at: DateTime.add(DateTime.utc_now(), @token_ttl_hours, :hour)
             })
             |> Ash.create(domain: __MODULE__) do
        token =
          Enum.join([record.id, Base.url_encode64(secret, padding: false), CA.prefix(ca)], ".")

        {:ok, %{token: token, record: record}}
      end
    end
  end

  defp valid_name(name), do: if(CA.valid_name?(name), do: :ok, else: {:error, :invalid_name})

  defp ca do
    case CA.load() do
      {:ok, ca} -> {:ok, ca}
      {:error, _} -> {:error, :no_ca}
    end
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  @doc """
  Exchange a token and CSR for a builder and its one-year certificate. One
  transaction: the builder, its certificate row and the token's use land
  together or not at all.
  """
  @spec enrol(String.t(), String.t(), map()) ::
          {:ok, %{builder: Builder.t(), cert_pem: String.t(), expires_at: DateTime.t()}}
          | {:error, :invalid_token | :token_used | :token_expired | :invalid_csr | :name_taken}
  def enrol(token, csr_pem, attrs) when is_binary(token) do
    with {:ok, record} <- token_record(token),
         :ok <- token_usable(record),
         :ok <- name_free(record.name) do
      Repo.transaction(fn -> enrol_in_transaction(record, csr_pem, attrs) end)
    end
  end

  def enrol(_token, _csr_pem, _attrs), do: {:error, :invalid_token}

  # The token is spent first, by one conditional update: two enrolments
  # racing on the same token both pass `token_usable/1`, and the second one's
  # update finds `used_at` set and rolls back as `:token_used`, whatever else
  # (the builder name's unique index) would have caught it.
  defp enrol_in_transaction(record, csr_pem, attrs) do
    with :ok <- spend_token(record),
         {:ok, builder} <- create_builder(record.name, attrs),
         {:ok, issued} <- CA.issue_client(csr_pem, record.name, builder.id),
         {:ok, builder} <- rotate(builder, issued),
         {:ok, _cert} <- record_certificate(builder, issued),
         {:ok, _token} <-
           record
           |> Ash.Changeset.for_update(:use, %{builder_id: builder.id})
           |> Ash.update(domain: __MODULE__) do
      %{builder: builder, cert_pem: issued.pem, expires_at: issued.expires_at}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp spend_token(%EnrolmentToken{id: id}) do
    {count, _} =
      Repo.update_all(
        from(t in "builder_enrolment_tokens",
          where: t.id == type(^id, Ecto.UUID) and is_nil(t.used_at)
        ),
        set: [used_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
      )

    if count == 1, do: :ok, else: {:error, :token_used}
  end

  defp token_record(token) do
    with [id, secret, _prefix] <- String.split(token, "."),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, bytes} <- Base.url_decode64(secret, padding: false),
         {:ok, %EnrolmentToken{} = record} <- Ash.get(EnrolmentToken, id, domain: __MODULE__),
         true <- Plug.Crypto.secure_compare(record.token_hash, hash(bytes)) do
      {:ok, record}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp token_usable(%EnrolmentToken{used_at: used}) when not is_nil(used),
    do: {:error, :token_used}

  defp token_usable(%EnrolmentToken{expires_at: expires}) do
    if DateTime.compare(expires, DateTime.utc_now()) == :lt,
      do: {:error, :token_expired},
      else: :ok
  end

  defp name_free(name) do
    case Builder |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: __MODULE__) do
      nil -> :ok
      _ -> {:error, :name_taken}
    end
  end

  # The fingerprint is not known until the certificate exists, and the
  # certificate names the builder id, so the row is created with a placeholder
  # fingerprint and rotated in the same transaction.
  defp create_builder(name, attrs) do
    now = DateTime.utc_now()

    Builder
    |> Ash.Changeset.for_create(:enrol, %{
      name: name,
      fingerprint: "pending-" <> Ecto.UUID.generate(),
      cert_pem: "pending",
      cert_expires_at: now,
      slots: Map.get(attrs, :slots) || 1,
      last_version: Map.get(attrs, :agent_version),
      enrolled_at: now
    })
    |> Ash.create(domain: __MODULE__)
    |> case do
      {:ok, builder} ->
        {:ok, builder}

      # Another enrolment of the same name won the race past `name_free/1`.
      {:error, error} ->
        if name_conflict?(error), do: {:error, :name_taken}, else: {:error, error}
    end
  end

  defp name_conflict?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &match?(%{field: :name}, &1))

  defp name_conflict?(_), do: false

  defp rotate(builder, issued) do
    builder
    |> Ash.Changeset.for_update(:rotate_cert, %{
      fingerprint: issued.fingerprint,
      cert_pem: issued.pem,
      cert_expires_at: issued.expires_at
    })
    |> Ash.update(domain: __MODULE__)
  end

  defp record_certificate(builder, issued) do
    BuilderCertificate
    |> Ash.Changeset.for_create(:create, %{
      builder_id: builder.id,
      fingerprint: issued.fingerprint,
      issued_at: DateTime.utc_now(),
      expires_at: issued.expires_at
    })
    |> Ash.create(domain: __MODULE__)
  end

  @doc """
  A new one-year certificate for a builder within 30 days of expiry. The old
  certificate row is superseded and stays valid for 24 hours, so an agent
  mid-request on the old certificate is not cut off.
  """
  @spec renew(Builder.t(), String.t()) ::
          {:ok, %{cert_pem: String.t(), expires_at: DateTime.t()}}
          | {:error, :too_early | :revoked | :invalid_csr}
  def renew(%Builder{status: :revoked}, _csr), do: {:error, :revoked}

  def renew(%Builder{} = builder, csr_pem) do
    if DateTime.diff(builder.cert_expires_at, DateTime.utc_now(), :day) > @renew_within_days do
      {:error, :too_early}
    else
      Repo.transaction(fn -> renew_in_transaction(builder, csr_pem) end)
    end
  end

  defp renew_in_transaction(builder, csr_pem) do
    with {:ok, issued} <- CA.issue_client(csr_pem, builder.name, builder.id),
         :ok <- supersede_current(builder),
         {:ok, builder} <- rotate(builder, issued),
         {:ok, _} <- record_certificate(builder, issued) do
      %{cert_pem: issued.pem, expires_at: issued.expires_at}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Every live row of the builder, not just the one matching the caller's
  # struct: two renewals racing on the same stale struct would otherwise leave
  # the loser's certificate unsuperseded, and valid, for good.
  defp supersede_current(builder) do
    BuilderCertificate
    |> Ash.Query.filter(builder_id == ^builder.id and is_nil(superseded_at))
    |> Ash.read!(domain: __MODULE__)
    |> Enum.reduce_while(:ok, fn cert, :ok ->
      case cert |> Ash.Changeset.for_update(:supersede, %{}) |> Ash.update(domain: __MODULE__) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  The builder a client certificate belongs to: by its current fingerprint, or
  by a certificate row not superseded, or superseded within the last 24 hours.
  """
  @spec by_fingerprint(term()) :: {:ok, Builder.t()} | {:error, :unknown | :revoked}
  def by_fingerprint(fp) when is_binary(fp) do
    case Builder |> Ash.Query.filter(fingerprint == ^fp) |> Ash.read_one!(domain: __MODULE__) do
      nil -> builder_by_certificate(fp)
      builder -> builder
    end
    |> case do
      nil -> {:error, :unknown}
      %Builder{status: :revoked} -> {:error, :revoked}
      %Builder{} = builder -> {:ok, builder}
    end
  end

  def by_fingerprint(_), do: {:error, :unknown}

  defp builder_by_certificate(fp) do
    grace = DateTime.add(DateTime.utc_now(), -@superseded_grace_hours, :hour)

    BuilderCertificate
    |> Ash.Query.filter(fingerprint == ^fp and (is_nil(superseded_at) or superseded_at > ^grace))
    |> Ash.Query.load(:builder)
    |> Ash.read_one!(domain: __MODULE__)
    |> case do
      nil -> nil
      cert -> cert.builder
    end
  end

  @doc """
  Refresh `last_seen_at` (at most once a minute, so a busy agent does not
  write the row on every request) and record a changed agent version.
  """
  @spec touch(Builder.t(), String.t() | nil) :: Builder.t()
  def touch(%Builder{} = builder, version) do
    now = DateTime.utc_now()

    stale? =
      is_nil(builder.last_seen_at) or
        DateTime.diff(now, builder.last_seen_at, :second) >= @touch_every_seconds

    version_changed? = is_binary(version) and version != builder.last_version

    if stale? or version_changed? do
      builder
      |> Ash.Changeset.for_update(:touch, %{
        last_seen_at: if(stale?, do: now, else: builder.last_seen_at),
        last_version: version || builder.last_version
      })
      |> Ash.update!(domain: __MODULE__)
    else
      builder
    end
  end

  @spec list_builders() :: [Builder.t()]
  def list_builders, do: Builder |> Ash.Query.sort(name: :asc) |> Ash.read!(domain: __MODULE__)

  @spec get_builder(term()) :: {:ok, Builder.t()} | {:error, :not_found}
  def get_builder(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, builder} <- Ash.get(Builder, id, domain: __MODULE__) do
      {:ok, builder}
    else
      _ -> {:error, :not_found}
    end
  end

  def set_publishing(builder, flag) when is_boolean(flag),
    do: update(builder, :set_publishing, %{publishing: flag})

  def set_egress(builder, status), do: update(builder, :set_egress, %{egress_status: status})

  def set_slots(builder, slots), do: update(builder, :set_slots, %{slots: slots})

  defp update(builder, action, params),
    do: builder |> Ash.Changeset.for_update(action, params) |> Ash.update(domain: __MODULE__)

  @doc "What `revoke/1` would do: how many runs it revokes, which packages it rebuilds."
  @spec revoke_preview(Builder.t()) :: %{runs: non_neg_integer(), packages: [String.t()]}
  def revoke_preview(%Builder{} = builder) do
    runs = open_runs(builder, load: :package)

    %{runs: length(runs), packages: package_names(runs)}
  end

  defp open_runs(%Builder{id: id}, opts) do
    Run
    |> Ash.Query.filter(builder_id == ^id and is_nil(revoked_at))
    |> Ash.Query.load(Keyword.get(opts, :load, []))
    |> Ash.read!(domain: Portal.Catalog)
  end

  @doc """
  Revoke a builder: status `:revoked`, its runs revoked (the next precompiled
  batch drops their files), its open leases back to `:queued` -- or, when no
  other enrolled builder is left to claim them, `:failed` with "builder
  revoked", and every queued lease `:failed` with "no enrolled builder",
  their requests errored -- and the affected packages (those failed
  leases' included) rebuilt on this host through `Portal.BulkRebuild` with
  `pin_local`, so the catalogue heals without routing to a remote builder.
  """
  @spec revoke(Builder.t()) ::
          {:ok,
           %{
             builder: Builder.t(),
             runs_revoked: non_neg_integer(),
             packages: [String.t()],
             sweep_id: String.t() | nil
           }}
          | {:error, term()}
  def revoke(%Builder{} = builder) do
    # The status is committed on its own and first, so the builder is shut out
    # even if what follows fails. The rest is one transaction: if any run
    # revoke or the rebuild enqueue fails, nothing of it sticks and a retry
    # still finds the runs open and their packages to rebuild. The package
    # names come from the runs revoked here, not from an earlier preview, so a
    # run ingested in between is rebuilt too.
    with {:ok, builder} <- mark_revoked(builder),
         {:ok, result} <- Repo.transaction(fn -> revoke_in_transaction(builder) end) do
      # Once committed: the failed leases' upload dirs hold nothing anyone
      # will ingest.
      {lease_ids, result} = Map.pop(result, :failed_lease_ids)
      Enum.each(lease_ids, &Portal.Builders.Upload.cleanup/1)
      {:ok, result}
    end
  end

  defp revoke_in_transaction(builder) do
    runs = open_runs(builder, load: :package)
    Enum.each(runs, &revoke_run!/1)
    failed_leases = settle_leases(builder)

    packages =
      (package_names(runs) ++ Enum.map(failed_leases, fn {_id, package, _req} -> package end))
      |> Enum.uniq()
      |> Enum.sort()

    case rebuild(packages, builder) do
      {:ok, sweep_id} ->
        %{
          builder: builder,
          runs_revoked: length(runs),
          packages: packages,
          sweep_id: sweep_id,
          failed_lease_ids: Enum.map(failed_leases, fn {id, _package, _req} -> id end)
        }

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # A retry after a failed revoke keeps the original `revoked_at`.
  defp mark_revoked(%Builder{status: :revoked} = builder), do: {:ok, builder}
  defp mark_revoked(builder), do: update(builder, :revoke, %{})

  defp revoke_run!(run) do
    case run |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update(domain: Portal.Catalog) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp package_names(runs), do: runs |> Enum.map(& &1.package.name) |> Enum.uniq() |> Enum.sort()

  # The revoked builder's in-flight leases go back to the queue while another
  # enrolled builder can take them. With none left a requeued lease would wait
  # forever and its open request block every later `create_once/1` for its
  # package, so they fail instead (their requests errored), together with
  # every lease still `queued` ("no enrolled builder"), and their packages
  # join the local rebuild. Either way its `done` leases whose ingest has not
  # committed a run yet fail too: `Portal.Workers.Ingest` would drop that
  # upload as a revoked builder's, so the package goes to the local rebuild
  # now rather than being left errored. Answers the failed ones as `{id,
  # package, scan_request_id}`.
  defp settle_leases(builder) do
    done = fail_done_without_run(builder)

    if other_enrolled?(builder) do
      requeue_leases(builder)
      done
    else
      fail_leases(builder) ++ done
    end
  end

  defp fail_done_without_run(builder) do
    fail_where(
      from(l in "builder_leases",
        where:
          l.builder_id == type(^builder.id, Ecto.UUID) and l.state == "done" and
            fragment("NOT EXISTS (SELECT 1 FROM catalog_runs r WHERE r.run_id = ?)", l.run_id)
      ),
      "builder revoked"
    )
  end

  defp other_enrolled?(%Builder{id: id}) do
    Builder
    |> Ash.Query.filter(status == :enrolled and id != ^id)
    |> Ash.exists?(domain: __MODULE__)
  end

  # The revoked builder's in-flight leases, and every lease still queued:
  # with no enrolled builder left nothing would ever claim those either.
  defp fail_leases(builder) do
    held =
      fail_where(
        from(l in "builder_leases",
          where:
            l.builder_id == type(^builder.id, Ecto.UUID) and l.state in ["leased", "uploading"]
        ),
        "builder revoked"
      )

    queued =
      fail_where(from(l in "builder_leases", where: l.state == "queued"), "no enrolled builder")

    held ++ queued
  end

  defp fail_where(query, reason) do
    {_, failed} =
      Repo.update_all(
        from(l in query,
          select: {type(l.id, Ecto.UUID), l.package, type(l.scan_request_id, Ecto.UUID)}
        ),
        set: [state: "failed", error: reason, phase: nil, updated_at: DateTime.utc_now()]
      )

    for {_id, _package, scan_request_id} <- failed do
      Portal.Workers.Progress.mark(scan_request_id, :error, error_reason: reason)
      Portal.Workers.Progress.broadcast(scan_request_id, :error, %{reason: reason})
    end

    failed
  end

  # Wakes the other builders' long polls the way `Leases.enqueue/1` does,
  # rather than leaving the requeued leases for their next 25 s poll.
  defp requeue_leases(builder) do
    {_, ids} =
      Repo.update_all(
        from(l in "builder_leases",
          where:
            l.builder_id == type(^builder.id, Ecto.UUID) and l.state in ["leased", "uploading"],
          select: type(l.id, Ecto.UUID)
        ),
        set: [
          state: "queued",
          builder_id: nil,
          leased_at: nil,
          heartbeat_at: nil,
          phase: nil,
          updated_at: DateTime.utc_now()
        ]
      )

    for id <- ids,
        do: Phoenix.PubSub.broadcast(Portal.PubSub, Leases.topic(), {:lease_queued, id})
  end

  defp rebuild([], _builder), do: {:ok, nil}

  defp rebuild(names, builder) do
    with {:ok, %{sweep_id: id}} <-
           Portal.BulkRebuild.run(
             names: names,
             limit: length(names),
             what: :full,
             pin_local: true,
             created_by: "revoke builder #{builder.name}"
           ) do
      {:ok, id}
    end
  end

  @doc "How many catalogue runs each builder produced, revoked ones included: `%{builder_id => n}`."
  @spec runs_count() :: %{String.t() => non_neg_integer()}
  def runs_count do
    from(r in "catalog_runs",
      where: not is_nil(r.builder_id),
      group_by: r.builder_id,
      select: {type(r.builder_id, Ecto.UUID), count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Leases each builder finished in the last 24 hours, by outcome:
  `%{builder_id => %{done: n, failed: n}}`. A lease counts by its last
  change, so one failed and requeued is not counted until it ends again.
  """
  @spec throughput_24h() :: %{
          String.t() => %{done: non_neg_integer(), failed: non_neg_integer()}
        }
  def throughput_24h do
    since = DateTime.add(DateTime.utc_now(), -24, :hour)

    from(l in "builder_leases",
      where:
        not is_nil(l.builder_id) and l.state in ["done", "failed"] and
          l.updated_at > type(^since, :utc_datetime_usec),
      group_by: [l.builder_id, l.state],
      select: {type(l.builder_id, Ecto.UUID), l.state, count()}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, state, n}, acc ->
      key = if state == "done", do: :done, else: :failed
      Map.update(acc, id, Map.put(%{done: 0, failed: 0}, key, n), &Map.put(&1, key, n))
    end)
  end
end
