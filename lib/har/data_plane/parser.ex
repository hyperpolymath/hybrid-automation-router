defmodule HAR.DataPlane.Parser do
  @moduledoc """
  Behaviour for IaC format parsers.

  Parsers convert source configuration formats (Ansible, Salt, Terraform, etc.)
  into HAR's semantic graph intermediate representation.
  """

  alias HAR.Semantic.Graph

  @callback parse(content :: String.t() | map(), opts :: keyword()) ::
              {:ok, Graph.t()} | {:error, term()}

  @callback validate(content :: String.t() | map()) ::
              :ok | {:error, term()}

  @doc """
  Parse content in specified format to semantic graph.

  ## Examples

      iex> Parser.parse(:ansible, ansible_yaml)
      {:ok, %Graph{}}

      iex> Parser.parse(:salt, salt_sls)
      {:ok, %Graph{}}
  """
  @spec parse(atom(), String.t() | map(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  def parse(format, content, opts \\ [])

  def parse(:ansible, content, opts) do
    HAR.DataPlane.Parsers.Ansible.parse(content, opts)
  end

  def parse(:salt, content, opts) do
    HAR.DataPlane.Parsers.Salt.parse(content, opts)
  end

  def parse(:terraform, content, opts) do
    HAR.DataPlane.Parsers.Terraform.parse(content, opts)
  end

  def parse(format, _content, _opts) do
    {:error, {:unsupported_format, format}}
  end
end
