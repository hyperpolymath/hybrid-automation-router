defmodule Mix.Tasks.Har.Transform do
  @moduledoc """
  Transform a HAR semantic graph to target IaC format.

  ## Usage

      mix har.transform INPUT_FILE --to FORMAT [--output OUTPUT_FILE]

  ## Options

    * `--to` - Target format: ansible, salt, terraform (required)
    * `--output` - Output file path (prints to stdout if not specified)
    * `--provider` - Cloud provider for Terraform: aws, gcp, azure (default: aws)
    * `--region` - Cloud region for Terraform (default: us-east-1)

  ## Examples

      # Transform graph to Salt format
      mix har.transform graph.json --to salt

      # Transform to Terraform with GCP provider
      mix har.transform graph.json --to terraform --provider gcp

      # Save output to file
      mix har.transform graph.json --to ansible --output playbook.yml

  """

  use Mix.Task
  require Logger

  @shortdoc "Transform HAR semantic graph to IaC format"

  @switches [
    to: :string,
    output: :string,
    provider: :string,
    region: :string,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches)

    if opts[:help] || args == [] || opts[:to] == nil do
      Mix.shell().info(@moduledoc)
      exit(:normal)
    end

    # Start application
    Application.ensure_all_started(:yaml_elixir)

    [input_file | _] = args

    unless File.exists?(input_file) do
      Mix.raise("File not found: #{input_file}")
    end

    target = String.to_atom(opts[:to])
    graph = load_graph(input_file)

    transform_opts =
      [to: target]
      |> maybe_add(:provider, opts[:provider])
      |> maybe_add(:region, opts[:region])

    case HAR.DataPlane.Transformer.transform(graph, transform_opts) do
      {:ok, output} ->
        write_output(output, opts[:output])
        Mix.shell().info("Successfully transformed to #{target}")

      {:error, reason} ->
        Mix.raise("Transform error: #{inspect(reason)}")
    end
  end

  defp load_graph(path) do
    content = File.read!(path)
    data = Jason.decode!(content)

    vertices =
      Enum.map(data["vertices"] || [], fn v ->
        HAR.Semantic.Operation.new(
          String.to_atom(v["type"]),
          atomize_keys(v["params"] || %{}),
          id: v["id"],
          target: atomize_keys(v["target"] || %{}),
          metadata: atomize_keys(v["metadata"] || %{})
        )
      end)

    edges =
      Enum.map(data["edges"] || [], fn e ->
        HAR.Semantic.Dependency.new(
          e["from"],
          e["to"],
          String.to_atom(e["type"]),
          metadata: atomize_keys(e["metadata"] || %{})
        )
      end)

    HAR.Semantic.Graph.new(
      vertices: vertices,
      edges: edges,
      metadata: atomize_keys(data["metadata"] || %{})
    )
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(value), do: value

  defp maybe_add(opts, _key, nil), do: opts

  defp maybe_add(opts, key, value) do
    Keyword.put(opts, key, String.to_atom(value))
  end

  defp write_output(output, nil) do
    Mix.shell().info("\n--- Output ---")
    IO.puts(output)
  end

  defp write_output(output, path) do
    File.write!(path, output)
    Mix.shell().info("Output written to #{path}")
  end
end
