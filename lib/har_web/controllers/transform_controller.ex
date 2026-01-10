# SPDX-License-Identifier: MPL-2.0
defmodule HARWeb.TransformController do
  @moduledoc """
  API controller for HAR transformation operations.

  Provides JSON API endpoints for programmatic access to HAR's
  parsing and transformation capabilities.
  """

  use HARWeb, :controller

  alias HAR.DataPlane.{Parser, Transformer}
  alias HAR.Semantic.Graph

  @supported_formats ~w(ansible salt terraform puppet chef kubernetes docker_compose cloudformation pulumi)

  @doc """
  Transform configuration from source format to target format.

  ## Request Body

      {
        "source_format": "ansible",
        "target_format": "salt",
        "content": "---\n- name: Install nginx..."
      }

  ## Response

      {
        "success": true,
        "output": "nginx:\\n  pkg.installed...",
        "graph": {
          "operations": 3,
          "dependencies": 2
        }
      }
  """
  def transform(conn, params) do
    with {:ok, source_format} <- validate_format(params["source_format"], "source_format"),
         {:ok, target_format} <- validate_format(params["target_format"], "target_format"),
         {:ok, content} <- validate_content(params["content"]),
         {:ok, graph} <- Parser.parse(source_format, content),
         {:ok, output} <- Transformer.transform(graph, to: target_format) do
      json(conn, %{
        success: true,
        output: output,
        graph: summarize_graph(graph)
      })
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: format_error(reason)})
    end
  end

  @doc """
  Parse configuration and return semantic graph information.

  ## Request Body

      {
        "format": "ansible",
        "content": "---\n- name: Install nginx..."
      }

  ## Response

      {
        "success": true,
        "graph": {
          "operations": 3,
          "dependencies": 2,
          "operation_types": ["package_install", "service_manage"],
          "vertices": [...]
        }
      }
  """
  def parse(conn, params) do
    with {:ok, format} <- validate_format(params["format"], "format"),
         {:ok, content} <- validate_content(params["content"]),
         {:ok, graph} <- Parser.parse(format, content) do
      json(conn, %{
        success: true,
        graph: detailed_graph(graph)
      })
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: format_error(reason)})
    end
  end

  @doc """
  List all supported formats.

  ## Response

      {
        "formats": [
          {"id": "ansible", "name": "Ansible", "description": "YAML playbooks and roles"},
          ...
        ]
      }
  """
  def formats(conn, _params) do
    formats = [
      %{id: "ansible", name: "Ansible", description: "YAML playbooks and roles"},
      %{id: "salt", name: "Salt", description: "SLS states and pillars"},
      %{id: "terraform", name: "Terraform", description: "HCL configurations"},
      %{id: "puppet", name: "Puppet", description: "Manifests and modules"},
      %{id: "chef", name: "Chef", description: "Recipes and cookbooks"},
      %{id: "kubernetes", name: "Kubernetes", description: "YAML manifests"},
      %{id: "docker_compose", name: "Docker Compose", description: "Compose files"},
      %{id: "cloudformation", name: "CloudFormation", description: "AWS templates"},
      %{id: "pulumi", name: "Pulumi", description: "YAML configurations"}
    ]

    json(conn, %{formats: formats})
  end

  # Validation helpers

  defp validate_format(nil, field) do
    {:error, "#{field} is required"}
  end

  defp validate_format(format, field) when is_binary(format) do
    if format in @supported_formats do
      {:ok, String.to_existing_atom(format)}
    else
      {:error, "Invalid #{field}: #{format}. Supported formats: #{Enum.join(@supported_formats, ", ")}"}
    end
  end

  defp validate_content(nil) do
    {:error, "content is required"}
  end

  defp validate_content("") do
    {:error, "content cannot be empty"}
  end

  defp validate_content(content) when is_binary(content) do
    {:ok, content}
  end

  # Graph summarization

  defp summarize_graph(%Graph{} = graph) do
    types = graph.vertices |> Enum.map(& &1.type) |> Enum.uniq()

    %{
      operations: length(graph.vertices),
      dependencies: length(graph.edges),
      operation_types: types,
      source_format: graph.metadata[:source_format]
    }
  end

  defp detailed_graph(%Graph{} = graph) do
    %{
      operations: length(graph.vertices),
      dependencies: length(graph.edges),
      operation_types: graph.vertices |> Enum.map(& &1.type) |> Enum.uniq(),
      source_format: graph.metadata[:source_format],
      vertices:
        Enum.map(graph.vertices, fn op ->
          %{
            id: op.id,
            type: op.type,
            params: op.params,
            target: op.target
          }
        end),
      edges:
        Enum.map(graph.edges, fn dep ->
          %{
            from: dep.from,
            to: dep.to,
            type: dep.type
          }
        end)
    }
  end

  # Error formatting

  defp format_error({:yaml_parse_error, details}) do
    "YAML parse error: #{inspect(details)}"
  end

  defp format_error({:json_parse_error, details}) do
    "JSON parse error: #{inspect(details)}"
  end

  defp format_error({:unsupported_format, format}) do
    "Unsupported format: #{format}"
  end

  defp format_error({:unsupported_target, target}) do
    "Unsupported target format: #{target}"
  end

  defp format_error({:invalid_graph, reason}) do
    "Invalid graph: #{inspect(reason)}"
  end

  defp format_error(reason) when is_binary(reason) do
    reason
  end

  defp format_error(reason) do
    inspect(reason)
  end
end
