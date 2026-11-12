defmodule Compatibility.Elf do
  @moduledoc """
  A bounded reader for the parts of an ELF file that decide whether a
  target build runs on another release of the same Nerves system: the
  file's class, machine and type, its `DT_NEEDED` libraries and `DT_SONAME`,
  the symbol versions it needs from each library (`.gnu.version_r`) and the
  ones it defines (`.gnu.version_d`). A precompiled NIF built against one
  release can be installed on another when every library it needs is there
  and defines every version it asks for.

  The files are untrusted (built package code), so the reader is bounded
  and never raises. `read/1` checks every slice against the binary's size,
  refuses a section header table or section that runs past the end of the
  file, a string table over 1 MiB, a string with no NUL within 4096 bytes,
  more than 256 `DT_NEEDED` entries and more than 4096 version entries
  (needs and definitions, aux entries included), and follows the version
  chains no further than their counts. Anything it cannot read is
  `{:error, :bounds}`. Only little-endian files are read.

  A dynamic object (`ET_DYN`, `ET_EXEC` with a `PT_DYNAMIC` program header)
  whose section headers are missing or name no dynamic section is
  `{:error, :no_dynamic}`: its needs cannot be read, so it cannot be judged.
  A static executable reads with no needs.

  `satisfied?/2` is membership: the dynamic linker looks a version up by
  name and a library keeps every old version node, so a needed version is
  met only by a definition of that exact name. Names `parse_version/1` does
  not read (`GLIBC_PRIVATE`, `V1`) are skipped.
  """

  import Bitwise

  @max_file 64 * 1024 * 1024
  @max_strtab 1024 * 1024
  @max_string 4096
  @max_needed 256
  @max_versions 4096

  @pt_dynamic 2
  @sht_dynamic 6
  @sht_nobits 8
  @sht_verdef 0x6FFFFFFD
  @sht_verneed 0x6FFFFFFE
  @dt_null 0
  @dt_needed 1
  @dt_soname 14
  @ver_flg_base 1

  @machines %{183 => :aarch64, 40 => :arm, 62 => :x86_64, 243 => :riscv, 3 => :x86}
  @types %{1 => :rel, 2 => :exec, 3 => :dyn, 4 => :core}

  @type info :: %{
          class: 32 | 64,
          machine: :aarch64 | :arm | :x86_64 | :riscv | :x86 | non_neg_integer(),
          type: :rel | :exec | :dyn | :core | {:other, non_neg_integer()},
          soname: String.t() | nil,
          needed: [String.t()],
          needs: %{String.t() => [String.t()]},
          defines: [String.t()]
        }

  @type error :: :bounds | :big_endian | :truncated | :bad_class | :no_dynamic

  @doc "Reads an ELF image. Never raises."
  @spec read(binary()) :: {:ok, info()} | :not_elf | {:error, error()}
  def read(<<0x7F, "ELF", _::binary>> = bin) do
    parse(bin)
  rescue
    _ -> {:error, :bounds}
  catch
    {__MODULE__, reason} -> {:error, reason}
  end

  def read(bin) when is_binary(bin), do: :not_elf

  @doc "Reads the ELF file at `path`, refusing one over 64 MiB."
  @spec read_file(Path.t()) ::
          {:ok, info()} | :not_elf | {:error, error() | :too_large | File.posix()}
  # sobelow_skip ["Traversal.FileModule"]
  def read_file(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- if(size > @max_file, do: {:error, :too_large}, else: :ok),
         {:ok, bin} <- File.read(path) do
      read(bin)
    end
  end

  @doc "Whether a file of this type can be loaded as built: `:dyn` and `:exec`."
  @spec portable_type?(atom()) :: boolean()
  def portable_type?(type), do: type in [:dyn, :exec]

  @doc """
  Splits a symbol version such as `GLIBC_2.17` into its prefix and numbers,
  `{"GLIBC", [2, 17]}`. A name without a dotted number suffix is `nil`.
  """
  @spec parse_version(String.t()) :: {String.t(), [non_neg_integer()]} | nil
  def parse_version(name) do
    case Regex.run(~r/^(.+?)_(\d+(?:\.\d+)*)$/, name) do
      [_, prefix, numbers] ->
        {prefix, numbers |> String.split(".") |> Enum.map(&String.to_integer/1)}

      nil ->
        nil
    end
  end

  @doc """
  `:ok` when every needed version `parse_version/1` reads is among the
  `defined` ones, else the first that is not.
  """
  @spec satisfied?([String.t()], [String.t()]) :: :ok | {:missing, String.t()}
  def satisfied?(needed, defined) do
    defined = MapSet.new(defined)

    case Enum.find(needed, &(parse_version(&1) != nil and not MapSet.member?(defined, &1))) do
      nil -> :ok
      name -> {:missing, name}
    end
  end

  @doc "The `major.minor` series of a `major.minor.patch` version, else `nil`."
  @spec series_from_version(String.t()) :: String.t() | nil
  def series_from_version(version) do
    case Regex.run(~r/^(\d+)\.(\d+)\.\d+$/, version) do
      [_, major, minor] -> major <> "." <> minor
      nil -> nil
    end
  end

  defp parse(<<0x7F, "ELF", class, data, _::binary>> = bin) do
    bits = class_bits(class)

    case data do
      1 -> :ok
      2 -> fail(:big_endian)
      _ -> fail(:bad_class)
    end

    if byte_size(bin) < header_size(bits), do: fail(:truncated)
    header = header(bits, part!(bin, 0, header_size(bits)))
    dynamic? = pt_dynamic?(bin, bits, header)
    sections = sections(bin, bits, header)
    type = Map.get(@types, header.type, {:other, header.type})
    dynamic = find_section(sections, @sht_dynamic)

    if type in [:dyn, :exec] and dynamic? and dynamic == nil, do: fail(:no_dynamic)

    {needed, soname} = dynamic(bin, bits, sections, dynamic)
    {needs, budget} = verneed(bin, sections, find_section(sections, @sht_verneed), @max_versions)
    defines = verdef(bin, sections, find_section(sections, @sht_verdef), budget)

    {:ok,
     %{
       class: bits,
       machine: Map.get(@machines, header.machine, header.machine),
       type: type,
       soname: soname,
       needed: needed,
       needs: needs,
       defines: defines
     }}
  end

  defp parse(_), do: {:error, :truncated}

  defp class_bits(1), do: 32
  defp class_bits(2), do: 64
  defp class_bits(_), do: fail(:bad_class)

  defp header_size(32), do: 52
  defp header_size(64), do: 64

  defp header(
         64,
         <<_::binary-size(16), type::little-16, machine::little-16, _::32, _::64,
           phoff::little-64, shoff::little-64, _::32, _::16, phentsize::little-16,
           phnum::little-16, shentsize::little-16, shnum::little-16, _::16>>
       ) do
    %{
      type: type,
      machine: machine,
      phoff: phoff,
      phentsize: phentsize,
      phnum: phnum,
      shoff: shoff,
      shentsize: shentsize,
      shnum: shnum
    }
  end

  defp header(
         32,
         <<_::binary-size(16), type::little-16, machine::little-16, _::32, _::32,
           phoff::little-32, shoff::little-32, _::32, _::16, phentsize::little-16,
           phnum::little-16, shentsize::little-16, shnum::little-16, _::16>>
       ) do
    %{
      type: type,
      machine: machine,
      phoff: phoff,
      phentsize: phentsize,
      phnum: phnum,
      shoff: shoff,
      shentsize: shentsize,
      shnum: shnum
    }
  end

  defp pt_dynamic?(_bin, _bits, %{phnum: 0}), do: false

  defp pt_dynamic?(bin, bits, %{phoff: phoff, phentsize: entsize, phnum: phnum}) do
    if entsize != phentsize(bits), do: fail(:bounds)
    part!(bin, phoff, phnum * entsize)

    Enum.any?(0..(phnum - 1), fn i ->
      <<p_type::little-32>> = part!(bin, phoff + i * entsize, 4)
      p_type == @pt_dynamic
    end)
  end

  defp phentsize(64), do: 56
  defp phentsize(32), do: 32

  defp shentsize(64), do: 64
  defp shentsize(32), do: 40

  # `e_shnum == 0` is also how extended section numbering starts; the real
  # count would come from section 0, which is not trusted.
  defp sections(_bin, _bits, %{shoff: 0}), do: {}
  defp sections(_bin, _bits, %{shnum: 0}), do: {}

  defp sections(bin, bits, %{shoff: shoff, shentsize: entsize, shnum: shnum}) do
    if entsize != shentsize(bits), do: fail(:bounds)
    part!(bin, shoff, shnum * entsize)

    0..(shnum - 1)
    |> Enum.map(fn i ->
      section = section(bits, part!(bin, shoff + i * entsize, entsize))

      if section.type != @sht_nobits and section.offset + section.size > byte_size(bin),
        do: fail(:bounds)

      section
    end)
    |> List.to_tuple()
  end

  defp section(
         64,
         <<_name::32, type::little-32, _flags::64, _addr::64, offset::little-64, size::little-64,
           link::little-32, info::little-32, _align::64, _entsize::64>>
       ),
       do: %{type: type, offset: offset, size: size, link: link, info: info}

  defp section(
         32,
         <<_name::32, type::little-32, _flags::32, _addr::32, offset::little-32, size::little-32,
           link::little-32, info::little-32, _align::32, _entsize::32>>
       ),
       do: %{type: type, offset: offset, size: size, link: link, info: info}

  defp find_section(sections, type) do
    sections |> Tuple.to_list() |> Enum.find(&(&1.type == type))
  end

  defp dynamic(_bin, _bits, _sections, nil), do: {[], nil}

  defp dynamic(bin, bits, sections, section) do
    strtab = strtab(sections, section.link)
    entsize = div(bits, 4)

    {needed, soname} =
      dynamic_entries(bin, bits, section, entsize, 0, div(section.size, entsize), [], nil)

    {Enum.map(needed, &string(bin, strtab, &1)), soname && string(bin, strtab, soname)}
  end

  defp dynamic_entries(_bin, _bits, _section, _entsize, count, count, needed, soname),
    do: {Enum.reverse(needed), soname}

  defp dynamic_entries(bin, bits, section, entsize, i, count, needed, soname) do
    {tag, value} = dynamic_entry(bits, in_section!(bin, section, i * entsize, entsize))

    case tag do
      @dt_null ->
        {Enum.reverse(needed), soname}

      @dt_needed when length(needed) >= @max_needed ->
        fail(:bounds)

      @dt_needed ->
        dynamic_entries(bin, bits, section, entsize, i + 1, count, [value | needed], soname)

      @dt_soname ->
        dynamic_entries(bin, bits, section, entsize, i + 1, count, needed, soname || value)

      _ ->
        dynamic_entries(bin, bits, section, entsize, i + 1, count, needed, soname)
    end
  end

  defp dynamic_entry(64, <<tag::little-64, value::little-64>>), do: {tag, value}
  defp dynamic_entry(32, <<tag::little-32, value::little-32>>), do: {tag, value}

  defp verneed(_bin, _sections, nil, budget), do: {%{}, budget}

  defp verneed(bin, sections, section, budget) do
    strtab = strtab(sections, section.link)
    budget = spend(budget, section.info)
    verneed_entries(bin, section, strtab, 0, section.info, %{}, budget)
  end

  defp verneed_entries(_bin, _section, _strtab, _rel, 0, needs, budget), do: {needs, budget}

  defp verneed_entries(bin, section, strtab, rel, left, needs, budget) do
    <<_version::16, cnt::little-16, file::little-32, aux::little-32, next::little-32>> =
      in_section!(bin, section, rel, 16)

    budget = spend(budget, cnt)
    names = vernaux(bin, section, strtab, rel + aux, cnt, [])
    needs = Map.update(needs, string(bin, strtab, file), names, &(&1 ++ names))

    if next == 0,
      do: {needs, budget},
      else: verneed_entries(bin, section, strtab, rel + next, left - 1, needs, budget)
  end

  defp vernaux(_bin, _section, _strtab, _rel, 0, names), do: Enum.reverse(names)

  defp vernaux(bin, section, strtab, rel, left, names) do
    <<_hash::32, _flags::16, _other::16, name::little-32, next::little-32>> =
      in_section!(bin, section, rel, 16)

    names = [string(bin, strtab, name) | names]

    if next == 0,
      do: Enum.reverse(names),
      else: vernaux(bin, section, strtab, rel + next, left - 1, names)
  end

  defp verdef(_bin, _sections, nil, _budget), do: []

  defp verdef(bin, sections, section, budget) do
    strtab = strtab(sections, section.link)
    budget = spend(budget, section.info)
    verdef_entries(bin, section, strtab, 0, section.info, [], budget)
  end

  defp verdef_entries(_bin, _section, _strtab, _rel, 0, names, _budget), do: Enum.reverse(names)

  defp verdef_entries(bin, section, strtab, rel, left, names, budget) do
    <<_version::16, flags::little-16, _ndx::16, cnt::little-16, _hash::32, aux::little-32,
      next::little-32>> = in_section!(bin, section, rel, 20)

    budget = spend(budget, cnt)

    names =
      if (flags &&& @ver_flg_base) != 0 or cnt == 0 do
        names
      else
        <<name::little-32, _next::32>> = in_section!(bin, section, rel + aux, 8)
        [string(bin, strtab, name) | names]
      end

    if next == 0,
      do: Enum.reverse(names),
      else: verdef_entries(bin, section, strtab, rel + next, left - 1, names, budget)
  end

  defp spend(budget, count) when count <= budget, do: budget - count
  defp spend(_budget, _count), do: fail(:bounds)

  defp strtab(sections, index) when index < tuple_size(sections) do
    section = elem(sections, index)
    if section.size > @max_strtab, do: fail(:bounds)
    section
  end

  defp strtab(_sections, _index), do: fail(:bounds)

  defp string(_bin, %{size: size}, offset) when offset >= size, do: fail(:bounds)

  defp string(bin, strtab, offset) do
    chunk = in_section!(bin, strtab, offset, min(@max_string, strtab.size - offset))

    case :binary.match(chunk, <<0>>) do
      {at, _} -> part!(chunk, 0, at)
      :nomatch -> fail(:bounds)
    end
  end

  defp in_section!(bin, %{offset: offset, size: size}, rel, len) when rel + len <= size,
    do: part!(bin, offset + rel, len)

  defp in_section!(_bin, _section, _rel, _len), do: fail(:bounds)

  defp part!(bin, offset, len)
       when offset >= 0 and len >= 0 and offset + len <= byte_size(bin),
       do: binary_part(bin, offset, len)

  defp part!(_bin, _offset, _len), do: fail(:bounds)

  defp fail(reason), do: throw({__MODULE__, reason})
end
