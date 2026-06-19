defmodule NccWorker.NativeLang do
  @moduledoc """
  Detects the implementation language of a package's NIFs and/or port
  companion programs by inspecting its source tree after `mix deps.get`.

  Called once per package (package-level signal, not per-system) and its
  output is stored at `result.package.native_components` so the site can
  attribute failures to a specific native-code ecosystem (e.g. "Rust packages
  fail on riscv64 because RustlerPrecompiled doesn't ship that triple").

  Applies to both NIFs and ports — a port is usually a companion binary or
  script in priv/, potentially written in the same or a different language
  than any NIF the package also ships.
  """

  @type lang :: :rust | :zig | :c | :shell | :python | :ruby | :other

  @type result :: %{
          nif_language: lang() | nil,
          port_languages: [lang()],
          evidence: [String.t()]
        }

  @doc """
  Run all detectors against deps/<package>/ under project_dir. Returns nil
  when the source isn't on disk (so the caller can choose to omit the field
  rather than store a stub).
  """
  @spec detect(String.t(), String.t()) :: result() | nil
  def detect(project_dir, package_name) do
    pkg_dir = Path.join([project_dir, "deps", package_name])

    if File.dir?(pkg_dir) do
      evidence = []
      {nif_lang, evidence} = detect_nif(pkg_dir, evidence)
      {port_langs, evidence} = detect_ports(pkg_dir, evidence)

      %{
        nif_language: nif_lang,
        port_languages: Enum.uniq(port_langs),
        evidence: Enum.reverse(evidence)
      }
    end
  end

  # -- NIF detection --------------------------------------------------------
  #
  # Authoritative signal is the package's own mix.exs deps list. Rustler/
  # Zigler's presence is effectively a declaration that "this package ships
  # a NIF in <language>", and every package we've seen uses that convention.
  # C NIFs don't have a standard wrapper library — fall back to filesystem
  # heuristics (c_src/ with compilable sources + elixir_make).

  defp detect_nif(pkg_dir, evidence) do
    mix_exs = read_file(Path.join(pkg_dir, "mix.exs"))

    cond do
      mix_exs && String.match?(mix_exs, ~r/:rustler_precompiled\b/) ->
        {:rust, ["mix.exs uses :rustler_precompiled" | evidence]}

      mix_exs && String.match?(mix_exs, ~r/:rustler\b/) ->
        {:rust, ["mix.exs uses :rustler" | evidence]}

      mix_exs && String.match?(mix_exs, ~r/:zigler_precompiled\b/) ->
        {:zig, ["mix.exs uses :zigler_precompiled" | evidence]}

      mix_exs && String.match?(mix_exs, ~r/:zigler\b/) ->
        {:zig, ["mix.exs uses :zigler" | evidence]}

      has_rust_sources?(pkg_dir) ->
        {:rust, ["native/*/Cargo.toml present" | evidence]}

      has_zig_sources?(pkg_dir) ->
        {:zig, ["native/*.zig present" | evidence]}

      has_c_nif_sources?(pkg_dir, mix_exs) ->
        {:c, ["c_src/*.c + elixir_make/Makefile present" | evidence]}

      true ->
        {nil, evidence}
    end
  end

  defp has_rust_sources?(pkg_dir) do
    [pkg_dir, "native", "*", "Cargo.toml"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.any?()
  end

  defp has_zig_sources?(pkg_dir) do
    [pkg_dir, "native", "*.zig"] |> Path.join() |> Path.wildcard() |> Enum.any?() or
      [pkg_dir, "**", "*.zig"] |> Path.join() |> Path.wildcard() |> Enum.any?()
  end

  defp has_c_nif_sources?(pkg_dir, mix_exs) do
    c_src_glob = [pkg_dir, "c_src", "**", "*.{c,cc,cpp,cxx}"] |> Path.join() |> Path.wildcard()
    uses_make? = mix_exs && String.match?(mix_exs, ~r/:elixir_make\b/)

    has_makefile? =
      File.exists?(Path.join(pkg_dir, "Makefile")) or
        File.exists?(Path.join(pkg_dir, "c_src/Makefile"))

    c_src_glob != [] and (uses_make? or has_makefile?)
  end

  # -- Port detection -------------------------------------------------------
  #
  # A port is a companion binary or script shipped in priv/ and launched via
  # Port.open or System.cmd. Inspect priv/ directly — a .sh / .py / .rb file
  # means the package launches an interpreter, an ELF/Mach-O means a native
  # port (usually compiled from c_src/).

  defp detect_ports(pkg_dir, evidence) do
    priv_dir = Path.join(pkg_dir, "priv")

    if File.dir?(priv_dir) do
      {langs, evidence} = scan_priv_tree(priv_dir, evidence)
      {langs, evidence}
    else
      {[], evidence}
    end
  end

  defp scan_priv_tree(priv_dir, evidence) do
    files =
      priv_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    Enum.reduce(files, {[], evidence}, fn file, {langs, ev} ->
      case classify_priv_file(file) do
        nil -> {langs, ev}
        {lang, note} -> {[lang | langs], [note | ev]}
      end
    end)
  end

  defp classify_priv_file(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext == ".sh" -> {:shell, "priv shell script: #{Path.basename(path)}"}
      ext == ".py" -> {:python, "priv python script: #{Path.basename(path)}"}
      ext == ".rb" -> {:ruby, "priv ruby script: #{Path.basename(path)}"}
      native_binary?(path) -> {:c, "priv native binary: #{Path.basename(path)}"}
      true -> nil
    end
  end

  # A port companion binary is conventionally an executable file in priv/
  # with no extension or a generic one. We detect by reading the first 4
  # bytes: ELF ("\x7fELF") or Mach-O ("\xcf\xfa\xed\xfe" etc.) means native
  # executable, which we attribute to C for lack of a better signal.
  defp native_binary?(path) do
    ext = Path.extname(path)

    cond do
      # Shared libraries and resource files, not ports
      ext in [".so", ".dylib", ".dll", ".a", ".o"] -> false
      ext in [".beam", ".app"] -> false
      ext in [".png", ".jpg", ".jpeg", ".gif", ".ico", ".svg"] -> false
      ext in [".json", ".toml", ".yaml", ".yml", ".xml", ".html", ".md", ".txt"] -> false
      true -> elf_or_macho?(path)
    end
  end

  defp elf_or_macho?(path) do
    case File.open(path, [:read, :binary], fn handle -> IO.binread(handle, 4) end) do
      {:ok, <<0x7F, "ELF">>} -> true
      {:ok, <<0xCF, 0xFA, 0xED, 0xFE>>} -> true
      {:ok, <<0xCE, 0xFA, 0xED, 0xFE>>} -> true
      {:ok, <<0xFE, 0xED, 0xFA, 0xCF>>} -> true
      {:ok, <<0xFE, 0xED, 0xFA, 0xCE>>} -> true
      _ -> false
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end
end
