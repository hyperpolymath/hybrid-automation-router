defmodule HAR.DataPlane.Parsers.TerraformTest do
  use ExUnit.Case, async: true

  alias HAR.DataPlane.Parsers.Terraform
  alias HAR.Semantic.Graph

  describe "parse/2 with JSON format" do
    test "parses terraform plan JSON output" do
      json = """
      {
        "format_version": "1.0",
        "terraform_version": "1.5.0",
        "resources": [
          {
            "address": "aws_instance.web",
            "type": "aws_instance",
            "name": "web",
            "values": {
              "ami": "ami-12345678",
              "instance_type": "t3.micro",
              "tags": {"Name": "webserver"}
            }
          }
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      assert length(graph.vertices) == 1

      [op] = graph.vertices
      assert op.type == :compute_instance_create
      assert op.params.ami == "ami-12345678"
      assert op.params.instance_type == "t3.micro"
      assert op.metadata.source == :terraform
      assert op.metadata.resource_type == "aws_instance"
    end

    test "parses terraform show JSON output with nested structure" do
      json = """
      {
        "format_version": "1.0",
        "values": {
          "root_module": {
            "resources": [
              {
                "address": "aws_s3_bucket.assets",
                "type": "aws_s3_bucket",
                "name": "assets",
                "values": {
                  "bucket": "my-assets-bucket"
                }
              }
            ]
          }
        }
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      assert length(graph.vertices) == 1

      [op] = graph.vertices
      assert op.type == :storage_bucket_create
      assert op.params.bucket == "my-assets-bucket"
    end

    test "handles multiple resources with dependencies" do
      json = """
      {
        "resources": [
          {
            "address": "aws_vpc.main",
            "type": "aws_vpc",
            "name": "main",
            "values": {"cidr_block": "10.0.0.0/16"}
          },
          {
            "address": "aws_subnet.public",
            "type": "aws_subnet",
            "name": "public",
            "values": {"vpc_id": "${aws_vpc.main.id}", "cidr_block": "10.0.1.0/24"},
            "depends_on": ["aws_vpc.main"]
          }
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      assert length(graph.vertices) == 2
      assert length(graph.edges) >= 1

      types = Enum.map(graph.vertices, & &1.type)
      assert :network_create in types
      assert :network_subnet_create in types
    end

    test "parses AWS security group resources" do
      json = """
      {
        "resources": [
          {
            "address": "aws_security_group.web",
            "type": "aws_security_group",
            "name": "web",
            "values": {
              "name": "webserver-sg",
              "description": "Allow HTTP traffic",
              "vpc_id": "vpc-12345"
            }
          }
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      [op] = graph.vertices
      assert op.type == :firewall_rule
      assert op.params.name == "webserver-sg"
    end

    test "parses AWS RDS database resources" do
      json = """
      {
        "resources": [
          {
            "address": "aws_db_instance.main",
            "type": "aws_db_instance",
            "name": "main",
            "values": {
              "identifier": "mydb",
              "engine": "postgres",
              "instance_class": "db.t3.micro"
            }
          }
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      [op] = graph.vertices
      assert op.type == :database_create
      assert op.params.identifier == "mydb"
      assert op.params.engine == "postgres"
    end

    test "parses AWS IAM resources" do
      json = """
      {
        "resources": [
          {
            "address": "aws_iam_user.deploy",
            "type": "aws_iam_user",
            "name": "deploy",
            "values": {"name": "deploy-user", "path": "/system/"}
          },
          {
            "address": "aws_iam_role.app",
            "type": "aws_iam_role",
            "name": "app",
            "values": {"name": "app-role"}
          }
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      assert length(graph.vertices) == 2

      types = Enum.map(graph.vertices, & &1.type)
      assert :user_create in types
      assert :role_create in types
    end

    test "parses local file resources" do
      json = """
      {
        "resources": [
          {
            "address": "local_file.config",
            "type": "local_file",
            "name": "config",
            "values": {
              "filename": "/etc/app/config.json",
              "content": "{\\"key\\": \\"value\\"}"
            }
          }
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      [op] = graph.vertices
      assert op.type == :file_write
      assert op.params.path == "/etc/app/config.json"
    end

    test "parses null_resource with command" do
      json = """
      {
        "resources": [
          {
            "address": "null_resource.setup",
            "type": "null_resource",
            "name": "setup",
            "values": {
              "triggers": {"always_run": "123"}
            }
          }
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      [op] = graph.vertices
      assert op.type == :command_run
    end

    test "returns error for invalid JSON" do
      invalid_json = "{ invalid json }"
      assert {:error, {:json_parse_error, _}} = Terraform.parse(invalid_json)
    end
  end

  describe "parse/2 with HCL format" do
    test "parses basic HCL resource blocks" do
      hcl = """
      resource "aws_instance" "web" {
        ami           = "ami-12345678"
        instance_type = "t3.micro"
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(hcl)
      assert length(graph.vertices) == 1

      [op] = graph.vertices
      assert op.type == :compute_instance_create
      assert op.metadata.resource_type == "aws_instance"
    end

    test "parses multiple HCL resources" do
      hcl = """
      resource "aws_vpc" "main" {
        cidr_block = "10.0.0.0/16"
      }

      resource "aws_subnet" "public" {
        vpc_id     = aws_vpc.main.id
        cidr_block = "10.0.1.0/24"
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(hcl)
      assert length(graph.vertices) == 2
    end

    test "extracts depends_on from HCL" do
      hcl = """
      resource "aws_instance" "web" {
        ami = "ami-12345678"
        depends_on = [aws_security_group.web]
      }

      resource "aws_security_group" "web" {
        name = "webserver"
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(hcl)
      assert length(graph.vertices) == 2
    end

    test "parses HCL with nested blocks" do
      hcl = """
      resource "aws_instance" "web" {
        ami           = "ami-12345678"
        instance_type = "t3.micro"

        tags = {
          Name = "webserver"
        }
      }
      """

      assert {:ok, %Graph{}} = Terraform.parse(hcl)
    end
  end

  describe "validate/1" do
    test "validates correct JSON" do
      json = ~s({"resources": []})
      assert :ok = Terraform.validate(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = Terraform.validate("{ invalid }")
    end

    test "validates balanced HCL braces" do
      hcl = """
      resource "aws_instance" "web" {
        ami = "ami-12345678"
      }
      """

      assert :ok = Terraform.validate(hcl)
    end

    test "returns error for unbalanced HCL braces" do
      hcl = """
      resource "aws_instance" "web" {
        ami = "ami-12345678"
      """

      assert {:error, {:hcl_parse_error, _}} = Terraform.validate(hcl)
    end
  end

  describe "resource type mapping" do
    test "maps GCP resources correctly" do
      json = """
      {
        "resources": [
          {"address": "google_compute_instance.vm", "type": "google_compute_instance", "name": "vm", "values": {}},
          {"address": "google_storage_bucket.data", "type": "google_storage_bucket", "name": "data", "values": {}},
          {"address": "google_compute_firewall.fw", "type": "google_compute_firewall", "name": "fw", "values": {}}
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)

      types = Enum.map(graph.vertices, & &1.type)
      assert :compute_instance_create in types
      assert :storage_bucket_create in types
      assert :firewall_rule in types
    end

    test "maps Azure resources correctly" do
      json = """
      {
        "resources": [
          {"address": "azurerm_linux_virtual_machine.vm", "type": "azurerm_linux_virtual_machine", "name": "vm", "values": {}},
          {"address": "azurerm_storage_account.storage", "type": "azurerm_storage_account", "name": "storage", "values": {}},
          {"address": "azurerm_virtual_network.vnet", "type": "azurerm_virtual_network", "name": "vnet", "values": {}}
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)

      types = Enum.map(graph.vertices, & &1.type)
      assert :compute_instance_create in types
      assert :storage_bucket_create in types
      assert :network_create in types
    end

    test "maps Kubernetes resources correctly" do
      json = """
      {
        "resources": [
          {"address": "kubernetes_deployment.app", "type": "kubernetes_deployment", "name": "app", "values": {}},
          {"address": "kubernetes_service.svc", "type": "kubernetes_service", "name": "svc", "values": {}}
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)

      types = Enum.map(graph.vertices, & &1.type)
      assert :container_deployment_create in types
      assert :service_create in types
    end

    test "uses fallback for unknown resource types" do
      json = """
      {
        "resources": [
          {"address": "custom_resource.example", "type": "custom_resource", "name": "example", "values": {}}
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      [op] = graph.vertices
      assert op.type == :"terraform.custom_resource"
    end
  end

  describe "dependency extraction" do
    test "extracts explicit depends_on dependencies" do
      json = """
      {
        "resources": [
          {"address": "aws_vpc.main", "type": "aws_vpc", "name": "main", "values": {}},
          {"address": "aws_subnet.public", "type": "aws_subnet", "name": "public", "values": {}, "depends_on": ["aws_vpc.main"]}
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      assert length(graph.edges) >= 1

      dep = Enum.find(graph.edges, &(&1.type == :depends_on))
      assert dep != nil
    end

    test "extracts implicit dependencies from resource references" do
      json = """
      {
        "resources": [
          {"address": "aws_vpc.main", "type": "aws_vpc", "name": "main", "values": {"cidr_block": "10.0.0.0/16"}},
          {"address": "aws_subnet.public", "type": "aws_subnet", "name": "public", "values": {"vpc_id": "${aws_vpc.main.id}"}}
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      assert length(graph.edges) >= 1
    end

    test "deduplicates dependencies" do
      json = """
      {
        "resources": [
          {"address": "aws_vpc.main", "type": "aws_vpc", "name": "main", "values": {}},
          {"address": "aws_subnet.public", "type": "aws_subnet", "name": "public", "values": {"vpc_id": "${aws_vpc.main.id}"}, "depends_on": ["aws_vpc.main"]}
        ]
      }
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      # Should have 1 dependency even though it's referenced twice
      unique_deps =
        graph.edges
        |> Enum.map(fn d -> {d.from, d.to} end)
        |> Enum.uniq()

      assert length(unique_deps) == 1
    end
  end

  describe "metadata extraction" do
    test "includes source information in metadata" do
      json = """
      {"resources": [{"address": "aws_instance.web", "type": "aws_instance", "name": "web", "values": {}}]}
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      [op] = graph.vertices

      assert op.metadata.source == :terraform
      assert op.metadata.resource_type == "aws_instance"
      assert op.metadata.resource_name == "web"
      assert op.metadata.address == "aws_instance.web"
    end

    test "includes target information with provider" do
      json = """
      {"resources": [{"address": "aws_instance.web", "type": "aws_instance", "name": "web", "values": {"region": "us-west-2"}}]}
      """

      assert {:ok, %Graph{} = graph} = Terraform.parse(json)
      [op] = graph.vertices

      assert op.target.provider == :aws
      assert op.target.region == "us-west-2"
      assert op.target.resource_address == "aws_instance.web"
    end

    test "graph metadata includes format and timestamp" do
      json = ~s({"resources": []})
      assert {:ok, %Graph{} = graph} = Terraform.parse(json)

      assert graph.metadata.source == :terraform
      assert graph.metadata.format == :json
      assert %DateTime{} = graph.metadata.parsed_at
    end
  end
end
