defmodule BeamScannerTest do
  use ExUnit.Case
  doctest BeamScanner

  @tag :tmp_dir
  test "scans remote calls in unstripped abstract code", %{tmp_dir: root} do
    forms = [
      {:attribute, 1, :module, :ncc_test_abstract_nif},
      {:attribute, 1, :export, [load: 0]},
      {:function, 1, :load, 0,
       [
         {:clause, 1, [], [],
          [
            {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, :load_nif}},
             [{:string, 1, ~c"test_nif"}, {:integer, 1, 0}]}
          ]}
       ]}
    ]

    {:ok, module, binary} = :compile.forms(forms, [:binary, :debug_info])

    assert {:ok, {^module, [abstract_code: {:raw_abstract_v1, _}]}} =
             :beam_lib.chunks(binary, [:abstract_code])

    File.mkdir_p!(Path.join(root, "ebin"))
    File.write!(Path.join([root, "ebin", "#{module}.beam"]), binary)

    result = BeamScanner.analyze(root)
    assert result.nif_calls?
    assert result.errors == []
  end

  @tag :tmp_dir
  test "loading a port driver counts as a NIF-class call", %{tmp_dir: root} do
    call = fn function ->
      {:call, 1, {:remote, 1, {:atom, 1, :erl_ddll}, {:atom, 1, function}},
       [{:string, 1, ~c"priv"}, {:string, 1, ~c"drv"}]}
    end

    forms = [
      {:attribute, 1, :module, :ncc_test_port_driver},
      {:attribute, 1, :export, [load: 0, load_driver: 0]},
      {:function, 1, :load, 0, [{:clause, 1, [], [], [call.(:load)]}]},
      {:function, 1, :load_driver, 0, [{:clause, 1, [], [], [call.(:load_driver)]}]}
    ]

    {:ok, module, binary} = :compile.forms(forms, [:binary, :debug_info])
    File.mkdir_p!(Path.join(root, "ebin"))
    File.write!(Path.join([root, "ebin", "#{module}.beam"]), binary)

    result = BeamScanner.analyze(root)
    assert result.nif_calls?

    assert result.nif_evidence |> Enum.map(& &1.mfa) |> Enum.sort() ==
             [{:erl_ddll, :load, 2}, {:erl_ddll, :load_driver, 2}]
  end

  test "analyzes circuits_gpio fixture" do
    result = BeamScanner.analyze("test/fixture/circuits_gpio-2.1.3")

    assert result.start_callback? == false
    assert result.start_callback_modules == []
    assert result.beam_count == 8
    assert result.nif_calls? == true
    assert result.languages == [:elixir]

    assert result.protocols_defined == [
             %{
               protocol: Circuits.GPIO.Handle,
               fallback_to_any: false,
               file: "test/fixture/circuits_gpio-2.1.3/ebin/Elixir.Circuits.GPIO.Handle.beam"
             }
           ]

    assert result.nif_evidence == [
             %{
               beam: Circuits.GPIO.Nif,
               file: "test/fixture/circuits_gpio-2.1.3/ebin/Elixir.Circuits.GPIO.Nif.beam",
               mfa: {:erlang, :load_nif, 2}
             }
           ]

    assert result.app_env_calls? == true

    assert result.app_env_evidence == [
             %{
               beam: Circuits.GPIO,
               file: "test/fixture/circuits_gpio-2.1.3/ebin/Elixir.Circuits.GPIO.beam",
               mfa: {Application, :get_env, 2}
             }
           ]

    assert result.shell_calls? == false
    assert result.os_env_calls? == false
    assert result.os_exec_calls? == false

    assert result.protocol_impls == [
             %{
               protocol: Circuits.GPIO.Handle,
               for: Circuits.GPIO.CDev,
               impl: Circuits.GPIO.Handle.Circuits.GPIO.CDev,
               file:
                 "test/fixture/circuits_gpio-2.1.3/ebin/Elixir.Circuits.GPIO.Handle.Circuits.GPIO.CDev.beam"
             }
           ]

    assert result.halt_calls? == false
    assert result.errors == []

    assert result.footprint.ebin == %{file_count: 9, total_bytes: 38_218}
    assert result.footprint.priv == %{file_count: 1, total_bytes: 76_848}
    assert result.footprint.file_count == 10
    assert result.footprint.total_bytes == 115_066
    assert is_list(result.footprint.manifest)
    assert length(result.footprint.manifest) == 10

    assert Enum.all?(result.footprint.manifest, fn entry ->
             is_map(entry) and Map.has_key?(entry, :path) and
               Map.has_key?(entry, :size) and Map.has_key?(entry, :sha256)
           end)
  end

  test "analyzes circuits_uart fixture" do
    result = BeamScanner.analyze("test/fixture/circuits_uart-1.5.5")

    assert result.start_callback? == false
    assert result.start_callback_modules == []
    assert result.beam_count == 8
    assert result.nif_calls? == false
    assert result.app_env_calls? == false
    assert result.shell_calls? == false
    assert result.os_env_calls? == false
    assert result.os_exec_calls? == true
    assert result.protocols_defined == []
    assert result.protocol_impls == []
    assert result.halt_calls? == false
    assert result.languages == [:elixir]

    assert result.os_exec_evidence == [
             %{
               beam: Circuits.UART,
               file: "test/fixture/circuits_uart-1.5.5/ebin/Elixir.Circuits.UART.beam",
               mfa: {:erlang, :open_port, 2}
             },
             %{
               beam: Circuits.UART.Enumerator,
               file: "test/fixture/circuits_uart-1.5.5/ebin/Elixir.Circuits.UART.Enumerator.beam",
               mfa: {:erlang, :open_port, 2}
             }
           ]

    assert result.errors == []

    assert result.footprint.ebin == %{file_count: 9, total_bytes: 29_551}
    assert result.footprint.priv == %{file_count: 1, total_bytes: 209_688}
    assert result.footprint.file_count == 10
    assert result.footprint.total_bytes == 239_239
    assert is_list(result.footprint.manifest)
    assert length(result.footprint.manifest) == 10
  end

  test "analyzes circular_buffer fixture" do
    result = BeamScanner.analyze("test/fixture/circular_buffer-1.0.0")

    assert result.start_callback? == false
    assert result.start_callback_modules == []
    assert result.beam_count == 4
    assert result.nif_calls? == false
    assert result.app_env_calls? == false
    assert result.shell_calls? == false
    assert result.os_env_calls? == false
    assert result.os_exec_calls? == false
    assert result.protocols_defined == []
    assert result.languages == [:elixir]

    assert result.protocol_impls == [
             %{
               protocol: Collectable,
               for: CircularBuffer,
               impl: Collectable.CircularBuffer,
               file:
                 "test/fixture/circular_buffer-1.0.0/ebin/Elixir.Collectable.CircularBuffer.beam"
             },
             %{
               protocol: Enumerable,
               for: CircularBuffer,
               impl: Enumerable.CircularBuffer,
               file:
                 "test/fixture/circular_buffer-1.0.0/ebin/Elixir.Enumerable.CircularBuffer.beam"
             },
             %{
               protocol: Inspect,
               for: CircularBuffer,
               impl: Inspect.CircularBuffer,
               file: "test/fixture/circular_buffer-1.0.0/ebin/Elixir.Inspect.CircularBuffer.beam"
             }
           ]

    assert result.halt_calls? == false
    assert result.errors == []

    assert result.footprint.ebin == %{file_count: 5, total_bytes: 9139}
    assert result.footprint.priv == %{file_count: 0, total_bytes: 0}
    assert result.footprint.file_count == 5
    assert result.footprint.total_bytes == 9139
    assert is_list(result.footprint.manifest)
    assert length(result.footprint.manifest) == 5
  end

  test "analyzes cerlc fixture" do
    result = BeamScanner.analyze("test/fixture/cerlc-0.2.1")

    assert result.start_callback? == false
    assert result.start_callback_modules == []
    assert result.beam_count == 1
    assert result.nif_calls? == false
    assert result.languages == [:erlang]
    assert result.protocols_defined == []
    assert result.nif_evidence == []
    assert result.app_env_calls? == false
    assert result.app_env_evidence == []
    assert result.shell_calls? == false
    assert result.os_env_calls? == false
    assert result.os_exec_calls? == false
    assert result.protocol_impls == []
    assert result.halt_calls? == false
    assert result.errors == []

    assert result.footprint.ebin == %{file_count: 2, total_bytes: 5861}
    assert result.footprint.priv == %{file_count: 0, total_bytes: 0}
    assert result.footprint.file_count == 2
    assert result.footprint.total_bytes == 5861
    assert is_list(result.footprint.manifest)
    assert length(result.footprint.manifest) == 2
  end

  @tag :tmp_dir
  test "manifest entries carry the file's real mode, not a fixed 0644", %{tmp_dir: root} do
    ebin_dir = Path.join(root, "ebin")
    priv_dir = Path.join(root, "priv")
    File.mkdir_p!(ebin_dir)
    File.mkdir_p!(priv_dir)

    beam_path = Path.join(ebin_dir, "x.beam")
    File.write!(beam_path, "fake beam content")
    File.chmod!(beam_path, 0o644)

    exec_path = Path.join(priv_dir, "tool")
    File.write!(exec_path, "#!/bin/sh\necho hi\n")
    File.chmod!(exec_path, 0o755)

    data_path = Path.join(priv_dir, "data.txt")
    File.write!(data_path, "hello")
    File.chmod!(data_path, 0o644)

    result = BeamScanner.analyze(root)

    manifest_by_path = Map.new(result.footprint.manifest, &{&1.path, &1})

    assert manifest_by_path["ebin/x.beam"].mode == 33_188
    assert manifest_by_path["priv/tool"].mode == 33_261
    assert manifest_by_path["priv/data.txt"].mode == 33_188
  end
end
