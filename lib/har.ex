defmodule HAR do
  @moduledoc """
  HAR (Hybrid Automation Router) - Infrastructure automation router.

  HAR treats configuration management like network packet routing. It parses
  configs from any IaC tool (Ansible, Salt, Terraform, bash), extracts semantic
  operations, and routes/transforms them to any target format.

  ## Core Concepts

  - **Semantic Graph**: Platform-agnostic IR representing infrastructure operations
  - **Control Plane**: Routing decisions, backend selection, policy enforcement
  - **Data Plane**: Parsing, transformation, execution
  - **Distributed Routing**: OTP-based clustering for scale
  - **Content Addressing**: IPFS for immutable config versioning

  ## Architecture

  ```
  IaC Config → Parser → Semantic Graph → Router → Transformer → Target Format
  ```

  ## Examples

      # Parse Ansible playbook to semantic graph
      {:ok, graph} = HAR.parse(:ansible, playbook_yaml)

      # Route operations to Salt backend
      {:ok, routing_plan} = HAR.route(graph, target: :salt)

      # Transform to Salt SLS
      {:ok, salt_sls} = HAR.transform(routing_plan)

      # One-step transformation
      {:ok, salt_sls} = HAR.convert(:ansible, playbook_yaml, to: :salt)
  """

  alias HAR.DataPlane.Parser
  alias HAR.ControlPlane.Router
  alias HAR.DataPlane.Transformer
  alias HAR.Semantic.Graph

  @doc """
  Parse IaC configuration to semantic graph.

  ## Parameters

  - `format` - Source format (`:ansible`, `:salt`, `:terraform`, `:bash`)
  - `content` - Configuration content (string or map)
  - `opts` - Parser options

  ## Examples

      HAR.parse(:ansible, ansible_yaml)
      HAR.parse(:terraform, tf_hcl, strict: true)
  """
  @spec parse(atom(), String.t() | map(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  def parse(format, content, opts \\ []) do
    Parser.parse(format, content, opts)
  end

  @doc """
  Route semantic graph operations to target backend.

  ## Parameters

  - `graph` - Semantic graph from parser
  - `opts` - Routing options (`:target`, `:policies`, `:constraints`)

  ## Examples

      HAR.route(graph, target: :salt)
      HAR.route(graph, target: :ansible, policies: [:min_latency])
  """
  @spec route(Graph.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def route(graph, opts \\ []) do
    Router.route(graph, opts)
  end

  @doc """
  Transform routing plan to target format.

  ## Parameters

  - `routing_plan` - Plan from router
  - `opts` - Transformation options

  ## Examples

      HAR.transform(routing_plan)
      HAR.transform(routing_plan, pretty: true)
  """
  @spec transform(map(), keyword()) :: {:ok, String.t() | map()} | {:error, term()}
  def transform(routing_plan, opts \\ []) do
    Transformer.transform(routing_plan, opts)
  end

  @doc """
  One-step conversion from source to target format.

  ## Parameters

  - `from` - Source format
  - `content` - Source content
  - `opts` - Options including `:to` (required)

  ## Examples

      HAR.convert(:ansible, playbook, to: :salt)
      HAR.convert(:terraform, tf_config, to: :ansible, validate: true)
  """
  @spec convert(atom(), String.t() | map(), keyword()) :: {:ok, String.t() | map()} | {:error, term()}
  def convert(from, content, opts \\ []) do
    target = Keyword.fetch!(opts, :to)

    with {:ok, graph} <- parse(from, content, opts),
         {:ok, plan} <- route(graph, Keyword.put(opts, :target, target)),
         {:ok, result} <- transform(plan, opts) do
      {:ok, result}
    end
  end

  @doc """
  Get HAR version.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:har, :vsn) |> to_string()
  end
end
