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

# Configure loggers
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :operation_id]

# Telemetry metrics are defined in HAR.Telemetry module at runtime
# (Telemetry.Metrics functions can't be called at config compile time)

# Import environment-specific config
import_config "#{config_env()}.exs"
