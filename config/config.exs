import Config

# Portal (Phoenix) config lives with the app and is imported here when present.
# Guarded so the worker Docker image (which copies only compatibility + worker)
# still builds without apps/portal on disk.
if File.exists?(Path.expand("../apps/portal/config/config.exs", __DIR__)) do
  import_config "../apps/portal/config/config.exs"
end

# The commit a release was built from, stamped by ops/build-release.sh and read
# at compile time by `PortalWeb.HealthController`: a blue/green deploy checks
# that the release answering is the one it just built.
config :portal, :build_sha, System.get_env("NCC_BUILD_SHA")
