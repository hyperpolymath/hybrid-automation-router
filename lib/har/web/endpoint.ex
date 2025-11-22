defmodule HAR.Web.Endpoint do
  @moduledoc """
  Web endpoint for HAR dashboard and API.

  Provides HTTP interface for:
  - Configuration submission
  - Routing visualization
  - Metrics and monitoring
  - Health checks
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Application.get_env(:har, :web_enabled, false) do
      port = Application.get_env(:har, :web_port, 4000)
      Logger.info("Web endpoint enabled on port #{port}")
      # TODO: Start Plug/Phoenix endpoint
      {:ok, %{enabled: true, port: port}}
    else
      Logger.info("Web endpoint disabled")
      {:ok, %{enabled: false}}
    end
  end

  @doc """
  Health check endpoint.
  """
  def health_check do
    {:ok, %{status: "healthy", version: HAR.version()}}
  end
end
