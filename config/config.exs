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

# Configure telemetry
config :har, HAR.Telemetry,
  metrics: [
    # Control Plane metrics
    counter("har.control_plane.routing.decisions.total"),
    summary("har.control_plane.routing.latency",
      unit: {:native, :millisecond},
      tags: [:operation_type]
    ),
    counter("har.control_plane.policy.violations.total", tags: [:policy_name]),

    # Data Plane metrics
    counter("har.data_plane.parse.total", tags: [:format, :status]),
    summary("har.data_plane.parse.latency",
      unit: {:native, :millisecond},
      tags: [:format]
    ),
    counter("har.data_plane.transform.total", tags: [:target, :status]),
    summary("har.data_plane.transform.latency",
      unit: {:native, :millisecond},
      tags: [:target]
    ),

    # Graph metrics
    distribution("har.semantic.graph.operation_count", buckets: [0, 10, 50, 100, 500, 1000]),
    distribution("har.semantic.graph.dependency_count", buckets: [0, 10, 50, 100, 500, 1000])
  ]

# Import environment-specific config
import_config "#{config_env()}.exs"
