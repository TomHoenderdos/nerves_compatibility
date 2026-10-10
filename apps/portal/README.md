# Portal

The Phoenix web app of the Nerves Compatibility Tracker: package browser,
scan requests, accounts and admin, Oban build queue, Catalog, badges, and the
JSON and precompiled APIs. See the root `README.md` and `CLAUDE.md`.

Run everything from the umbrella root, not from this directory: the umbrella
shares one `mix.lock`, and `mix setup` / `mix precommit` here run dependency
tasks that rewrite it.

```bash
mix deps.get
mix ecto.create && mix ecto.migrate
mix phx.server          # or: iex -S mix phx.server
```

Then visit [`localhost:4001`](http://localhost:4001). For production, see
`DEPLOY.md`.
