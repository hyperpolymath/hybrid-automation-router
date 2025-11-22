defmodule HAR.Telemetry do
  @moduledoc """
  Telemetry setup and metric definitions for HAR.

  Provides observability into routing decisions, parsing performance,
  transformation latency, and system health.
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Telemetry poller for periodic measurements
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Attach telemetry handlers for logging and metrics.
  """
  def attach_handlers do
    # Attach logging handler
    :telemetry.attach_many(
      "har-logger",
      [
        [:har, :control_plane, :routing, :decision],
        [:har, :data_plane, :parse, :complete],
        [:har, :data_plane, :transform, :complete]
      ],
      &handle_event/4,
      nil
    )
  end

  defp handle_event([:har, :control_plane, :routing, :decision], measurements, metadata, _config) do
    Logger.info("Routing decision",
      latency_ms: measurements[:latency],
      operation_type: metadata[:operation_type],
      backend: metadata[:backend]
    )
  end

  defp handle_event([:har, :data_plane, :parse, :complete], measurements, metadata, _config) do
    Logger.debug("Parse complete",
      latency_ms: measurements[:latency],
      format: metadata[:format],
      operation_count: metadata[:operation_count]
    )
  end

  defp handle_event([:har, :data_plane, :transform, :complete], measurements, metadata, _config) do
    Logger.debug("Transform complete",
      latency_ms: measurements[:latency],
      target: metadata[:target],
      operation_count: metadata[:operation_count]
    )
  end

  defp periodic_measurements do
    [
      # VM metrics
      {__MODULE__, :measure_memory, []},
      {__MODULE__, :measure_process_count, []}
    ]
  end

  def measure_memory do
    memory = :erlang.memory()

    :telemetry.execute(
      [:vm, :memory],
      %{
        total: memory[:total],
        processes: memory[:processes],
        system: memory[:system]
      }
    )
  end

  def measure_process_count do
    :telemetry.execute(
      [:vm, :process_count],
      %{count: :erlang.system_info(:process_count)}
    )
  end
end
