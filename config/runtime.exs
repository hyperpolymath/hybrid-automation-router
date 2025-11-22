import Config

# Runtime configuration loaded from environment variables

if config_env() == :prod do
  # Cluster configuration
  config :har,
    cluster_nodes:
      System.get_env("HAR_CLUSTER_NODES", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_atom/1)

  # Erlang cookie for distribution
  if cookie = System.get_env("RELEASE_COOKIE") do
    config :kernel, :cookie, String.to_atom(cookie)
  end

  # TLS certificates
  config :har, :tls,
    cert_file: System.get_env("HAR_TLS_CERT", "/opt/har/certs/server.crt"),
    key_file: System.get_env("HAR_TLS_KEY", "/opt/har/certs/server.key"),
    ca_file: System.get_env("HAR_TLS_CA", "/opt/har/certs/ca.crt")

  # IPFS configuration
  config :har, :ipfs,
    api_url: System.get_env("IPFS_API_URL", "http://localhost:5001")

  # Web endpoint
  config :har, HAR.Web.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))],
    url: [host: System.get_env("HOST", "localhost")],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
