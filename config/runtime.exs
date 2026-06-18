import Config

if File.exists?(Path.expand("../apps/portal/config/runtime.exs", __DIR__)) do
  import_config "../apps/portal/config/runtime.exs"
end
