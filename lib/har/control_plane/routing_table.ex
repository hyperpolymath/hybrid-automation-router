defmodule HAR.ControlPlane.RoutingTable do
  @moduledoc """
  Pattern-based routing table for backend selection.

  Loads routing rules from YAML configuration and matches operations
  against patterns to determine appropriate backends.
  """

  use GenServer
  require Logger

  alias HAR.Semantic.Operation

  @type backend :: %{
          name: String.t(),
          type: atom(),
          priority: non_neg_integer(),
          capabilities: [atom()],
          metadata: map()
        }

  @type route :: %{
          pattern: map(),
          backends: [backend()]
        }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Match an operation against routing table to find backends.

  Returns list of backends sorted by priority (highest first).
  """
  @spec match(Operation.t(), atom()) :: [backend()]
  def match(%Operation{} = operation, target) do
    GenServer.call(__MODULE__, {:match, operation, target})
  end

  @doc """
  Reload routing table from file.
  """
  @spec reload(String.t()) :: :ok | {:error, term()}
  def reload(path) do
    GenServer.call(__MODULE__, {:reload, path})
  end

  @doc """
  Get current routing table.
  """
  @spec get_routes() :: [route()]
  def get_routes do
    GenServer.call(__MODULE__, :get_routes)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    table_path = Keyword.get(opts, :routing_table_path, default_table_path())

    case load_routing_table(table_path) do
      {:ok, routes} ->
        Logger.info("Loaded #{length(routes)} routing rules from #{table_path}")
        {:ok, %{routes: routes, path: table_path}}

      {:error, reason} ->
        Logger.warning("Failed to load routing table: #{inspect(reason)}, using defaults")
        {:ok, %{routes: default_routes(), path: nil}}
    end
  end

  @impl true
  def handle_call({:match, operation, target}, _from, state) do
    matching_backends = find_matching_backends(operation, target, state.routes)
    {:reply, matching_backends, state}
  end

  def handle_call({:reload, path}, _from, state) do
    case load_routing_table(path) do
      {:ok, routes} ->
        Logger.info("Reloaded routing table from #{path}")
        {:reply, :ok, %{state | routes: routes, path: path}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_routes, _from, state) do
    {:reply, state.routes, state}
  end

  # Internal Functions

  defp load_routing_table(path) do
    with {:ok, content} <- File.read(path),
         {:ok, yaml} <- YamlElixir.read_from_string(content) do
      routes = parse_routing_config(yaml)
      {:ok, routes}
    end
  end

  defp parse_routing_config(%{"routes" => routes}) when is_list(routes) do
    Enum.map(routes, &parse_route/1)
  end

  defp parse_routing_config(_), do: []

  defp parse_route(%{"pattern" => pattern, "backends" => backends}) do
    %{
      pattern: parse_pattern(pattern),
      backends: Enum.map(backends, &parse_backend/1)
    }
  end

  defp parse_pattern(pattern) when is_map(pattern) do
    Map.new(pattern, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp parse_backend(%{"name" => name} = backend) do
    %{
      name: name,
      type: Map.get(backend, "type", "local") |> String.to_atom(),
      priority: Map.get(backend, "priority", 50),
      capabilities: Map.get(backend, "capabilities", []) |> Enum.map(&String.to_atom/1),
      metadata: Map.get(backend, "metadata", %{})
    }
  end

  defp find_matching_backends(operation, target, routes) do
    routes
    |> Enum.filter(fn route -> pattern_matches?(route.pattern, operation, target) end)
    |> Enum.flat_map(& &1.backends)
    |> Enum.sort_by(& &1.priority, :desc)
    |> Enum.uniq_by(& &1.name)
  end

  defp pattern_matches?(pattern, operation, _target) do
    # Match operation type
    operation_matches = match_field(pattern[:operation], operation.type)

    # Match target fields
    target_matches =
      if pattern[:target] do
        Enum.all?(pattern.target, fn {key, pattern_value} ->
          actual_value = Map.get(operation.target, key)
          match_field(pattern_value, actual_value)
        end)
      else
        true
      end

    operation_matches and target_matches
  end

  defp match_field(nil, _actual), do: true
  defp match_field("*", _actual), do: true
  defp match_field(pattern, actual) when is_atom(pattern), do: pattern == actual
  defp match_field(pattern, actual) when is_binary(pattern) and is_atom(actual) do
    match_field(pattern, Atom.to_string(actual))
  end
  defp match_field(pattern, actual) when is_binary(pattern) and is_binary(actual) do
    cond do
      String.contains?(pattern, "*") -> wildcard_match?(pattern, actual)
      true -> pattern == actual
    end
  end
  defp match_field(pattern, actual), do: pattern == actual

  defp wildcard_match?(pattern, string) do
    regex_pattern =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")
      |> then(&("^" <> &1 <> "$"))

    Regex.match?(Regex.compile!(regex_pattern), string)
  end

  defp default_table_path do
    Path.join([Application.app_dir(:har, "priv"), "routing_table.yaml"])
  end

  defp default_routes do
    [
      # Fallback: use target backend
      %{
        pattern: %{operation: "*"},
        backends: [
          %{
            name: "default",
            type: :passthrough,
            priority: 1,
            capabilities: [:all],
            metadata: %{}
          }
        ]
      }
    ]
  end
end
