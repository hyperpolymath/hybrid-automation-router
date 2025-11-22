import Config

# Production environment configuration

config :har,
  security_tier: :industrial,
  require_tls: true,
  require_mutual_tls: true,
  accept_self_signed: false,
  audit_logging: :ipfs,
  web_enabled: true,
  telemetry_enabled: true,
  ipfs_enabled: true

config :logger, :console,
  level: :info,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :operation_id, :user_id]

# Load runtime configuration from environment variables
import_config "runtime.exs"
