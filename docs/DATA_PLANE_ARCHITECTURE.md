# HAR Data Plane Architecture

**Purpose:** Transformation execution - parsing, semantic graph construction, target generation

The data plane is the "hands" of HAR - it performs the actual work of parsing source configs, building semantic graphs, and generating target formats. While the control plane decides WHERE to route, the data plane executes the transformation.

## Overview

```
┌──────────────────────────────────────────────────────────────┐
│                      Data Plane                              │
│                                                               │
│  ┌────────────┐      ┌─────────────┐      ┌──────────────┐  │
│  │  Parsers   │────► │  Semantic   │────► │Transformers  │  │
│  │            │      │    Graph    │      │              │  │
│  └────────────┘      └─────────────┘      └──────────────┘  │
│        ↑                                          │          │
│        │                                          │          │
│   Source Format                              Target Format    │
│   (Ansible, Salt,                           (Any IaC tool)    │
│    Terraform, etc)                                           │
└──────────────────────────────────────────────────────────────┘
```

## Components

### 1. Parser System

**Responsibility:** Convert source IaC configs to semantic graph

**Architecture:**

```elixir
defmodule HAR.DataPlane.Parser do
  @callback parse(content :: String.t() | map(), opts :: keyword()) ::
    {:ok, Graph.t()} | {:error, term()}

  @callback validate(content :: String.t() | map()) ::
    :ok | {:error, term()}
end
```

**Parser Implementations:**

#### Ansible Parser

```elixir
defmodule HAR.DataPlane.Parsers.Ansible do
  @behaviour HAR.DataPlane.Parser

  alias HAR.Semantic.{Graph, Operation, Dependency}

  @doc """
  Parse Ansible YAML playbook to semantic graph.

  ## Examples

      iex> yaml = \"\"\"
      ...> - hosts: webservers
      ...>   tasks:
      ...>     - name: Install nginx
      ...>       apt:
      ...>         name: nginx
      ...>         state: present
      ...> \"\"\"
      iex> {:ok, graph} = parse(yaml)
  """
  def parse(yaml_content, opts \\ []) do
    with {:ok, playbook} <- YamlElixir.read_from_string(yaml_content),
         {:ok, operations} <- extract_operations(playbook),
         {:ok, dependencies} <- build_dependencies(operations) do
      {:ok, Graph.new(vertices: operations, edges: dependencies)}
    end
  end

  defp extract_operations(playbook) do
    operations = playbook
    |> Enum.flat_map(fn play ->
      play["tasks"]
      |> Enum.map(&task_to_operation/1)
    end)

    {:ok, operations}
  end

  defp task_to_operation(task) do
    # Ansible task → HAR operation
    {module, params} = extract_module(task)

    %Operation{
      id: generate_id(task),
      type: normalize_type(module),
      params: normalize_params(module, params),
      target: extract_target(task),
      metadata: %{
        source: :ansible,
        original_task: task
      }
    }
  end

  defp normalize_type("apt"), do: :package_install
  defp normalize_type("yum"), do: :package_install
  defp normalize_type("service"), do: :service_control
  defp normalize_type("template"), do: :file_template
  defp normalize_type("copy"), do: :file_copy
  defp normalize_type(module), do: String.to_atom("ansible." <> module)

  defp normalize_params("apt", %{"name" => name, "state" => state}) do
    %{
      package: name,
      action: normalize_package_state(state)
    }
  end

  defp normalize_package_state("present"), do: :install
  defp normalize_package_state("absent"), do: :remove
  defp normalize_package_state("latest"), do: :upgrade

  defp build_dependencies(operations) do
    # Extract dependencies from:
    # - Sequential ordering (default)
    # - when: conditionals
    # - notify: handlers
    # - register/uses relationships

    dependencies = operations
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [op1, op2] ->
      %Dependency{
        from: op1.id,
        to: op2.id,
        type: :sequential,
        metadata: %{}
      }
    end)

    {:ok, dependencies}
  end
end
```

#### Salt Parser

```elixir
defmodule HAR.DataPlane.Parsers.Salt do
  @behaviour HAR.DataPlane.Parser

  def parse(sls_content, opts \\ []) do
    with {:ok, state_tree} <- YamlElixir.read_from_string(sls_content),
         {:ok, operations} <- extract_operations(state_tree),
         {:ok, dependencies} <- build_dependencies(operations) do
      {:ok, Graph.new(vertices: operations, edges: dependencies)}
    end
  end

  defp extract_operations(state_tree) do
    operations = state_tree
    |> Enum.flat_map(fn {state_id, state_data} ->
      state_data
      |> Enum.map(&state_to_operation(state_id, &1))
    end)

    {:ok, operations}
  end

  defp state_to_operation(state_id, {module, args}) do
    %Operation{
      id: generate_id(state_id, module),
      type: normalize_type(module),
      params: normalize_params(module, args),
      target: extract_target(args),
      metadata: %{
        source: :salt,
        state_id: state_id
      }
    }
  end

  defp normalize_type("pkg.installed"), do: :package_install
  defp normalize_type("service.running"), do: :service_start
  defp normalize_type("file.managed"), do: :file_write
  defp normalize_type(module), do: String.to_atom("salt." <> module)

  defp build_dependencies(operations) do
    # Extract require, watch, prereq relationships
    # Salt is more explicit about dependencies than Ansible

    dependencies = operations
    |> Enum.flat_map(fn op ->
      requires = get_in(op.metadata, [:original_state, "require"]) || []

      Enum.map(requires, fn req ->
        req_op = find_operation_by_reference(operations, req)

        %Dependency{
          from: req_op.id,
          to: op.id,
          type: :requires,
          metadata: %{relationship: :require}
        }
      end)
    end)

    {:ok, dependencies}
  end
end
```

#### Terraform Parser

```elixir
defmodule HAR.DataPlane.Parsers.Terraform do
  @behaviour HAR.DataPlane.Parser

  # Use HCL parser (e.g., terraform-hcl-ex or shell out to terraform)
  def parse(hcl_content, opts \\ []) do
    with {:ok, ast} <- parse_hcl(hcl_content),
         {:ok, resources} <- extract_resources(ast),
         {:ok, operations} <- resources_to_operations(resources),
         {:ok, dependencies} <- build_dependencies(operations, resources) do
      {:ok, Graph.new(vertices: operations, edges: dependencies)}
    end
  end

  defp parse_hcl(hcl_content) do
    # Option 1: Use Elixir HCL parser
    # Option 2: Shell out to terraform
    case System.cmd("terraform", ["show", "-json", "-"], input: hcl_content) do
      {json_output, 0} ->
        Jason.decode(json_output)
      {error, _} ->
        {:error, {:terraform_parse_error, error}}
    end
  end

  defp resources_to_operations(resources) do
    operations = resources
    |> Enum.map(fn resource ->
      %Operation{
        id: resource["address"],
        type: normalize_type(resource["type"]),
        params: normalize_params(resource["type"], resource["values"]),
        target: extract_target(resource),
        metadata: %{
          source: :terraform,
          resource_type: resource["type"],
          provider: resource["provider"]
        }
      }
    end)

    {:ok, operations}
  end

  defp normalize_type("aws_instance"), do: :compute_instance_create
  defp normalize_type("aws_s3_bucket"), do: :storage_bucket_create
  defp normalize_type("null_resource"), do: :script_execute
  defp normalize_type(type), do: String.to_atom("terraform." <> type)

  defp build_dependencies(_operations, resources) do
    # Terraform explicit depends_on + implicit (reference-based)
    dependencies = resources
    |> Enum.flat_map(fn resource ->
      depends_on = get_in(resource, ["values", "depends_on"]) || []

      Enum.map(depends_on, fn dep ->
        %Dependency{
          from: dep,
          to: resource["address"],
          type: :depends_on,
          metadata: %{}
        }
      end)
    end)

    {:ok, dependencies}
  end
end
```

### 2. Semantic Graph

**Core Data Structure:**

```elixir
defmodule HAR.Semantic.Graph do
  @moduledoc """
  Directed acyclic graph representing infrastructure operations.

  Vertices: Operations (install package, start service, etc.)
  Edges: Dependencies (requires, notifies, sequential)
  """

  defstruct vertices: [], edges: [], metadata: %{}

  @type t :: %__MODULE__{
    vertices: [Operation.t()],
    edges: [Dependency.t()],
    metadata: map()
  }
end

defmodule HAR.Semantic.Operation do
  defstruct [
    :id,           # UUID
    :type,         # :package_install, :service_start, etc.
    :params,       # Operation-specific parameters
    :target,       # Target system (OS, arch, IPv6, etc.)
    :metadata      # Source tool, annotations, etc.
  ]

  @type operation_type ::
    :package_install | :package_remove | :package_upgrade |
    :service_start | :service_stop | :service_restart |
    :file_write | :file_copy | :file_template | :file_delete |
    :user_create | :user_delete | :user_modify |
    :group_create | :group_delete |
    :network_interface | :network_route | :firewall_rule |
    :script_execute | :command_run |
    atom()  # Plugin-defined types

  @type t :: %__MODULE__{
    id: String.t(),
    type: operation_type(),
    params: map(),
    target: target(),
    metadata: map()
  }

  @type target :: %{
    os: String.t(),
    arch: String.t(),
    ipv6: String.t(),
    environment: :dev | :staging | :prod,
    device_type: atom()
  }
end

defmodule HAR.Semantic.Dependency do
  defstruct [:from, :to, :type, :metadata]

  @type dependency_type ::
    :sequential |      # A must complete before B
    :requires |        # B requires A to exist
    :notifies |        # A completion triggers B
    :watches |         # B watches A for changes
    :conflicts |       # A and B cannot both run
    atom()

  @type t :: %__MODULE__{
    from: String.t(),  # Source operation ID
    to: String.t(),    # Target operation ID
    type: dependency_type(),
    metadata: map()
  }
end
```

**Graph Operations:**

```elixir
defmodule HAR.Semantic.GraphOps do
  alias HAR.Semantic.Graph

  @doc "Topological sort - find valid execution order"
  def topological_sort(%Graph{} = graph) do
    case LibGraph.topsort(to_libgraph(graph)) do
      {:ok, sorted_ids} ->
        sorted_ops = Enum.map(sorted_ids, &find_operation(graph, &1))
        {:ok, sorted_ops}
      {:error, :not_acyclic} ->
        {:error, :circular_dependency}
    end
  end

  @doc "Find cycles in dependency graph"
  def find_cycles(%Graph{} = graph) do
    g = to_libgraph(graph)
    cycles = LibGraph.cycles(g)

    Enum.map(cycles, fn cycle ->
      Enum.map(cycle, &find_operation(graph, &1))
    end)
  end

  @doc "Partition graph by target (for distributed execution)"
  def partition_by_target(%Graph{} = graph) do
    graph.vertices
    |> Enum.group_by(& &1.target.ipv6)
    |> Enum.map(fn {target, operations} ->
      subgraph_vertices = operations
      subgraph_edges = filter_edges_for_vertices(graph.edges, operations)

      {target, %Graph{vertices: subgraph_vertices, edges: subgraph_edges}}
    end)
  end

  @doc "Merge multiple graphs (union operation)"
  def merge(graphs) when is_list(graphs) do
    %Graph{
      vertices: Enum.flat_map(graphs, & &1.vertices) |> Enum.uniq_by(& &1.id),
      edges: Enum.flat_map(graphs, & &1.edges) |> Enum.uniq(),
      metadata: %{merged_from: Enum.map(graphs, & &1.metadata)}
    }
  end

  @doc "Validate graph (no cycles, all references exist)"
  def validate(%Graph{} = graph) do
    with :ok <- validate_no_cycles(graph),
         :ok <- validate_references(graph),
         :ok <- validate_operation_params(graph) do
      :ok
    end
  end
end
```

### 3. Transformer System

**Responsibility:** Convert semantic graph to target format

```elixir
defmodule HAR.DataPlane.Transformer do
  @callback transform(Graph.t(), opts :: keyword()) ::
    {:ok, String.t() | map()} | {:error, term()}

  @callback validate_operation(Operation.t()) ::
    :ok | {:error, term()}
end
```

**Transformer Implementations:**

#### Salt Transformer

```elixir
defmodule HAR.DataPlane.Transformers.Salt do
  @behaviour HAR.DataPlane.Transformer

  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, sorted_ops} <- GraphOps.topological_sort(graph),
         {:ok, salt_states} <- operations_to_states(sorted_ops),
         {:ok, sls_content} <- format_sls(salt_states, opts) do
      {:ok, sls_content}
    end
  end

  defp operations_to_states(operations) do
    states = Enum.map(operations, &operation_to_state/1)
    {:ok, states}
  end

  defp operation_to_state(%Operation{type: :package_install} = op) do
    {
      state_id(op),
      %{
        "pkg.installed" => [
          %{"name" => op.params.package}
        ]
      }
    }
  end

  defp operation_to_state(%Operation{type: :service_start} = op) do
    {
      state_id(op),
      %{
        "service.running" => [
          %{"name" => op.params.service},
          %{"enable" => true}
        ]
      }
    }
  end

  defp format_sls(states, opts) do
    yaml_map = Enum.into(states, %{})
    {:ok, YamlElixir.write_to_string!(yaml_map)}
  end
end
```

#### Ansible Transformer

```elixir
defmodule HAR.DataPlane.Transformers.Ansible do
  @behaviour HAR.DataPlane.Transformer

  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, sorted_ops} <- GraphOps.topological_sort(graph),
         {:ok, tasks} <- operations_to_tasks(sorted_ops),
         {:ok, playbook} <- format_playbook(tasks, opts) do
      {:ok, playbook}
    end
  end

  defp operations_to_tasks(operations) do
    tasks = Enum.map(operations, &operation_to_task/1)
    {:ok, tasks}
  end

  defp operation_to_task(%Operation{type: :package_install} = op) do
    %{
      "name" => "Install #{op.params.package}",
      "apt" => %{
        "name" => op.params.package,
        "state" => "present"
      }
    }
  end

  defp format_playbook(tasks, opts) do
    playbook = [
      %{
        "hosts" => opts[:hosts] || "all",
        "tasks" => tasks
      }
    ]

    {:ok, YamlElixir.write_to_string!(playbook)}
  end
end
```

#### Terraform Transformer

```elixir
defmodule HAR.DataPlane.Transformers.Terraform do
  @behaviour HAR.DataPlane.Transformer

  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, resources} <- operations_to_resources(graph.vertices),
         {:ok, hcl} <- format_hcl(resources, opts) do
      {:ok, hcl}
    end
  end

  defp operations_to_resources(operations) do
    resources = Enum.map(operations, &operation_to_resource/1)
    {:ok, resources}
  end

  defp operation_to_resource(%Operation{type: :compute_instance_create} = op) do
    """
    resource "aws_instance" "#{sanitize_id(op.id)}" {
      ami           = "#{op.params.image}"
      instance_type = "#{op.params.instance_type}"

      tags = {
        Name = "#{op.params.name}"
      }
    }
    """
  end

  defp format_hcl(resources, _opts) do
    hcl = Enum.join(resources, "\n\n")
    {:ok, hcl}
  end
end
```

### 4. Data Plane Supervisor

```elixir
defmodule HAR.DataPlane.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      # Parser pool
      {HAR.DataPlane.Parsers.Ansible, []},
      {HAR.DataPlane.Parsers.Salt, []},
      {HAR.DataPlane.Parsers.Terraform, []},

      # Transformer pool
      {HAR.DataPlane.Transformers.Ansible, []},
      {HAR.DataPlane.Transformers.Salt, []},
      {HAR.DataPlane.Transformers.Terraform, []},

      # Graph cache (ETS-backed)
      {HAR.DataPlane.GraphCache, []},

      # Validation engine
      {HAR.DataPlane.Validator, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

## Optimization Techniques

### 1. Semantic Graph Caching

```elixir
defmodule HAR.DataPlane.GraphCache do
  use GenServer

  # Cache parsed semantic graphs
  # Key: hash(source_content)
  # Value: semantic graph
  # TTL: 1 hour

  def get(content_hash) do
    GenServer.call(__MODULE__, {:get, content_hash})
  end

  def put(content_hash, graph) do
    GenServer.cast(__MODULE__, {:put, content_hash, graph})
  end

  def handle_call({:get, hash}, _from, state) do
    case :ets.lookup(:graph_cache, hash) do
      [{^hash, graph, expires_at}] ->
        if DateTime.utc_now() < expires_at do
          {:reply, {:ok, graph}, state}
        else
          :ets.delete(:graph_cache, hash)
          {:reply, {:error, :not_found}, state}
        end
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end
end
```

### 2. Parallel Parsing

```elixir
def parse_batch(configs) do
  configs
  |> Task.async_stream(fn {format, content} ->
    HAR.DataPlane.Parser.parse(format, content)
  end, max_concurrency: System.schedulers_online() * 2)
  |> Enum.map(fn {:ok, result} -> result end)
end
```

### 3. Incremental Transformation

```elixir
# Only transform changed operations
def transform_incremental(old_graph, new_graph) do
  changed_ops = diff_operations(old_graph, new_graph)

  # Transform only changed operations
  partial_result = Transformer.transform(%Graph{vertices: changed_ops})

  # Merge with cached unchanged parts
  merge_transformation_results(old_result, partial_result)
end
```

## Error Handling

**Parser Errors:**

```elixir
case Parser.parse(:ansible, invalid_yaml) do
  {:error, {:yaml_parse_error, line, message}} ->
    Logger.error("YAML parse error at line #{line}: #{message}")
    {:error, :invalid_syntax}

  {:error, {:unsupported_module, module}} ->
    Logger.warn("Unsupported Ansible module: #{module}, using passthrough")
    {:ok, graph_with_passthrough_operation}
end
```

**Transformation Errors:**

```elixir
case Transformer.transform(graph, to: :salt) do
  {:error, {:unsupported_operation, op}} ->
    # Some operations can't translate (e.g., cloud-specific)
    Logger.warn("Operation #{op.type} cannot be translated to Salt")
    {:ok, graph_without_op}

  {:error, {:validation_failed, errors}} ->
    # Generated config invalid
    {:error, {:transformation_failed, errors}}
end
```

## Testing Strategy

**Property-Based Testing:**

```elixir
defmodule HAR.DataPlane.ParserTest do
  use ExUnit.Case
  use PropCheck

  property "parsing and transforming is idempotent" do
    forall config <- ansible_playbook_generator() do
      # Parse → Transform → Parse → Transform
      # Should produce same result

      {:ok, graph1} = Parser.parse(:ansible, config)
      {:ok, salt1} = Transformer.transform(graph1, to: :salt)
      {:ok, graph2} = Parser.parse(:salt, salt1)
      {:ok, salt2} = Transformer.transform(graph2, to: :salt)

      # Semantic equivalence (not literal string match)
      semantically_equivalent?(salt1, salt2)
    end
  end
end
```

## Summary

The data plane executes HAR transformations:
- **Parsers:** Convert IaC configs to semantic graphs
- **Semantic Graph:** Universal IR, tool-agnostic
- **Transformers:** Generate target format from graph
- **Optimizations:** Caching, parallelization, incremental updates
- **Fault Tolerance:** Supervision trees isolate failures

**Key Design Principles:**
- **Plugin Architecture:** Easy to add new parsers/transformers
- **Composability:** Parse once, transform to many targets
- **Validation:** Catch errors early in pipeline
- **Performance:** Parallel processing, caching

**Next:** See examples/ directory for real-world transformations.
