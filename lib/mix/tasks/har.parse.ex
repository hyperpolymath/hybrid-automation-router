defmodule Mix.Tasks.Har.Parse do
  @moduledoc """
  Parse an IaC configuration file to HAR semantic graph.

  ## Usage

      mix har.parse INPUT_FILE [--format FORMAT] [--output OUTPUT_FILE]

  ## Options

    * `--format` - Source format: ansible, salt, terraform (auto-detected if not specified)
    * `--output` - Output file path (prints to stdout if not specified)
    * `--json` - Output as JSON (default)
    * `--inspect` - Output as Elixir inspect format

  ## Examples

      # Parse an Ansible playbook
      mix har.parse examples/ansible/webserver.yml

      # Parse with explicit format
      mix har.parse config.yaml --format ansible

      # Save output to file
      mix har.parse main.tf --output graph.json

  """

  use Mix.Task
  require Logger

  @shortdoc "Parse IaC file to HAR semantic graph"

  @switches [
    format: :string,
    output: :string,
    json: :boolean,
    inspect: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches)

    if opts[:help] || args == [] do
      Mix.shell().info(@moduledoc)
      exit(:normal)
    end

    # Start application for YAML parser
    Application.ensure_all_started(:yaml_elixir)

    [input_file | _] = args

    unless File.exists?(input_file) do
      Mix.raise("File not found: #{input_file}")
    end

    format = detect_format(input_file, opts[:format])
    content = File.read!(input_file)

    case HAR.DataPlane.Parser.parse(format, content) do
      {:ok, graph} ->
        output = format_output(graph, opts)
        write_output(output, opts[:output])
        Mix.shell().info("Successfully parsed #{input_file} as #{format}")

      {:error, reason} ->
        Mix.raise("Parse error: #{inspect(reason)}")
    end
  end

  defp detect_format(file, nil) do
    cond do
      String.ends_with?(file, [".yml", ".yaml"]) ->
        # Could be Ansible or Salt - check content
        content = File.read!(file)

        cond do
          content =~ ~r/hosts:\s*\w/ -> :ansible
          content =~ ~r/\w+:\s*\n\s+\w+\./ -> :salt
          true -> :ansible
        end

      String.ends_with?(file, ".tf") ->
        :terraform

      String.ends_with?(file, ".json") ->
        # Check if it's Terraform JSON
        content = File.read!(file)

        if content =~ "terraform" or content =~ "resource" do
          :terraform
        else
          :ansible
        end

      String.ends_with?(file, ".sls") ->
        :salt

      true ->
        :ansible
    end
  end

  defp detect_format(_file, format) when is_binary(format) do
    String.to_atom(format)
  end

  defp format_output(graph, opts) do
    cond do
      opts[:inspect] ->
        inspect(graph, pretty: true, limit: :infinity)

      true ->
        graph_to_json(graph)
    end
  end

  defp graph_to_json(graph) do
    %{
      vertices:
        Enum.map(graph.vertices, fn op ->
          %{
            id: op.id,
            type: op.type,
            params: op.params,
            target: op.target,
            metadata: op.metadata
          }
        end),
      edges:
        Enum.map(graph.edges, fn dep ->
          %{
            from: dep.from,
            to: dep.to,
            type: dep.type,
            metadata: dep.metadata
          }
        end),
      metadata: graph.metadata
    }
    |> Jason.encode!(pretty: true)
  end

  defp write_output(output, nil) do
    Mix.shell().info("\n--- Semantic Graph ---")
    IO.puts(output)
  end

  defp write_output(output, path) do
    File.write!(path, output)
    Mix.shell().info("Output written to #{path}")
  end
end
