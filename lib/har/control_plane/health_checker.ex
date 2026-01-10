defmodule HAR.ControlPlane.HealthChecker do
  @moduledoc """
  Health checker for routing backends.

  Monitors backend health status and provides filtering for routing decisions.
  Supports multiple health check strategies:
  - HTTP health endpoints
  - TCP connectivity
  - Custom health functions
  """

  use GenServer
  require Logger

  @type backend :: map()
  @type health_status :: :healthy | :unhealthy | :degraded | :unknown

  @default_check_interval 30_000
  @default_timeout 5_000

  defstruct [
    :check_interval,
    :timeout,
    backend_health: %{},
    last_check: nil
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a backend is healthy.
  """
  @spec healthy?(backend()) :: boolean()
  def healthy?(backend) do
    case get_health(backend) do
      :healthy -> true
      :degraded -> true
      _ -> false
    end
  end

  @doc """
  Get the health status of a backend.
  """
  @spec get_health(backend()) :: health_status()
  def get_health(backend) do
    backend_id = backend_identifier(backend)

    try do
      GenServer.call(__MODULE__, {:get_health, backend_id})
    catch
      :exit, _ -> :unknown
    end
  end

  @doc """
  Filter a list of backends to only healthy ones.
  """
  @spec filter_healthy([backend()]) :: [backend()]
  def filter_healthy(backends) when is_list(backends) do
    Enum.filter(backends, &healthy?/1)
  end

  @doc """
  Register a backend for health monitoring.
  """
  @spec register_backend(backend()) :: :ok
  def register_backend(backend) do
    GenServer.cast(__MODULE__, {:register, backend})
  end

  @doc """
  Manually set health status (useful for testing or admin overrides).
  """
  @spec set_health(backend(), health_status()) :: :ok
  def set_health(backend, status) do
    GenServer.cast(__MODULE__, {:set_health, backend_identifier(backend), status})
  end

  @doc """
  Force an immediate health check on a backend.
  """
  @spec check_now(backend()) :: health_status()
  def check_now(backend) do
    GenServer.call(__MODULE__, {:check_now, backend})
  end

  @doc """
  Get health status for all registered backends.
  """
  @spec all_health() :: %{String.t() => health_status()}
  def all_health do
    try do
      GenServer.call(__MODULE__, :all_health)
    catch
      :exit, _ -> %{}
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval, @default_check_interval)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    state = %__MODULE__{
      check_interval: check_interval,
      timeout: timeout,
      backend_health: %{},
      last_check: DateTime.utc_now()
    }

    # Schedule periodic health checks
    if check_interval > 0 do
      schedule_health_check(check_interval)
    end

    Logger.info("HealthChecker started with #{check_interval}ms interval")
    {:ok, state}
  end

  @impl true
  def handle_call({:get_health, backend_id}, _from, state) do
    status = Map.get(state.backend_health, backend_id, :unknown)
    {:reply, status, state}
  end

  @impl true
  def handle_call(:all_health, _from, state) do
    {:reply, state.backend_health, state}
  end

  @impl true
  def handle_call({:check_now, backend}, _from, state) do
    status = perform_health_check(backend, state.timeout)
    backend_id = backend_identifier(backend)

    new_health = Map.put(state.backend_health, backend_id, status)
    new_state = %{state | backend_health: new_health}

    {:reply, status, new_state}
  end

  @impl true
  def handle_cast({:register, backend}, state) do
    backend_id = backend_identifier(backend)

    if not Map.has_key?(state.backend_health, backend_id) do
      # Initial status is unknown, will be updated on next check
      new_health = Map.put(state.backend_health, backend_id, :unknown)
      {:noreply, %{state | backend_health: new_health}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:set_health, backend_id, status}, state) do
    new_health = Map.put(state.backend_health, backend_id, status)
    {:noreply, %{state | backend_health: new_health}}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Perform health checks on all registered backends
    new_health =
      Enum.reduce(state.backend_health, %{}, fn {backend_id, _old_status}, acc ->
        # For now, assume all backends are healthy (mock check)
        # In production, this would perform actual health checks
        Map.put(acc, backend_id, :healthy)
      end)

    new_state = %{state | backend_health: new_health, last_check: DateTime.utc_now()}

    # Schedule next check
    schedule_health_check(state.check_interval)

    {:noreply, new_state}
  end

  # Private Functions

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end

  defp backend_identifier(backend) when is_map(backend) do
    # Create a unique identifier for the backend
    type = Map.get(backend, :type) || Map.get(backend, "type") || "unknown"
    name = Map.get(backend, :name) || Map.get(backend, "name") || ""
    "#{type}:#{name}"
  end

  defp backend_identifier(backend) when is_binary(backend), do: backend
  defp backend_identifier(backend) when is_atom(backend), do: Atom.to_string(backend)

  defp perform_health_check(backend, timeout) do
    # Determine check type based on backend configuration
    case Map.get(backend, :health_check) do
      nil ->
        # Default: assume healthy
        :healthy

      %{type: :http, url: url} ->
        check_http(url, timeout)

      %{type: :tcp, host: host, port: port} ->
        check_tcp(host, port, timeout)

      %{type: :function, fun: fun} when is_function(fun, 0) ->
        check_function(fun)

      _ ->
        :unknown
    end
  end

  defp check_http(url, timeout) do
    # Simple HTTP health check
    # In production, use a proper HTTP client
    try do
      case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, timeout}], []) do
        {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :healthy
        {:ok, {{_, status, _}, _, _}} when status in 500..599 -> :unhealthy
        {:ok, _} -> :degraded
        {:error, _} -> :unhealthy
      end
    rescue
      _ -> :unhealthy
    catch
      _ -> :unhealthy
    end
  end

  defp check_tcp(host, port, timeout) do
    host_charlist =
      if is_binary(host), do: String.to_charlist(host), else: host

    case :gen_tcp.connect(host_charlist, port, [], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :healthy

      {:error, _} ->
        :unhealthy
    end
  end

  defp check_function(fun) do
    try do
      case fun.() do
        true -> :healthy
        false -> :unhealthy
        :ok -> :healthy
        :healthy -> :healthy
        :unhealthy -> :unhealthy
        :degraded -> :degraded
        _ -> :unknown
      end
    rescue
      _ -> :unhealthy
    end
  end
end
