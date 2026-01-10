# SPDX-License-Identifier: MPL-2.0
defmodule HAR.DataPlane.Parsers.Puppet do
  @moduledoc """
  Parser for Puppet manifests (.pp files).

  Converts Puppet DSL declarations to HAR semantic graph operations.

  ## Supported Constructs

  - Resource declarations: `package { 'nginx': ensure => present }`
  - Class declarations: `class webserver { ... }`
  - Defined types: `define mytype(...) { ... }`
  - Resource relationships: `->`, `~>`, `require`, `before`, `notify`, `subscribe`
  - Variable references: `$variable`, `$::fact`
  - Resource collectors: `Package <| |>`
  - Virtual resources: `@package { ... }`
  - Exported resources: `@@package { ... }`

  For full Puppet DSL parsing, prefer puppet parser dump --format json output.
  """

  @behaviour HAR.DataPlane.Parser

  alias HAR.Semantic.{Graph, Operation, Dependency}
  require Logger

  @impl true
  def parse(content, opts \\ []) when is_binary(content) do
    with {:ok, resources} <- extract_resources(content),
         {:ok, classes} <- extract_classes(content),
         {:ok, operations} <- build_operations(resources ++ classes, opts),
         {:ok, dependencies} <- build_dependencies(operations, content) do
      graph =
        Graph.new(
          vertices: operations,
          edges: dependencies,
          metadata: %{source: :puppet, parsed_at: DateTime.utc_now()}
        )

      {:ok, graph}
    end
  end

  @impl true
  def validate(content) when is_binary(content) do
    # Basic validation: check for balanced braces and valid resource syntax
    open_braces = String.graphemes(content) |> Enum.count(&(&1 == "{"))
    close_braces = String.graphemes(content) |> Enum.count(&(&1 == "}"))

    cond do
      open_braces != close_braces ->
        {:error, {:puppet_parse_error, "Unbalanced braces: #{open_braces} open, #{close_braces} close"}}

      not has_valid_syntax?(content) ->
        {:error, {:puppet_parse_error, "Invalid Puppet syntax"}}

      true ->
        :ok
    end
  end

  defp has_valid_syntax?(content) do
    # Check for common Puppet patterns
    String.contains?(content, "{") and String.contains?(content, "}")
  end

  # Resource extraction

  defp extract_resources(content) do
    # Match standard resource declarations: type { 'title': attr => value, ... }
    resources = extract_standard_resources(content)
    virtual_resources = extract_virtual_resources(content)
    exported_resources = extract_exported_resources(content)

    {:ok, resources ++ virtual_resources ++ exported_resources}
  end

  defp extract_standard_resources(content) do
    # Match: type { 'title': ... } or type { title: ... }
    resource_regex = ~r/([a-z][a-z0-9_]*)\s*\{\s*(?:'([^']+)'|"([^"]+)"|(\$?[a-z][a-z0-9_]*))\s*:\s*([^}]+)\}/is

    Regex.scan(resource_regex, content)
    |> Enum.map(fn match ->
      [_full, type | rest] = match
      title = find_title(rest)
      body = List.last(rest)

      %{
        type: String.downcase(type),
        title: title,
        attributes: parse_attributes(body),
        virtual: false,
        exported: false
      }
    end)
  end

  defp extract_virtual_resources(content) do
    # Match: @type { 'title': ... }
    virtual_regex = ~r/@([a-z][a-z0-9_]*)\s*\{\s*(?:'([^']+)'|"([^"]+)"|(\$?[a-z][a-z0-9_]*))\s*:\s*([^}]+)\}/is

    Regex.scan(virtual_regex, content)
    |> Enum.map(fn match ->
      [_full, type | rest] = match
      title = find_title(rest)
      body = List.last(rest)

      %{
        type: String.downcase(type),
        title: title,
        attributes: parse_attributes(body),
        virtual: true,
        exported: false
      }
    end)
  end

  defp extract_exported_resources(content) do
    # Match: @@type { 'title': ... }
    exported_regex = ~r/@@([a-z][a-z0-9_]*)\s*\{\s*(?:'([^']+)'|"([^"]+)"|(\$?[a-z][a-z0-9_]*))\s*:\s*([^}]+)\}/is

    Regex.scan(exported_regex, content)
    |> Enum.map(fn match ->
      [_full, type | rest] = match
      title = find_title(rest)
      body = List.last(rest)

      %{
        type: String.downcase(type),
        title: title,
        attributes: parse_attributes(body),
        virtual: false,
        exported: true
      }
    end)
  end

  defp find_title(captures) do
    captures
    |> Enum.take(3)
    |> Enum.find(&(&1 != "" and &1 != nil))
    |> case do
      nil -> "unnamed"
      title -> title
    end
  end

  defp parse_attributes(body) do
    # Parse Puppet attribute syntax: attr => value,
    attr_regex = ~r/([a-z][a-z0-9_]*)\s*=>\s*(.+?)(?=,\s*[a-z]|$)/is

    Regex.scan(attr_regex, body)
    |> Enum.map(fn [_full, key, value] ->
      {String.trim(key), parse_value(String.trim(value))}
    end)
    |> Map.new()
  end

  defp parse_value(value) do
    cond do
      # Boolean
      value in ~w(true false) ->
        value == "true"

      # Quoted string
      String.match?(value, ~r/^['"].*['"]$/) ->
        String.slice(value, 1..-2//1)

      # Array
      String.starts_with?(value, "[") ->
        parse_array(value)

      # Variable reference
      String.starts_with?(value, "$") ->
        "${#{String.slice(value, 1..-1//1)}}"

      # Resource reference: Type['title']
      String.match?(value, ~r/^[A-Z][a-z]+\[/) ->
        value

      # Number
      String.match?(value, ~r/^\d+$/) ->
        String.to_integer(value)

      # Hash/dict
      String.starts_with?(value, "{") ->
        parse_hash(value)

      # Undef
      value == "undef" ->
        nil

      true ->
        value
    end
  end

  defp parse_array(value) do
    # Parse: ['a', 'b', 'c']
    inner = String.slice(value, 1..-2//1)

    ~r/'([^']*)'|"([^"]*)"|(\$[a-z_]+)/
    |> Regex.scan(inner)
    |> Enum.map(fn
      [_, str, "", ""] -> str
      [_, "", str, ""] -> str
      [_, "", "", var] -> "${#{String.slice(var, 1..-1//1)}}"
    end)
  end

  defp parse_hash(value) do
    # Parse: { 'key' => 'value' }
    inner = String.slice(value, 1..-2//1)

    ~r/['"]([^'"]+)['"]\s*=>\s*['"]([^'"]+)['"]/
    |> Regex.scan(inner)
    |> Enum.map(fn [_, key, val] -> {key, val} end)
    |> Map.new()
  end

  # Class extraction

  defp extract_classes(content) do
    # Match class declarations: class name { ... } or class name(...) { ... }
    class_regex = ~r/class\s+([a-z][a-z0-9_:]*)\s*(?:\(([^)]*)\))?\s*\{/is

    classes =
      Regex.scan(class_regex, content, return: :index)
      |> Enum.map(fn [{start, len} | captures] ->
        [{name_start, name_len} | params_capture] = captures
        name = String.slice(content, name_start, name_len)

        params =
          case params_capture do
            [{params_start, params_len}] when params_len > 0 ->
              String.slice(content, params_start, params_len) |> parse_class_params()

            _ ->
              %{}
          end

        body = extract_block_body(content, start + len)

        %{
          type: "class",
          title: name,
          attributes: %{parameters: params},
          body: body,
          virtual: false,
          exported: false
        }
      end)

    {:ok, classes}
  end

  defp parse_class_params(params_str) do
    # Parse: $param = default, $param2
    ~r/\$([a-z_]+)(?:\s*=\s*(?:'([^']*)'|"([^"]*)"|(\S+)))?/i
    |> Regex.scan(params_str)
    |> Enum.map(fn
      [_, name, default, "", ""] -> {name, default}
      [_, name, "", default, ""] -> {name, default}
      [_, name, "", "", default] -> {name, default}
      [_, name | _] -> {name, nil}
    end)
    |> Map.new()
  end

  defp extract_block_body(content, start_pos) do
    chars = String.graphemes(String.slice(content, start_pos..-1//1))
    extract_balanced_block(chars, 0, [])
  end

  defp extract_balanced_block([], _depth, acc), do: Enum.join(Enum.reverse(acc))
  defp extract_balanced_block(["{" | rest], depth, acc), do: extract_balanced_block(rest, depth + 1, ["{" | acc])
  defp extract_balanced_block(["}" | _rest], 1, acc), do: Enum.join(Enum.reverse(acc))
  defp extract_balanced_block(["}" | rest], depth, acc) when depth > 1, do: extract_balanced_block(rest, depth - 1, ["}" | acc])
  defp extract_balanced_block([char | rest], depth, acc), do: extract_balanced_block(rest, depth, [char | acc])

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
    type = Map.get(resource, :type)
    title = Map.get(resource, :title)
    attrs = Map.get(resource, :attributes, %{})

    Operation.new(
      normalize_resource_type(type),
      normalize_params(type, attrs, title),
      id: generate_id(type, title, index),
      target: %{
        resource_type: type,
        resource_title: title
      },
      metadata: %{
        source: :puppet,
        puppet_type: type,
        puppet_title: title,
        virtual: Map.get(resource, :virtual, false),
        exported: Map.get(resource, :exported, false),
        original_attributes: attrs
      }
    )
  end

  # Resource type normalization

  defp normalize_resource_type("package"), do: :package_install
  defp normalize_resource_type("service"), do: :service_start
  defp normalize_resource_type("file"), do: :file_create
  defp normalize_resource_type("user"), do: :user_create
  defp normalize_resource_type("group"), do: :group_create
  defp normalize_resource_type("exec"), do: :command_run
  defp normalize_resource_type("cron"), do: :cron_create
  defp normalize_resource_type("mount"), do: :mount_create
  defp normalize_resource_type("host"), do: :host_entry_create
  defp normalize_resource_type("ssh_authorized_key"), do: :ssh_key_create
  defp normalize_resource_type("yumrepo"), do: :repository_create
  defp normalize_resource_type("apt::source"), do: :repository_create
  defp normalize_resource_type("firewall"), do: :firewall_rule
  defp normalize_resource_type("class"), do: :class_include
  defp normalize_resource_type(type), do: String.to_atom("puppet.#{type}")

  # Parameter normalization

  defp normalize_params("package", attrs, title) do
    ensure_val = Map.get(attrs, "ensure", "present")

    %{
      name: title,
      state: normalize_ensure(ensure_val),
      provider: Map.get(attrs, "provider"),
      version: if(ensure_val not in ["present", "absent", "latest"], do: ensure_val, else: nil)
    }
  end

  defp normalize_params("service", attrs, title) do
    %{
      name: title,
      state: normalize_service_ensure(Map.get(attrs, "ensure")),
      enabled: Map.get(attrs, "enable"),
      provider: Map.get(attrs, "provider")
    }
  end

  defp normalize_params("file", attrs, title) do
    %{
      path: title,
      content: Map.get(attrs, "content"),
      source: Map.get(attrs, "source"),
      ensure: Map.get(attrs, "ensure", "present"),
      owner: Map.get(attrs, "owner"),
      group: Map.get(attrs, "group"),
      mode: Map.get(attrs, "mode")
    }
  end

  defp normalize_params("user", attrs, title) do
    %{
      name: title,
      ensure: Map.get(attrs, "ensure", "present"),
      uid: Map.get(attrs, "uid"),
      gid: Map.get(attrs, "gid"),
      home: Map.get(attrs, "home"),
      shell: Map.get(attrs, "shell"),
      groups: Map.get(attrs, "groups", [])
    }
  end

  defp normalize_params("group", attrs, title) do
    %{
      name: title,
      ensure: Map.get(attrs, "ensure", "present"),
      gid: Map.get(attrs, "gid")
    }
  end

  defp normalize_params("exec", attrs, title) do
    %{
      command: Map.get(attrs, "command", title),
      creates: Map.get(attrs, "creates"),
      unless: Map.get(attrs, "unless"),
      onlyif: Map.get(attrs, "onlyif"),
      cwd: Map.get(attrs, "cwd"),
      user: Map.get(attrs, "user"),
      path: Map.get(attrs, "path"),
      refreshonly: Map.get(attrs, "refreshonly", false)
    }
  end

  defp normalize_params("cron", attrs, title) do
    %{
      name: title,
      command: Map.get(attrs, "command"),
      user: Map.get(attrs, "user", "root"),
      minute: Map.get(attrs, "minute", "*"),
      hour: Map.get(attrs, "hour", "*"),
      monthday: Map.get(attrs, "monthday", "*"),
      month: Map.get(attrs, "month", "*"),
      weekday: Map.get(attrs, "weekday", "*")
    }
  end

  defp normalize_params("class", attrs, title) do
    %{
      name: title,
      parameters: Map.get(attrs, :parameters, %{})
    }
  end

  defp normalize_params(_type, attrs, title) do
    Map.put(attrs, :name, title)
  end

  defp normalize_ensure("present"), do: :installed
  defp normalize_ensure("installed"), do: :installed
  defp normalize_ensure("absent"), do: :removed
  defp normalize_ensure("purged"), do: :purged
  defp normalize_ensure("latest"), do: :latest
  defp normalize_ensure(version) when is_binary(version), do: :installed
  defp normalize_ensure(_), do: :installed

  defp normalize_service_ensure("running"), do: :running
  defp normalize_service_ensure("stopped"), do: :stopped
  defp normalize_service_ensure(true), do: :running
  defp normalize_service_ensure(false), do: :stopped
  defp normalize_service_ensure(_), do: :running

  # Dependency building

  defp build_dependencies(operations, content) do
    # Build lookup: type_title -> operation_id
    op_lookup =
      operations
      |> Enum.map(fn op ->
        key = "#{op.metadata.puppet_type}[#{op.metadata.puppet_title}]"
        {String.downcase(key), op.id}
      end)
      |> Map.new()

    # Extract relationships from attributes and chaining arrows
    explicit_deps = extract_explicit_relationships(operations, op_lookup)
    chaining_deps = extract_chaining_arrows(content, op_lookup)

    all_deps =
      (explicit_deps ++ chaining_deps)
      |> Enum.uniq_by(fn dep -> {dep.from, dep.to, dep.type} end)

    {:ok, all_deps}
  end

  defp extract_explicit_relationships(operations, op_lookup) do
    operations
    |> Enum.flat_map(fn op ->
      attrs = Map.get(op.metadata, :original_attributes, %{})

      # require => [Resource['title']]
      requires = extract_relationship_refs(attrs, "require", op_lookup)
      |> Enum.map(fn dep_id ->
        Dependency.new(dep_id, op.id, :requires, metadata: %{reason: "puppet_require"})
      end)

      # before => [Resource['title']]
      befores = extract_relationship_refs(attrs, "before", op_lookup)
      |> Enum.map(fn dep_id ->
        Dependency.new(op.id, dep_id, :before, metadata: %{reason: "puppet_before"})
      end)

      # notify => [Resource['title']]
      notifies = extract_relationship_refs(attrs, "notify", op_lookup)
      |> Enum.map(fn dep_id ->
        Dependency.new(op.id, dep_id, :notifies, metadata: %{reason: "puppet_notify"})
      end)

      # subscribe => [Resource['title']]
      subscribes = extract_relationship_refs(attrs, "subscribe", op_lookup)
      |> Enum.map(fn dep_id ->
        Dependency.new(dep_id, op.id, :watches, metadata: %{reason: "puppet_subscribe"})
      end)

      requires ++ befores ++ notifies ++ subscribes
    end)
  end

  defp extract_relationship_refs(attrs, key, op_lookup) do
    case Map.get(attrs, key) do
      nil -> []
      refs when is_list(refs) -> Enum.flat_map(refs, &resolve_ref(&1, op_lookup))
      ref when is_binary(ref) -> resolve_ref(ref, op_lookup)
    end
  end

  defp resolve_ref(ref, op_lookup) when is_binary(ref) do
    # Parse: Type['title'] or Type["title"]
    case Regex.run(~r/([A-Z][a-z_]+)\[['"]([^'"]+)['"]\]/, ref) do
      [_, type, title] ->
        key = String.downcase("#{type}[#{title}]")
        case Map.get(op_lookup, key) do
          nil -> []
          id -> [id]
        end

      nil ->
        []
    end
  end

  defp resolve_ref(_, _), do: []

  defp extract_chaining_arrows(content, op_lookup) do
    # Match: Resource['title'] -> Resource['title']
    # or: Resource['title'] ~> Resource['title']
    chain_regex = ~r/([A-Z][a-z_]+)\[['"]([^'"]+)['"]\]\s*(->|~>)\s*([A-Z][a-z_]+)\[['"]([^'"]+)['"]\]/

    Regex.scan(chain_regex, content)
    |> Enum.flat_map(fn [_full, type1, title1, arrow, type2, title2] ->
      key1 = String.downcase("#{type1}[#{title1}]")
      key2 = String.downcase("#{type2}[#{title2}]")

      from_id = Map.get(op_lookup, key1)
      to_id = Map.get(op_lookup, key2)

      if from_id && to_id do
        dep_type = if arrow == "->", do: :requires, else: :watches
        [Dependency.new(from_id, to_id, dep_type, metadata: %{reason: "puppet_chaining_#{arrow}"})]
      else
        []
      end
    end)
  end

  defp generate_id(type, title, index) do
    safe_title =
      title
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.slice(0, 30)

    "puppet_#{type}_#{safe_title}_#{index}_#{:erlang.unique_integer([:positive])}"
  end
end
