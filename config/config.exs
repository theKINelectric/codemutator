# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mutator,
  ecto_repos: [Mutator.Repo],
  generators: [timestamp_type: :utc_datetime]

# SQLite: WAL + busy timeout keep the serialized application writer and the
# web reads from colliding (MVP_PLAN.md §2). Small pool by design.
config :mutator, Mutator.Repo,
  database: Path.expand("../mutator_#{config_env()}.db", __DIR__),
  pool_size: 2,
  journal_mode: :wal,
  busy_timeout: 5_000

# Mutation service: where subject clones and worker trees live.
config :mutator,
  workspace_root: Path.expand("../temporary_subject", __DIR__),
  # Copy exclusions target VCS metadata and original build caches only;
  # tests and vendored dependencies are always copied (MVP_PLAN.md §3).
  # rsync patterns, anchored with a leading "/" so they match only the
  # subject's own root: `deps/<gitdep>/.git` must survive or mix declares
  # the dependency unavailable (observed with heroicons in the dogfood).
  copy_excludes: [
    "/.git",
    "/.hg",
    "/.zig-cache",
    "/zig-out",
    "/_build",
    "/.elixir_ls",
    ".DS_Store"
  ]

# Configures the endpoint
config :mutator, MutatorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MutatorWeb.ErrorHTML, json: MutatorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mutator.PubSub,
  live_view: [signing_salt: "85CBbAs5"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  mutator: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  mutator: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
