defmodule HAR.DataPlane.Transformers.Ansible do
  @moduledoc """
  Transformer for Ansible playbook format.

  Converts HAR semantic graph to Ansible playbook (YAML) configuration.
  Supports OS-aware package management (apt, yum, dnf, zypper, apk, pacman).
  """

  @behaviour HAR.DataPlane.Transformer

  alias HAR.Semantic.{Graph, Operation}
  require Logger

  # OS family to package manager mapping
  @os_package_managers %{
    # Debian-based
    "debian" => "apt",
    "ubuntu" => "apt",
    "linuxmint" => "apt",
    "pop_os" => "apt",
    # RedHat-based
    "redhat" => "yum",
    "centos" => "yum",
    "rhel" => "yum",
    "fedora" => "dnf",
    "rocky" => "dnf",
    "almalinux" => "dnf",
    "oracle" => "yum",
    # SUSE
    "suse" => "zypper",
    "opensuse" => "zypper",
    "sles" => "zypper",
    # Alpine
    "alpine" => "apk",
    # Arch
    "arch" => "pacman",
    "manjaro" => "pacman",
    # FreeBSD
    "freebsd" => "pkgng",
    # macOS
    "darwin" => "homebrew",
    "macos" => "homebrew",
    # Windows
    "windows" => "win_chocolatey"
  }

  @impl true
  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, sorted_ops} <- Graph.topological_sort(graph),
         {:ok, tasks} <- operations_to_tasks(sorted_ops, opts),
         {:ok, playbook} <- format_playbook(tasks, opts) do
      {:ok, playbook}
    end
  end

  @impl true
  def validate(%Graph{} = graph) do
    Graph.validate(graph)
  end

  # Internal Functions

  defp operations_to_tasks(operations, opts) do
    tasks =
      operations
      |> Enum.map(&operation_to_task(&1, opts))
      |> Enum.reject(&is_nil/1)

    {:ok, tasks}
  end

  defp operation_to_task(%Operation{type: :package_install} = op, opts) do
    package_name = op.params[:package] || op.params[:name]
    pkg_manager = get_package_manager(op, opts)

    task = %{
      "name" => task_name(op, "Install #{package_name}"),
      pkg_manager => build_package_params(pkg_manager, package_name, "present", op)
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :package_remove} = op, opts) do
    package_name = op.params[:package] || op.params[:name]
    pkg_manager = get_package_manager(op, opts)

    task = %{
      "name" => task_name(op, "Remove #{package_name}"),
      pkg_manager => build_package_params(pkg_manager, package_name, "absent", op)
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :package_upgrade} = op, opts) do
    package_name = op.params[:package] || op.params[:name]
    pkg_manager = get_package_manager(op, opts)

    task = %{
      "name" => task_name(op, "Upgrade #{package_name}"),
      pkg_manager => build_package_params(pkg_manager, package_name, "latest", op)
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :service_start} = op, _opts) do
    service_name = op.params[:service] || op.params[:name]

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

  defp operation_to_task(%Operation{type: :service_stop} = op, _opts) do
    service_name = op.params[:service] || op.params[:name]

    task = %{
      "name" => task_name(op, "Stop #{service_name}"),
      "service" => %{
        "name" => service_name,
        "state" => "stopped"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :service_restart} = op, _opts) do
    service_name = op.params[:service] || op.params[:name]

    task = %{
      "name" => task_name(op, "Restart #{service_name}"),
      "service" => %{
        "name" => service_name,
        "state" => "restarted"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :service_enable} = op, _opts) do
    service_name = op.params[:service] || op.params[:name]

    task = %{
      "name" => task_name(op, "Enable #{service_name}"),
      "service" => %{
        "name" => service_name,
        "enabled" => true
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :service_disable} = op, _opts) do
    service_name = op.params[:service] || op.params[:name]

    task = %{
      "name" => task_name(op, "Disable #{service_name}"),
      "service" => %{
        "name" => service_name,
        "enabled" => false
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :file_write} = op, _opts) do
    path = op.params[:path] || op.params[:destination]

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

  defp operation_to_task(%Operation{type: :file_copy} = op, _opts) do
    task = %{
      "name" => task_name(op, "Copy file to #{op.params[:destination]}"),
      "copy" => %{
        "src" => op.params[:source],
        "dest" => op.params[:destination]
      }
    }

    task =
      task
      |> maybe_add_module_param("copy", "mode", op.params[:mode])
      |> maybe_add_module_param("copy", "owner", op.params[:owner] || op.params[:user])
      |> maybe_add_module_param("copy", "group", op.params[:group])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :file_template} = op, _opts) do
    task = %{
      "name" => task_name(op, "Template file to #{op.params[:destination]}"),
      "template" => %{
        "src" => op.params[:source],
        "dest" => op.params[:destination]
      }
    }

    task =
      task
      |> maybe_add_module_param("template", "mode", op.params[:mode])
      |> maybe_add_module_param("template", "owner", op.params[:owner] || op.params[:user])
      |> maybe_add_module_param("template", "group", op.params[:group])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :file_delete} = op, _opts) do
    task = %{
      "name" => task_name(op, "Delete file #{op.params[:path]}"),
      "file" => %{
        "path" => op.params[:path],
        "state" => "absent"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :directory_create} = op, _opts) do
    task = %{
      "name" => task_name(op, "Create directory #{op.params[:path]}"),
      "file" => %{
        "path" => op.params[:path],
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

  defp operation_to_task(%Operation{type: :directory_delete} = op, _opts) do
    task = %{
      "name" => task_name(op, "Delete directory #{op.params[:path]}"),
      "file" => %{
        "path" => op.params[:path],
        "state" => "absent"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :user_create} = op, _opts) do
    task = %{
      "name" => task_name(op, "Create user #{op.params[:name]}"),
      "user" => %{
        "name" => op.params[:name],
        "state" => "present"
      }
    }

    task =
      task
      |> maybe_add_module_param("user", "shell", op.params[:shell])
      |> maybe_add_module_param("user", "home", op.params[:home])
      |> maybe_add_module_param("user", "groups", op.params[:groups])
      |> maybe_add_module_param("user", "uid", op.params[:uid])
      |> maybe_add_module_param("user", "comment", op.params[:comment])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :user_delete} = op, _opts) do
    task = %{
      "name" => task_name(op, "Delete user #{op.params[:name]}"),
      "user" => %{
        "name" => op.params[:name],
        "state" => "absent"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :group_create} = op, _opts) do
    task = %{
      "name" => task_name(op, "Create group #{op.params[:name]}"),
      "group" => %{
        "name" => op.params[:name],
        "state" => "present"
      }
    }

    task = maybe_add_module_param(task, "group", "gid", op.params[:gid])
    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :group_delete} = op, _opts) do
    task = %{
      "name" => task_name(op, "Delete group #{op.params[:name]}"),
      "group" => %{
        "name" => op.params[:name],
        "state" => "absent"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :command_run} = op, _opts) do
    task = %{
      "name" => task_name(op, "Run command"),
      "command" => op.params[:command] || op.params[:cmd]
    }

    task =
      task
      |> maybe_add_param("chdir", op.params[:chdir] || op.params[:cwd])
      |> maybe_add_param("creates", op.params[:creates])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :shell_run} = op, _opts) do
    task = %{
      "name" => task_name(op, "Run shell command"),
      "shell" => op.params[:command] || op.params[:cmd]
    }

    task =
      task
      |> maybe_add_param("chdir", op.params[:chdir] || op.params[:cwd])
      |> maybe_add_param("creates", op.params[:creates])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :script_execute} = op, _opts) do
    task = %{
      "name" => task_name(op, "Execute script"),
      "script" => op.params[:script] || op.params[:path]
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :cron_create} = op, _opts) do
    task = %{
      "name" => task_name(op, "Create cron job"),
      "cron" => %{
        "name" => op.params[:name],
        "job" => op.params[:command] || op.params[:job]
      }
    }

    task =
      task
      |> maybe_add_module_param("cron", "minute", op.params[:minute])
      |> maybe_add_module_param("cron", "hour", op.params[:hour])
      |> maybe_add_module_param("cron", "day", op.params[:day])
      |> maybe_add_module_param("cron", "month", op.params[:month])
      |> maybe_add_module_param("cron", "weekday", op.params[:weekday])
      |> maybe_add_module_param("cron", "user", op.params[:user])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :cron_delete} = op, _opts) do
    task = %{
      "name" => task_name(op, "Delete cron job"),
      "cron" => %{
        "name" => op.params[:name],
        "state" => "absent"
      }
    }

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :git_clone} = op, _opts) do
    task = %{
      "name" => task_name(op, "Clone git repository"),
      "git" => %{
        "repo" => op.params[:repo] || op.params[:url],
        "dest" => op.params[:dest] || op.params[:destination]
      }
    }

    task =
      task
      |> maybe_add_module_param("git", "version", op.params[:version] || op.params[:branch])
      |> maybe_add_module_param("git", "depth", op.params[:depth])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :docker_container} = op, _opts) do
    task = %{
      "name" => task_name(op, "Manage Docker container #{op.params[:name]}"),
      "docker_container" => %{
        "name" => op.params[:name],
        "image" => op.params[:image],
        "state" => op.params[:state] || "started"
      }
    }

    task =
      task
      |> maybe_add_module_param("docker_container", "ports", op.params[:ports])
      |> maybe_add_module_param("docker_container", "volumes", op.params[:volumes])
      |> maybe_add_module_param("docker_container", "env", op.params[:env])

    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: :docker_image} = op, _opts) do
    task = %{
      "name" => task_name(op, "Manage Docker image #{op.params[:name]}"),
      "docker_image" => %{
        "name" => op.params[:name],
        "source" => op.params[:source] || "pull"
      }
    }

    task = maybe_add_module_param(task, "docker_image", "tag", op.params[:tag])
    maybe_add_when(task, op)
  end

  defp operation_to_task(%Operation{type: type} = _op, _opts) do
    Logger.warning("Unsupported operation type for Ansible: #{type}")

    # Generate comment task
    %{
      "name" => "Unsupported operation: #{type}",
      "debug" => %{
        "msg" => "Operation #{type} not supported in Ansible transformation"
      }
    }
  end

  # Package manager helper functions

  # Determine package manager from operation target or options
  defp get_package_manager(op, opts) do
    # Priority: operation target > opts > default
    os = get_os_from_target(op.target) || Keyword.get(opts, :os)

    case os do
      nil ->
        # Use generic 'package' module for OS-agnostic operations
        "package"
      os_name ->
        os_key = os_name |> to_string() |> String.downcase()
        Map.get(@os_package_managers, os_key, "package")
    end
  end

  defp get_os_from_target(nil), do: nil
  defp get_os_from_target(target) when is_map(target) do
    target[:os] || target[:os_family] || target["os"] || target["os_family"]
  end
  defp get_os_from_target(_), do: nil

  # Build package params based on package manager specifics
  defp build_package_params("apt", name, state, op) do
    params = %{"name" => name, "state" => state}
    params = if op.params[:update_cache], do: Map.put(params, "update_cache", true), else: params
    params
  end

  defp build_package_params("yum", name, state, _op) do
    %{"name" => name, "state" => state}
  end

  defp build_package_params("dnf", name, state, _op) do
    %{"name" => name, "state" => state}
  end

  defp build_package_params("zypper", name, state, _op) do
    %{"name" => name, "state" => state}
  end

  defp build_package_params("apk", name, state, op) do
    params = %{"name" => name, "state" => state}
    params = if op.params[:update_cache], do: Map.put(params, "update_cache", true), else: params
    params
  end

  defp build_package_params("pacman", name, state, op) do
    params = %{"name" => name, "state" => state}
    params = if op.params[:update_cache], do: Map.put(params, "update_cache", true), else: params
    params
  end

  defp build_package_params("homebrew", name, state, _op) do
    %{"name" => name, "state" => state}
  end

  defp build_package_params("win_chocolatey", name, state, _op) do
    %{"name" => name, "state" => state}
  end

  defp build_package_params("pkgng", name, state, _op) do
    %{"name" => name, "state" => state}
  end

  defp build_package_params("package", name, state, _op) do
    # Generic package module - most portable
    %{"name" => name, "state" => state}
  end

  defp build_package_params(_manager, name, state, _op) do
    %{"name" => name, "state" => state}
  end

  # Task helper functions

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
