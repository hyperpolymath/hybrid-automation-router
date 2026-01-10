defmodule HAR.DataPlane.Transformers.Salt do
  @moduledoc """
  Transformer for Salt Stack SLS format.

  Converts HAR semantic graph to Salt SLS (YAML) configuration.
  """

  @behaviour HAR.DataPlane.Transformer

  alias HAR.Semantic.{Graph, Operation}
  require Logger

  @impl true
  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, sorted_ops} <- Graph.topological_sort(graph),
         {:ok, states} <- operations_to_states(sorted_ops),
         {:ok, sls_content} <- format_sls(states, opts) do
      {:ok, sls_content}
    end
  end

  @impl true
  def validate(%Graph{} = graph) do
    Graph.validate(graph)
  end

  # Internal Functions

  defp operations_to_states(operations) do
    states =
      operations
      |> Enum.with_index()
      |> Enum.map(fn {op, idx} ->
        operation_to_state(op, idx)
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, states}
  end

  defp operation_to_state(%Operation{type: :package_install} = op, idx) do
    state_id = state_id_for_operation(op, idx, "install_package")

    state = %{
      "pkg.installed" => [
        %{"name" => op.params.package || op.params.name}
      ]
    }

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: :package_remove} = op, idx) do
    state_id = state_id_for_operation(op, idx, "remove_package")

    state = %{
      "pkg.removed" => [
        %{"name" => op.params.package || op.params.name}
      ]
    }

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: :service_start} = op, idx) do
    state_id = state_id_for_operation(op, idx, "start_service")

    state_def = [%{"name" => op.params.service || op.params.name}]

    state_def =
      if op.params[:enabled] do
        state_def ++ [%{"enable" => true}]
      else
        state_def
      end

    state = %{"service.running" => state_def}

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: :service_stop} = op, idx) do
    state_id = state_id_for_operation(op, idx, "stop_service")

    state = %{
      "service.dead" => [
        %{"name" => op.params.service || op.params.name}
      ]
    }

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: :file_write} = op, idx) do
    state_id = state_id_for_operation(op, idx, "manage_file")

    state_def = [%{"name" => op.params.path || op.params.destination}]

    state_def =
      state_def
      |> maybe_add("contents", op.params[:content])
      |> maybe_add("source", op.params[:source])
      |> maybe_add("mode", op.params[:mode])
      |> maybe_add("user", op.params[:owner] || op.params[:user])
      |> maybe_add("group", op.params[:group])

    state = %{"file.managed" => state_def}

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: :file_copy} = op, idx) do
    state_id = state_id_for_operation(op, idx, "copy_file")

    state_def = [
      %{"name" => op.params.destination},
      %{"source" => op.params.source}
    ]

    state_def =
      state_def
      |> maybe_add("mode", op.params[:mode])
      |> maybe_add("user", op.params[:owner] || op.params[:user])
      |> maybe_add("group", op.params[:group])

    state = %{"file.managed" => state_def}

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: :directory_create} = op, idx) do
    state_id = state_id_for_operation(op, idx, "create_directory")

    state_def = [%{"name" => op.params.path}]

    state_def =
      state_def
      |> maybe_add("mode", op.params[:mode])
      |> maybe_add("user", op.params[:owner] || op.params[:user])
      |> maybe_add("group", op.params[:group])
      |> maybe_add("makedirs", op.params[:makedirs])

    state = %{"file.directory" => state_def}

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: :user_create} = op, idx) do
    state_id = state_id_for_operation(op, idx, "create_user")

    state_def = [%{"name" => op.params.name}]

    state_def =
      state_def
      |> maybe_add("shell", op.params[:shell])
      |> maybe_add("home", op.params[:home])
      |> maybe_add("groups", op.params[:groups])

    state = %{"user.present" => state_def}

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: :command_run} = op, idx) do
    state_id = state_id_for_operation(op, idx, "run_command")

    state_def = [%{"name" => op.params.command}]

    state_def =
      state_def
      |> maybe_add("cwd", op.params[:chdir] || op.params[:cwd])
      |> maybe_add("creates", op.params[:creates])
      |> maybe_add("unless", op.params[:unless])

    state = %{"cmd.run" => state_def}

    {state_id, state}
  end

  defp operation_to_state(%Operation{type: type} = op, idx) do
    # Fallback for unsupported types
    Logger.warning("Unsupported operation type for Salt: #{type}")

    # Generate passthrough state
    state_id = state_id_for_operation(op, idx, "unsupported")

    state = %{
      "cmd.run" => [
        %{"name" => "echo 'Unsupported operation: #{type}'"}
      ]
    }

    {state_id, state}
  end

  defp state_id_for_operation(op, idx, prefix) do
    # Generate readable state ID
    case op.metadata[:task_name] || op.metadata[:state_id] do
      nil ->
        "#{prefix}_#{idx}"

      name ->
        safe_name =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9_]/, "_")
          |> String.slice(0..50)

        "#{safe_name}_#{idx}"
    end
  end

  defp maybe_add(list, _key, nil), do: list
  defp maybe_add(list, key, value), do: list ++ [%{key => value}]

  defp format_sls(states, _opts) do
    sls_map = Enum.into(states, %{})
    HAR.Utils.YamlFormatter.to_yaml(sls_map)
  end
end
