defmodule NccWorker.DepsGetClassifierTest do
  use ExUnit.Case, async: true

  alias NccWorker.DepsGetClassifier

  describe "deterministic failures" do
    test "a dependency's mix.exs raising an OTP-version guard (reckon_db)" do
      output = """
      Resolving Hex dependencies...
      Dependency resolution completed:
      New:
        reckon_db 2.3.0
      * Getting reckon_db (Hex package)
      ** (Mix) The dependency reckon_db in mix.exs did not match the requirement ~> 2.3, got 2.3.0
      ** (RuntimeError) reckon_db supports Erlang/OTP 28; this is OTP 29. Pin erlang to 28.x or wait for a reckon_db release that supports 29.
          (reckon_db 2.3.0) mix.exs:4: Reckon.Db.MixProject.__info__/1
          (mix 1.20.4) lib/mix/project.ex:252: Mix.Project.pop/0
      """

      assert DepsGetClassifier.classify(output) == :deterministic
    end

    test "a version resolution conflict" do
      output = """
      Resolving Hex dependencies...
      Dependency resolution failed
      Failed to use "decimal" (version 2.0.0) because
        mix.exs requires ~> 1.9
        some_dep requires ~> 2.0

      Unchecked dependencies: there are 1 dependency on this machine not matching
      the requirements declared in your deps. Run "mix deps.get" or update it.
      """

      assert DepsGetClassifier.classify(output) == :deterministic
    end

    test "could not find a version satisfying constraints" do
      output = """
      Resolving Hex dependencies...
      Dependency resolution failed
      could not find a version that satisfies >= 1.0.0 and <= 0.5.0 for jason
      """

      assert DepsGetClassifier.classify(output) == :deterministic
    end

    test "a package that does not exist on Hex" do
      output = """
      Resolving Hex dependencies...
      ** (Mix) No package with name totally_not_a_real_package_xyz (>= 0.0.0) found in registry
      """

      assert DepsGetClassifier.classify(output) == :deterministic
    end

    test "unrecognized output defaults to deterministic" do
      output = "mix deps.get exited with status 1\nsomething went wrong somewhere\n"

      assert DepsGetClassifier.classify(output) == :deterministic
    end

    test "empty output defaults to deterministic" do
      assert DepsGetClassifier.classify("") == :deterministic
    end
  end

  describe "transient failures" do
    test "DNS resolution failure (:nxdomain)" do
      output = """
      Resolving Hex dependencies...
      ** (Mix) Request failed (:nxdomain)
      Could not fetch record for decimal from registry.hex.pm
      """

      assert DepsGetClassifier.classify(output) == :transient
    end

    test "connection refused" do
      output = """
      ** (Mix) Could not fetch dependency information from Hex.
      Reason: connection refused (:econnrefused) connecting to repo.hex.pm:443
      """

      assert DepsGetClassifier.classify(output) == :transient
    end

    test "connection closed mid-fetch" do
      output = """
      ** (Mix) Failed to fetch record for jason from registry
      Reason: the connection was closed (:closed)
      """

      assert DepsGetClassifier.classify(output) == :transient
    end

    test "a plain network timeout" do
      output = """
      ** (Mix) Request to https://repo.hex.pm/tarballs/jason-1.4.1.tar failed:
      the request timed out after 30000ms
      """

      assert DepsGetClassifier.classify(output) == :transient
    end

    test "TLS handshake failure" do
      output = """
      ** (Mix) Could not fetch record for jason from registry
      Reason: {:tls_alert, {:handshake_failure, 'TLS client: In state cipher received SERVER ALERT: Fatal - Handshake Failure'}}
      """

      assert DepsGetClassifier.classify(output) == :transient
    end

    test "HTTP 503 from hex.pm named on the same line" do
      output = """
      Resolving Hex dependencies...
      ** (Mix) Received 503 response from hex.pm fetching package information
      """

      assert DepsGetClassifier.classify(output) == :transient
    end

    test "HTTP 429 rate limit from repo.hex.pm" do
      output = """
      ** (Mix) repo.hex.pm responded 429 Too Many Requests, try again later
      """

      assert DepsGetClassifier.classify(output) == :transient
    end

    test "a bare HTTP 500 without a hex host on the same line is not treated as transient" do
      output = "unrelated log line mentioning 500 widgets shipped today\n"

      assert DepsGetClassifier.classify(output) == :deterministic
    end

    test "host unreachable" do
      output = "** (Mix) Could not fetch record: :ehostunreach"

      assert DepsGetClassifier.classify(output) == :transient
    end
  end
end
