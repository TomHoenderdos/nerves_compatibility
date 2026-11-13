defmodule NccWorker.Portability.TreesTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.Trees
  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir

  @contents %{
    "mix.exs" => "defmodule X.MixProject do end\n",
    "lib/x.ex" => "defmodule X do end\n",
    "lib/a/b.js" => "1\n"
  }

  # deps/x as `deps.get` leaves it (the tarball's files, `.hex` and
  # `hex_metadata.config`), plus its verified Hex release.
  defp fetched(dir, contents \\ @contents) do
    proj = Path.join(dir, "proj")
    dest = Path.join([proj, "deps", "x"])

    for {path, body} <- contents do
      File.mkdir_p!(Path.dirname(Path.join(dest, path)))
      File.write!(Path.join(dest, path), body)
    end

    File.write!(Path.join(dest, ".hex"), "hex")
    File.write!(Path.join(dest, "hex_metadata.config"), "{<<\"name\">>,<<\"x\">>}.\n")
    home = Path.join(dir, "hex")
    {app, release} = TracerFixtures.hex_release(home, "x", Map.keys(contents), contents)
    %{proj: proj, dest: dest, home: home, releases: %{app => release}}
  end

  defp snap(f, native \\ [], opts \\ []),
    do: Trees.snapshot(f.proj, f.releases, f.home, native, opts)["x"]

  test "a tree as deps.get left it matches, Hex's own files aside", %{tmp_dir: dir} do
    f = fetched(dir)
    assert {:ok, members} = snap(f)
    assert Map.keys(members) |> Enum.sort() == ["lib/a/b.js", "lib/x.ex", "mix.exs"]
  end

  test "rebar3's own _build at the root is not the tree's", %{tmp_dir: dir} do
    f = fetched(dir)
    dag = Path.join(f.dest, "_build/prod/lib/.rebar3/rebar_compiler_erl/source.dag")
    File.mkdir_p!(Path.dirname(dag))
    File.write!(dag, "dag")
    assert {:ok, _members} = snap(f)

    # Anywhere else it is an extra file.
    File.mkdir_p!(Path.join(f.dest, "lib/_build"))
    File.write!(Path.join(f.dest, "lib/_build/y"), "y")
    assert {:differs, "extra file lib/_build/y"} = snap(f)
  end

  test "an extra, a missing or a modified file differs", %{tmp_dir: dir} do
    f = fetched(Path.join(dir, "extra"))
    File.write!(Path.join(f.dest, "lib/a/extra.js"), "2\n")
    assert {:differs, "extra file lib/a/extra.js"} = snap(f)

    f = fetched(Path.join(dir, "missing"))
    File.rm!(Path.join(f.dest, "lib/x.ex"))
    assert {:differs, "missing file lib/x.ex"} = snap(f)

    f = fetched(Path.join(dir, "modified"))
    File.write!(Path.join(f.dest, "lib/a/b.js"), "changed\n")
    assert {:differs, "modified file lib/a/b.js"} = snap(f)

    f = fetched(Path.join(dir, "link"))
    File.ln_s!("/etc/hosts", Path.join(f.dest, "lib/hosts"))
    assert {:differs, "link lib/hosts"} = snap(f)

    # A Hex file name below the root is the tree's.
    f = fetched(Path.join(dir, "nested_hex"))
    File.write!(Path.join(f.dest, "lib/.hex"), "x")
    assert {:differs, "extra file lib/.hex"} = snap(f)
  end

  test "no verified tarball, a native build, no source dir or no time is unverified",
       %{tmp_dir: dir} do
    f = fetched(dir)
    assert {:unverified, "no verified tarball"} = Trees.snapshot(f.proj, f.releases, nil, [])["x"]

    bad = %{"x" => %{f.releases["x"] | checksum: String.duplicate("0", 64)}}
    assert {:unverified, "no verified tarball"} = Trees.snapshot(f.proj, bad, f.home, [])["x"]

    assert {:unverified, "native build"} = snap(f, ["x"])
    assert {:unverified, "no time left"} = snap(f, [], budget_ms: 0)
    assert {:unverified, "tree too large"} = snap(f, [], max_tree_bytes: 4)
    File.rm_rf!(f.dest)
    assert {:unverified, "no source dir"} = snap(f)
  end

  test "a tarball without contents, or with links, is unverified", %{tmp_dir: dir} do
    assert {:unverified, "tarball unreadable"} = Trees.members("not a tarball")

    src = Path.join(dir, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "a"), "a")
    File.ln_s!("/etc/hosts", Path.join(src, "b"))
    gz = Path.join(dir, "contents.tar.gz")

    # Full paths rather than File.cd!/2: the working directory is the whole
    # VM's, and the async test files load beside this one. erl_tar keeps a
    # link only for a plain file name, so the members carry the full path.
    entries = for n <- ["a", "b"], do: String.to_charlist(Path.join(src, n))
    :ok = :erl_tar.create(String.to_charlist(gz), entries, [:compressed])

    outer = Path.join(dir, "outer.tar")
    :ok = :erl_tar.create(String.to_charlist(outer), [{~c"contents.tar.gz", File.read!(gz)}])
    assert {:unverified, "tarball has links"} = Trees.members(File.read!(outer))
  end

  test "check_read: a read file must be its member; a listing must be the members",
       %{tmp_dir: dir} do
    f = fetched(dir)
    {:ok, members} = snap(f)
    assert :ok = Trees.check_read(f.dest, "lib/x.ex", members, false)
    assert :ok = Trees.check_read(f.dest, "lib/a", members, true)
    assert :ok = Trees.check_read(f.dest, "lib", members, true)
    assert :ok = Trees.check_read(f.dest, "", members, true)
    assert :ok = Trees.check_read(f.dest, "hex_metadata.config", members, false)
    # A directory read as a file, and a path that is not there, are today's verdict.
    assert :ok = Trees.check_read(f.dest, "lib", members, false)
    assert :ok = Trees.check_read(f.dest, "lib/none.ex", members, false)
    assert :ok = Trees.check_read(f.dest, "lib/none", members, true)
    # Under a root name the snapshot leaves out: today's verdict too.
    File.mkdir_p!(Path.join(f.dest, "_build/prod"))
    assert :ok = Trees.check_read(f.dest, "_build", members, true)
    assert :ok = Trees.check_read(f.dest, "", members, true)

    File.write!(Path.join(f.dest, "lib/a/late.js"), "3\n")
    assert {:differs, "listing lib/a"} = Trees.check_read(f.dest, "lib/a", members, true)
    # A listing is one level deep: a file generated deeper (leex, yecc)
    # changes only the listing of its own directory.
    assert :ok = Trees.check_read(f.dest, "", members, true)
    assert :ok = Trees.check_read(f.dest, "lib", members, true)
    File.mkdir_p!(Path.join(f.dest, "late"))
    assert {:differs, "listing ."} = Trees.check_read(f.dest, "", members, true)
    # A directory made after the check, only probed (`File.dir?/1`).
    assert {:differs, "read late"} = Trees.check_read(f.dest, "late", members, false)
    assert :ok = Trees.check_read(f.dest, "lib/a", members, false)
    File.write!(Path.join(f.dest, "lib/x.ex"), "changed\n")
    assert {:differs, "read lib/x.ex"} = Trees.check_read(f.dest, "lib/x.ex", members, false)
  end

  test "merge: an unchanged release keeps its pre-compile tree; a refetched one never refuses" do
    r = fn v -> %{name: "x", version: v, checksum: v} end
    first = %{"a" => {:ok, %{}}, "b" => {:ok, %{}}}

    later = %{
      "a" => {:differs, "extra file src/a.erl"},
      "b" => {:differs, "x"},
      "c" => {:differs, "y"}
    }

    assert Trees.merge(first, %{"a" => r.("1"), "b" => r.("1")}, later, %{
             "a" => r.("1"),
             "b" => r.("2"),
             "c" => r.("1")
           }) == %{
             "a" => {:ok, %{}},
             "b" => {:unverified, "refetched after a compile: x"},
             "c" => {:differs, "y"}
           }
  end

  test "absent?/2: a path no member is or lies under, outside the left-out root names" do
    members = %{"lib/a.ex" => "s", "README.md" => "s", "_build/x" => "s"}

    assert Trees.absent?("guides", members)
    assert Trees.absent?("guides/a/b.md", members)
    assert Trees.absent?("lib/b.ex", members)
    assert Trees.absent?("li", members)

    refute Trees.absent?("lib", members)
    refute Trees.absent?("lib/a.ex", members)
    refute Trees.absent?("README.md", members)
    refute Trees.absent?("", members)

    for rel <- ["_build/y", "_build", ".hex", "hex_metadata.config", ".hex/x"] do
      refute Trees.absent?(rel, members), rel
    end
  end
end
