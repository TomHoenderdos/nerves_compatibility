#!/usr/bin/env bash
# Regenerates the kino_vega_lite 0.1.13 fixtures of Compatibility.KinoAssets
# and the foreign priv judge: a real Hex build of the package against kino
# 0.19.1 on Elixir 1.20.5/OTP 28 (its beams, the archives Kino.JS packed into
# kino's priv, the writer's Hex tarball, kino's lib/kino/js.ex), and the
# same members packed by :erl_tar on OTP 27 and 29, as Kino.JS packs them.
# Needs network access to hex.pm and these asdf installs. Run it from
# anywhere; it writes next to itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export ASDF_ELIXIR_VERSION=1.20.5-otp-28 ASDF_ERLANG_VERSION=28.5.0.2
export HEX_HOME="$work/hex" MIX_ENV=prod
mkdir -p "$work/kv/lib"
cat > "$work/kv/mix.exs" <<'EOF'
defmodule Kv.MixProject do
  use Mix.Project

  def project,
    do: [app: :kv, version: "0.1.0", deps: [{:kino_vega_lite, "== 0.1.13"}, {:kino, "== 0.19.1"}]]
end
EOF
cd "$work/kv"
mix deps.get
mix deps.compile
lib="$work/kv/_build/prod/lib"
cp "$HEX_HOME/packages/hexpm/kino_vega_lite-0.1.13.tar" "$here/"
tar -xOf "$HEX_HOME/packages/hexpm/kino-0.19.1.tar" contents.tar.gz | tar -xzOf - lib/kino/js.ex > "$here/kino-0.19.1-js.ex.txt"
cp "$lib/kino_vega_lite/ebin/Elixir.Kino.VegaLite.beam" "$lib/kino_vega_lite/ebin/Elixir.KinoVegaLite.ChartCell.beam" "$here/"
rm -rf "$here/otp27" "$here/otp28" "$here/otp29"
for d in Kino_VegaLite KinoVegaLite_ChartCell; do
  mkdir -p "$here/otp28/$d"
  cp "$lib/kino/priv/assets/$d/"*.tar.gz "$here/otp28/$d/"
done
for pair in 27.2.4:otp27 29.1.1:otp29; do
  ver="${pair%%:*}"; out="${pair##*:}"
  for d in Kino_VegaLite KinoVegaLite_ChartCell; do
    src="$(ls "$here/otp28/$d/"*.tar.gz)"
    mkdir -p "$here/$out/$d"
    ASDF_ERLANG_VERSION="$ver" erl -noshell -eval "
      {ok, Ms} = erl_tar:extract(\"$src\", [memory, compressed]),
      ok = erl_tar:create(\"$here/$out/$d/$(basename "$src")\", lists:sort(Ms), [compressed]),
      halt()."
  done
done
shasum -a 256 "$here/kino-0.19.1-js.ex.txt"
