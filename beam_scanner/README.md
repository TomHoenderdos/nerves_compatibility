# BeamScanner

BeamScanner inspects an OTP release-style directory (expects an `ebin` subdir) and summarizes risky capabilities found in the BEAM files, such as NIF loads, shell/OS command execution, env access, and halting the VM. It also reports protocols and implementations plus detected source languages.

## Usage

```elixir
iex> BeamScanner.analyze("/path/to/_build/target_env/rel/project/lib/package_version/")
%{
  start_callback?: false,
  nif_calls?: true,
  nif_evidence: [%{beam: MyMod, file: "...", mfa: {:erlang, :load_nif, 2}}],
  shell_calls?: false,
  app_env_calls?: true,
  os_env_calls?: false,
  os_exec_calls?: false,
  halt_calls?: false,
  protocols_defined: [],
  protocol_impls: [],
  languages: [:elixir],
  beam_count: 5,
  errors: []
}
```

See the tests under `test/fixture` for sample inputs and expected outputs.

