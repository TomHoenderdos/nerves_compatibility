import Config

# Portal (Phoenix) config lives with the app and is imported here when present.
# Guarded so the worker Docker image (which copies only compatibility + worker)
# still builds without apps/portal on disk.
if File.exists?(Path.expand("../apps/portal/config/config.exs", __DIR__)) do
  import_config "../apps/portal/config/config.exs"
end
