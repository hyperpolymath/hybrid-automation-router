defmodule HAR.Semantic.OperationTest do
  use ExUnit.Case
  doctest HAR.Semantic.Operation

  alias HAR.Semantic.Operation

  describe "new/3" do
    test "creates operation with generated ID" do
      op = Operation.new(:package_install, %{package: "nginx"})

      assert op.type == :package_install
      assert op.params == %{package: "nginx"}
      assert is_binary(op.id)
      assert String.length(op.id) == 36  # UUID format
    end

    test "creates operation with custom ID" do
      op = Operation.new(:package_install, %{package: "nginx"}, id: "custom_id")

      assert op.id == "custom_id"
    end

    test "creates operation with target" do
      op = Operation.new(
        :package_install,
        %{package: "nginx"},
        target: %{os: "debian", arch: "amd64"}
      )

      assert op.target.os == "debian"
      assert op.target.arch == "amd64"
    end

    test "creates operation with metadata" do
      op = Operation.new(
        :package_install,
        %{package: "nginx"},
        metadata: %{source: :ansible, task_name: "Install nginx"}
      )

      assert op.metadata.source == :ansible
      assert op.metadata.task_name == "Install nginx"
    end
  end

  describe "validate/1" do
    test "validates package_install operation" do
      op = Operation.new(:package_install, %{package: "nginx"})
      assert Operation.validate(op) == :ok
    end

    test "validates package_install with name instead of package" do
      op = Operation.new(:package_install, %{name: "nginx"})
      assert Operation.validate(op) == :ok
    end

    test "fails validation for package_install without package" do
      op = Operation.new(:package_install, %{})
      assert {:error, {:missing_param, :package}} = Operation.validate(op)
    end

    test "validates service_start operation" do
      op = Operation.new(:service_start, %{service: "nginx"})
      assert Operation.validate(op) == :ok
    end

    test "fails validation for service_start without service" do
      op = Operation.new(:service_start, %{})
      assert {:error, {:missing_param, :service}} = Operation.validate(op)
    end

    test "validates file_write operation with path and content" do
      op = Operation.new(:file_write, %{path: "/etc/nginx/nginx.conf", content: "config"})
      assert Operation.validate(op) == :ok
    end

    test "validates file_write operation with path and source" do
      op = Operation.new(:file_write, %{path: "/etc/nginx/nginx.conf", source: "nginx.conf"})
      assert Operation.validate(op) == :ok
    end

    test "fails validation for file_write without path" do
      op = Operation.new(:file_write, %{content: "config"})
      assert {:error, {:missing_param, :path}} = Operation.validate(op)
    end

    test "fails validation for file_write without content or source" do
      op = Operation.new(:file_write, %{path: "/etc/nginx/nginx.conf"})
      assert {:error, {:missing_param, :content_or_source}} = Operation.validate(op)
    end

    test "validates unknown operation types" do
      op = Operation.new(:custom_operation, %{custom: "param"})
      assert Operation.validate(op) == :ok
    end
  end

  describe "to_string/1" do
    test "converts operation to string representation" do
      op = Operation.new(:package_install, %{package: "nginx", version: "1.18"})
      string_repr = Operation.to_string(op)

      assert string_repr =~ "package_install"
      assert string_repr =~ "nginx"
    end
  end

  describe "UUID generation" do
    test "generates unique IDs" do
      op1 = Operation.new(:package_install, %{package: "nginx"})
      op2 = Operation.new(:package_install, %{package: "nginx"})

      assert op1.id != op2.id
    end

    test "generates valid UUID v4 format" do
      op = Operation.new(:package_install, %{package: "nginx"})

      # UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      assert op.id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end
  end
end
