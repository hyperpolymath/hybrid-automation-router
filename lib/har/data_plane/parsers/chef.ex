# SPDX-License-Identifier: MPL-2.0
defmodule HAR.DataPlane.Parsers.Chef do
  @moduledoc """
  Parser for Chef recipes and cookbooks (Ruby DSL).

  Converts Chef resource declarations to HAR semantic graph operations.

  ## Supported Constructs

  - Resource declarations: `package 'nginx' do ... end`
  - Resource actions: `action :install`
  - Guard clauses: `not_if`, `only_if`
  - Notifications: `notifies`, `subscribes`
  - Template resources with variables
  - Attributes and node references

  For full Chef parsing, prefer chef-client's JSON output.
  """

  @behaviour HAR.DataPlane.Parser

  alias HAR.Semantic.{Graph, Operation, Dependency}
  require Logger

  @impl true
  def parse(content, opts \\ []) when is_binary(content) do
    with {:ok, resources} <- extract_resources(content),
         {:ok, operations} <- build_operations(resources, opts),
         {:ok, dependencies} <- build_dependencies(operations, content) do
      graph =
        Graph.new(
          vertices: operations,
          edges: dependencies,
          metadata: %{source: :chef, parsed_at: DateTime.utc_now()}
        )

      {:ok, graph}
    end
  end

  @impl true
  def validate(content) when is_binary(content) do
    # Basic validation: check for balanced do/end blocks
    dos = Regex.scan(~r/\bdo\b/, content) |> length()
    ends = Regex.scan(~r/\bend\b/, content) |> length()

    if abs(dos - ends) <= 1 do
      :ok
    else
      {:error, {:chef_parse_error, "Unbalanced do/end blocks"}}
    end
  end

  # Resource extraction

  defp extract_resources(content) do
    # Match Chef resource declarations: resource_type 'name' do ... end
    # Also matches inline: resource_type 'name'
    resources = extract_block_resources(content) ++ extract_inline_resources(content)
    {:ok, resources}
  end

  defp extract_block_resources(content) do
    # Match: type 'name' do ... end or type "name" do ... end
    resource_regex = ~r/([a-z_]+)\s+['"]([^'"]+)['"]\s+do\b/s

    Regex.scan(resource_regex, content, return: :index)
    |> Enum.map(fn [{start, _len} | captures] ->
      [{type_start, type_len}, {name_start, name_len}] = captures
      type = String.slice(content, type_start, type_len)
      name = String.slice(content, name_start, name_len)

      # Find the 'do' position and extract body
      do_match = Regex.run(~r/do\b/, String.slice(content, start..-1//1), return: :index)

      body =
        case do_match do
          [{do_offset, _}] ->
            body_start = start + do_offset + 2
            extract_do_block(content, body_start)

          nil ->
            ""
        end

      %{
        type: type,
        name: name,
        attributes: parse_attributes(body),
        action: extract_action(body),
        guards: extract_guards(body),
        notifications: extract_notifications(body)
      }
    end)
  end

  defp extract_inline_resources(content) do
    # Match inline resources: package 'nginx' (without do block)
    # Be careful not to match resources that have do blocks
    lines = String.split(content, "\n")

    lines
    |> Enum.filter(fn line ->
      # Match resource pattern but not followed by 'do'
      String.match?(line, ~r/^\s*[a-z_]+\s+['"][^'"]+['"]\s*$/)
    end)
    |> Enum.map(fn line ->
      case Regex.run(~r/([a-z_]+)\s+['"]([^'"]+)['"]/, line) do
        [_, type, name] ->
          %{
            type: type,
            name: name,
            attributes: %{},
            action: [:nothing],
            guards: %{},
            notifications: []
          }

        nil ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_do_block(content, start_pos) do
    # Extract content between do and matching end
    remaining = String.slice(content, start_pos..-1//1)
    find_matching_end(remaining, 1, [])
  end

  defp find_matching_end(<<>>, _depth, acc), do: Enum.join(Enum.reverse(acc))

  defp find_matching_end(content, depth, acc) do
    cond do
      String.starts_with?(content, "do\n") or String.starts_with?(content, "do ") ->
        find_matching_end(String.slice(content, 2..-1//1), depth + 1, ["do" | acc])

      String.starts_with?(content, "\nend") or String.starts_with?(content, " end") ->
        if depth == 1 do
          Enum.join(Enum.reverse(acc))
        else
          find_matching_end(String.slice(content, 4..-1//1), depth - 1, ["end\n" | acc])
        end

      true ->
        <<char::utf8, rest::binary>> = content
        find_matching_end(rest, depth, [<<char::utf8>> | acc])
    end
  end

  defp parse_attributes(body) do
    # Parse Chef attribute syntax: attribute value or attribute 'value'
    attr_regex = ~r/^\s*([a-z_]+)\s+(.+)$/m

    Regex.scan(attr_regex, body)
    |> Enum.reject(fn [_, key, _] ->
      # Skip keywords
      key in ~w(action not_if only_if notifies subscribes retries retry_delay)
    end)
    |> Enum.map(fn [_, key, value] ->
      {key, parse_value(String.trim(value))}
    end)
    |> Map.new()
  end

  defp parse_value(value) do
    cond do
      # Boolean
      value in ~w(true false) ->
        value == "true"

      # Symbol
      String.starts_with?(value, ":") ->
        String.slice(value, 1..-1//1) |> String.to_atom()

      # Quoted string
      String.match?(value, ~r/^['"].*['"]$/) ->
        String.slice(value, 1..-2//1)

      # Array
      String.starts_with?(value, "[") ->
        parse_array(value)

      # Hash
      String.starts_with?(value, "{") ->
        parse_hash(value)

      # Number
      String.match?(value, ~r/^\d+$/) ->
        String.to_integer(value)

      # Node/attribute reference
      String.starts_with?(value, "node[") ->
        "${#{value}}"

      # Variable reference
      String.match?(value, ~r/^[a-z_]+$/) ->
        "${#{value}}"

      true ->
        value
    end
  end

  defp parse_array(value) do
    inner = String.slice(value, 1..-2//1)

    ~r/'([^']*)'|"([^"]*)"|:([a-z_]+)/
    |> Regex.scan(inner)
    |> Enum.map(fn
      [_, str, "", ""] -> str
      [_, "", str, ""] -> str
      [_, "", "", sym] -> String.to_atom(sym)
    end)
  end

  defp parse_hash(value) do
    inner = String.slice(value, 1..-2//1)

    ~r/['"]([^'"]+)['"]\s*=>\s*['"]([^'"]+)['"]/
    |> Regex.scan(inner)
    |> Enum.map(fn [_, key, val] -> {key, val} end)
    |> Map.new()
  end

  defp extract_action(body) do
    case Regex.run(~r/action\s+(\[.+?\]|:\w+)/, body) do
      [_, action_str] ->
        if String.starts_with?(action_str, "[") do
          # Array of actions
          ~r/:(\w+)/
          |> Regex.scan(action_str)
          |> Enum.map(fn [_, action] -> String.to_atom(action) end)
        else
          # Single action
          [String.to_atom(String.slice(action_str, 1..-1//1))]
        end

      nil ->
        # Default action depends on resource type
        [:nothing]
    end
  end

  defp extract_guards(body) do
    not_if_guards =
      Regex.scan(~r/not_if\s+(.+)/, body)
      |> Enum.map(fn [_, guard] -> {:not_if, String.trim(guard)} end)

    only_if_guards =
      Regex.scan(~r/only_if\s+(.+)/, body)
      |> Enum.map(fn [_, guard] -> {:only_if, String.trim(guard)} end)

    %{
      not_if: Enum.map(not_if_guards, fn {:not_if, g} -> g end),
      only_if: Enum.map(only_if_guards, fn {:only_if, g} -> g end)
    }
  end

  defp extract_notifications(body) do
    # notifies :action, 'resource[name]', :timing
    notifies =
      Regex.scan(~r/notifies\s+:(\w+),\s*['"]([^'"]+)['"]\s*(?:,\s*:(\w+))?/, body)
      |> Enum.map(fn
        [_, action, resource, ""] -> {:notifies, action, resource, :delayed}
        [_, action, resource, timing] -> {:notifies, action, resource, String.to_atom(timing)}
      end)

    # subscribes :action, 'resource[name]', :timing
    subscribes =
      Regex.scan(~r/subscribes\s+:(\w+),\s*['"]([^'"]+)['"]\s*(?:,\s*:(\w+))?/, body)
      |> Enum.map(fn
        [_, action, resource, ""] -> {:subscribes, action, resource, :delayed}
        [_, action, resource, timing] -> {:subscribes, action, resource, String.to_atom(timing)}
      end)

    notifies ++ subscribes
  end

  # Operation building

  defp build_operations(resources, _opts) do
    operations =
      resources
      |> Enum.with_index()
      |> Enum.map(fn {resource, index} ->
        resource_to_operation(resource, index)
      end)

    {:ok, operations}
  end

  defp resource_to_operation(resource, index) do
    type = resource.type
    name = resource.name
    attrs = resource.attributes
    action = List.first(resource.action) || :nothing

    Operation.new(
      normalize_resource_type(type, action),
      normalize_params(type, attrs, name, action),
      id: generate_id(type, name, index),
      target: %{
        resource_type: type,
        resource_name: name
      },
      metadata: %{
        source: :chef,
        chef_type: type,
        chef_name: name,
        action: resource.action,
        guards: resource.guards,
        notifications: resource.notifications,
        original_attributes: attrs
      }
    )
  end

  # Resource type normalization

  defp normalize_resource_type("package", action) do
    case action do
      :install -> :package_install
      :remove -> :package_remove
      :purge -> :package_remove
      :upgrade -> :package_upgrade
      _ -> :package_install
    end
  end

  defp normalize_resource_type("apt_package", action), do: normalize_resource_type("package", action)
  defp normalize_resource_type("yum_package", action), do: normalize_resource_type("package", action)
  defp normalize_resource_type("dnf_package", action), do: normalize_resource_type("package", action)

  defp normalize_resource_type("service", action) do
    case action do
      :start -> :service_start
      :stop -> :service_stop
      :restart -> :service_restart
      :reload -> :service_restart
      :enable -> :service_enable
      :disable -> :service_disable
      _ -> :service_start
    end
  end

  defp normalize_resource_type("file", action) do
    case action do
      :create -> :file_create
      :create_if_missing -> :file_create
      :delete -> :file_delete
      :touch -> :file_create
      _ -> :file_create
    end
  end

  defp normalize_resource_type("template", _action), do: :file_template
  defp normalize_resource_type("cookbook_file", _action), do: :file_copy
  defp normalize_resource_type("remote_file", _action), do: :file_copy

  defp normalize_resource_type("directory", action) do
    case action do
      :create -> :directory_create
      :delete -> :file_delete
      _ -> :directory_create
    end
  end

  defp normalize_resource_type("user", action) do
    case action do
      :create -> :user_create
      :remove -> :user_delete
      :modify -> :user_modify
      :manage -> :user_create
      :lock -> :user_modify
      :unlock -> :user_modify
      _ -> :user_create
    end
  end

  defp normalize_resource_type("group", action) do
    case action do
      :create -> :group_create
      :remove -> :group_delete
      :modify -> :group_create
      _ -> :group_create
    end
  end

  defp normalize_resource_type("execute", _action), do: :command_run
  defp normalize_resource_type("bash", _action), do: :shell_run
  defp normalize_resource_type("script", _action), do: :shell_run
  defp normalize_resource_type("powershell_script", _action), do: :shell_run

  defp normalize_resource_type("cron", action) do
    case action do
      :create -> :cron_create
      :delete -> :cron_delete
      _ -> :cron_create
    end
  end

  defp normalize_resource_type("mount", action) do
    case action do
      :mount -> :mount_create
      :umount -> :mount_delete
      :enable -> :mount_create
      :disable -> :mount_delete
      _ -> :mount_create
    end
  end

  defp normalize_resource_type("git", _action), do: :git_clone
  defp normalize_resource_type("docker_container", _action), do: :docker_container_run
  defp normalize_resource_type("docker_image", _action), do: :docker_image_pull

  defp normalize_resource_type(type, _action), do: String.to_atom("chef.#{type}")

  # Parameter normalization

  defp normalize_params("package", attrs, name, _action) do
    %{
      name: name,
      version: Map.get(attrs, "version"),
      options: Map.get(attrs, "options")
    }
  end

  defp normalize_params(pkg_type, attrs, name, action)
       when pkg_type in ~w(apt_package yum_package dnf_package) do
    normalize_params("package", attrs, name, action)
  end

  defp normalize_params("service", attrs, name, _action) do
    %{
      name: name,
      pattern: Map.get(attrs, "pattern"),
      supports: Map.get(attrs, "supports", %{})
    }
  end

  defp normalize_params("file", attrs, name, _action) do
    %{
      path: name,
      content: Map.get(attrs, "content"),
      owner: Map.get(attrs, "owner"),
      group: Map.get(attrs, "group"),
      mode: Map.get(attrs, "mode")
    }
  end

  defp normalize_params("template", attrs, name, _action) do
    %{
      path: name,
      source: Map.get(attrs, "source"),
      variables: Map.get(attrs, "variables", %{}),
      owner: Map.get(attrs, "owner"),
      group: Map.get(attrs, "group"),
      mode: Map.get(attrs, "mode")
    }
  end

  defp normalize_params("directory", attrs, name, _action) do
    %{
      path: name,
      owner: Map.get(attrs, "owner"),
      group: Map.get(attrs, "group"),
      mode: Map.get(attrs, "mode"),
      recursive: Map.get(attrs, "recursive", false)
    }
  end

  defp normalize_params("user", attrs, name, _action) do
    %{
      name: name,
      uid: Map.get(attrs, "uid"),
      gid: Map.get(attrs, "gid"),
      home: Map.get(attrs, "home"),
      shell: Map.get(attrs, "shell"),
      comment: Map.get(attrs, "comment")
    }
  end

  defp normalize_params("group", attrs, name, _action) do
    %{
      name: name,
      gid: Map.get(attrs, "gid"),
      members: Map.get(attrs, "members", [])
    }
  end

  defp normalize_params(exec_type, attrs, name, _action)
       when exec_type in ~w(execute bash script powershell_script) do
    %{
      command: Map.get(attrs, "command", name),
      cwd: Map.get(attrs, "cwd"),
      user: Map.get(attrs, "user"),
      environment: Map.get(attrs, "environment", %{}),
      creates: Map.get(attrs, "creates")
    }
  end

  defp normalize_params("cron", attrs, name, _action) do
    %{
      name: name,
      command: Map.get(attrs, "command"),
      user: Map.get(attrs, "user", "root"),
      minute: Map.get(attrs, "minute", "*"),
      hour: Map.get(attrs, "hour", "*"),
      day: Map.get(attrs, "day", "*"),
      month: Map.get(attrs, "month", "*"),
      weekday: Map.get(attrs, "weekday", "*")
    }
  end

  defp normalize_params("git", attrs, name, _action) do
    %{
      destination: name,
      repository: Map.get(attrs, "repository"),
      revision: Map.get(attrs, "revision", "HEAD"),
      user: Map.get(attrs, "user")
    }
  end

  defp normalize_params(_type, attrs, name, _action) do
    Map.put(attrs, :name, name)
  end

  # Dependency building

  defp build_dependencies(operations, _content) do
    # Build lookup: resource[name] -> operation_id
    op_lookup =
      operations
      |> Enum.map(fn op ->
        key = "#{op.metadata.chef_type}[#{op.metadata.chef_name}]"
        {String.downcase(key), op.id}
      end)
      |> Map.new()

    # Extract notification-based dependencies
    notification_deps = extract_notification_dependencies(operations, op_lookup)

    # Add sequential ordering for resources without explicit deps
    sequential_deps = build_sequential_dependencies(operations)

    all_deps =
      (notification_deps ++ sequential_deps)
      |> Enum.uniq_by(fn dep -> {dep.from, dep.to, dep.type} end)

    {:ok, all_deps}
  end

  defp extract_notification_dependencies(operations, op_lookup) do
    operations
    |> Enum.flat_map(fn op ->
      notifications = Map.get(op.metadata, :notifications, [])

      Enum.flat_map(notifications, fn notification ->
        case notification do
          {:notifies, _action, resource_ref, _timing} ->
            key = String.downcase(resource_ref)

            case Map.get(op_lookup, key) do
              nil -> []
              target_id -> [Dependency.new(op.id, target_id, :notifies, metadata: %{reason: "chef_notifies"})]
            end

          {:subscribes, _action, resource_ref, _timing} ->
            key = String.downcase(resource_ref)

            case Map.get(op_lookup, key) do
              nil -> []
              source_id -> [Dependency.new(source_id, op.id, :watches, metadata: %{reason: "chef_subscribes"})]
            end
        end
      end)
    end)
  end

  defp build_sequential_dependencies(operations) do
    operations
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [prev, curr] ->
      Dependency.new(prev.id, curr.id, :sequential, metadata: %{reason: "chef_order"})
    end)
  end

  defp generate_id(type, name, index) do
    safe_name =
      name
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.slice(0, 30)

    "chef_#{type}_#{safe_name}_#{index}_#{:erlang.unique_integer([:positive])}"
  end
end
