import Config

# Configure HAR application
config :har,
  # Security tier: :development, :iot, :industrial, :critical
  security_tier: :development,
  # Enable/disable components
  web_enabled: true,
  telemetry_enabled: true,
  ipfs_enabled: false,
  # Routing table path
  routing_table_path: Path.join([__DIR__, "..", "priv", "routing_table.yaml"])

# Configure Phoenix endpoint
config :har, HARWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HARWeb.ErrorHTML, json: HARWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HAR.PubSub,
  live_view: [signing_salt: "HAR_liveview_salt"]

# Configure esbuild (JS bundler)
config :esbuild,
  version: "0.17.11",
  har: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure Tailwind
config :tailwind,
  version: "3.4.0",
  har: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure loggers
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :operation_id]

# Use Jason for JSON parsing
config :phoenix, :json_library, Jason

# Telemetry metrics are defined in HAR.Telemetry module at runtime
# (Telemetry.Metrics functions can't be called at config compile time)

# Import environment-specific config
import_config "#{config_env()}.exs"
