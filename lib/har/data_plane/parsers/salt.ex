defmodule HAR.DataPlane.Parsers.Salt do
  @moduledoc """
  Parser for Salt Stack SLS files (YAML format).

  Converts Salt states to HAR semantic graph operations.
  """

  @behaviour HAR.DataPlane.Parser

  alias HAR.Semantic.{Graph, Operation, Dependency}
  require Logger

  @impl true
  def parse(sls_content, opts \\ []) when is_binary(sls_content) do
    with {:ok, state_tree} <- parse_yaml(sls_content),
         {:ok, operations} <- extract_operations(state_tree, opts),
         {:ok, dependencies} <- build_dependencies(operations, state_tree) do
      graph = Graph.new(
        vertices: operations,
        edges: dependencies,
        metadata: %{source: :salt, parsed_at: DateTime.utc_now()}
      )

      {:ok, graph}
    end
  end

  @impl true
  def validate(sls_content) when is_binary(sls_content) do
    case parse_yaml(sls_content) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # Internal Functions

  defp parse_yaml(yaml_content) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:yaml_parse_error, reason}}
    end
  rescue
    e -> {:error, {:yaml_parse_error, Exception.message(e)}}
  end

  defp extract_operations(state_tree, _opts) when is_map(state_tree) do
    operations =
      state_tree
      |> Enum.flat_map(fn {state_id, state_data} ->
        extract_state_operations(state_id, state_data)
      end)

    {:ok, operations}
  end

  defp extract_state_operations(state_id, state_data) when is_map(state_data) do
    state_data
    |> Enum.with_index()
    |> Enum.map(fn {{function, args}, idx} ->
      state_function_to_operation(state_id, function, args, idx)
    end)
  end

  defp extract_state_operations(state_id, state_data) when is_list(state_data) do
    state_data
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      case item do
        {function, args} when is_map(args) or is_list(args) ->
          [state_function_to_operation(state_id, function, args, idx)]

        _ ->
          []
      end
    end)
  end

  defp state_function_to_operation(state_id, function, args, idx) do
    normalized_args = normalize_args(args)

    Operation.new(
      normalize_function_type(function),
      normalize_function_params(function, normalized_args),
      id: generate_state_id(state_id, function, idx),
      metadata: %{
        source: :salt,
        state_id: state_id,
        function: function,
        original_args: args
      }
    )
  end

  defp normalize_args(args) when is_list(args) do
    # Convert list of maps to single map
    Enum.reduce(args, %{}, fn
      item, acc when is_map(item) -> Map.merge(acc, item)
      _, acc -> acc
    end)
  end

  defp normalize_args(args) when is_map(args), do: args
  defp normalize_args(args), do: %{"_value" => args}

  defp normalize_function_type("pkg.installed"), do: :package_install
  defp normalize_function_type("pkg.removed"), do: :package_remove
  defp normalize_function_type("pkg.latest"), do: :package_upgrade
  defp normalize_function_type("service.running"), do: :service_start
  defp normalize_function_type("service.dead"), do: :service_stop
  defp normalize_function_type("file.managed"), do: :file_write
  defp normalize_function_type("file.directory"), do: :directory_create
  defp normalize_function_type("file.absent"), do: :file_delete
  defp normalize_function_type("file.copy"), do: :file_copy
  defp normalize_function_type("file.symlink"), do: :file_write
  defp normalize_function_type("user.present"), do: :user_create
  defp normalize_function_type("user.absent"), do: :user_delete
  defp normalize_function_type("group.present"), do: :group_create
  defp normalize_function_type("group.absent"), do: :group_delete
  defp normalize_function_type("cmd.run"), do: :command_run
  defp normalize_function_type("cmd.script"), do: :script_execute
  defp normalize_function_type(function), do: String.to_atom("salt." <> function)

  defp normalize_function_params("pkg.installed", args) do
    %{
      package: Map.get(args, "name") || Map.get(args, "pkgs"),
      version: Map.get(args, "version"),
      refresh: Map.get(args, "refresh", false)
    }
  end

  defp normalize_function_params("pkg.removed", args) do
    %{
      package: Map.get(args, "name") || Map.get(args, "pkgs")
    }
  end

  defp normalize_function_params("service.running", args) do
    %{
      service: Map.get(args, "name"),
      enable: Map.get(args, "enable", true),
      reload: Map.get(args, "reload", false),
      watch: Map.get(args, "watch", [])
    }
  end

  defp normalize_function_params("service.dead", args) do
    %{
      service: Map.get(args, "name"),
      enable: Map.get(args, "enable", false)
    }
  end

  defp normalize_function_params("file.managed", args) do
    %{
      path: Map.get(args, "name"),
      source: Map.get(args, "source"),
      contents: Map.get(args, "contents"),
      mode: Map.get(args, "mode"),
      user: Map.get(args, "user"),
      group: Map.get(args, "group"),
      template: Map.get(args, "template")
    }
  end

  defp normalize_function_params("file.directory", args) do
    %{
      path: Map.get(args, "name"),
      mode: Map.get(args, "mode"),
      user: Map.get(args, "user"),
      group: Map.get(args, "group"),
      makedirs: Map.get(args, "makedirs", false)
    }
  end

  defp normalize_function_params("user.present", args) do
    %{
      name: Map.get(args, "name"),
      uid: Map.get(args, "uid"),
      gid: Map.get(args, "gid"),
      home: Map.get(args, "home"),
      shell: Map.get(args, "shell"),
      groups: Map.get(args, "groups", [])
    }
  end

  defp normalize_function_params("cmd.run", args) do
    %{
      command: Map.get(args, "name") || Map.get(args, "_value"),
      cwd: Map.get(args, "cwd"),
      creates: Map.get(args, "creates"),
      unless: Map.get(args, "unless"),
      onlyif: Map.get(args, "onlyif")
    }
  end

  defp normalize_function_params(_function, args), do: args

  defp build_dependencies(operations, state_tree) do
    # Extract Salt-specific dependencies: require, watch, prereq, use

    dependencies =
      operations
      |> Enum.flat_map(fn op ->
        original_state = Map.get(state_tree, op.metadata.state_id, %{})
        extract_state_dependencies(op, original_state, operations)
      end)

    {:ok, dependencies}
  end

  defp extract_state_dependencies(operation, state_data, all_operations) when is_map(state_data) do
    state_data
    |> Enum.flat_map(fn
      {_function, args} when is_list(args) ->
        args
        |> Enum.flat_map(fn arg ->
          extract_requirement_deps(operation, arg, all_operations)
        end)

      _ ->
        []
    end)
  end

  defp extract_state_dependencies(_operation, _state_data, _all_operations), do: []

  defp extract_requirement_deps(operation, args, all_operations) when is_map(args) do
    [
      extract_deps(operation, Map.get(args, "require", []), :requires, all_operations),
      extract_deps(operation, Map.get(args, "watch", []), :watches, all_operations),
      extract_deps(operation, Map.get(args, "prereq", []), :requires, all_operations)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp extract_requirement_deps(_operation, _args, _all_operations), do: []

  defp extract_deps(operation, requirements, dep_type, all_operations) when is_list(requirements) do
    requirements
    |> Enum.map(fn req ->
      case find_operation_by_requirement(req, all_operations) do
        nil ->
          nil

        required_op ->
          Dependency.new(required_op.id, operation.id, dep_type,
            metadata: %{salt_requisite: req}
          )
      end
    end)
  end

  defp extract_deps(_operation, _requirements, _dep_type, _all_operations), do: []

  defp find_operation_by_requirement(requirement, operations) when is_map(requirement) do
    # Requirement format: %{"pkg" => "nginx"} or %{"service" => "nginx"}
    {type, name} = Enum.at(requirement, 0)

    Enum.find(operations, fn op ->
      op.metadata.function =~ type and
        (get_in(op.params, [:package]) == name or
           get_in(op.params, [:service]) == name or
           get_in(op.params, [:name]) == name)
    end)
  end

  defp find_operation_by_requirement(_requirement, _operations), do: nil

  defp generate_state_id(state_id, function, idx) do
    safe_state_id = String.replace(state_id, ~r/[^a-zA-Z0-9_]/, "_")
    "salt_#{safe_state_id}_#{function}_#{idx}_#{:erlang.unique_integer([:positive])}"
  end
end
