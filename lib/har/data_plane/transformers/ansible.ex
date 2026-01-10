defmodule HAR.DataPlane.Transformers.Ansible do
  @moduledoc """
  Transformer for Ansible playbook format.

  Converts HAR semantic graph to Ansible playbook (YAML) configuration.
  """

  @behaviour HAR.DataPlane.Transformer

  alias HAR.Semantic.{Graph, Operation}
  require Logger

  @impl true
  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, sorted_ops} <- Graph.topological_sort(graph),
         {:ok, tasks} <- operations_to_tasks(sorted_ops),
         {:ok, playbook} <- format_playbook(tasks, opts) do
      {:ok, playbook}
    end
  end

  @impl true
  def validate(%Graph{} = graph) do
    Graph.validate(graph)
  end

  # Internal Functions

  defp operations_to_tasks(operations) do
    tasks =
      operations
      |> Enum.map(&operation_to_task/1)
      |> Enum.reject(&is_nil/1)

    {:ok, tasks}
  end

  defp operation_to_task(%Operation{type: :package_install} = op) do
    package_name = op.params.package || op.params.name

    task = %{
      "name" => task_name(op, "Install #{package_name}"),
      "apt" => %{
        "name" => package_name,
        "state" => "present"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :package_remove} = op) do
    package_name = op.params.package || op.params.name

    task = %{
      "name" => task_name(op, "Remove #{package_name}"),
      "apt" => %{
        "name" => package_name,
        "state" => "absent"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :package_upgrade} = op) do
    package_name = op.params.package || op.params.name

    task = %{
      "name" => task_name(op, "Upgrade #{package_name}"),
      "apt" => %{
        "name" => package_name,
        "state" => "latest"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :service_start} = op) do
    service_name = op.params.service || op.params.name

    task = %{
      "name" => task_name(op, "Start #{service_name}"),
      "service" => %{
        "name" => service_name,
        "state" => "started"
      }
    }

    task =
      if op.params[:enabled] do
        put_in(task, ["service", "enabled"], true)
      else
        task
      end

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :service_stop} = op) do
    service_name = op.params.service || op.params.name

    task = %{
      "name" => task_name(op, "Stop #{service_name}"),
      "service" => %{
        "name" => service_name,
        "state" => "stopped"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :service_restart} = op) do
    service_name = op.params.service || op.params.name

    task = %{
      "name" => task_name(op, "Restart #{service_name}"),
      "service" => %{
        "name" => service_name,
        "state" => "restarted"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :file_write} = op) do
    path = op.params.path || op.params.destination

    task = %{
      "name" => task_name(op, "Manage file #{path}"),
      "copy" => %{
        "dest" => path
      }
    }

    task =
      task
      |> maybe_add_module_param("copy", "content", op.params[:content])
      |> maybe_add_module_param("copy", "src", op.params[:source])
      |> maybe_add_module_param("copy", "mode", op.params[:mode])
      |> maybe_add_module_param("copy", "owner", op.params[:owner] || op.params[:user])
      |> maybe_add_module_param("copy", "group", op.params[:group])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :file_copy} = op) do
    task = %{
      "name" => task_name(op, "Copy file to #{op.params.destination}"),
      "copy" => %{
        "src" => op.params.source,
        "dest" => op.params.destination
      }
    }

    task =
      task
      |> maybe_add_module_param("copy", "mode", op.params[:mode])
      |> maybe_add_module_param("copy", "owner", op.params[:owner] || op.params[:user])
      |> maybe_add_module_param("copy", "group", op.params[:group])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :file_template} = op) do
    task = %{
      "name" => task_name(op, "Template file to #{op.params.destination}"),
      "template" => %{
        "src" => op.params.source,
        "dest" => op.params.destination
      }
    }

    task =
      task
      |> maybe_add_module_param("template", "mode", op.params[:mode])
      |> maybe_add_module_param("template", "owner", op.params[:owner] || op.params[:user])
      |> maybe_add_module_param("template", "group", op.params[:group])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :directory_create} = op) do
    task = %{
      "name" => task_name(op, "Create directory #{op.params.path}"),
      "file" => %{
        "path" => op.params.path,
        "state" => "directory"
      }
    }

    task =
      task
      |> maybe_add_module_param("file", "mode", op.params[:mode])
      |> maybe_add_module_param("file", "owner", op.params[:owner] || op.params[:user])
      |> maybe_add_module_param("file", "group", op.params[:group])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :user_create} = op) do
    task = %{
      "name" => task_name(op, "Create user #{op.params.name}"),
      "user" => %{
        "name" => op.params.name,
        "state" => "present"
      }
    }

    task =
      task
      |> maybe_add_module_param("user", "shell", op.params[:shell])
      |> maybe_add_module_param("user", "home", op.params[:home])
      |> maybe_add_module_param("user", "groups", op.params[:groups])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :command_run} = op) do
    task = %{
      "name" => task_name(op, "Run command"),
      "command" => op.params.command
    }

    task =
      task
      |> maybe_add_param("chdir", op.params[:chdir] || op.params[:cwd])
      |> maybe_add_param("creates", op.params[:creates])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :script_execute} = op) do
    task = %{
      "name" => task_name(op, "Execute script"),
      "script" => op.params.script || op.params.path
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: type} = op) do
    Logger.warning("Unsupported operation type for Ansible: #{type}")

    # Generate comment task
    %{
      "name" => "Unsupported operation: #{type}",
      "debug" => %{
        "msg" => "Operation #{type} not supported in Ansible transformation"
      }
    }
  end

  defp task_name(op, default) do
    op.metadata[:task_name] || default
  end

  defp maybe_add_when(task, op) do
    case op.target[:when] do
      nil -> task
      condition -> Map.put(task, "when", condition)
    end
  end

  defp maybe_add_param(task, _key, nil), do: task
  defp maybe_add_param(task, key, value), do: Map.put(task, key, value)

  defp maybe_add_module_param(task, _module, _key, nil), do: task

  defp maybe_add_module_param(task, module, key, value) do
    put_in(task, [module, key], value)
  end

  defp format_playbook(tasks, opts) do
    hosts = Keyword.get(opts, :hosts, "all")
    become = Keyword.get(opts, :become, false)

    play = %{
      "hosts" => hosts,
      "tasks" => tasks
    }

    play =
      if become do
        Map.put(play, "become", true)
      else
        play
      end

    playbook = [play]

    HAR.Utils.YamlFormatter.to_yaml(playbook)
  end
end
