# SPDX-License-Identifier: MPL-2.0
defmodule HAR.DataPlane.Transformers.Chef do
  @moduledoc """
  Transformer for Chef recipe format (Ruby DSL).

  Converts HAR semantic graph to Chef recipes.

  ## Features

  - Resource declarations with actions
  - Notification chains (notifies/subscribes)
  - Guard clauses (not_if, only_if)
  - Platform-specific resources
  - Attribute references
  """

  @behaviour HAR.DataPlane.Transformer

  alias HAR.Semantic.{Graph, Operation}
  require Logger

  @impl true
  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, sorted_ops} <- Graph.topological_sort(graph),
         {:ok, resources} <- operations_to_resources(sorted_ops, graph, opts),
         {:ok, recipe} <- format_recipe(resources, opts) do
      {:ok, recipe}
    end
  end

  @impl true
  def validate(%Graph{} = graph) do
    case Graph.topological_sort(graph) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:invalid_graph, reason}}
    end
  end

  defp operations_to_resources(operations, graph, opts) do
    # Build operation ID to resource mapping for notifications
    op_to_resource =
      operations
      |> Enum.map(fn op ->
        {type, name} = operation_to_chef_ref(op)
        {op.id, "#{type}[#{name}]"}
      end)
      |> Map.new()

    resources =
      Enum.map(operations, fn op ->
        operation_to_resource(op, graph, op_to_resource, opts)
      end)

    {:ok, resources}
  end

  defp operation_to_resource(op, graph, op_to_resource, _opts) do
    {chef_type, chef_name} = operation_to_chef_ref(op)
    action = operation_to_action(op)
    attributes = operation_to_attributes(op)
    notifications = build_notifications(op, graph, op_to_resource)

    %{
      type: chef_type,
      name: chef_name,
      action: action,
      attributes: attributes,
      notifications: notifications
    }
  end

  defp operation_to_chef_ref(%Operation{type: type, params: params}) do
    name = Map.get(params, :name) || Map.get(params, :path) || "unnamed"
    chef_type = semantic_to_chef_type(type)
    {chef_type, name}
  end

  # Semantic operation type to Chef resource type mapping

  defp semantic_to_chef_type(:package_install), do: "package"
  defp semantic_to_chef_type(:package_remove), do: "package"
  defp semantic_to_chef_type(:package_upgrade), do: "package"
  defp semantic_to_chef_type(:service_start), do: "service"
  defp semantic_to_chef_type(:service_stop), do: "service"
  defp semantic_to_chef_type(:service_restart), do: "service"
  defp semantic_to_chef_type(:service_enable), do: "service"
  defp semantic_to_chef_type(:service_disable), do: "service"
  defp semantic_to_chef_type(:file_create), do: "file"
  defp semantic_to_chef_type(:file_template), do: "template"
  defp semantic_to_chef_type(:file_copy), do: "cookbook_file"
  defp semantic_to_chef_type(:file_delete), do: "file"
  defp semantic_to_chef_type(:file_permissions), do: "file"
  defp semantic_to_chef_type(:directory_create), do: "directory"
  defp semantic_to_chef_type(:user_create), do: "user"
  defp semantic_to_chef_type(:user_delete), do: "user"
  defp semantic_to_chef_type(:user_modify), do: "user"
  defp semantic_to_chef_type(:group_create), do: "group"
  defp semantic_to_chef_type(:group_delete), do: "group"
  defp semantic_to_chef_type(:command_run), do: "execute"
  defp semantic_to_chef_type(:shell_run), do: "bash"
  defp semantic_to_chef_type(:cron_create), do: "cron"
  defp semantic_to_chef_type(:cron_delete), do: "cron"
  defp semantic_to_chef_type(:mount_create), do: "mount"
  defp semantic_to_chef_type(:git_clone), do: "git"
  defp semantic_to_chef_type(:docker_container_run), do: "docker_container"
  defp semantic_to_chef_type(:docker_image_pull), do: "docker_image"
  defp semantic_to_chef_type(type), do: to_string(type)

  # Operation to Chef action

  defp operation_to_action(%Operation{type: :package_install}), do: :install
  defp operation_to_action(%Operation{type: :package_remove}), do: :remove
  defp operation_to_action(%Operation{type: :package_upgrade}), do: :upgrade
  defp operation_to_action(%Operation{type: :service_start}), do: [:enable, :start]
  defp operation_to_action(%Operation{type: :service_stop}), do: :stop
  defp operation_to_action(%Operation{type: :service_restart}), do: :restart
  defp operation_to_action(%Operation{type: :service_enable}), do: :enable
  defp operation_to_action(%Operation{type: :service_disable}), do: :disable
  defp operation_to_action(%Operation{type: :file_create}), do: :create
  defp operation_to_action(%Operation{type: :file_template}), do: :create
  defp operation_to_action(%Operation{type: :file_copy}), do: :create
  defp operation_to_action(%Operation{type: :file_delete}), do: :delete
  defp operation_to_action(%Operation{type: :directory_create}), do: :create
  defp operation_to_action(%Operation{type: :user_create}), do: :create
  defp operation_to_action(%Operation{type: :user_delete}), do: :remove
  defp operation_to_action(%Operation{type: :user_modify}), do: :modify
  defp operation_to_action(%Operation{type: :group_create}), do: :create
  defp operation_to_action(%Operation{type: :group_delete}), do: :remove
  defp operation_to_action(%Operation{type: :command_run}), do: :run
  defp operation_to_action(%Operation{type: :shell_run}), do: :run
  defp operation_to_action(%Operation{type: :cron_create}), do: :create
  defp operation_to_action(%Operation{type: :cron_delete}), do: :delete
  defp operation_to_action(%Operation{type: :mount_create}), do: :mount
  defp operation_to_action(%Operation{type: :git_clone}), do: :sync
  defp operation_to_action(%Operation{type: _}), do: :nothing

  # Operation to Chef attributes

  defp operation_to_attributes(%Operation{type: :package_install, params: params}) do
    %{}
    |> add_if_present("version", params[:version])
    |> add_if_present("options", params[:options])
  end

  defp operation_to_attributes(%Operation{type: :package_remove, params: _params}), do: %{}
  defp operation_to_attributes(%Operation{type: :package_upgrade, params: _params}), do: %{}

  defp operation_to_attributes(%Operation{type: type, params: _params})
       when type in [:service_start, :service_stop, :service_restart, :service_enable, :service_disable] do
    %{}
    |> add_if_present("supports", %{restart: true, reload: true, status: true})
  end

  defp operation_to_attributes(%Operation{type: :file_create, params: params}) do
    %{}
    |> add_if_present("content", params[:content])
    |> add_if_present("owner", params[:owner])
    |> add_if_present("group", params[:group])
    |> add_if_present("mode", params[:mode])
  end

  defp operation_to_attributes(%Operation{type: :file_template, params: params}) do
    source = params[:source] || params[:template]

    %{}
    |> add_if_present("source", source)
    |> add_if_present("variables", params[:variables] || params[:vars])
    |> add_if_present("owner", params[:owner])
    |> add_if_present("group", params[:group])
    |> add_if_present("mode", params[:mode])
  end

  defp operation_to_attributes(%Operation{type: :file_copy, params: params}) do
    %{}
    |> add_if_present("source", params[:source])
    |> add_if_present("owner", params[:owner])
    |> add_if_present("group", params[:group])
    |> add_if_present("mode", params[:mode])
  end

  defp operation_to_attributes(%Operation{type: :directory_create, params: params}) do
    %{}
    |> add_if_present("owner", params[:owner])
    |> add_if_present("group", params[:group])
    |> add_if_present("mode", params[:mode])
    |> add_if_present("recursive", params[:recursive])
  end

  defp operation_to_attributes(%Operation{type: :user_create, params: params}) do
    %{}
    |> add_if_present("uid", params[:uid])
    |> add_if_present("gid", params[:gid])
    |> add_if_present("home", params[:home])
    |> add_if_present("shell", params[:shell])
    |> add_if_present("comment", params[:comment])
    |> add_if_present("manage_home", params[:create_home])
  end

  defp operation_to_attributes(%Operation{type: :group_create, params: params}) do
    %{}
    |> add_if_present("gid", params[:gid])
    |> add_if_present("members", params[:members])
  end

  defp operation_to_attributes(%Operation{type: type, params: params})
       when type in [:command_run, :shell_run] do
    command = Map.get(params, :command) || Map.get(params, :cmd)

    %{}
    |> add_if_present("command", command)
    |> add_if_present("cwd", params[:cwd])
    |> add_if_present("user", params[:user])
    |> add_if_present("environment", params[:environment])
    |> add_if_present("creates", params[:creates])
    |> add_if_present("not_if", params[:unless])
    |> add_if_present("only_if", params[:onlyif])
  end

  defp operation_to_attributes(%Operation{type: :cron_create, params: params}) do
    %{
      "command" => params[:command],
      "user" => Map.get(params, :user, "root"),
      "minute" => Map.get(params, :minute, "*"),
      "hour" => Map.get(params, :hour, "*"),
      "day" => Map.get(params, :day, "*"),
      "month" => Map.get(params, :month, "*"),
      "weekday" => Map.get(params, :weekday, "*")
    }
  end

  defp operation_to_attributes(%Operation{type: :git_clone, params: params}) do
    %{}
    |> add_if_present("repository", params[:repository] || params[:repo])
    |> add_if_present("revision", params[:revision] || params[:version])
    |> add_if_present("user", params[:user])
  end

  defp operation_to_attributes(%Operation{params: params}) do
    # Generic fallback - convert params to attributes
    params
    |> Map.delete(:name)
    |> Map.delete(:path)
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  defp add_if_present(map, _key, nil), do: map
  defp add_if_present(map, key, value), do: Map.put(map, key, value)

  # Build notification chains from graph dependencies

  defp build_notifications(op, graph, op_to_resource) do
    deps = get_dependencies_for_op(op.id, graph)

    notifies =
      deps
      |> Enum.filter(fn dep -> dep.type in [:notifies] end)
      |> Enum.map(fn dep ->
        resource = Map.get(op_to_resource, dep.to)
        {:notifies, :restart, resource, :delayed}
      end)
      |> Enum.reject(fn {_, _, r, _} -> is_nil(r) end)

    subscribes =
      deps
      |> Enum.filter(fn dep -> dep.type in [:watches, :watch] end)
      |> Enum.map(fn dep ->
        resource = Map.get(op_to_resource, dep.from)
        {:subscribes, :restart, resource, :immediately}
      end)
      |> Enum.reject(fn {_, _, r, _} -> is_nil(r) end)

    notifies ++ subscribes
  end

  defp get_dependencies_for_op(op_id, graph) do
    graph.edges
    |> Enum.filter(fn dep -> dep.to == op_id or dep.from == op_id end)
  end

  # Recipe formatting

  defp format_recipe(resources, opts) do
    cookbook_name = Keyword.get(opts, :cookbook_name, "generated")

    resource_blocks =
      resources
      |> Enum.map(&format_resource/1)
      |> Enum.join("\n\n")

    recipe = """
    # Generated by HAR (Hybrid Automation Router)
    # Chef recipe for cookbook: #{cookbook_name}

    #{resource_blocks}
    """

    {:ok, String.trim(recipe) <> "\n"}
  end

  defp format_resource(resource) do
    type = resource.type
    name = resource.name
    action = resource.action
    attrs = resource.attributes
    notifications = resource.notifications

    if map_size(attrs) == 0 and length(notifications) == 0 and action == :nothing do
      # Simple inline resource
      "#{type} '#{name}'"
    else
      # Full resource block
      lines = ["#{type} '#{name}' do"]

      # Add action
      action_line = format_action(action)
      lines = if action_line, do: lines ++ ["  #{action_line}"], else: lines

      # Add attributes
      attr_lines =
        attrs
        |> Enum.sort_by(fn {key, _} -> attr_sort_order(key) end)
        |> Enum.map(fn {key, value} -> "  #{key} #{format_value(value)}" end)

      lines = lines ++ attr_lines

      # Add notifications
      notif_lines = Enum.map(notifications, &format_notification/1)
      lines = lines ++ notif_lines

      lines = lines ++ ["end"]

      Enum.join(lines, "\n")
    end
  end

  defp format_action(actions) when is_list(actions) do
    formatted = Enum.map(actions, fn a -> ":#{a}" end) |> Enum.join(", ")
    "action [#{formatted}]"
  end

  defp format_action(:nothing), do: nil
  defp format_action(action), do: "action :#{action}"

  defp attr_sort_order("not_if"), do: 100
  defp attr_sort_order("only_if"), do: 101
  defp attr_sort_order(_), do: 50

  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(nil), do: "nil"
  defp format_value(value) when is_integer(value), do: to_string(value)
  defp format_value(value) when is_atom(value), do: ":#{value}"

  defp format_value(value) when is_list(value) do
    items = Enum.map(value, &format_value/1) |> Enum.join(", ")
    "[#{items}]"
  end

  defp format_value(value) when is_map(value) do
    items =
      value
      |> Enum.map(fn {k, v} -> "#{format_key(k)} => #{format_value(v)}" end)
      |> Enum.join(", ")

    "{ #{items} }"
  end

  defp format_value(value) when is_binary(value) do
    if String.contains?(value, "'") do
      "\"#{value}\""
    else
      "'#{value}'"
    end
  end

  defp format_value(value), do: "'#{value}'"

  defp format_key(key) when is_atom(key), do: ":#{key}"
  defp format_key(key), do: "'#{key}'"

  defp format_notification({:notifies, action, resource, timing}) do
    "  notifies :#{action}, '#{resource}', :#{timing}"
  end

  defp format_notification({:subscribes, action, resource, timing}) do
    "  subscribes :#{action}, '#{resource}', :#{timing}"
  end
end
