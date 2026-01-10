defmodule Mix.Tasks.Har.Convert do
  @moduledoc """
  Convert an IaC configuration from one format to another.

  This is a convenience task that combines parse + transform in one step.

  ## Usage

      mix har.convert INPUT_FILE --to FORMAT [OPTIONS]

  ## Options

    * `--from` - Source format: ansible, salt, terraform (auto-detected if not specified)
    * `--to` - Target format: ansible, salt, terraform (required)
    * `--output` - Output file path (prints to stdout if not specified)
    * `--provider` - Cloud provider for Terraform output: aws, gcp, azure (default: aws)
    * `--region` - Cloud region for Terraform output (default: us-east-1)

  ## Examples

      # Convert Ansible playbook to Salt
      mix har.convert examples/ansible/webserver.yml --to salt

      # Convert Terraform to Ansible
      mix har.convert main.tf --to ansible

      # Convert Salt to Terraform with GCP
      mix har.convert states/webserver.sls --to terraform --provider gcp

      # Save output to file
      mix har.convert playbook.yml --to terraform --output main.tf

  ## Demonstration

  HAR enables tool-agnostic infrastructure automation. Convert configurations
  freely between Ansible, Salt, and Terraform while preserving semantic meaning.

  """

  use Mix.Task
  require Logger

  @shortdoc "Convert IaC configuration between formats"

  @switches [
    from: :string,
    to: :string,
    output: :string,
    provider: :string,
    region: :string,
    help: :boolean,
    verbose: :boolean
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

    source_format = detect_format(input_file, opts[:from])
    target_format = String.to_atom(opts[:to])

    if opts[:verbose] do
      Mix.shell().info("Converting #{input_file}")
      Mix.shell().info("  Source format: #{source_format}")
      Mix.shell().info("  Target format: #{target_format}")
    end

    content = File.read!(input_file)

    # Parse
    case HAR.DataPlane.Parser.parse(source_format, content) do
      {:ok, graph} ->
        if opts[:verbose] do
          Mix.shell().info("  Operations: #{length(graph.vertices)}")
          Mix.shell().info("  Dependencies: #{length(graph.edges)}")
        end

        # Transform
        transform_opts =
          [to: target_format]
          |> maybe_add(:provider, opts[:provider])
          |> maybe_add(:region, opts[:region])

        case HAR.DataPlane.Transformer.transform(graph, transform_opts) do
          {:ok, output} ->
            write_output(output, opts[:output], target_format)

            Mix.shell().info(
              "Successfully converted #{source_format} -> #{target_format}"
            )

          {:error, reason} ->
            Mix.raise("Transform error: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Parse error: #{inspect(reason)}")
    end
  end

  defp detect_format(file, nil) do
    cond do
      String.ends_with?(file, [".yml", ".yaml"]) ->
        content = File.read!(file)

        cond do
          content =~ ~r/hosts:\s*\w/ -> :ansible
          content =~ ~r/\w+:\s*\n\s+\w+\./ -> :salt
          true -> :ansible
        end

      String.ends_with?(file, ".tf") ->
        :terraform

      String.ends_with?(file, ".json") ->
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

  defp maybe_add(opts, _key, nil), do: opts

  defp maybe_add(opts, key, value) do
    Keyword.put(opts, key, String.to_atom(value))
  end

  defp write_output(output, nil, _format) do
    Mix.shell().info("\n--- Output ---")
    IO.puts(output)
  end

  defp write_output(output, path, _format) do
    File.write!(path, output)
    Mix.shell().info("Output written to #{path}")
  end
end
