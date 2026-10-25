defmodule NccAgent.Token do
  @moduledoc """
  An enrolment token, `"<id>.<secret>.<ca prefix>"`. The prefix is the
  first 16 lowercase hex characters of the sha256 of the portal CA
  certificate's DER: it is what authenticates the CA the agent fetches
  before it has any trust anchor.
  """

  @type t :: %{id: String.t(), secret: String.t(), ca_prefix: String.t()}

  @spec parse(String.t() | nil) :: {:ok, t()} | :error
  def parse(token) when is_binary(token) do
    with [id, secret, prefix] when id != "" and secret != "" <- String.split(token, "."),
         true <- prefix =~ ~r/\A[0-9a-f]{16}\z/ do
      {:ok, %{id: id, secret: secret, ca_prefix: prefix}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error
end
