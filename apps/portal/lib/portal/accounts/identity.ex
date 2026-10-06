defmodule Portal.Accounts.Identity do
  @moduledoc """
  An account at Hex.pm or GitHub that the provider has just vouched for.

  `uid` is what links match on: the Hex username (which its owner cannot
  change) or the numeric GitHub user id (the login can change and be taken by
  someone else). `username` is only a suggestion for a new local account.

  `access_token` exists so the GitHub repo check can use it within the same
  request. It is never stored and never written to the session.
  """

  @enforce_keys [:provider, :uid, :username]
  defstruct [:provider, :uid, :username, profile: %{}, access_token: nil]

  @type provider :: :hex | :github
  @type t :: %__MODULE__{
          provider: provider(),
          uid: String.t() | integer(),
          username: String.t(),
          profile: map(),
          access_token: String.t() | nil
        }

  @spec to_session(t()) :: map()
  def to_session(%__MODULE__{} = identity) do
    %{
      "provider" => Atom.to_string(identity.provider),
      "uid" => identity.uid,
      "username" => identity.username
    }
  end

  @spec from_session(term()) :: {:ok, t()} | :error
  def from_session(%{"provider" => "hex", "uid" => uid, "username" => name})
      when is_binary(uid) and is_binary(name),
      do: {:ok, %__MODULE__{provider: :hex, uid: uid, username: name}}

  def from_session(%{"provider" => "github", "uid" => uid, "username" => name})
      when is_integer(uid) and is_binary(name),
      do: {:ok, %__MODULE__{provider: :github, uid: uid, username: name}}

  def from_session(_), do: :error
end
