defmodule HAR.Semantic.Graph do
  @moduledoc """
  Directed acyclic graph representing infrastructure operations and their dependencies.

  The semantic graph is HAR's intermediate representation (IR) - a tool-agnostic
  representation of infrastructure changes that can be transformed to any target format.
  """

  alias HAR.Semantic.{Operation, Dependency}

  @type t :: %__MODULE__{
          vertices: [Operation.t()],
          edges: [Dependency.t()],
          metadata: map()
        }

  defstruct vertices: [],
            edges: [],
            metadata: %{}

  @doc """
  Create a new semantic graph.

  ## Examples

      iex> Graph.new()
      %Graph{vertices: [], edges: []}

      iex> Graph.new(vertices: [op1, op2], edges: [dep1])
      %Graph{vertices: [op1, op2], edges: [dep1]}
  """
  def new(opts \\ []) do
    %__MODULE__{
      vertices: Keyword.get(opts, :vertices, []),
      edges: Keyword.get(opts, :edges, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Add an operation to the graph.
  """
  @spec add_operation(t(), Operation.t()) :: t()
  def add_operation(%__MODULE__{} = graph, %Operation{} = operation) do
    %{graph | vertices: [operation | graph.vertices]}
  end

  @doc """
  Add a dependency to the graph.
  """
  @spec add_dependency(t(), Dependency.t()) :: t()
  def add_dependency(%__MODULE__{} = graph, %Dependency{} = dependency) do
    %{graph | edges: [dependency | graph.edges]}
  end

  @doc """
  Find an operation by ID.
  """
  @spec find_operation(t(), String.t()) :: Operation.t() | nil
  def find_operation(%__MODULE__{vertices: vertices}, id) do
    Enum.find(vertices, fn op -> op.id == id end)
  end

  @doc """
  Get all operations of a specific type.
  """
  @spec operations_by_type(t(), atom()) :: [Operation.t()]
  def operations_by_type(%__MODULE__{vertices: vertices}, type) do
    Enum.filter(vertices, fn op -> op.type == type end)
  end

  @doc """
  Get dependencies for a specific operation.
  """
  @spec dependencies_for(t(), String.t()) :: [Dependency.t()]
  def dependencies_for(%__MODULE__{edges: edges}, operation_id) do
    Enum.filter(edges, fn dep -> dep.to == operation_id end)
  end

  @doc """
  Get operations that depend on a specific operation.
  """
  @spec dependents_of(t(), String.t()) :: [Dependency.t()]
  def dependents_of(%__MODULE__{edges: edges}, operation_id) do
    Enum.filter(edges, fn dep -> dep.from == operation_id end)
  end

  @doc """
  Validate the graph structure.

  Checks:
  - All dependency references point to existing operations
  - No circular dependencies
  - All operations have valid parameters
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = graph) do
    with :ok <- validate_references(graph),
         :ok <- validate_acyclic(graph),
         :ok <- validate_operations(graph) do
      :ok
    end
  end

  defp validate_references(%__MODULE__{vertices: vertices, edges: edges}) do
    operation_ids = MapSet.new(vertices, & &1.id)

    invalid_refs =
      Enum.filter(edges, fn dep ->
        not MapSet.member?(operation_ids, dep.from) or
          not MapSet.member?(operation_ids, dep.to)
      end)

    if Enum.empty?(invalid_refs) do
      :ok
    else
      {:error, {:invalid_references, invalid_refs}}
    end
  end

  defp validate_acyclic(%__MODULE__{} = graph) do
    case topological_sort(graph) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_operations(%__MODULE__{vertices: vertices}) do
    invalid_ops =
      Enum.reject(vertices, fn op ->
        Operation.validate(op) == :ok
      end)

    if Enum.empty?(invalid_ops) do
      :ok
    else
      {:error, {:invalid_operations, invalid_ops}}
    end
  end

  @doc """
  Perform topological sort to find valid execution order.

  Returns operations in dependency order (dependencies before dependents).
  """
  @spec topological_sort(t()) :: {:ok, [Operation.t()]} | {:error, :circular_dependency}
  def topological_sort(%__MODULE__{} = graph) do
    case kahn_sort(graph) do
      {:ok, sorted_ids} ->
        sorted_ops = Enum.map(sorted_ids, &find_operation(graph, &1))
        {:ok, sorted_ops}

      {:error, _} = error ->
        error
    end
  end

  # Kahn's algorithm for topological sorting
  defp kahn_sort(%__MODULE__{vertices: vertices, edges: edges}) do
    # Build adjacency list and in-degree map
    adj_list = build_adjacency_list(edges)
    in_degree = build_in_degree_map(vertices, edges)

    # Start with nodes that have no incoming edges
    queue =
      vertices
      |> Enum.filter(fn op -> Map.get(in_degree, op.id, 0) == 0 end)
      |> Enum.map(& &1.id)

    kahn_sort_loop(queue, adj_list, in_degree, [])
  end

  defp kahn_sort_loop([], _adj_list, in_degree, result) do
    # Check if all nodes were processed
    remaining = Enum.filter(in_degree, fn {_k, v} -> v > 0 end)

    if Enum.empty?(remaining) do
      {:ok, Enum.reverse(result)}
    else
      {:error, :circular_dependency}
    end
  end

  defp kahn_sort_loop([node | rest], adj_list, in_degree, result) do
    # Process node
    new_result = [node | result]

    # Reduce in-degree of neighbors
    neighbors = Map.get(adj_list, node, [])

    {new_queue, new_in_degree} =
      Enum.reduce(neighbors, {rest, in_degree}, fn neighbor, {queue_acc, degree_acc} ->
        new_degree = Map.update!(degree_acc, neighbor, &(&1 - 1))

        if new_degree[neighbor] == 0 do
          {queue_acc ++ [neighbor], new_degree}
        else
          {queue_acc, new_degree}
        end
      end)

    kahn_sort_loop(new_queue, adj_list, new_in_degree, new_result)
  end

  defp build_adjacency_list(edges) do
    Enum.reduce(edges, %{}, fn dep, acc ->
      Map.update(acc, dep.from, [dep.to], fn existing -> [dep.to | existing] end)
    end)
  end

  defp build_in_degree_map(vertices, edges) do
    base_map = Map.new(vertices, fn op -> {op.id, 0} end)

    Enum.reduce(edges, base_map, fn dep, acc ->
      Map.update!(acc, dep.to, &(&1 + 1))
    end)
  end

  @doc """
  Partition graph by target criteria.

  Useful for distributed execution - split graph into subgraphs
  that can run independently on different targets.
  """
  @spec partition_by(t(), (Operation.t() -> term())) :: [{term(), t()}]
  def partition_by(%__MODULE__{vertices: vertices, edges: edges}, fun) do
    # Group operations by key function
    grouped = Enum.group_by(vertices, fun)

    # For each group, create subgraph with relevant edges
    Enum.map(grouped, fn {key, ops} ->
      op_ids = MapSet.new(ops, & &1.id)

      relevant_edges =
        Enum.filter(edges, fn dep ->
          MapSet.member?(op_ids, dep.from) and MapSet.member?(op_ids, dep.to)
        end)

      subgraph = %__MODULE__{
        vertices: ops,
        edges: relevant_edges,
        metadata: %{partition_key: key}
      }

      {key, subgraph}
    end)
  end

  @doc """
  Merge multiple graphs into one.
  """
  @spec merge([t()]) :: t()
  def merge(graphs) when is_list(graphs) do
    %__MODULE__{
      vertices:
        graphs
        |> Enum.flat_map(& &1.vertices)
        |> Enum.uniq_by(& &1.id),
      edges:
        graphs
        |> Enum.flat_map(& &1.edges)
        |> Enum.uniq(),
      metadata: %{
        merged_from: Enum.map(graphs, & &1.metadata)
      }
    }
  end

  @doc """
  Count operations in graph.
  """
  @spec operation_count(t()) :: non_neg_integer()
  def operation_count(%__MODULE__{vertices: vertices}), do: length(vertices)

  @doc """
  Count dependencies in graph.
  """
  @spec dependency_count(t()) :: non_neg_integer()
  def dependency_count(%__MODULE__{edges: edges}), do: length(edges)

  @doc """
  Check if graph is empty.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{vertices: []}), do: true
  def empty?(%__MODULE__{}), do: false
end
