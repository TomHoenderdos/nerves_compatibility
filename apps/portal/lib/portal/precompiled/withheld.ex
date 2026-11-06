defmodule Portal.Precompiled.Withheld do
  @moduledoc """
  Packages whose presence in a build's dependency closure keeps that build
  from being served: the one rule every precompiled selector applies
  (`Portal.Catalog.precompiled_manifest/1`, `precompiled_manifest_v2/1`,
  `precompiled_manifests/1`, `packages_with_precompiled_files/0` and
  `published_sha256?/1`), so the manifests, the batch and the file route
  agree on what is published.

  A build is withheld when the package itself is on the list, or when its
  recorded dependency lock (`deps_lock`; for a system result the result's own
  lock, else the lock of the run that built it) names a package on the list.

  Why: some packages change what their dependents compile to through
  application config the user's project sets and our builds do not. Every
  new Phoenix 1.8 app sets `config :phoenix_live_view, root_tag_attribute:
  "phx-r"`, which `Phoenix.LiveView.TagEngine` reads at compile time and
  which changes the markup of every `~H` root tag, and LiveView's colocated
  hooks, JS and CSS write asset files at compile time that installing BEAMs
  never provides. A build whose closure has `phoenix_live_view` therefore
  differs from what the user's own compile produces, and is not served until
  builds can carry that config.

  Configured with `config :portal, #{inspect(__MODULE__)}, packages: [...]`.
  Without that key, or with anything but a list of strings, the default
  (`#{inspect(["phoenix_live_view"])}`) applies, so a misconfiguration
  withholds rather than publishes. An empty list withholds nothing.
  """

  @default ["phoenix_live_view"]

  @doc "The withheld package names, sorted."
  @spec packages() :: [String.t()]
  def packages do
    case Application.get_env(:portal, __MODULE__, [])[:packages] do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: Enum.sort(list), else: @default

      _ ->
        @default
    end
  end

  @doc """
  Whether a build of `package_name` whose dependency lock is `deps_lock` is
  withheld. `deps_lock` is the `name => %{"version", "checksum"}` map a build
  records; `nil` (a build from before locks were recorded) names nothing.
  """
  @spec withheld?(String.t(), map() | nil, [String.t()]) :: boolean()
  def withheld?(package_name, deps_lock, packages \\ packages()) do
    package_name in packages or
      (is_map(deps_lock) and Enum.any?(packages, &Map.has_key?(deps_lock, &1)))
  end
end
