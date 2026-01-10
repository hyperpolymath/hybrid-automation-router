defmodule HAR.DataPlane.Transformer do
  @moduledoc """
  Behaviour for target format transformers.

  Transformers convert HAR semantic graphs to target configuration formats
  (Ansible, Salt, Terraform, etc.).
  """

  alias HAR.Semantic.Graph
  alias HAR.ControlPlane.RoutingPlan

  @callback transform(Graph.t() | RoutingPlan.t(), opts :: keyword()) ::
              {:ok, String.t() | map()} | {:error, term()}

  @callback validate(Graph.t()) :: :ok | {:error, term()}

  @doc """
  Transform semantic graph or routing plan to target format.

  ## Examples

      iex> Transformer.transform(graph, to: :salt)
      {:ok, salt_sls_string}

      iex> Transformer.transform(routing_plan, to: :ansible)
      {:ok, ansible_playbook_string}
  """
  @spec transform(Graph.t() | RoutingPlan.t(), keyword()) ::
          {:ok, String.t() | map()} | {:error, term()}
  def transform(input, opts \\ [])

  def transform(%RoutingPlan{graph: graph} = _plan, opts) do
    # Extract graph from routing plan
    transform(graph, opts)
  end

  def transform(%Graph{} = graph, opts) do
    target = Keyword.fetch!(opts, :to)
    do_transform(target, graph, opts)
  end

  defp do_transform(:ansible, graph, opts) do
    HAR.DataPlane.Transformers.Ansible.transform(graph, opts)
  end

  defp do_transform(:salt, graph, opts) do
    HAR.DataPlane.Transformers.Salt.transform(graph, opts)
  end

  defp do_transform(:terraform, graph, opts) do
    HAR.DataPlane.Transformers.Terraform.transform(graph, opts)
  end

  defp do_transform(:puppet, graph, opts) do
    HAR.DataPlane.Transformers.Puppet.transform(graph, opts)
  end

  defp do_transform(:chef, graph, opts) do
    HAR.DataPlane.Transformers.Chef.transform(graph, opts)
  end

  defp do_transform(:kubernetes, graph, opts) do
    HAR.DataPlane.Transformers.Kubernetes.transform(graph, opts)
  end

  defp do_transform(target, _graph, _opts) do
    {:error, {:unsupported_target, target}}
  end
end
