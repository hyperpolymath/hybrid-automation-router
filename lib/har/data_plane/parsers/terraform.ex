defmodule HAR.DataPlane.Parsers.Terraform do
  @moduledoc """
  Parser for Terraform configurations.

  Supports two input formats:
  - JSON: Output from `terraform show -json` or `terraform plan -json`
  - HCL: Native Terraform configuration (basic pattern matching)

  Converts Terraform resources to HAR semantic graph operations.
  """

  @behaviour HAR.DataPlane.Parser

  alias HAR.Semantic.{Graph, Operation, Dependency}
  require Logger

  @impl true
  def parse(content, opts \\ []) when is_binary(content) do
    format = detect_format(content)

    with {:ok, parsed} <- do_parse(content, format),
         {:ok, operations} <- extract_operations(parsed, opts),
         {:ok, dependencies} <- build_dependencies(operations, parsed) do
      graph =
        Graph.new(
          vertices: operations,
          edges: dependencies,
          metadata: %{source: :terraform, format: format, parsed_at: DateTime.utc_now()}
        )

      {:ok, graph}
    end
  end

  @impl true
  def validate(content) when is_binary(content) do
    case detect_format(content) do
      :json -> validate_json(content)
      :hcl -> validate_hcl(content)
    end
  end

  # Format Detection

  defp detect_format(content) do
    trimmed = String.trim_leading(content)

    if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
      :json
    else
      :hcl
    end
  end

  # Parsing

  defp do_parse(content, :json) do
    case Jason.decode(content) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp do_parse(content, :hcl) do
    # Parse HCL using regex patterns
    # This is a simplified parser for common Terraform patterns
    resources = parse_hcl_resources(content)
    variables = parse_hcl_variables(content)
    outputs = parse_hcl_outputs(content)

    {:ok,
     %{
       "format_version" => "1.0",
       "terraform_version" => "unknown",
       "resources" => resources,
       "variables" => variables,
       "outputs" => outputs
     }}
  end

  defp parse_hcl_resources(content) do
    # Match resource blocks: resource "type" "name" { ... }
    resource_regex = ~r/resource\s+"([^"]+)"\s+"([^"]+)"\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}/s

    Regex.scan(resource_regex, content)
    |> Enum.map(fn [_full, type, name, body] ->
      %{
        "address" => "#{type}.#{name}",
        "type" => type,
        "name" => name,
        "values" => parse_hcl_attributes(body),
        "depends_on" => extract_depends_on(body)
      }
    end)
  end

  defp parse_hcl_variables(content) do
    # Match variable blocks: variable "name" { ... }
    variable_regex = ~r/variable\s+"([^"]+)"\s*\{([^}]*)\}/s

    Regex.scan(variable_regex, content)
    |> Enum.map(fn [_full, name, body] ->
      %{
        "name" => name,
        "default" => extract_default(body),
        "type" => extract_type(body)
      }
    end)
    |> Map.new(fn v -> {v["name"], v} end)
  end

  defp parse_hcl_outputs(content) do
    # Match output blocks: output "name" { value = ... }
    output_regex = ~r/output\s+"([^"]+)"\s*\{([^}]*)\}/s

    Regex.scan(output_regex, content)
    |> Enum.map(fn [_full, name, body] ->
      %{
        "name" => name,
        "value" => extract_value(body)
      }
    end)
    |> Map.new(fn o -> {o["name"], o} end)
  end

  defp parse_hcl_attributes(body) do
    # Parse key = value pairs from HCL block body
    attr_regex = ~r/(\w+)\s*=\s*(?:"([^"]*)"|(true|false|\d+)|(\w+\.\w+(?:\.\w+)*))/

    Regex.scan(attr_regex, body)
    |> Enum.map(fn
      [_full, key, string_val, "", ""] when string_val != "" -> {key, string_val}
      [_full, key, "", literal_val, ""] when literal_val != "" -> {key, parse_literal(literal_val)}
      [_full, key, "", "", ref] when ref != "" -> {key, "${#{ref}}"}
      [_full, key | _] -> {key, nil}
    end)
    |> Map.new()
  end

  defp parse_literal("true"), do: true
  defp parse_literal("false"), do: false
  defp parse_literal(num), do: String.to_integer(num)

  defp extract_depends_on(body) do
    depends_regex = ~r/depends_on\s*=\s*\[([^\]]*)\]/s

    case Regex.run(depends_regex, body) do
      [_, deps_content] ->
        ~r/(\w+\.\w+)/
        |> Regex.scan(deps_content)
        |> Enum.map(fn [_, ref] -> ref end)

      nil ->
        []
    end
  end

  defp extract_default(body) do
    case Regex.run(~r/default\s*=\s*"([^"]*)"/, body) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp extract_type(body) do
    case Regex.run(~r/type\s*=\s*(\w+)/, body) do
      [_, type] -> type
      nil -> "string"
    end
  end

  defp extract_value(body) do
    case Regex.run(~r/value\s*=\s*(.+)/, body) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  # Validation

  defp validate_json(content) do
    case Jason.decode(content) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp validate_hcl(content) do
    # Basic HCL validation - check for balanced braces
    open = String.graphemes(content) |> Enum.count(&(&1 == "{"))
    close = String.graphemes(content) |> Enum.count(&(&1 == "}"))

    if open == close do
      :ok
    else
      {:error, {:hcl_parse_error, "Unbalanced braces: #{open} open, #{close} close"}}
    end
  end

  # Operation Extraction

  defp extract_operations(parsed, _opts) do
    resources = get_resources(parsed)

    operations =
      resources
      |> Enum.with_index()
      |> Enum.map(fn {resource, index} ->
        resource_to_operation(resource, index)
      end)

    {:ok, operations}
  end

  defp get_resources(%{"resources" => resources}) when is_list(resources), do: resources

  defp get_resources(%{"planned_values" => %{"root_module" => %{"resources" => resources}}}),
    do: resources

  defp get_resources(%{"values" => %{"root_module" => %{"resources" => resources}}}),
    do: resources

  defp get_resources(_), do: []

  defp resource_to_operation(resource, index) do
    type = Map.get(resource, "type", "unknown")
    name = Map.get(resource, "name", "unnamed")
    address = Map.get(resource, "address", "#{type}.#{name}")
    values = Map.get(resource, "values", %{})
    provider = extract_provider(type)

    Operation.new(
      normalize_resource_type(type),
      normalize_resource_params(type, values),
      id: generate_resource_id(address, index),
      target: %{
        provider: provider,
        region: Map.get(values, "region"),
        resource_address: address
      },
      metadata: %{
        source: :terraform,
        resource_type: type,
        resource_name: name,
        address: address,
        original_values: values
      }
    )
  end

  # Resource Type Normalization - maps Terraform resources to semantic operations

  # AWS Compute
  defp normalize_resource_type("aws_instance"), do: :compute_instance_create
  defp normalize_resource_type("aws_launch_template"), do: :compute_instance_create
  defp normalize_resource_type("aws_autoscaling_group"), do: :compute_instance_create

  # AWS Storage
  defp normalize_resource_type("aws_s3_bucket"), do: :storage_bucket_create
  defp normalize_resource_type("aws_s3_object"), do: :file_write
  defp normalize_resource_type("aws_ebs_volume"), do: :storage_volume_create

  # AWS Database
  defp normalize_resource_type("aws_db_instance"), do: :database_create
  defp normalize_resource_type("aws_rds_cluster"), do: :database_create
  defp normalize_resource_type("aws_dynamodb_table"), do: :database_create

  # AWS Networking
  defp normalize_resource_type("aws_vpc"), do: :network_create
  defp normalize_resource_type("aws_subnet"), do: :network_subnet_create
  defp normalize_resource_type("aws_security_group"), do: :firewall_rule
  defp normalize_resource_type("aws_security_group_rule"), do: :firewall_rule
  defp normalize_resource_type("aws_route_table"), do: :network_route
  defp normalize_resource_type("aws_internet_gateway"), do: :network_gateway_create
  defp normalize_resource_type("aws_nat_gateway"), do: :network_gateway_create
  defp normalize_resource_type("aws_lb"), do: :load_balancer_create
  defp normalize_resource_type("aws_alb"), do: :load_balancer_create

  # AWS IAM
  defp normalize_resource_type("aws_iam_user"), do: :user_create
  defp normalize_resource_type("aws_iam_group"), do: :group_create
  defp normalize_resource_type("aws_iam_role"), do: :role_create
  defp normalize_resource_type("aws_iam_policy"), do: :policy_create

  # AWS Lambda
  defp normalize_resource_type("aws_lambda_function"), do: :function_create

  # GCP Compute
  defp normalize_resource_type("google_compute_instance"), do: :compute_instance_create
  defp normalize_resource_type("google_compute_disk"), do: :storage_volume_create

  # GCP Storage
  defp normalize_resource_type("google_storage_bucket"), do: :storage_bucket_create
  defp normalize_resource_type("google_storage_bucket_object"), do: :file_write

  # GCP Database
  defp normalize_resource_type("google_sql_database_instance"), do: :database_create

  # GCP Networking
  defp normalize_resource_type("google_compute_network"), do: :network_create
  defp normalize_resource_type("google_compute_subnetwork"), do: :network_subnet_create
  defp normalize_resource_type("google_compute_firewall"), do: :firewall_rule

  # Azure Compute
  defp normalize_resource_type("azurerm_virtual_machine"), do: :compute_instance_create
  defp normalize_resource_type("azurerm_linux_virtual_machine"), do: :compute_instance_create
  defp normalize_resource_type("azurerm_windows_virtual_machine"), do: :compute_instance_create

  # Azure Storage
  defp normalize_resource_type("azurerm_storage_account"), do: :storage_bucket_create
  defp normalize_resource_type("azurerm_storage_container"), do: :storage_bucket_create
  defp normalize_resource_type("azurerm_managed_disk"), do: :storage_volume_create

  # Azure Database
  defp normalize_resource_type("azurerm_sql_database"), do: :database_create
  defp normalize_resource_type("azurerm_cosmosdb_account"), do: :database_create

  # Azure Networking
  defp normalize_resource_type("azurerm_virtual_network"), do: :network_create
  defp normalize_resource_type("azurerm_subnet"), do: :network_subnet_create
  defp normalize_resource_type("azurerm_network_security_group"), do: :firewall_rule

  # Kubernetes
  defp normalize_resource_type("kubernetes_deployment"), do: :container_deployment_create
  defp normalize_resource_type("kubernetes_service"), do: :service_create
  defp normalize_resource_type("kubernetes_config_map"), do: :config_create
  defp normalize_resource_type("kubernetes_secret"), do: :secret_create
  defp normalize_resource_type("kubernetes_namespace"), do: :namespace_create

  # Local/Null providers
  defp normalize_resource_type("null_resource"), do: :command_run
  defp normalize_resource_type("local_file"), do: :file_write
  defp normalize_resource_type("local_sensitive_file"), do: :file_write

  # Fallback for unknown resource types
  defp normalize_resource_type(type), do: String.to_atom("terraform." <> type)

  # Parameter Normalization

  defp normalize_resource_params("aws_instance", values) do
    %{
      ami: Map.get(values, "ami"),
      instance_type: Map.get(values, "instance_type"),
      key_name: Map.get(values, "key_name"),
      vpc_security_group_ids: Map.get(values, "vpc_security_group_ids", []),
      subnet_id: Map.get(values, "subnet_id"),
      tags: Map.get(values, "tags", %{})
    }
  end

  defp normalize_resource_params("aws_s3_bucket", values) do
    %{
      bucket: Map.get(values, "bucket"),
      acl: Map.get(values, "acl"),
      versioning: Map.get(values, "versioning"),
      tags: Map.get(values, "tags", %{})
    }
  end

  defp normalize_resource_params("aws_security_group", values) do
    %{
      name: Map.get(values, "name"),
      description: Map.get(values, "description"),
      vpc_id: Map.get(values, "vpc_id"),
      ingress: Map.get(values, "ingress", []),
      egress: Map.get(values, "egress", []),
      tags: Map.get(values, "tags", %{})
    }
  end

  defp normalize_resource_params("aws_db_instance", values) do
    %{
      identifier: Map.get(values, "identifier"),
      engine: Map.get(values, "engine"),
      engine_version: Map.get(values, "engine_version"),
      instance_class: Map.get(values, "instance_class"),
      allocated_storage: Map.get(values, "allocated_storage"),
      storage_type: Map.get(values, "storage_type"),
      tags: Map.get(values, "tags", %{})
    }
  end

  defp normalize_resource_params("aws_vpc", values) do
    %{
      cidr_block: Map.get(values, "cidr_block"),
      enable_dns_hostnames: Map.get(values, "enable_dns_hostnames"),
      enable_dns_support: Map.get(values, "enable_dns_support"),
      tags: Map.get(values, "tags", %{})
    }
  end

  defp normalize_resource_params("aws_subnet", values) do
    %{
      vpc_id: Map.get(values, "vpc_id"),
      cidr_block: Map.get(values, "cidr_block"),
      availability_zone: Map.get(values, "availability_zone"),
      map_public_ip_on_launch: Map.get(values, "map_public_ip_on_launch"),
      tags: Map.get(values, "tags", %{})
    }
  end

  defp normalize_resource_params("aws_iam_user", values) do
    %{
      name: Map.get(values, "name"),
      path: Map.get(values, "path", "/"),
      tags: Map.get(values, "tags", %{})
    }
  end

  defp normalize_resource_params("aws_iam_role", values) do
    %{
      name: Map.get(values, "name"),
      assume_role_policy: Map.get(values, "assume_role_policy"),
      tags: Map.get(values, "tags", %{})
    }
  end

  defp normalize_resource_params("local_file", values) do
    %{
      path: Map.get(values, "filename"),
      content: Map.get(values, "content"),
      permissions: Map.get(values, "file_permission")
    }
  end

  defp normalize_resource_params("null_resource", values) do
    %{
      triggers: Map.get(values, "triggers", %{}),
      provisioners: extract_provisioners(values)
    }
  end

  defp normalize_resource_params(_type, values), do: values

  defp extract_provisioners(%{"provisioner" => provisioners}) when is_list(provisioners) do
    provisioners
  end

  defp extract_provisioners(_), do: []

  defp extract_provider(type) do
    case String.split(type, "_", parts: 2) do
      [provider, _] -> String.to_atom(provider)
      _ -> :unknown
    end
  end

  # Dependency Building

  defp build_dependencies(operations, parsed) do
    resources = get_resources(parsed)

    # Build lookup table: address -> operation_id
    address_to_id =
      Enum.zip(resources, operations)
      |> Enum.map(fn {resource, operation} ->
        address = Map.get(resource, "address", "")
        {address, operation.id}
      end)
      |> Map.new()

    # Extract explicit depends_on dependencies
    explicit_deps =
      Enum.zip(resources, operations)
      |> Enum.flat_map(fn {resource, operation} ->
        depends_on = Map.get(resource, "depends_on", [])

        Enum.flat_map(depends_on, fn dep_address ->
          case Map.get(address_to_id, dep_address) do
            nil ->
              Logger.debug("Dependency not found: #{dep_address}")
              []

            dep_id ->
              [
                Dependency.new(dep_id, operation.id, :depends_on,
                  metadata: %{reason: "terraform_depends_on", source: dep_address}
                )
              ]
          end
        end)
      end)

    # Extract implicit dependencies from resource references in values
    implicit_deps =
      Enum.zip(resources, operations)
      |> Enum.flat_map(fn {resource, operation} ->
        values = Map.get(resource, "values", %{})
        refs = find_resource_references(values, address_to_id)

        Enum.flat_map(refs, fn ref_id ->
          if ref_id != operation.id do
            [
              Dependency.new(ref_id, operation.id, :requires,
                metadata: %{reason: "terraform_implicit_reference"}
              )
            ]
          else
            []
          end
        end)
      end)

    # Deduplicate dependencies
    all_deps =
      (explicit_deps ++ implicit_deps)
      |> Enum.uniq_by(fn dep -> {dep.from, dep.to, dep.type} end)

    {:ok, all_deps}
  end

  defp find_resource_references(values, address_to_id) when is_map(values) do
    values
    |> Enum.flat_map(fn {_key, value} ->
      find_resource_references(value, address_to_id)
    end)
  end

  defp find_resource_references(value, address_to_id) when is_binary(value) do
    # Look for resource references like ${aws_vpc.main.id} or aws_vpc.main
    ref_regex = ~r/(?:\$\{)?(\w+\.\w+)(?:\.\w+)*\}?/

    Regex.scan(ref_regex, value)
    |> Enum.flat_map(fn [_, ref] ->
      case Map.get(address_to_id, ref) do
        nil -> []
        id -> [id]
      end
    end)
  end

  defp find_resource_references(values, address_to_id) when is_list(values) do
    Enum.flat_map(values, &find_resource_references(&1, address_to_id))
  end

  defp find_resource_references(_, _), do: []

  # ID Generation

  defp generate_resource_id(address, index) do
    safe_address =
      address
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.slice(0, 40)

    "tf_#{safe_address}_#{index}_#{:erlang.unique_integer([:positive])}"
  end
end
