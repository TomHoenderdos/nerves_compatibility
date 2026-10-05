defmodule Portal.Settings do
  @moduledoc """
  Runtime settings an admin edits from `/admin`. See `Portal.Settings.Setting`.
  """

  use Ash.Domain

  require Ash.Query

  alias Portal.Settings.Setting

  @key "global"

  @defaults %{
    key: @key,
    argus_enabled: true,
    argus_analyses: [:default, :exposure],
    argus_scope: :firmware,
    argus_min_severity: :warning,
    argus_timeout_seconds: 300
  }

  resources do
    resource(Setting)
  end

  @doc "The stored settings, or the defaults when none have been saved."
  @spec get() :: Setting.t()
  def get do
    Setting
    |> Ash.Query.filter(key == ^@key)
    |> Ash.read_one!(domain: __MODULE__)
    |> case do
      nil -> struct(Setting, @defaults)
      setting -> setting
    end
  end

  @doc """
  Saves `params` over the current settings. Unspecified fields keep their
  current value, so a partial update never resets the rest to defaults.
  """
  @spec update(map()) :: {:ok, Setting.t()} | {:error, term()}
  def update(params) do
    current = get() |> Map.take(Map.keys(@defaults))

    Setting
    |> Ash.Changeset.for_create(:upsert, Map.merge(current, Map.put(params, :key, @key)))
    |> Ash.create(domain: __MODULE__)
  end

  @doc "The `argus` key of the worker's `NCC_INPUT`, or nil when argus is off."
  @spec worker_argus(Setting.t()) :: map() | nil
  def worker_argus(%Setting{argus_enabled: false}), do: nil

  def worker_argus(%Setting{} = setting) do
    %{
      "analyses" => Enum.map(setting.argus_analyses, &Atom.to_string/1),
      "scope" => Atom.to_string(setting.argus_scope),
      "timeout_seconds" => setting.argus_timeout_seconds
    }
  end
end
