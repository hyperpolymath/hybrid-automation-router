import Config

# Development environment configuration

config :har,
  security_tier: :development,
  require_tls: false,
  accept_self_signed: true,
  audit_logging: false,
  dev_routes: true

# Phoenix endpoint configuration for development
config :har, HARWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "development_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:har, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:har, ~w(--watch)]}
  ]

# Watch static and templates for browser reloading.
config :har, HARWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/har_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :logger, :console,
  level: :debug

# Enable code reloading
config :mix_test_watch,
  clear: true,
  tasks: [
    "test",
    "credo"
  ]

# Disable swoosh api client as it is only required for production adapters.
config :phoenix, :plug_init_mode, :runtime
