defmodule Portal.Precompiled.PluginWatch.Declared do
  @moduledoc """
  The Hex releases whose rebar3 config can make Mix's rebar3 run a plugin in
  a build judged before S5, from a static scan of their Hex tarballs
  (2026-11-21): every non-Mix release in the dependency closure of a passing
  toolchain build, an earlier build or a host-native build on that day
  (2,939 releases; none was built, nothing was evaluated).
  `Portal.Precompiled.PluginWatch` reads it only for a build with no plugin
  record (review S5 S1): what such a build's closure may have run.

  Every build since the S5 worker records its plugin releases, so a build
  with no record was judged before S5, and that judge refused every plugin
  but `rebar3_hex` (`hex_plugin?/1` on main, in the config from the tarball
  and in the `mix.rebar.config` Mix wrote from a script's result). A passing
  one ran at most `rebar3_hex` and its dependencies. So a release is listed,
  with why:

    * `rebar3_hex`: `rebar3_hex` in its top-level `plugins`, or in the
      `default` or `prod` profile's, the sections Mix's `rebar3 bare
      compile` reads (`REBAR_PROFILE=prod`; `project_plugins` are dropped and
      skipped, and other profiles never run). Every such entry the scan
      found names `rebar3_hex` alone;
    * `script`: a `rebar.config.script` that names `rebar3_hex`, whose
      result no scan can know;
    * `unread`: a lock name and version the scan could not fetch from Hex
      (a package whose Hex name is not its app's, or one gone from Hex): fail
      closed.

  Not listed, since a passing build judged before S5 cannot have run what
  they add: a script that adds only another plugin (yamerl's and director's
  `coveralls`, lbm_kv's `rebar3_proper`) or only edits `project_plugins`
  (locus, tls_certificate_check), an `overrides` entry that adds another
  plugin (gen_smtp 0.11.0's `pc` for eiconv), and `project_plugins` or
  another profile's `plugins`, which Mix never runs. A release published
  after the scan is not listed, and needs not be: its builds record.
  """

  @releases """
    agent rebar3_hex 0.1.0
    alara rebar3_hex 0.1.6 0.1.8
    alara_uuid rebar3_hex 0.1.3
    ale_call rebar3_hex 0.1.3
    aleph_ollama rebar3_hex 0.1.0
    aleppo unread 1.1.1
    altworx_utils rebar3_hex 0.0.5
    amqp_client unread 3.6.2
    amqp_filter rebar3_hex 0.3.11
    anvil unread 0.1.1
    apdu rebar3_hex 0.3.1
    aten rebar3_hex 0.5.6
    atom_filter rebar3_hex 0.2.8
    atom_utils script 1.0.13
    au rebar3_hex 0.7.4
    audi rebar3_hex 0.7.3
    base16 rebar3_hex 2.0.1
    base32 rebar3_hex 0.1.0
    bcs unread 0.1.1
    bellboy rebar3_hex 2.0.0
    bin_parser rebar3_hex 0.1.4
    bit_utils script 1.0.7
    bloodbath rebar3_hex 1.0.0
    cerlc rebar3_hex 0.2.1 0.2.2
    cfg rebar3_hex 17.12.26
    cgolam rebar3_hex 1.0.1
    claude_handler rebar3_hex 0.2.0
    code_utils script 1.1.9
    couchbeam_amuino rebar3_hex 1.4.3-amuino.8
    countries_erlang rebar3_hex 0.5.0
    cowboy_routes_tree rebar3_hex 0.2.0
    cowboy_telemetry rebar3_hex 0.1.0 0.2.0 0.3.0
    credentials_obfuscation rebar3_hex 3.2.0
    crossover_io rebar3_hex 0.1.0
    ct_containers rebar3_hex 0.1.2
    decimal unread 0.4.3
    despachante rebar3_hex 0.2.1
    dh_date rebar3_hex 1.0.0
    dhcp_lib rebar3_hex 1.0.0
    digraph_export rebar3_hex 1.0.1
    director rebar3_hex 17.9.10
    discord_bot_light rebar3_hex 2.1.0
    doppler rebar3_hex 0.1.0
    duoweb rebar3_hex 1.0.0
    eauthor rebar3_hex 17.12.30
    eavmlib rebar3_hex 0.1.0
    ebils rebar3_hex 0.1.1
    eblake2 rebar3_hex 1.0.0
    elasticsearch_filter rebar3_hex 0.1.3
    elb rebar3_hex 1.0.1
    elixir_uuid unread 1.6.5
    elli_swagger rebar3_hex 0.4.1
    elogstash rebar3_hex 1.0.0
    em rebar3_hex 7.3.0
    em_filter rebar3_hex 1.2.5 1.3.2 1.3.3
    embryo rebar3_hex 0.4.0
    epipe rebar3_hex 1.0.0
    epns rebar3_hex 1.1.0
    eredis_sync rebar3_hex 0.1.4
    ereturn rebar3_hex 18.6.14
    erl_base58 rebar3_hex 0.0.1
    erl_nbt rebar3_hex 1.0.0
    erlang_adk rebar3_hex 0.10.0
    erlang_osc rebar3_hex 1.0.1
    erlang_pmp rebar3_hex 0.1.1
    erlang_rethinkdb rebar3_hex 0.2.2
    erlangchain rebar3_hex 0.4.1 4.2.0 4.2.4
    erlarg rebar3_hex 1.0.1
    erldrasil rebar3_hex 0.1.0
    erlflake rebar3_hex 0.1.1
    erlguten rebar3_hex 1.0.1
    erlogger rebar3_hex 0.1.0
    erlpop rebar3_hex 2.3.1
    erlwater rebar3_hex 0.1.6
    erlxml rebar3_hex 1.0.3-beta
    ersip rebar3_hex 1.1.0
    eunzip rebar3_hex 1.0.0
    evaluator rebar3_hex 0.1.3
    evews rebar3_hex 0.1.9
    fieldmask script 0.0.1
    forge unread 0.1.1
    forms rebar3_hex 0.0.1
    forseti rebar3_hex 2.2.0
    fs_sync rebar3_hex 1.1.3
    geminic rebar3_hex 0.1.0
    gen_cycle rebar3_hex 1.0.4
    gen_fw rebar3_hex 18.6.2
    gen_leader rebar3_hex 0.1.0
    gen_rpc rebar3_hex 2.1.0
    gleam_jsone rebar3_hex 0.5.0
    global_flags rebar3_hex 1.0.0
    gollum unread 0.5.0
    gurka rebar3_hex 0.1.8
    gustav rebar3_hex 0.1.8
    h1 unread 0.10.1 0.11.0 0.9.3
    hacker_news rebar3_hex 0.0.3
    haki rebar3_hex 0.3.2
    hkdf_erlang rebar3_hex 0.1.1 1.0.0
    hpack unread 0.2.3 0.3.0
    inet_free_port rebar3_hex 0.2.0
    influx_udp rebar3_hex 1.1.2
    intercept rebar3_hex 1.0.0
    irc_parser rebar3_hex 0.1.0
    is_auto_imported_bif rebar3_hex 17.8.24
    iso_erlang rebar3_hex 0.11.0
    jesse unread 2025.1.0
    jhn_s3c rebar3_hex 1.0.1 1.0.4
    jhn_stdlib rebar3_hex 5.12.2 5.12.4 5.12.8
    jpparse rebar3_hex 1.3.1
    json_feed_filter rebar3_hex 0.2.8
    jsone unread 2025.1.0
    justatimer rebar3_hex 0.1.2
    jwalk rebar3_hex 1.2.0
    kashe rebar3_hex 1.0.1
    kdtree rebar3_hex 1.0.0
    keylara rebar3_hex 1.2.3 1.2.5
    kube_dist script 0.0.2
    kvconf rebar3_hex 2025.1.0
    lager_iowrite_formatter rebar3_hex 1.0.0
    lazy_lists rebar3_hex 0.1.0
    lb rebar3_hex 17.6.12
    ldclient unread 3.0.4 3.11.3 3.12.2 3.7.2
    llists rebar3_hex 1.2.0
    logger_telegram_h rebar3_hex 0.1.0
    loki_csv rebar3_hex 0.1.0
    loki_xml rebar3_hex 0.1.0
    matrix_bot_light rebar3_hex 0.1.4
    mbcs rebar3_hex 1.1.1
    memhash rebar3_hex 0.1.0
    meta rebar3_hex 0.1.3
    milenage rebar3_hex 0.2.0
    mimerl rebar3_hex 1.0.0 1.0.1
    mistral_handler rebar3_hex 0.2.0
    mnesplit rebar3_hex 0.0.1
    mnp_plasmon rebar3_hex 0.1.0
    msrpce rebar3_hex 0.1.1
    mtproxy_url rebar3_hex 0.1.0
    mybench script 0.0.0
    mylib rebar3_hex 0.1.1
    mysql_client rebar3_hex 1.2.8
    nebula rebar3_hex 0.1.1
    neo script 1.2.0
    neotoma rebar3_hex 1.7.3
    nested rebar3_hex 0.1.2
    ollama_handler rebar3_hex 0.1.0 0.2.0
    ollama_summarizer rebar3_hex 0.1.4
    ollama_tests_generator rebar3_hex 0.1.0
    ollama_translator rebar3_hex 0.1.5
    openai_handler rebar3_hex 0.2.0
    optic rebar3_hex 3.1.0
    partial rebar3_hex 1.2.0
    personnummer_erl rebar3_hex 3.1.2
    posthaste rebar3_hex 18.10.14
    pp_record rebar3_hex 0.1.3
    priq rebar3_hex 0.2.0
    process_group script 1.1.3
    qsp rebar3_hex 0.1.0
    quantile_estimator rebar3_hex 0.2.1
    rebar3_cobertura rebar3_hex 0.3.1
    rebar3_dirs rebar3_hex 0.1.0
    rebar3_elixir rebar3_hex 0.2.4
    rebar3_exunit rebar3_hex 0.1.1
    rebar3_shellcheck rebar3_hex 1.0.1
    rebar3_static_deps rebar3_hex 2021.1.0
    rebar_edown_plugin rebar3_hex 0.7.0
    redbug rebar3_hex 1.2.2
    reddit_filter rebar3_hex 0.2.4
    regine rebar3_hex 1.1.0
    relflow rebar3_hex 1.0.6
    rmpc rebar3_hex 18.5.9
    roni rebar3_hex 1.0.1
    rsrc_pool rebar3_hex 1.0.3
    rss_filter rebar3_hex 0.6.8
    shot rebar3_hex 1.1.1
    sleeplocks rebar3_hex 1.1.1
    slugerl rebar3_hex 1.0.0
    sockerl rebar3_hex 17.9.10
    statix unread 1.7.0 1.8.0 1.9.0
    swidden rebar3_hex 2026.2.1
    telegram_bot_api rebar3_hex 2.5.0 3.0.0
    term2html rebar3_hex 1.1.0
    tesla_api rebar3_hex 1.0.0
    tsuru rebar3_hex 1.4.1
    tunnerl rebar3_hex 1.3.0
    url rebar3_hex 1.1.0
    uuid unread 1.7.5 2.0.7
    verl rebar3_hex 0.1.0
    vincenty rebar3_hex 1.0.0
    vptree script 0.0.0
    wade rebar3_hex 0.2.2
    webpage rebar3_hex 1.0.0
    websock_adapter unread 0.15.2 0.16.5 0.16.6
    wechat unread 0.20.1
    worker_pool rebar3_hex 4.0.3
  """

  @pairs for line <- String.split(@releases, "\n", trim: true),
             [name, _why | versions] = String.split(line),
             version <- versions,
             do: {name, version}

  @doc "The listed releases, as `{name, version}`."
  @spec releases() :: [{String.t(), String.t()}]
  def releases, do: @pairs

  @doc "The listed releases as two arrays, names and versions, for SQL `unnest`."
  @spec columns() :: {[String.t()], [String.t()]}
  def columns, do: Enum.unzip(@pairs)
end
