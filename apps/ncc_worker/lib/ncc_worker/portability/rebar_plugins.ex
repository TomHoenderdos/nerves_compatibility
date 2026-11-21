defmodule NccWorker.Portability.RebarPlugins do
  @moduledoc """
  The rebar3 plugins a rebar3 app's build installed, each pinned to a
  reviewed Hex release (precompiled judge, stream S5 item 8).

  rebar3 installs a dependency's `plugins` inside `rebar3 bare compile`,
  with their own dependencies, from Hex at whatever release its registry
  cache resolves; no lock names them. A plugin's `init/1` runs in the traced
  child VM, but what it does to rebar3's state (a compiler it adds, the
  `erl_opts` it sets) no event shows. So `NccWorker.Portability.Rebar` lets
  only reviewed plugins through by name, and this module holds every
  release a build installed to the exact releases that were reviewed, by
  version and Hex outer checksum (`pins/0`): the plugins' own releases and
  those of every dependency they pull. A release not in the table refuses,
  naming the plugin and its version.

  rebar3 extracts each one into `<app>/_build/default/plugins/<name>` (the
  `prod` profile links to it) and keeps its tarball in its cache,
  `<cache>/hex/hexpm/packages/<name>-<version>.tar`, where `<cache>` is
  `REBAR_CACHE_DIR` or `$HOME/.cache/rebar3` of the compile. A release is the
  reviewed one only when all of these hold:

    * its `hex_metadata.config` names it and its version, and the table pins
      that version;
    * its cached tarball hashes to the pinned checksum;
    * its dir holds exactly the tarball's files, byte for byte, plus
      `hex_metadata.config` (the tarball's `metadata.config`) and an `ebin`
      of `<name>.app` and one beam per module of its own sources (or the
      tarball's own `ebin` files): no file planted, changed or left out.

  Every entry of every `_build/<profile>/plugins` dir is judged (a link must
  name a plugin dir of the same name under `_build`), and every reviewed
  plugin the app's config names must be installed. A dir that cannot be
  read, a missing tarball or an unknown cache dir cannot be judged.

  A new release of a plugin or of one of its dependencies refuses until it
  is reviewed and added to `pins/0`; see the S5 design note for how.
  """

  alias NccWorker.Portability.{HexFiles, Rebar}

  @max_tarball_bytes 32 * 1024 * 1024
  @max_files 2_000
  @max_bytes 64 * 1024 * 1024
  @version ~r/\A[0-9A-Za-z][0-9A-Za-z.+-]{0,63}\z/
  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/

  # Reviewed 2026-11-21, every release on Hex then: each plugin release's
  # `init/1` closure (the providers its app env names, or its own module)
  # only registers providers (rebar3_hex 7.3.0 to 7.5.0 also set rebar3's
  # package resources to its own HTTP adapter, which fetches nothing in a
  # `bare compile`); no `-on_load`, no parse transform, no native build, no
  # compile hook or plugin of its own; a `rebar.config.script` only when it
  # was read (env reads the trace records, `ex_doc` or coverage keys only).
  # A release whose dependency requirements reach any release that fails
  # the same checks is left out, and so are the dependencies' releases no
  # pinned release reaches.
  @pins %{
    "coveralls" => %{
      "1.3.0" => "98f0bc06f2133074e2195d0faa1d5bf6b1ad9c2ced72c515711bebfe812e0a64",
      "1.4.0" => "3122aad48e24adac5fb03a971aa5cb7ad2737f4ccbacc3e708c668a804854f5c",
      "1.4.1" => "65786e4c7783510364f1a147085bfc43d3cc0f51265671fa41fd029afc1b94a9",
      "1.5.0" => "a95b1ba48e968c3c297141ce0d65513153ef116cdf7edc333a3d81ded8222520",
      "2.0.1" => "b185947c2c8f4529b63a7d06dd9911f814d6e8038769fe2245fbc6e14fc27731",
      "2.1.0" => "bbfbe2a7bebb2d22db15a657e6c1733243e1501714d60fe14a14790d96e7c3b2",
      "2.2.0" => "cd54db0aa8c64b539280189c5619ecee13a46a28b0f1cb774544ddcc166204a3"
    },
    "covertool" => %{
      "2.0.1" => "0ba585d63624bec9cd73475e4b0d7536d96f067e8c576cc17c0d416d7c13941e",
      "2.0.2" => "19591e24dab990ee4d669700f9389b09f93a45fb8832ff7380a70cd4c3717743",
      "2.0.3" => "5c13170a55dbd6bd9efc722bc7fa32caff6f3c9cde9c692bd4a88bfc9ac4f029",
      "2.0.4" => "5c9568ba4308fda2082172737c80c31d991ea83961eb10791f06106a870d0cdc",
      "2.0.5" => "eec7d3457ff1f0bc4217ea8fbf2ba89ca42594a419d31f176904fb12fa05dbf2",
      "2.0.6" => "5db3fcd82180d8ea4ad857d4d1ab21a8d31b5aee0d60d2f6c0f9e25a411d1e21",
      "2.0.7" => "46158ed6e1a0df7c0a912e314c7b8e053bd74daa5fc6b790614922a155b5720c"
    },
    "elvis_core" => %{
      "1.0.0" => "dda7a54cd4ce3d2bd93a4c9b421f59ca69c2301ecf3c171761bf098c6eb6ae0a",
      "1.1.1" => "391c95baa49f2718d7fb498bcf08046ddfc202cf0aab63b2e439271485c9dc42",
      "1.1.2" => "c4ee42a7a7c2fc567f3ea6b5150164cd68290f1100e9b19a4cf886d8aa1ca73c",
      "1.2.0" => "0d5002c27dd1fa707ffb148c2b86d23fca5c3d255e13b988a3ae3112fb89b6b8",
      "1.3.0" => "1bbf3ac5aa1dffaa2324c9e956687a7657f041fe53324b787d5e96c42830386a",
      "1.3.1" => "7a8890bf8185a3252cd4ebd826fe5f8ad6b93024edf88576eb27ae9e5dc19d69",
      "1.3.2" => "272bc61172a3db9247575e9d8d7942ddea6a8888bdb59e8d37c341c4ea834484",
      "1.4.0" => "0dda7bffba2afe507f07410727196e1c55fb18b4306d7f46004c342f9c10b0f4",
      "2.0.0" => "5b7a25c60bb3820e8059c9eb59f08b340ac7d40713daab43c3ff6682e51a5277",
      "2.0.1" => "4ed8385a940b7aeb2dd3f871fffd399584f37dd76312c1ff2233629726e2fdb0",
      "3.0.0" => "b0aa00cf1f644eda625187a2a73b07b6e102c284ea2a588b3c468a2e6fefe2b1",
      "3.0.1" => "4cf735401e7465c10851c6245c1e3e8e764984d8c0b5949d5697b14b5faead49",
      "3.1.0" => "8e02fba315d04dad4dc97ee96627e01eca4ded15d11251270d26668ac327c72e",
      "3.2.0" => "05ebf8d4840f4a81721907e1ddce2f3455be8ea0f0fb280d50c8de85c40060fa",
      "3.2.1" => "4f1996776bb53ef35d0cda0a6799fc14cdb9190ba89f07883afca734d464ae3c",
      "3.2.2" => "3786f027751cc265e7389bf5ac1329db547510d80f499b45efe771bdaf889b36",
      "3.2.3" => "a0f0d681ccd9355a165c35973675551f1021687cf992f15c5bff66b6664ede04",
      "3.2.4" => "8106dfa0565330772fb31759ae69b79bc143a59cf804577fa83ffa76164c151f",
      "3.2.5" => "34d9218f0b8072511903bf6ccbf59eb1765decfc73fcc6833ba5c8959db7f383",
      "4.0.0" => "fa2ee30f2464466d3599fb1fcfaa615c89959fc5019a45619ef7adb7ed420be5",
      "4.1.0" => "4a020a90fa01a9c868433b311aad8311692827ba0225771101d19523f0de2ff1",
      "4.1.1" => "80a562574b8d974a2e7544e9a9455716d04c9e095dbc8c8915e2468031dd1385",
      "4.2.0" => "ab467c7d3ff3827f8b2cddb75c838ab00eea5db90e1cc4c7e4a6d7563a5745bd",
      "4.2.1" => "0f774b891e64a8cb9949ff4f55485c9608c1144148103a833a101493b97c27b2",
      "4.2.2" => "fe10f28044baf82613f3c83c074480e7dfb073124f94c467b705ee81c93b88ce",
      "4.2.3" => "c72e318a73da6f9d69dee0f187f8797471f9ee46cf4ddacedfa2c9f9bcb18ea0",
      "5.0.1" => "e23d13201db148009a0dd88871ef09dbe20b1abc1af177002dbc7ba8d2e76aea",
      "5.0.2" => "4856b84ee4ba10dc6d8ca040a12dad679c9702e051148003bd3b1fb18513c5d7",
      "5.0.3" => "9c65a042a5426300742b89ae786f729d6b218f2145cb360b8bbc7cd3b3e8c26c",
      "5.0.4" => "7e0ce0d3236b1b569f0ef1398eb27321fd86367272e0b14f3890d0413acc3e9a",
      "6.0.0" => "3cf851717912daf56e07e95b3e369ba8af23d1412c85eba5065846e435a8e555"
    },
    "hex_core" => %{
      "0.5.0" => "b4f82253ba55089876b96483b8eea8e82e31b80b088cc27ec38d72c0dd24426a",
      "0.6.4" => "d2dbc9a4a293725c0497bea62328fce088e5077730e0d2af71f6baeedbf06a4c",
      "0.6.7" => "ae0e8db6e8d8744c717ce244f3b2b4921df2f2f05e4ae8cac66d9b243cdf1975",
      "0.6.8" => "ca65ff81a5598fc078f4798b6f11334883e38a3a76cdf0ac87db3f22f8fd6b9a",
      "0.6.9" => "8ec071f590a5a62a5ec2a08fc397d1597e38d80f2dcb2fdef7fde5f6aaa0d5a6",
      "0.7.0" => "42d91d9081956bd43750177e876b39130f7aa3c3584671bfe9311b231f04a528",
      "0.7.1" => "05c60411511b6dc79affcd99a93e67d71e1b9d6abcb28ba75cd4ebc8585b8d02",
      "0.8.4" => "4b8c21fa049515d778395e38b0d0e5d48b7ecdc703bba1f7007e2651292ce61a",
      "0.10.1" => "fd39152d342b7fd4ce3f803ac7f084b60d1bc9bf13e707e35dbdce266fbb65f0",
      "0.10.3" => "bc7c2b6ceb99e29550f74234952ad3b8153e6f2dbc38892bd0ff46043be073f5",
      "0.12.2" => "00e402c302bf4b8cedc2d3425e22b55f8c70a2542d69c87a2e5ba7af2745f6c6",
      "0.18.0" => "20914163b13c2bbb8fc03936d1159396fe445519753ac39902268a5b60cde07e",
      "0.19.0" => "c2cc414f3893a7edbcab28207cadca13829407abe41f689c82f379fe22f026a5",
      "0.21.1" => "1971d16d188c58cf0042e21f19b185eb4f3f5c89678472c735952b696a8fc888"
    },
    "jsx" => %{
      "2.10.0" => "9a83e3704807298016968db506f9fad0f027de37546eb838b3ae1064c3a0ad62"
    },
    "katana_code" => %{
      "0.2.1" => "8448ad3f56d9814f98a28be650f7191bdd506575e345cc16d586660b10f6e992",
      "1.1.2" => "e7e6162a44e826a03f68b503b7d92981b894bf834c1ef0e647783f7d6688021c",
      "2.0.0" => "d2f3bb2f942a14daa42bf5ffd26b8720e10466743b21681881116cd11d00bae4",
      "2.0.1" => "d02f757c8dde643614d508474a97fc24d9015fe375477e34de26450bf21cac16",
      "2.0.2" => "3e57fed635e0b16a5fbdaccdc872ec53deb21ed9fc6e7eb9b6415ff199b7b138",
      "2.1.0" => "ae3bbaca187511588f69695a9ff22251cb2cc672fdccc180289779bdd25175ef",
      "2.1.1" => "0680f33525b9a882e6f4d3022518b15c46f648bd7b0dbe86900980fe1c291404",
      "2.4.0" => "53818dcb9cadc46e3e4a42da7a7a7bac65bb903262bd8e54f9163c64c39c51fe",
      "2.4.1" => "58efc63b5d9dabc82230cab50cde7f7b259287a690ed699f79a7fa80f49b0b3a",
      "2.4.2" => "9057bc1a4f80860d498bde00b67aa26c8e3e3a03097e8cb59ac889aadc0139b6",
      "2.4.3" => "614c6343dbaa45cedef27d23eb0901a383c46bfeb577039a5e60cad17186ccee",
      "2.5.3" => "383f0fa811aff4b15c28c8d5d0aebed738a134f9bb62d6c57c66ae100b10affe",
      "2.5.4" => "4e1fbb074079c3ac3a0a5a639d47fb5f9c8dfadde26dae81e3d743e9feead821"
    },
    "rebar3_ex_doc" => %{
      "0.2.0" => "94181aa8602c4e224b25ca997475b9d5711ca0b58934b338fd7d7cc8eafa0a1e",
      "0.2.1" => "3c80b4ec18a1bc7b14b6ba693e10681ad672fdf2a4b383c24cba31cac3537cce",
      "0.2.2" => "2dff77a8fc4ce27535d61cc1a8074105df63186b9a97ffcaa2ce23eb8fb9ac6d",
      "0.2.3" => "cc4d35f61cf7d438b5a2f712fdbf8989c8190903a676b606e77d1bb6391783e1",
      "0.2.4" => "f7bed8f6c1e1cd0768eef2290417a78c3d75e36c17bec6414792042a961fe4b6",
      "0.2.5" => "4ef951468b81b2d48326eb9a1d20cfc50d083b955cd4101a418f1fcd71a3a71b",
      "0.2.6" => "08c80f6480e8336c145bfc002a50ed8b1aea78e6f91a38d51d60fb7ebff84dde",
      "0.2.7" => "56f39ac9fce7f6accaef160b701ed84e74516154d41245df5e5e0601d9390b14",
      "0.2.8" => "d2bb4ce9ab1534ae800626133b9cee8ba41c9d6b748f611b8e3e053a48264b54",
      "0.2.9" => "a414c420c83bfe6dd592a116f6d130bc73c2cbbda2db7ad54cb12f848dc0eadd",
      "0.2.10" => "23603ec56113a72fb7aefdc7ee04b2d5a11ae66af1ae6083ad21d2864d222622",
      "0.2.11" => "aff065f89fd31b3830367dd2a7791e8aeb16b50cb8b4e054879bf15bb17ab610",
      "0.2.12" => "3d5b6026c7aef43befcf64d38fecf0dc32f7dabcfe12e07bc09779b1860e0ae0",
      "0.2.13" => "d1afca1e9637477c8aa13295da40bf3a04ffdb1b640618a3f63d9259c1f3b55a",
      "0.2.14" => "d36f5a779fe38e98ef879234bfe149af09f8bb32e8dc6ad677787edaeb00eb02",
      "0.2.15" => "f5c5fa206ac82c3c1f9d8d4b43820289678b56b7158a438d1305e4a4fdb01f3f",
      "0.2.16" => "0409a401082d2dc9a5469079fd9df0ca8100d6080aac439ca81394f5de888dbd",
      "0.2.17" => "38b230c36fb5f59abbe43bb9cebbab06832fdfbc84c9a824f982434a92d7a0e7",
      "0.2.18" => "2d6c550c2d093c07f8b9f5794a1725aed0ccc2ea3efab4162bcb9cde3037a5a9",
      "0.2.19" => "f68896cd6d47a9b079c64f3aecf0670532200aa419279af1c496ba32f6278c3c",
      "0.2.20" => "ac78134d1e04daa0b07cffbb31fd669917d6c1565889768fecdfa7d88391f846",
      "0.2.21" => "b57104313131ecf507dd77686644022e62e85fb7059b22a9267e0027a106e230",
      "0.2.22" => "2e47addf57642777bed392cf3252e7a9aa69b41646839c5b2deb1b4b67135c10",
      "0.2.23" => "3be40b03f32af3dcf7c3773d2794ef591860eb15d575eff018fdba842a31cdc8",
      "0.2.24" => "5a4d2f1c2651b54dc522362077c9c9922113a13e047f424684104fc0b2dc6e88",
      "0.2.25" => "8f49b8c8b8898cab03ca0b62b3f88bbc8edcf095d5acdee028c17d178430b6a6",
      "0.2.26" => "4dfee066b900e3cec7dec8b91ee0503fbc342c2df42db2022c6392cb2b22f301",
      "0.2.27" => "109477dafcc5c5b3807d7c9ef540b0b1ef01ae824b864a429dbb1ac3e0aaf8fd",
      "0.2.28" => "3b8f533c5b0c00b7c966c7b0c1e6b879e22af957ba7810ed6023a18946ab39fe",
      "0.2.29" => "11a4d2c39b26ab57c32273075ccee192b62419454ead998c78505d04f5483e08",
      "0.2.30" => "6bc438522e29f7f5d66876689d78647704394afdb372af131e46c536b02d8158",
      "0.2.31" => "a6f3d0440085529d13d57a95cf5194fd15fcbf850f46b94d02e80e020e76b110",
      "0.3.0" => "026100be885317619fc420c468e26e468ea3162265081b69b397fcc73b18f87a"
    },
    "rebar3_hex" => %{
      "6.0.0" => "c7165ce3845da1b62994a22e9db42f8a2935645924dcc18ed6a9eb15df0c5fd3",
      "6.1.0" => "5cebe91643efeea8d50a949cf3495e0eed87f230c24d749efd87d7eec2d57702",
      "6.2.0" => "c0eeada1e0a1bb4cb78b6c5c032ade67177b2e27c7fa6692293536d48c218337",
      "6.3.0" => "73671a1c53cc01f07e281b4cae3f0f1b6d86df31adc1ac7a41273230b1ca9acb",
      "6.4.0" => "1f69373935f93e9bb191d9ce1989d4b2006e90b68bdacadce1ec030b8b5361e7",
      "6.5.0" => "ef390c84f38b5038eae3b4aff8783423f0c8e0e63ee7852cbe76c7cf81f469e9",
      "6.6.0" => "9bb9fb29289c334318bc79043e8103c6ebd85287562107b8b2ea2baf27c41a09",
      "6.7.0" => "16048338294163191001c704275835b2a1a9a8d365f0b100a5080cc79ddc5d7f",
      "6.8.0" => "f9b479f3a716250bd49d6eab9d04150e4219ab5c446fd39feb6cc0564a31bd6d",
      "6.9.0" => "590d5d7e15a59cf5250f0bf775b5dec0b2f4aeb631648af60a1adf1c90e23b64",
      "6.9.1" => "9cf509758b38537bed5be21289593737edc4e919800454a6e1142f3b5dd7c40f",
      "6.9.2" => "ba6bf2fc85ee60d9a5fdd14f6be54f207358d5d22a0017a50e0610a808e5519c",
      "6.9.3" => "9b54ce3caf19987ebc5731215cd9325b3676f2d1c2bec009e1be9f12f922e4c6",
      "6.9.4" => "c9211fad1ca11c01af304a936f93eda3c973e3487e9dbba639b0cac8efd1dff5",
      "6.9.5" => "f9908864977bebe504cde2d31ff5ed80179d502efa217eb65cc83ba282d3f02b",
      "6.9.6" => "81b75ab57360409290a854fac49f921e0fdb188a82e51faf4a0515e5fcf0350a",
      "6.10.0" => "b3db8a6149845644dc990ffdcdc1abaad0406f777d0f53ee6b882fed2fe9fc75",
      "6.10.1" => "66860f81870ef8b8ce974e0dd9d28c80a5f3f2cd6715d4da48e7b1d75cdd7785",
      "6.10.2" => "d7251029b357a4ce6e2665e6aa7148f16a2a8bb74e93cb43a56aa0ceff462ba5",
      "6.10.3" => "3fa5ce5cc82f1fe7c99fa2ecd84d6a3ee2700c50aeeb8d0653a08bfda4fc27aa",
      "6.11.0" => "bc7a532d713cecea31cdc1334248dfb54c2e3ce14661e812a566b56eb36e4646",
      "6.11.1" => "7f9ba77a02fd755a748dce683832d9f5dcfce555a6e6577e9428851fe3acb33b",
      "6.11.2" => "3bf9ee8802fdca0831dbc13a958606be51f120f8b5306d796f99363fdb7fef36",
      "6.11.3" => "a21989f20edee0547f19f18d7ce3d2dffb315ced908f6d8d457347df2e703e91",
      "6.11.4" => "18609e2fdc6435ef97b8d2cb608953f93bff2f4bc54259127987b7282104d08f",
      "6.11.5" => "d72c264cf84d83804fe99f24cdd16bc2632ef5a2ee474bb050cf2ac1832bcede",
      "6.11.6" => "d37cbf970afd4b9b422cf2d4dfa5d9db6b554b6c2d21469033ac0048c21bac25",
      "6.11.7" => "c2afb68c88169ed805534881b7b708154faedade2ee5d6f3605617e19d24275e",
      "6.11.8" => "5104e3d7c084342f0af17fdc660bc39222fab200ad3f3d12290d1120fa08cba8",
      "6.11.9" => "1acf16f0b99381554d6157faf37223e1f70cf776a81158b34ae71564345983d6",
      "7.0.0" => "a253f1de75a2820526ed87264fa70c7cd7cbc4ca5c2b18eafcd6ab95bee8a6fb",
      "7.0.1" => "f899f4e93727a5860eb66a299a4a3871a84ce06e97db4c564ff0b2108669fa56",
      "7.0.2" => "e537945f2432ef7ae73b10ccfb911ff2e84071debf2c0e3f7228be58c869adde",
      "7.0.3" => "37d5f234629de9c207f7288fed6ec1364470c72471f10dd4cc2c39ac74c633ec",
      "7.0.4" => "9332d84b774a7de80b55ba1fa6365d930985829841d45b34130541119736ac13",
      "7.0.5" => "5c89df770a3fb2c01468889ad7672784be03a78c255690b22e1451bea531a42f",
      "7.0.6" => "cfba16ef8b18ebbeb29f5ef7a4b4e1a12cbb7d2c607e4ebd585b481bf69ca420",
      "7.0.7" => "d52da2812c2222701352050b67513a7b674ae9823982f45f7c745f1751a0e4e9",
      "7.0.8" => "684634104670447a7a000b84d6949f9b946306353e3da689b8aa7b7ef5d18817",
      "7.0.9" => "ea3e725c4ca8d32fdedf30def44af8ffbd0712a79031f6899fbfa35a8f65b5f0",
      "7.0.10" => "6820713ed265300c8c34774dfcc278cd4ce33f6b2bc5b4a72984ceeb56b1e1e2",
      "7.0.11" => "baac0f78d16aaa150134f933626369592ba6e6ebd643d8b1bf3c4a8d91f8ba9f",
      "7.1.0" => "ecf9f445e9b52c9b3a0e7afe7dd464f7fc05259f07f5ad1e5c7532b2fc484893",
      "7.2.0" => "aefa5ed5b388f1170c9dc147c82a03f5c54f776f9207e9b48b846ac4fd81202c",
      "7.3.0" => "8c2389ae791aec845beb1010cf025d5644758f10c3aaa654efc23f0a907cff0d",
      "7.4.0" => "17ef895c3d6c0614ce762df029bfda08d6998675f40008983fa2b81d3e5db60f",
      "7.5.0" => "62f57c91c6300bd496624b432bc36c7c08e29f4e7bb6fde814ab9e3775753ddd"
    },
    "rebar3_lint" => %{
      "0.3.0" => "f2815435073c12c608b6b26c3e0a3ca5d5df1adfdfee661282d5f3f6422c8013",
      "0.3.2" => "699e0f7c159ad4cabb6d37972e4c128ac21170160985fa811fa41b3c87f7b71e",
      "0.4.0" => "23fd1dcea8bf03b8932d7e9f0a7f6562f17e76fa61c545501264bc59194e8b23",
      "0.4.1" => "40615e2f71d1b666a4b7e1ed35e440871fc5a4ee4d807660122470762fb579c9",
      "0.5.0" => "04b3574f352aed2f6c34a8f903355d82a8cbfa674bf40257b9d9a8a7e481b70b",
      "1.0.0" => "0303725c37589223a3ce3a93a7b15f2bddf9fce5f9f9e6bffbcd53f5ef2f56ae",
      "1.0.1" => "93822f005dfdec3efbdd7df3b656dc4fcb2d7896c8370af277d639a735cad037",
      "1.0.2" => "c5ea0eeff6a38e3be0418bbecf884cbdfcc0735a13c4e770601a61bab166cd65",
      "1.1.0" => "cbd3cedf46aa0b1eac310c44e70ab3322fe22635e71f4d6868fac818d2263f8e",
      "2.0.0" => "7852c3d9d8fad92f4db53781e13853cb0cc2b4d7da78f3bb1654da0aafa28312",
      "2.0.1" => "7c03c537b56d9d593a629381a3a1387f981a739373c123e66e80e258e876f20d",
      "3.0.0" => "7a838dba5daf41a1c6a4b7de1f12a9e9a6dac34b21140d06f2baa7a4576d67de",
      "3.0.1" => "c47a44b93b70be9e6bd3540b080c8cb01f28a2af8a580b7684dde0304e521579",
      "3.1.0" => "c04f57316f5545bda7770dc081a45d4e3411a011d5b7146752ffeca3d33bbdea",
      "3.2.0" => "d61023b6e609fbf9ab6a1cc90ce72b6cb8cc03187cdb9decd223bf193c39cd3f",
      "3.2.1" => "429f5616281999c16acf53662d404847344910e5846efa465b817dd1c0129831",
      "3.2.2" => "0b92a3e99762b78222debaee0762874f3e08c915e3b9514ee65d3b837ccb5638",
      "3.2.3" => "6edc6ddf2aefc0c3b12a201270e82366a6d6aea52f857fa6ae2cb3376c1f0d90",
      "3.2.4" => "a803d83f109366c518b554ee334aeb36d1fed2079250649112dfa4123875d653",
      "3.2.5" => "b5e88b254b5bc45e2d18973a363caae361aab0058063ace97d0ba9b3ffce5169",
      "3.2.6" => "b1124b93c3ee55efb319123d442634d6edc7b269f10f96c8fd831f3b6be4fba0",
      "4.0.0" => "422c5029e0cc667b33e0ed66d83f16299f4b9c07f3c957c0c695fc6f44c1ada7",
      "4.1.0" => "ad49c01e4985a6c0f2e7e036aca35451adeb53f027dc196cb351b8f536c494b1",
      "4.1.1" => "c63ee4078f7fecdd8a8c07e5a4016e4971a314b06581193219017998ad13e82f",
      "4.2.0" => "b2e826d37484f1f6e1e7189e1553167766aef163e90ec1018fadf032f14362df",
      "4.2.1" => "f341cf5dde3609f3323ce2e3e6b5155be76d0adea75b6bd239ff6499bc6c960a",
      "4.2.2" => "3773899026f5eaeebb510cea5eb6c47be0858eaee9aa5fed05516aec2d97e6d7",
      "4.2.3" => "33f757ae2fbe2bd08a079cfb2bae203fea629c267454bb983cc07ecc9f6bb83c",
      "5.0.1" => "8cff2e886da138a27f4c0da122f1dcedef5dfce00c888a0a8a66916338166997",
      "5.0.2" => "69390a93b1debbe8d549875cb6a232472e2a5ecd9b86600ae62bc937b57c68bf",
      "5.0.3" => "7ada9e83e10c1bcc17cbb691318a48837a547623152d1344731056f4d5190262",
      "5.0.4" => "d16794f70d98630b33783c2a8c73ba36959d34f870e70ff27f520810176cb554",
      "6.0.0" => "4e50bf8dc63f2c28e3a015417f53e546a566960fdc9dcb0e68d32a29df92fceb"
    },
    "rebar3_proper" => %{
      "0.10.0" => "3c9288e9fb7750f4f904378aaf0b3033285ad7cba4c2cc6ffb43642f730562ec",
      "0.10.1" => "fa1da56ba644cea3c6a32c0323dc3bbd6dc891c63397fff643dade16981550de",
      "0.10.2" => "2d1395946b19c44034d196aac5f0591db1b42b994958849719dd3ab747feae71",
      "0.10.3" => "4f59f9e794155a3b05ac5bfeeae86198e9d4ef07bad8c311c122c74669ff44d8",
      "0.10.4" => "3c1f3aaf6e46ec94ba187953f710691c3ff84d3064b8e7aa5e6f6d9bf3c0bada",
      "0.11.0" => "ad5f48d259925df2c627c4d0a2623d0c757914ffbdd8a1049884b646d95373e7",
      "0.11.1" => "aedbe20baa32b25328ca08c61a90b5241e36a9717119ebff1404b5f25e1accf7",
      "0.12.0" => "ac2af8ac83f15269547708f33623ccb39c2d59a469088e772301e2c3d04e2a64",
      "0.12.1" => "6691c4d1883543578240d157eaa9d49f3ebb3156892f7c320f070868962327b8"
    },
    "verl" => %{
      "1.0.1" => "f1939291d6b04ed7c20b4cf83cb0ebfc9141f692bb6fb51970429dfd145fec9d",
      "1.0.2" => "7a3a0a827c6c2400b26dbc87ca9231d45294abaa95d80a2aedc3310213a93139",
      "1.1.1" => "0925e51cd92a0a8be271765b02430b2e2cff8ac30ef24d123bd0d58511e8fb18"
    },
    "zipper" => %{
      "1.0.1" => "6a1fd3e1f0cc1d1df5642c9a0ce2178036411b0a5c9642851d1da276bd737c2d",
      "1.1.0" => "4644c83ae83ef3c09860cb5ed597b0c759fbbcd64ad5b00a62f51ae48aef7535"
    }
  }

  @doc "The reviewed releases: `%{package => %{version => outer sha256}}`."
  @spec pins() :: %{String.t() => %{String.t() => String.t()}}
  def pins, do: @pins

  @doc """
  `:ok` when every plugin installed for the rebar3 app in `dest` is a
  reviewed release and every name in `named` is installed; `{:refuse,
  reason}` or `{:unjudged, why}` otherwise. `cache` is rebar3's cache dir of
  the compile (`nil` when unknown), `pins` the table (`pins/0`).
  """
  @spec check(String.t(), String.t() | nil, [String.t()], map()) ::
          :ok | {:refuse, String.t()} | {:unjudged, String.t()}
  def check(dest, cache, named, pins \\ @pins) do
    with {:ok, installed} <- installed(dest),
         :ok <- all_named(named, installed) do
      Enum.reduce_while(Enum.sort(installed), :ok, fn {name, dir}, :ok ->
        case release(name, dir, cache, pins) do
          :ok -> {:cont, :ok}
          other -> {:halt, other}
        end
      end)
    end
  end

  defp all_named(named, installed) do
    case Enum.find(named, &(not Map.has_key?(installed, &1))) do
      nil -> :ok
      name -> {:unjudged, "rebar3 plugin #{name} is named but not installed"}
    end
  end

  # `%{name => real dir}` of every plugin under `dest/_build/*/plugins`.
  # sobelow_skip ["Traversal.FileModule"]
  defp installed(dest) do
    build = Path.join(dest, "_build")

    case File.lstat(build) do
      {:error, :enoent} -> {:ok, %{}}
      {:ok, %File.Stat{type: :directory}} -> profiles(build)
      _ -> {:unjudged, "rebar3 build dir cannot be read"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp profiles(build) do
    case File.ls(build) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, %{}}, fn profile, {:ok, acc} ->
          case plugins_dir(build, Path.join([build, profile, "plugins"])) do
            {:ok, found} -> {:cont, merge(acc, found)}
            other -> {:halt, other}
          end
        end)

      _ ->
        {:unjudged, "rebar3 build dir cannot be read"}
    end
  end

  defp merge(acc, found) do
    Enum.reduce_while(found, {:ok, acc}, fn {name, dir}, {:ok, acc} ->
      case Map.fetch(acc, name) do
        :error -> {:cont, {:ok, Map.put(acc, name, dir)}}
        {:ok, ^dir} -> {:cont, {:ok, acc}}
        {:ok, _other} -> {:halt, odd(name)}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp plugins_dir(build, dir) do
    case File.lstat(dir) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(dir) do
          {:ok, names} -> entries(build, dir, Enum.reject(names, &String.starts_with?(&1, ".")))
          _ -> {:unjudged, "rebar3 plugin dir cannot be read"}
        end

      {:ok, _other} ->
        {:refuse, "rebar3 build has a plugins dir that is not a directory"}

      _ ->
        {:unjudged, "rebar3 plugin dir cannot be read"}
    end
  end

  defp entries(build, dir, names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case entry(build, Path.join(dir, name), name) do
        {:ok, real} -> {:cont, {:ok, Map.put(acc, name, real)}}
        other -> {:halt, other}
      end
    end)
  end

  # A plugin's own dir, or rebar3's link from another profile to a plugin
  # dir of the same name under `_build`.
  # sobelow_skip ["Traversal.FileModule"]
  defp entry(build, path, name) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, path}

      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(path),
             real = Path.expand(target, Path.dirname(path)),
             true <- Path.basename(real) == name,
             true <- Path.basename(Path.dirname(real)) == "plugins",
             true <- Path.dirname(Path.dirname(Path.dirname(real))) == Path.expand(build),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(real) do
          {:ok, real}
        else
          _ -> odd(name)
        end

      _ ->
        odd(name)
    end
  end

  defp odd(name),
    do: {:refuse, "rebar3 build runs a plugin from a dir it cannot judge (#{name})"}

  defp release(name, dir, cache, pins) do
    with {:ok, version} <- metadata_version(name, dir),
         {:ok, sha} <- pinned(pins, name, version),
         {:ok, tarball} <- cached(cache, name, version),
         :ok <- same_sha(tarball, sha, name, version) do
      same_tree(tarball, dir, name, version)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp metadata_version(name, dir) do
    with true <- Regex.match?(@name, name),
         {:ok, text} <- small(Path.join(dir, "hex_metadata.config"), 1024 * 1024),
         {:ok, terms} <- HexFiles.parse(text),
         [^name] <- for({"name", n} <- terms, do: n),
         [version] when is_binary(version) <- for({"version", v} <- terms, do: v),
         true <- Regex.match?(@version, version) do
      {:ok, version}
    else
      _ -> {:unjudged, "rebar3 plugin #{name}: its release cannot be read"}
    end
  end

  defp pinned(pins, name, version) do
    case get_in(pins, [name, version]) do
      sha when is_binary(sha) -> {:ok, sha}
      _ -> {:refuse, "rebar3 build runs plugin #{name} #{version}, a release not reviewed"}
    end
  end

  defp cached(nil, name, version),
    do: {:unjudged, "rebar3 plugin #{name} #{version}: rebar3's cache dir is unknown"}

  defp cached(cache, name, version) do
    path = Path.join([cache, "hex", "hexpm", "packages", "#{name}-#{version}.tar"])

    case small(path, @max_tarball_bytes) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:unjudged, "rebar3 plugin #{name} #{version}: no cached Hex tarball"}
    end
  end

  defp same_sha(tarball, sha, name, version) do
    if :sha256 |> :crypto.hash(tarball) |> Base.encode16(case: :lower) == sha,
      do: :ok,
      else:
        {:refuse,
         "rebar3 build runs plugin #{name} #{version} from a Hex tarball " <>
           "that is not the reviewed release"}
  end

  defp same_tree(tarball, dir, name, version) do
    differs =
      {:refuse,
       "rebar3 build runs plugin #{name} #{version} from files that are not " <>
         "its reviewed release's"}

    with {:ok, files, metadata} <- tarball_files(tarball),
         {:ok, disk} <- walk(dir) do
      {ebin, rest} = Enum.split_with(disk, fn {path, _} -> String.starts_with?(path, "ebin/") end)
      expected = files |> Map.reject(fn {p, _} -> String.starts_with?(p, "ebin/") end)
      expected = Map.put(expected, "hex_metadata.config", metadata)

      if Map.new(rest) == expected and ebin_ok?(ebin, files, name),
        do: :ok,
        else: differs
    else
      {:unjudged, _} = unjudged -> unjudged
      _ -> differs
    end
  end

  # `ebin`: the app file and one beam per module of its own sources, or a
  # file the tarball itself ships there, byte for byte.
  defp ebin_ok?(ebin, files, name) do
    modules =
      for {path, _} <- files,
          String.starts_with?(path, "src/"),
          Path.extname(path) in [".erl", ".xrl", ".yrl"],
          into: MapSet.new(),
          do: Path.basename(path, Path.extname(path))

    Enum.all?(ebin, fn {"ebin/" <> file = path, bytes} ->
      cond do
        Map.get(files, path) == bytes -> true
        String.contains?(file, "/") -> false
        file == name <> ".app" -> true
        Path.extname(file) == ".beam" -> MapSet.member?(modules, Path.basename(file, ".beam"))
        true -> false
      end
    end)
  end

  defp tarball_files(tarball) do
    with {:ok, [{_, metadata}]} <-
           :erl_tar.extract({:binary, tarball}, [:memory, {:files, [~c"metadata.config"]}]),
         {:ok, tar} <- Rebar.contents_tar(tarball),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory]) do
      {:ok, Map.new(files, fn {path, bytes} -> {List.to_string(path), bytes} end), metadata}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Every regular file under `dir`, relative, with its bytes; anything else
  # (a link, a device) is not a release's file.
  defp walk(dir), do: walk(dir, "", {:ok, [], 0, 0})

  # sobelow_skip ["Traversal.FileModule"]
  defp walk(root, relative, acc) do
    case File.ls(Path.join(root, relative)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while(acc, fn name, acc ->
          case walk_entry(root, join(relative, name), acc) do
            {:ok, _, _, _} = acc -> {:cont, acc}
            other -> {:halt, other}
          end
        end)
        |> case do
          {:ok, files, _count, _bytes} when relative == "" -> {:ok, files}
          other -> other
        end

      _ ->
        {:unjudged, "rebar3 plugin dir cannot be read"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp walk_entry(root, relative, {:ok, files, count, bytes}) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(root, relative, {:ok, files, count, bytes})

      {:ok, %File.Stat{type: :regular, size: size}}
      when count < @max_files and bytes + size <= @max_bytes ->
        case File.read(path) do
          {:ok, data} -> {:ok, [{relative, data} | files], count + 1, bytes + size}
          _ -> {:unjudged, "rebar3 plugin dir cannot be read"}
        end

      _ ->
        :error
    end
  end

  defp join("", name), do: name
  defp join(relative, name), do: relative <> "/" <> name

  # sobelow_skip ["Traversal.FileModule"]
  defp small(path, max) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= max <- File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end
end
