import Config

# Development environment configuration

config :har,
  security_tier: :development,
  require_tls: false,
  accept_self_signed: true,
  audit_logging: false

config :logger, :console,
  level: :debug

# Enable code reloading
config :mix_test_watch,
  clear: true,
  tasks: [
    "test",
    "credo"
  ]
