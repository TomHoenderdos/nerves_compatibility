defmodule Portal.GitHubTest do
  use ExUnit.Case, async: true

  alias Portal.GitHub

  describe "scope/0" do
    test "requests no OAuth scope at all" do
      assert GitHub.scope() == ""
    end

    test "never requests write access to repositories" do
      # `public_repo` is read *and* write on every public repo the maintainer
      # owns. Both calls this module makes (GET /user, GET /repos/:owner/:repo)
      # work with a zero-scope token, so nothing here may widen.
      refute GitHub.scope() =~ "repo"
      refute GitHub.scope() =~ "write"
    end
  end

  describe "writable_permission?/1" do
    test "accepts admin, maintain and push" do
      for role <- ~w(admin maintain push) do
        assert GitHub.writable_permission?(%{role => true}),
               "expected #{role} to count as write access"
      end
    end

    test "rejects read-only access" do
      refute GitHub.writable_permission?(%{
               "admin" => false,
               "maintain" => false,
               "push" => false,
               "triage" => false,
               "pull" => true
             })
    end

    test "rejects triage, which cannot push" do
      refute GitHub.writable_permission?(%{"triage" => true, "pull" => true})
    end

    test "rejects a missing or malformed permissions block" do
      refute GitHub.writable_permission?(%{})
      refute GitHub.writable_permission?(nil)
    end
  end
end
