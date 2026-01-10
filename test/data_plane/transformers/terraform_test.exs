defmodule HAR.DataPlane.Transformers.TerraformTest do
  use ExUnit.Case, async: true

  alias HAR.DataPlane.Transformers.Terraform
  alias HAR.Semantic.{Graph, Operation}

  describe "transform/2" do
    test "transforms compute instance operation to AWS" do
      graph = build_graph([
        Operation.new(:compute_instance_create, %{
          ami: "ami-12345678",
          instance_type: "t3.micro"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      assert decoded["terraform"]["required_providers"]["aws"]
      assert decoded["provider"]["aws"]["region"]
      assert get_in(decoded, ["resource", "aws_instance"])
    end

    test "transforms compute instance operation to GCP" do
      graph = build_graph([
        Operation.new(:compute_instance_create, %{
          machine_type: "e2-micro",
          zone: "us-central1-a"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :gcp)
      decoded = Jason.decode!(output)

      assert decoded["terraform"]["required_providers"]["google"]
      assert decoded["provider"]["google"]["project"]
      assert get_in(decoded, ["resource", "google_compute_instance"])
    end

    test "transforms storage bucket operation" do
      graph = build_graph([
        Operation.new(:storage_bucket_create, %{
          bucket: "my-test-bucket"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      bucket_resource = get_in(decoded, ["resource", "aws_s3_bucket"])
      assert bucket_resource != nil
    end

    test "transforms database operation" do
      graph = build_graph([
        Operation.new(:database_create, %{
          engine: "postgres",
          instance_class: "db.t3.micro"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      db_resource = get_in(decoded, ["resource", "aws_db_instance"])
      assert db_resource != nil

      # Get the first db instance config
      [db_config] = Map.values(db_resource)
      assert db_config["engine"] == "postgres"
    end

    test "transforms network operations" do
      graph = build_graph([
        Operation.new(:network_create, %{
          cidr_block: "10.0.0.0/16"
        }),
        Operation.new(:network_subnet_create, %{
          cidr_block: "10.0.1.0/24"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      assert get_in(decoded, ["resource", "aws_vpc"])
      assert get_in(decoded, ["resource", "aws_subnet"])
    end

    test "transforms firewall operation" do
      graph = build_graph([
        Operation.new(:firewall_rule, %{
          name: "web-sg",
          description: "Allow HTTP"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      sg_resource = get_in(decoded, ["resource", "aws_security_group"])
      assert sg_resource != nil
    end

    test "transforms user create operation" do
      graph = build_graph([
        Operation.new(:user_create, %{
          name: "deploy-user",
          path: "/system/"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      user_resource = get_in(decoded, ["resource", "aws_iam_user"])
      assert user_resource != nil

      [user_config] = Map.values(user_resource)
      assert user_config["name"] == "deploy-user"
      assert user_config["path"] == "/system/"
    end

    test "transforms file write operation to local_file" do
      graph = build_graph([
        Operation.new(:file_write, %{
          path: "/etc/app/config.json",
          content: ~s({"key": "value"})
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      file_resource = get_in(decoded, ["resource", "local_file"])
      assert file_resource != nil

      [file_config] = Map.values(file_resource)
      assert file_config["filename"] == "/etc/app/config.json"
    end

    test "transforms command run operation to null_resource" do
      graph = build_graph([
        Operation.new(:command_run, %{
          command: "echo hello"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      null_resource = get_in(decoded, ["resource", "null_resource"])
      assert null_resource != nil
    end

    test "includes terraform block with required providers" do
      graph = build_graph([
        Operation.new(:compute_instance_create, %{})
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      assert decoded["terraform"]["required_version"] == ">= 1.0.0"
      assert decoded["terraform"]["required_providers"]["aws"]["source"] == "hashicorp/aws"
    end

    test "includes provider configuration" do
      assert {:ok, output} =
               build_graph([Operation.new(:compute_instance_create, %{})])
               |> Terraform.transform(provider: :aws, region: "eu-west-1")

      decoded = Jason.decode!(output)
      assert decoded["provider"]["aws"]["region"] == "eu-west-1"
    end

    test "includes variables when option is set" do
      graph = build_graph([Operation.new(:database_create, %{})])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws, include_variables: true)
      decoded = Jason.decode!(output)

      assert decoded["variable"]["db_username"]
      assert decoded["variable"]["db_password"]
    end

    test "omits variables when option is false" do
      graph = build_graph([Operation.new(:database_create, %{})])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws, include_variables: false)
      decoded = Jason.decode!(output)

      assert decoded["variable"] == nil
    end

    test "adds tags with HAR metadata" do
      graph = build_graph([
        Operation.new(:compute_instance_create, %{
          tags: %{"Environment" => "production"}
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      instance = get_in(decoded, ["resource", "aws_instance"])
      [config] = Map.values(instance)

      assert config["tags"]["ManagedBy"] == "HAR"
      assert config["tags"]["Environment"] == "production"
    end

    test "outputs HCL format when requested" do
      graph = build_graph([
        Operation.new(:compute_instance_create, %{
          ami: "ami-12345678"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws, format: :hcl)

      # HCL should be a string containing terraform blocks
      assert is_binary(output)
      assert output =~ "terraform"
      assert output =~ "provider"
      assert output =~ "resource"
    end
  end

  describe "validate/1" do
    test "validates graph structure" do
      graph = build_graph([Operation.new(:compute_instance_create, %{})])
      assert :ok = Terraform.validate(graph)
    end
  end

  describe "Azure provider" do
    test "transforms to Azure resources" do
      graph = build_graph([
        Operation.new(:compute_instance_create, %{
          size: "Standard_B2s"
        })
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :azure)
      decoded = Jason.decode!(output)

      assert decoded["terraform"]["required_providers"]["azurerm"]
      assert decoded["provider"]["azurerm"]
      assert get_in(decoded, ["resource", "azurerm_linux_virtual_machine"])
    end
  end

  describe "multiple operations" do
    test "transforms multiple operations into single config" do
      graph = build_graph([
        Operation.new(:network_create, %{cidr_block: "10.0.0.0/16"}),
        Operation.new(:network_subnet_create, %{cidr_block: "10.0.1.0/24"}),
        Operation.new(:firewall_rule, %{name: "web-sg"}),
        Operation.new(:compute_instance_create, %{instance_type: "t3.micro"})
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      assert get_in(decoded, ["resource", "aws_vpc"])
      assert get_in(decoded, ["resource", "aws_subnet"])
      assert get_in(decoded, ["resource", "aws_security_group"])
      assert get_in(decoded, ["resource", "aws_instance"])
    end
  end

  describe "resource naming" do
    test "generates unique resource names" do
      graph = build_graph([
        Operation.new(:compute_instance_create, %{}),
        Operation.new(:compute_instance_create, %{})
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      instances = get_in(decoded, ["resource", "aws_instance"])
      # Should have 2 different named instances
      assert map_size(instances) == 2
    end

    test "uses name from params when available" do
      graph = build_graph([
        Operation.new(:user_create, %{name: "my-custom-user"}, metadata: %{})
      ])

      assert {:ok, output} = Terraform.transform(graph, provider: :aws)
      decoded = Jason.decode!(output)

      users = get_in(decoded, ["resource", "aws_iam_user"])
      [user_name] = Map.keys(users)
      assert user_name =~ "my_custom_user"
    end
  end

  # Helper function to build a test graph
  defp build_graph(operations) do
    Graph.new(
      vertices: operations,
      edges: [],
      metadata: %{source: :test}
    )
  end
end
