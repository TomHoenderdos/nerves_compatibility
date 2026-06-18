defmodule Orchestrator.ScanRequest do
  @moduledoc """
  Validates package scan requests and maps them onto queue priority.

  Authentication providers are intentionally kept outside this module. Hex
  ownership, GitHub repository access, and Cloudflare Turnstile checks should
  verify the caller first, then submit a request with the corresponding
  `:source` and verification fields.
  """

  require Logger

  @type source :: :hex_owner | :github_repo | :anonymous_turnstile | :anonymous_manual

  @type request :: %{
          package: String.t(),
          version: String.t(),
          source: source(),
          subject: String.t() | nil
        }

  @doc """
  Submit a scan request.

  Expected attributes:
    * `:package` - Hex package name
    * `:version` - package version, or omitted to resolve latest from Hex
    * `:source` - `:hex_owner`, `:github_repo`, `:anonymous_turnstile`, or `:anonymous_manual`
    * `:verified?` - required for Hex/GitHub sources
    * `:verification_provider` - required for `:anonymous_turnstile`
  """
  @spec submit(map()) :: {:ok, request()} | {:error, atom()}
  def submit(attrs) when is_map(attrs) do
    with {:ok, package} <- fetch_package(attrs),
         :ok <- validate_package_name(package),
         {:ok, version} <- fetch_version(attrs, package),
         {:ok, source} <- fetch_source(attrs),
         :ok <- authorize_source(source, attrs) do
      priority = priority_for(source)

      :ok =
        Orchestrator.Queue.request_rescan({package, version},
          priority: priority,
          source: source,
          requested_at: DateTime.utc_now()
        )

      request = %{
        package: package,
        version: version,
        source: source,
        subject: Map.get(attrs, :subject) || Map.get(attrs, "subject")
      }

      Logger.info("Accepted scan request #{package}:#{version} via #{source}")
      {:ok, request}
    end
  end

  defp fetch_package(attrs) do
    package = Map.get(attrs, :package) || Map.get(attrs, "package")

    if is_binary(package) and String.trim(package) != "" do
      {:ok, package |> String.trim() |> String.downcase()}
    else
      {:error, :missing_package}
    end
  end

  defp validate_package_name(package) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, package) do
      :ok
    else
      {:error, :invalid_package}
    end
  end

  defp fetch_version(attrs, package) do
    case Map.get(attrs, :version) || Map.get(attrs, "version") do
      version when is_binary(version) and version != "" ->
        {:ok, String.trim(version)}

      _ ->
        latest_version(package)
    end
  end

  defp latest_version(package) do
    req = Req.new(base_url: "https://repo.hex.pm") |> ReqHex.attach()

    case Req.get(req, url: "/versions") do
      {:ok, %{status: 200, body: body}} ->
        body
        |> packages_from_versions_body()
        |> Enum.find(fn pkg -> (Map.get(pkg, :name) || Map.get(pkg, "name")) == package end)
        |> case do
          nil -> {:error, :unknown_package}
          pkg -> latest_non_retired(pkg)
        end

      {:ok, %{status: status}} ->
        Logger.warning("Hex versions lookup failed for #{package}: HTTP #{status}")
        {:error, :hex_unavailable}

      {:error, reason} ->
        Logger.warning("Hex versions lookup failed for #{package}: #{inspect(reason)}")
        {:error, :hex_unavailable}
    end
  end

  defp packages_from_versions_body(body) when is_list(body), do: body
  defp packages_from_versions_body(%{packages: packages}) when is_list(packages), do: packages
  defp packages_from_versions_body(%{"packages" => packages}) when is_list(packages), do: packages
  defp packages_from_versions_body(_), do: []

  defp latest_non_retired(%{versions: versions, retired: retired}) do
    latest_non_retired(versions, retired)
  end

  defp latest_non_retired(%{"versions" => versions, "retired" => retired}) do
    latest_non_retired(versions, retired)
  end

  defp latest_non_retired(versions, retired) when is_list(versions) and is_list(retired) do
    case versions
         |> Enum.reject(&(&1 in retired))
         |> Enum.sort_by(&Version.parse!/1, {:desc, Version}) do
      [version | _] -> {:ok, version}
      [] -> {:error, :unknown_package}
    end
  end

  defp fetch_source(attrs) do
    source = Map.get(attrs, :source) || Map.get(attrs, "source") || :anonymous_turnstile

    case normalize_source(source) do
      nil -> {:error, :invalid_source}
      source -> {:ok, source}
    end
  end

  defp normalize_source(source) when is_atom(source), do: normalize_source(Atom.to_string(source))
  defp normalize_source("hex_owner"), do: :hex_owner
  defp normalize_source("github_repo"), do: :github_repo
  defp normalize_source("anonymous_turnstile"), do: :anonymous_turnstile
  defp normalize_source("anonymous_manual"), do: :anonymous_manual
  defp normalize_source(_), do: nil

  defp authorize_source(source, attrs) when source in [:hex_owner, :github_repo] do
    if Map.get(attrs, :verified?) || Map.get(attrs, "verified") == true do
      :ok
    else
      {:error, :not_verified}
    end
  end

  defp authorize_source(:anonymous_turnstile, attrs) do
    verified? = Map.get(attrs, :verified?) || Map.get(attrs, "verified") == true
    provider = Map.get(attrs, :verification_provider) || Map.get(attrs, "verification_provider")

    if verified? and provider == "cloudflare_turnstile" do
      :ok
    else
      {:error, :human_check_required}
    end
  end

  defp authorize_source(:anonymous_manual, attrs) do
    human_check = Map.get(attrs, :human_check) || Map.get(attrs, "human_check")

    if human_check == :manual or human_check == "manual" do
      :ok
    else
      {:error, :human_check_required}
    end
  end

  defp priority_for(:hex_owner), do: :hex_owner
  defp priority_for(:github_repo), do: :github_repo
  defp priority_for(:anonymous_turnstile), do: :anonymous
  defp priority_for(:anonymous_manual), do: :anonymous
end
