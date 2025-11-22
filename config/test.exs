import Config

# Test environment configuration

config :har,
  security_tier: :development,
  web_enabled: false,
  telemetry_enabled: false,
  ipfs_enabled: false

config :logger, :console,
  level: :warn
