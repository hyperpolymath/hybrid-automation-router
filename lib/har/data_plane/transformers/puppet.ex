# SPDX-License-Identifier: MPL-2.0
defmodule HAR.DataPlane.Transformers.Puppet do
  @moduledoc """
  Transformer for Puppet manifest format.

  Converts HAR semantic graph to Puppet DSL (.pp files).

  ## Features

  - Resource declarations with proper ensure states
  - Relationship metaparameters (require, before, notify, subscribe)
  - Chaining arrows for ordering (-> and ~>)
  - Class wrapper generation
  - Parameter handling for common resource types
  """

  @behaviour HAR.DataPlane.Transformer

  alias HAR.Semantic.{Graph, Operation}
  require Logger

  @impl true
  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, sorted_ops} <- Graph.topological_sort(graph),
         {:ok, resources} <- operations_to_resources(sorted_ops, graph, opts),
         {:ok, manifest} <- format_manifest(resources, opts) do
      {:ok, manifest}
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
    # Build operation ID to resource mapping for relationships
    op_to_resource =
      operations
      |> Enum.map(fn op ->
        {type, title} = operation_to_puppet_ref(op)
        {op.id, "#{capitalize_type(type)}['#{title}']"}
      end)
      |> Map.new()

    resources =
      Enum.map(operations, fn op ->
        operation_to_resource(op, graph, op_to_resource, opts)
      end)

    {:ok, resources}
  end

  defp operation_to_resource(op, graph, op_to_resource, _opts) do
    {puppet_type, puppet_title} = operation_to_puppet_ref(op)
    attributes = operation_to_attributes(op)
    relationships = build_relationships(op, graph, op_to_resource)

    %{
      type: puppet_type,
      title: puppet_title,
      attributes: Map.merge(attributes, relationships)
    }
  end

  defp operation_to_puppet_ref(%Operation{type: type, params: params}) do
    title = Map.get(params, :name) || Map.get(params, :path) || "unnamed"
    puppet_type = semantic_to_puppet_type(type)
    {puppet_type, title}
  end

  # Semantic operation type to Puppet resource type mapping

  defp semantic_to_puppet_type(:package_install), do: "package"
  defp semantic_to_puppet_type(:package_remove), do: "package"
  defp semantic_to_puppet_type(:package_upgrade), do: "package"
  defp semantic_to_puppet_type(:service_start), do: "service"
  defp semantic_to_puppet_type(:service_stop), do: "service"
  defp semantic_to_puppet_type(:service_restart), do: "service"
  defp semantic_to_puppet_type(:service_enable), do: "service"
  defp semantic_to_puppet_type(:service_disable), do: "service"
  defp semantic_to_puppet_type(:file_create), do: "file"
  defp semantic_to_puppet_type(:file_template), do: "file"
  defp semantic_to_puppet_type(:file_copy), do: "file"
  defp semantic_to_puppet_type(:file_delete), do: "file"
  defp semantic_to_puppet_type(:file_permissions), do: "file"
  defp semantic_to_puppet_type(:directory_create), do: "file"
  defp semantic_to_puppet_type(:user_create), do: "user"
  defp semantic_to_puppet_type(:user_delete), do: "user"
  defp semantic_to_puppet_type(:user_modify), do: "user"
  defp semantic_to_puppet_type(:group_create), do: "group"
  defp semantic_to_puppet_type(:group_delete), do: "group"
  defp semantic_to_puppet_type(:command_run), do: "exec"
  defp semantic_to_puppet_type(:shell_run), do: "exec"
  defp semantic_to_puppet_type(:cron_create), do: "cron"
  defp semantic_to_puppet_type(:cron_delete), do: "cron"
  defp semantic_to_puppet_type(:mount_create), do: "mount"
  defp semantic_to_puppet_type(:firewall_rule), do: "firewall"
  defp semantic_to_puppet_type(:repository_create), do: "yumrepo"
  defp semantic_to_puppet_type(type), do: to_string(type)

  # Operation to Puppet attributes

  defp operation_to_attributes(%Operation{type: :package_install, params: params}) do
    base = %{"ensure" => Map.get(params, :version, "present")}
    add_if_present(base, "provider", params[:provider])
  end

  defp operation_to_attributes(%Operation{type: :package_remove, params: _params}) do
    %{"ensure" => "absent"}
  end

  defp operation_to_attributes(%Operation{type: :package_upgrade, params: _params}) do
    %{"ensure" => "latest"}
  end

  defp operation_to_attributes(%Operation{type: type, params: params})
       when type in [:service_start, :service_restart] do
    %{
      "ensure" => "running",
      "enable" => Map.get(params, :enabled, true)
    }
  end

  defp operation_to_attributes(%Operation{type: :service_stop, params: _params}) do
    %{"ensure" => "stopped"}
  end

  defp operation_to_attributes(%Operation{type: :service_enable, params: _params}) do
    %{"enable" => true}
  end

  defp operation_to_attributes(%Operation{type: :service_disable, params: _params}) do
    %{"enable" => false}
  end

  defp operation_to_attributes(%Operation{type: :file_create, params: params}) do
    base = %{"ensure" => "file"}
    base
    |> add_if_present("content", params[:content])
    |> add_if_present("source", params[:source])
    |> add_if_present("owner", params[:owner])
    |> add_if_present("group", params[:group])
    |> add_if_present("mode", params[:mode])
  end

  defp operation_to_attributes(%Operation{type: :file_template, params: params}) do
    base = %{"ensure" => "file"}
    base
    |> add_if_present("content", params[:content])
    |> add_if_present("owner", params[:owner])
    |> add_if_present("group", params[:group])
    |> add_if_present("mode", params[:mode])
  end

  defp operation_to_attributes(%Operation{type: :directory_create, params: params}) do
    base = %{"ensure" => "directory"}
    base
    |> add_if_present("owner", params[:owner])
    |> add_if_present("group", params[:group])
    |> add_if_present("mode", params[:mode])
    |> add_if_present("recurse", params[:recurse])
  end

  defp operation_to_attributes(%Operation{type: :file_delete, params: _params}) do
    %{"ensure" => "absent"}
  end

  defp operation_to_attributes(%Operation{type: :file_permissions, params: params}) do
    %{}
    |> add_if_present("owner", params[:owner])
    |> add_if_present("group", params[:group])
    |> add_if_present("mode", params[:mode])
  end

  defp operation_to_attributes(%Operation{type: :user_create, params: params}) do
    base = %{"ensure" => "present"}
    base
    |> add_if_present("uid", params[:uid])
    |> add_if_present("gid", params[:gid])
    |> add_if_present("home", params[:home])
    |> add_if_present("shell", params[:shell])
    |> add_if_present("groups", params[:groups])
    |> add_if_present("managehome", params[:create_home])
  end

  defp operation_to_attributes(%Operation{type: :user_delete, params: _params}) do
    %{"ensure" => "absent"}
  end

  defp operation_to_attributes(%Operation{type: :group_create, params: params}) do
    base = %{"ensure" => "present"}
    add_if_present(base, "gid", params[:gid])
  end

  defp operation_to_attributes(%Operation{type: :group_delete, params: _params}) do
    %{"ensure" => "absent"}
  end

  defp operation_to_attributes(%Operation{type: type, params: params})
       when type in [:command_run, :shell_run] do
    command = Map.get(params, :command) || Map.get(params, :cmd)

    base = %{}
    base
    |> add_if_present("command", command)
    |> add_if_present("creates", params[:creates])
    |> add_if_present("unless", params[:unless])
    |> add_if_present("onlyif", params[:onlyif])
    |> add_if_present("cwd", params[:cwd])
    |> add_if_present("user", params[:user])
    |> add_if_present("path", params[:path] || ["/usr/bin", "/usr/sbin", "/bin", "/sbin"])
    |> add_if_present("refreshonly", params[:refreshonly])
  end

  defp operation_to_attributes(%Operation{type: :cron_create, params: params}) do
    %{
      "ensure" => "present",
      "command" => params[:command],
      "user" => Map.get(params, :user, "root"),
      "minute" => Map.get(params, :minute, "*"),
      "hour" => Map.get(params, :hour, "*"),
      "monthday" => Map.get(params, :day, "*"),
      "month" => Map.get(params, :month, "*"),
      "weekday" => Map.get(params, :weekday, "*")
    }
  end

  defp operation_to_attributes(%Operation{type: :cron_delete, params: _params}) do
    %{"ensure" => "absent"}
  end

  defp operation_to_attributes(%Operation{params: params}) do
    # Generic fallback
    params
    |> Map.delete(:name)
    |> Map.delete(:path)
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  defp add_if_present(map, _key, nil), do: map
  defp add_if_present(map, key, value), do: Map.put(map, key, value)

  # Build relationship metaparameters from graph dependencies

  defp build_relationships(op, graph, op_to_resource) do
    deps = get_dependencies_for_op(op.id, graph)

    requires =
      deps
      |> Enum.filter(fn dep -> dep.type in [:requires, :depends_on, :sequential] end)
      |> Enum.map(fn dep -> Map.get(op_to_resource, dep.from) end)
      |> Enum.reject(&is_nil/1)

    notifies =
      deps
      |> Enum.filter(fn dep -> dep.type in [:notifies] end)
      |> Enum.map(fn dep -> Map.get(op_to_resource, dep.to) end)
      |> Enum.reject(&is_nil/1)

    subscribes =
      deps
      |> Enum.filter(fn dep -> dep.type in [:watches, :watch] end)
      |> Enum.map(fn dep -> Map.get(op_to_resource, dep.from) end)
      |> Enum.reject(&is_nil/1)

    %{}
    |> add_relationship("require", requires)
    |> add_relationship("notify", notifies)
    |> add_relationship("subscribe", subscribes)
  end

  defp get_dependencies_for_op(op_id, graph) do
    graph.edges
    |> Enum.filter(fn dep -> dep.to == op_id end)
  end

  defp add_relationship(map, _key, []), do: map
  defp add_relationship(map, key, [single]), do: Map.put(map, key, single)
  defp add_relationship(map, key, refs), do: Map.put(map, key, refs)

  # Manifest formatting

  defp format_manifest(resources, opts) do
    class_name = Keyword.get(opts, :class_name)
    indent = "  "

    resource_blocks =
      resources
      |> Enum.map(fn resource -> format_resource(resource, indent) end)
      |> Enum.join("\n\n")

    manifest =
      if class_name do
        """
        # Generated by HAR (Hybrid Automation Router)
        # Puppet manifest

        class #{class_name} {
        #{resource_blocks}
        }
        """
      else
        """
        # Generated by HAR (Hybrid Automation Router)
        # Puppet manifest

        #{resource_blocks}
        """
      end

    {:ok, String.trim(manifest) <> "\n"}
  end

  defp format_resource(resource, base_indent) do
    type = resource.type
    title = resource.title
    attrs = resource.attributes

    attr_lines =
      attrs
      |> Enum.sort_by(fn {key, _} -> attr_sort_order(key) end)
      |> Enum.map(fn {key, value} ->
        "#{base_indent}  #{key} => #{format_value(value)},"
      end)
      |> Enum.join("\n")

    "#{base_indent}#{type} { '#{title}':\n#{attr_lines}\n#{base_indent}}"
  end

  defp attr_sort_order("ensure"), do: 0
  defp attr_sort_order("enable"), do: 1
  defp attr_sort_order("require"), do: 100
  defp attr_sort_order("before"), do: 101
  defp attr_sort_order("notify"), do: 102
  defp attr_sort_order("subscribe"), do: 103
  defp attr_sort_order(_), do: 50

  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(nil), do: "undef"
  defp format_value(value) when is_integer(value), do: to_string(value)
  defp format_value(value) when is_float(value), do: to_string(value)

  defp format_value(value) when is_list(value) do
    items = Enum.map(value, &format_value/1) |> Enum.join(", ")
    "[#{items}]"
  end

  defp format_value(value) when is_map(value) do
    items =
      value
      |> Enum.map(fn {k, v} -> "'#{k}' => #{format_value(v)}" end)
      |> Enum.join(", ")

    "{ #{items} }"
  end

  defp format_value(value) when is_binary(value) do
    # Check if it's already a resource reference
    if String.match?(value, ~r/^[A-Z][a-z]+\[/) do
      value
    else
      "'#{escape_string(value)}'"
    end
  end

  defp format_value(value), do: "'#{value}'"

  defp escape_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  defp capitalize_type(type) do
    type
    |> String.split("::")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join("::")
  end
end
