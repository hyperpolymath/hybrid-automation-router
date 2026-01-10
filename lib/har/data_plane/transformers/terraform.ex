defmodule HAR.DataPlane.Transformers.Terraform do
  @moduledoc """
  Transformer for Terraform configuration format.

  Converts HAR semantic graph to Terraform configuration.
  Outputs JSON format (compatible with Terraform's JSON syntax)
  which can be used directly or converted to HCL.
  """

  @behaviour HAR.DataPlane.Transformer

  alias HAR.Semantic.{Graph, Operation}
  require Logger

  @impl true
  def transform(%Graph{} = graph, opts \\ []) do
    provider = Keyword.get(opts, :provider, :aws)
    output_format = Keyword.get(opts, :format, :json)

    with {:ok, sorted_ops} <- Graph.topological_sort(graph),
         {:ok, resources} <- operations_to_resources(sorted_ops, provider),
         {:ok, config} <- build_terraform_config(resources, graph, opts) do
      case output_format do
        :json -> {:ok, Jason.encode!(config, pretty: true)}
        :hcl -> {:ok, config_to_hcl(config)}
        _ -> {:ok, config}
      end
    end
  end

  @impl true
  def validate(%Graph{} = graph) do
    Graph.validate(graph)
  end

  # Internal Functions

  defp operations_to_resources(operations, provider) do
    resources =
      operations
      |> Enum.map(fn op -> operation_to_resource(op, provider) end)
      |> Enum.reject(&is_nil/1)

    {:ok, resources}
  end

  # Compute operations

  defp operation_to_resource(%Operation{type: :compute_instance_create} = op, :aws) do
    name = resource_name(op, "instance")

    %{
      "resource" => %{
        "aws_instance" => %{
          name => build_aws_instance(op)
        }
      }
    }
  end

  defp operation_to_resource(%Operation{type: :compute_instance_create} = op, :gcp) do
    name = resource_name(op, "instance")

    %{
      "resource" => %{
        "google_compute_instance" => %{
          name => build_gcp_instance(op)
        }
      }
    }
  end

  defp operation_to_resource(%Operation{type: :compute_instance_create} = op, :azure) do
    name = resource_name(op, "vm")

    %{
      "resource" => %{
        "azurerm_linux_virtual_machine" => %{
          name => build_azure_vm(op)
        }
      }
    }
  end

  # Storage operations

  defp operation_to_resource(%Operation{type: :storage_bucket_create} = op, :aws) do
    name = resource_name(op, "bucket")

    %{
      "resource" => %{
        "aws_s3_bucket" => %{
          name => build_aws_s3_bucket(op)
        }
      }
    }
  end

  defp operation_to_resource(%Operation{type: :storage_bucket_create} = op, :gcp) do
    name = resource_name(op, "bucket")

    %{
      "resource" => %{
        "google_storage_bucket" => %{
          name => build_gcp_storage_bucket(op)
        }
      }
    }
  end

  # Database operations

  defp operation_to_resource(%Operation{type: :database_create} = op, :aws) do
    name = resource_name(op, "db")

    %{
      "resource" => %{
        "aws_db_instance" => %{
          name => build_aws_rds(op)
        }
      }
    }
  end

  # Network operations

  defp operation_to_resource(%Operation{type: :network_create} = op, :aws) do
    name = resource_name(op, "vpc")

    %{
      "resource" => %{
        "aws_vpc" => %{
          name => build_aws_vpc(op)
        }
      }
    }
  end

  defp operation_to_resource(%Operation{type: :network_subnet_create} = op, :aws) do
    name = resource_name(op, "subnet")

    %{
      "resource" => %{
        "aws_subnet" => %{
          name => build_aws_subnet(op)
        }
      }
    }
  end

  defp operation_to_resource(%Operation{type: :firewall_rule} = op, :aws) do
    name = resource_name(op, "sg")

    %{
      "resource" => %{
        "aws_security_group" => %{
          name => build_aws_security_group(op)
        }
      }
    }
  end

  # User/IAM operations

  defp operation_to_resource(%Operation{type: :user_create} = op, :aws) do
    name = resource_name(op, "user")

    %{
      "resource" => %{
        "aws_iam_user" => %{
          name => build_aws_iam_user(op)
        }
      }
    }
  end

  defp operation_to_resource(%Operation{type: :role_create} = op, :aws) do
    name = resource_name(op, "role")

    %{
      "resource" => %{
        "aws_iam_role" => %{
          name => build_aws_iam_role(op)
        }
      }
    }
  end

  # File operations (using local provider)

  defp operation_to_resource(%Operation{type: :file_write} = op, _provider) do
    name = resource_name(op, "file")

    %{
      "resource" => %{
        "local_file" => %{
          name => build_local_file(op)
        }
      }
    }
  end

  # Command operations (using null resource)

  defp operation_to_resource(%Operation{type: :command_run} = op, _provider) do
    name = resource_name(op, "exec")

    %{
      "resource" => %{
        "null_resource" => %{
          name => build_null_resource(op)
        }
      }
    }
  end

  # Fallback for unmapped operations
  defp operation_to_resource(%Operation{type: type} = _op, _provider) do
    Logger.warning("Unsupported operation type for Terraform: #{type}")
    nil
  end

  # AWS Resource Builders

  defp build_aws_instance(op) do
    params = op.params

    config = %{
      "ami" => Map.get(params, :ami) || "${var.ami_id}",
      "instance_type" => Map.get(params, :instance_type) || "t3.micro"
    }

    config
    |> maybe_put("key_name", Map.get(params, :key_name))
    |> maybe_put("subnet_id", Map.get(params, :subnet_id))
    |> maybe_put("vpc_security_group_ids", Map.get(params, :vpc_security_group_ids))
    |> maybe_put("tags", build_tags(op))
  end

  defp build_aws_s3_bucket(op) do
    params = op.params

    %{
      "bucket" => Map.get(params, :bucket) || Map.get(params, :name) || generate_bucket_name(op)
    }
    |> maybe_put("tags", build_tags(op))
  end

  defp build_aws_rds(op) do
    params = op.params

    %{
      "identifier" => Map.get(params, :identifier) || resource_name(op, "db"),
      "engine" => Map.get(params, :engine) || "postgres",
      "engine_version" => Map.get(params, :engine_version) || "15",
      "instance_class" => Map.get(params, :instance_class) || "db.t3.micro",
      "allocated_storage" => Map.get(params, :allocated_storage) || 20,
      "storage_type" => Map.get(params, :storage_type) || "gp2",
      "username" => "${var.db_username}",
      "password" => "${var.db_password}",
      "skip_final_snapshot" => true
    }
    |> maybe_put("tags", build_tags(op))
  end

  defp build_aws_vpc(op) do
    params = op.params

    %{
      "cidr_block" => Map.get(params, :cidr_block) || "10.0.0.0/16",
      "enable_dns_hostnames" => Map.get(params, :enable_dns_hostnames, true),
      "enable_dns_support" => Map.get(params, :enable_dns_support, true)
    }
    |> maybe_put("tags", build_tags(op))
  end

  defp build_aws_subnet(op) do
    params = op.params

    %{
      "vpc_id" => Map.get(params, :vpc_id) || "${aws_vpc.main.id}",
      "cidr_block" => Map.get(params, :cidr_block) || "10.0.1.0/24"
    }
    |> maybe_put("availability_zone", Map.get(params, :availability_zone))
    |> maybe_put("map_public_ip_on_launch", Map.get(params, :map_public_ip_on_launch))
    |> maybe_put("tags", build_tags(op))
  end

  defp build_aws_security_group(op) do
    params = op.params

    %{
      "name" => Map.get(params, :name) || resource_name(op, "sg"),
      "description" => Map.get(params, :description) || "Managed by HAR"
    }
    |> maybe_put("vpc_id", Map.get(params, :vpc_id))
    |> maybe_put("ingress", Map.get(params, :ingress))
    |> maybe_put("egress", Map.get(params, :egress))
    |> maybe_put("tags", build_tags(op))
  end

  defp build_aws_iam_user(op) do
    params = op.params

    %{
      "name" => Map.get(params, :name) || resource_name(op, "user"),
      "path" => Map.get(params, :path, "/")
    }
    |> maybe_put("tags", build_tags(op))
  end

  defp build_aws_iam_role(op) do
    params = op.params

    %{
      "name" => Map.get(params, :name) || resource_name(op, "role"),
      "assume_role_policy" =>
        Map.get(params, :assume_role_policy) || default_assume_role_policy()
    }
    |> maybe_put("tags", build_tags(op))
  end

  # GCP Resource Builders

  defp build_gcp_instance(op) do
    params = op.params

    %{
      "name" => Map.get(params, :name) || resource_name(op, "instance"),
      "machine_type" => Map.get(params, :machine_type) || "e2-micro",
      "zone" => Map.get(params, :zone) || "${var.zone}",
      "boot_disk" => %{
        "initialize_params" => %{
          "image" => Map.get(params, :image) || "debian-cloud/debian-11"
        }
      },
      "network_interface" => %{
        "network" => Map.get(params, :network) || "default"
      }
    }
  end

  defp build_gcp_storage_bucket(op) do
    params = op.params

    %{
      "name" => Map.get(params, :name) || generate_bucket_name(op),
      "location" => Map.get(params, :location) || "US"
    }
  end

  # Azure Resource Builders

  defp build_azure_vm(op) do
    params = op.params

    %{
      "name" => Map.get(params, :name) || resource_name(op, "vm"),
      "resource_group_name" => "${azurerm_resource_group.main.name}",
      "location" => "${azurerm_resource_group.main.location}",
      "size" => Map.get(params, :size) || "Standard_B1s",
      "admin_username" => "${var.admin_username}",
      "network_interface_ids" => ["${azurerm_network_interface.main.id}"],
      "admin_ssh_key" => %{
        "username" => "${var.admin_username}",
        "public_key" => "${var.ssh_public_key}"
      },
      "os_disk" => %{
        "caching" => "ReadWrite",
        "storage_account_type" => "Standard_LRS"
      },
      "source_image_reference" => %{
        "publisher" => "Canonical",
        "offer" => "0001-com-ubuntu-server-jammy",
        "sku" => "22_04-lts",
        "version" => "latest"
      }
    }
  end

  # Local/Null Providers

  defp build_local_file(op) do
    params = op.params

    %{
      "filename" => Map.get(params, :path) || Map.get(params, :destination),
      "content" => Map.get(params, :content) || ""
    }
    |> maybe_put("file_permission", Map.get(params, :mode) || Map.get(params, :permissions))
  end

  defp build_null_resource(op) do
    params = op.params

    base = %{
      "triggers" => %{
        "always_run" => "${timestamp()}"
      }
    }

    command = Map.get(params, :command)

    if command do
      Map.put(base, "provisioner", %{
        "local-exec" => %{
          "command" => command
        }
      })
    else
      base
    end
  end

  # Config Building

  defp build_terraform_config(resources, graph, opts) do
    provider = Keyword.get(opts, :provider, :aws)

    # Merge all resources
    merged_resources =
      resources
      |> Enum.reduce(%{}, fn res, acc ->
        deep_merge(acc, res)
      end)

    config = %{
      "terraform" => %{
        "required_version" => ">= 1.0.0",
        "required_providers" => required_providers(provider)
      },
      "provider" => provider_config(provider, opts)
    }

    config = deep_merge(config, merged_resources)

    # Add variables if needed
    config =
      if Keyword.get(opts, :include_variables, true) do
        Map.put(config, "variable", generate_variables(graph, provider))
      else
        config
      end

    {:ok, config}
  end

  defp required_providers(:aws) do
    %{
      "aws" => %{
        "source" => "hashicorp/aws",
        "version" => "~> 5.0"
      }
    }
  end

  defp required_providers(:gcp) do
    %{
      "google" => %{
        "source" => "hashicorp/google",
        "version" => "~> 5.0"
      }
    }
  end

  defp required_providers(:azure) do
    %{
      "azurerm" => %{
        "source" => "hashicorp/azurerm",
        "version" => "~> 3.0"
      }
    }
  end

  defp required_providers(_), do: %{}

  defp provider_config(:aws, opts) do
    region = Keyword.get(opts, :region, "us-east-1")

    %{
      "aws" => %{
        "region" => region
      }
    }
  end

  defp provider_config(:gcp, opts) do
    project = Keyword.get(opts, :project, "${var.project_id}")
    region = Keyword.get(opts, :region, "us-central1")

    %{
      "google" => %{
        "project" => project,
        "region" => region
      }
    }
  end

  defp provider_config(:azure, _opts) do
    %{
      "azurerm" => %{
        "features" => %{}
      }
    }
  end

  defp provider_config(_, _), do: %{}

  defp generate_variables(_graph, :aws) do
    %{
      "ami_id" => %{
        "description" => "AMI ID for EC2 instances",
        "type" => "string",
        "default" => ""
      },
      "db_username" => %{
        "description" => "Database username",
        "type" => "string",
        "sensitive" => true
      },
      "db_password" => %{
        "description" => "Database password",
        "type" => "string",
        "sensitive" => true
      }
    }
  end

  defp generate_variables(_graph, _provider), do: %{}

  # HCL Output

  defp config_to_hcl(config) do
    config
    |> Enum.map(fn {block_type, block_content} ->
      format_hcl_block(block_type, block_content)
    end)
    |> Enum.join("\n\n")
  end

  defp format_hcl_block("terraform", content) do
    """
    terraform {
    #{format_hcl_body(content, 1)}
    }
    """
  end

  defp format_hcl_block("provider", providers) do
    providers
    |> Enum.map(fn {name, config} ->
      """
      provider "#{name}" {
      #{format_hcl_body(config, 1)}
      }
      """
    end)
    |> Enum.join("\n")
  end

  defp format_hcl_block("resource", resources) do
    resources
    |> Enum.flat_map(fn {type, instances} ->
      Enum.map(instances, fn {name, config} ->
        """
        resource "#{type}" "#{name}" {
        #{format_hcl_body(config, 1)}
        }
        """
      end)
    end)
    |> Enum.join("\n")
  end

  defp format_hcl_block("variable", variables) do
    variables
    |> Enum.map(fn {name, config} ->
      """
      variable "#{name}" {
      #{format_hcl_body(config, 1)}
      }
      """
    end)
    |> Enum.join("\n")
  end

  defp format_hcl_block(block_type, content) do
    """
    #{block_type} {
    #{format_hcl_body(content, 1)}
    }
    """
  end

  defp format_hcl_body(map, indent) when is_map(map) do
    pad = String.duplicate("  ", indent)

    map
    |> Enum.map(fn {key, value} ->
      formatted_value = format_hcl_value(value, indent)
      "#{pad}#{key} = #{formatted_value}"
    end)
    |> Enum.join("\n")
  end

  defp format_hcl_value(value, _indent) when is_binary(value) do
    "\"#{value}\""
  end

  defp format_hcl_value(value, _indent) when is_number(value) do
    to_string(value)
  end

  defp format_hcl_value(value, _indent) when is_boolean(value) do
    to_string(value)
  end

  defp format_hcl_value(value, indent) when is_map(value) do
    pad = String.duplicate("  ", indent)
    "{\n#{format_hcl_body(value, indent + 1)}\n#{pad}}"
  end

  defp format_hcl_value(value, _indent) when is_list(value) do
    items =
      value
      |> Enum.map(&format_hcl_value(&1, 0))
      |> Enum.join(", ")

    "[#{items}]"
  end

  defp format_hcl_value(nil, _indent), do: "null"
  defp format_hcl_value(value, _indent), do: inspect(value)

  # Helpers

  defp resource_name(op, prefix) do
    # Try to get a meaningful name from metadata or params
    name =
      Map.get(op.metadata, :resource_name) ||
        Map.get(op.params, :name) ||
        Map.get(op.params, :identifier) ||
        "#{prefix}_#{:erlang.phash2(op.id, 9999)}"

    # Sanitize for Terraform identifier
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp generate_bucket_name(op) do
    base = resource_name(op, "bucket")
    suffix = :erlang.phash2(:erlang.monotonic_time(), 99999)
    "#{base}-#{suffix}"
  end

  defp build_tags(op) do
    default_tags = %{
      "ManagedBy" => "HAR",
      "Source" => to_string(Map.get(op.metadata, :source, :unknown))
    }

    existing_tags = Map.get(op.params, :tags, %{})
    Map.merge(default_tags, existing_tags)
  end

  defp default_assume_role_policy do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Action" => "sts:AssumeRole",
          "Principal" => %{
            "Service" => "ec2.amazonaws.com"
          },
          "Effect" => "Allow"
        }
      ]
    })
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, m) when m == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp deep_merge(_left, right), do: right
end
