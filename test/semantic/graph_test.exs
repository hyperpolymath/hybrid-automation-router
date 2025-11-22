defmodule HAR.Semantic.GraphTest do
  use ExUnit.Case
  doctest HAR.Semantic.Graph

  alias HAR.Semantic.{Graph, Operation, Dependency}

  describe "new/1" do
    test "creates empty graph" do
      graph = Graph.new()

      assert graph.vertices == []
      assert graph.edges == []
      assert graph.metadata == %{}
    end

    test "creates graph with operations" do
      op1 = Operation.new(:package_install, %{package: "nginx"})
      op2 = Operation.new(:service_start, %{service: "nginx"})

      graph = Graph.new(vertices: [op1, op2])

      assert length(graph.vertices) == 2
      assert Graph.operation_count(graph) == 2
    end

    test "creates graph with dependencies" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, id: "op1")
      op2 = Operation.new(:service_start, %{service: "nginx"}, id: "op2")
      dep = Dependency.new("op1", "op2", :requires)

      graph = Graph.new(vertices: [op1, op2], edges: [dep])

      assert Graph.dependency_count(graph) == 1
    end

    test "creates graph with metadata" do
      graph = Graph.new(metadata: %{source: :ansible, parsed_at: DateTime.utc_now()})

      assert graph.metadata.source == :ansible
    end
  end

  describe "add_operation/2" do
    test "adds operation to graph" do
      graph = Graph.new()
      op = Operation.new(:package_install, %{package: "nginx"})

      graph = Graph.add_operation(graph, op)

      assert Graph.operation_count(graph) == 1
      assert hd(graph.vertices) == op
    end

    test "adds multiple operations" do
      graph = Graph.new()
      op1 = Operation.new(:package_install, %{package: "nginx"})
      op2 = Operation.new(:service_start, %{service: "nginx"})

      graph =
        graph
        |> Graph.add_operation(op1)
        |> Graph.add_operation(op2)

      assert Graph.operation_count(graph) == 2
    end
  end

  describe "add_dependency/2" do
    test "adds dependency to graph" do
      graph = Graph.new()
      dep = Dependency.new("op1", "op2", :requires)

      graph = Graph.add_dependency(graph, dep)

      assert Graph.dependency_count(graph) == 1
      assert hd(graph.edges) == dep
    end
  end

  describe "find_operation/2" do
    test "finds operation by ID" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, id: "op1")
      op2 = Operation.new(:service_start, %{service: "nginx"}, id: "op2")
      graph = Graph.new(vertices: [op1, op2])

      found = Graph.find_operation(graph, "op1")

      assert found == op1
    end

    test "returns nil for non-existent ID" do
      graph = Graph.new()

      assert Graph.find_operation(graph, "nonexistent") == nil
    end
  end

  describe "operations_by_type/2" do
    test "filters operations by type" do
      op1 = Operation.new(:package_install, %{package: "nginx"})
      op2 = Operation.new(:package_install, %{package: "redis"})
      op3 = Operation.new(:service_start, %{service: "nginx"})
      graph = Graph.new(vertices: [op1, op2, op3])

      package_ops = Graph.operations_by_type(graph, :package_install)

      assert length(package_ops) == 2
      assert Enum.all?(package_ops, fn op -> op.type == :package_install end)
    end

    test "returns empty list for non-existent type" do
      graph = Graph.new()

      assert Graph.operations_by_type(graph, :nonexistent) == []
    end
  end

  describe "dependencies_for/2" do
    test "returns dependencies for an operation" do
      dep1 = Dependency.new("op1", "op2", :requires)
      dep2 = Dependency.new("op3", "op2", :requires)
      graph = Graph.new(edges: [dep1, dep2])

      deps = Graph.dependencies_for(graph, "op2")

      assert length(deps) == 2
    end

    test "returns empty list for operation without dependencies" do
      graph = Graph.new()

      assert Graph.dependencies_for(graph, "op1") == []
    end
  end

  describe "topological_sort/1" do
    test "sorts operations in dependency order" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, id: "op1")
      op2 = Operation.new(:service_start, %{service: "nginx"}, id: "op2")
      dep = Dependency.new("op1", "op2", :requires)

      graph = Graph.new(vertices: [op2, op1], edges: [dep])

      {:ok, sorted} = Graph.topological_sort(graph)

      assert length(sorted) == 2
      # op1 should come before op2 (dependency order)
      assert Enum.at(sorted, 0).id == "op1"
      assert Enum.at(sorted, 1).id == "op2"
    end

    test "handles graph with no dependencies" do
      op1 = Operation.new(:package_install, %{package: "nginx"})
      op2 = Operation.new(:package_install, %{package: "redis"})
      graph = Graph.new(vertices: [op1, op2])

      {:ok, sorted} = Graph.topological_sort(graph)

      assert length(sorted) == 2
    end

    test "detects circular dependencies" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, id: "op1")
      op2 = Operation.new(:service_start, %{service: "nginx"}, id: "op2")
      # Circular dependency: op1 -> op2 -> op1
      dep1 = Dependency.new("op1", "op2", :requires)
      dep2 = Dependency.new("op2", "op1", :requires)

      graph = Graph.new(vertices: [op1, op2], edges: [dep1, dep2])

      assert {:error, :circular_dependency} = Graph.topological_sort(graph)
    end
  end

  describe "validate/1" do
    test "validates graph with valid operations and dependencies" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, id: "op1")
      op2 = Operation.new(:service_start, %{service: "nginx"}, id: "op2")
      dep = Dependency.new("op1", "op2", :requires)

      graph = Graph.new(vertices: [op1, op2], edges: [dep])

      assert Graph.validate(graph) == :ok
    end

    test "fails validation for invalid dependency references" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, id: "op1")
      dep = Dependency.new("op1", "nonexistent", :requires)

      graph = Graph.new(vertices: [op1], edges: [dep])

      assert {:error, {:invalid_references, _}} = Graph.validate(graph)
    end

    test "fails validation for circular dependencies" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, id: "op1")
      op2 = Operation.new(:service_start, %{service: "nginx"}, id: "op2")
      dep1 = Dependency.new("op1", "op2", :requires)
      dep2 = Dependency.new("op2", "op1", :requires)

      graph = Graph.new(vertices: [op1, op2], edges: [dep1, dep2])

      assert {:error, :circular_dependency} = Graph.validate(graph)
    end

    test "fails validation for invalid operations" do
      # Operation without required parameter
      op = Operation.new(:package_install, %{}, id: "op1")
      graph = Graph.new(vertices: [op])

      assert {:error, {:invalid_operations, _}} = Graph.validate(graph)
    end
  end

  describe "partition_by/2" do
    test "partitions graph by operation type" do
      op1 = Operation.new(:package_install, %{package: "nginx"})
      op2 = Operation.new(:package_install, %{package: "redis"})
      op3 = Operation.new(:service_start, %{service: "nginx"})

      graph = Graph.new(vertices: [op1, op2, op3])

      partitions = Graph.partition_by(graph, fn op -> op.type end)

      assert length(partitions) == 2
      assert Enum.any?(partitions, fn {key, _subgraph} -> key == :package_install end)
      assert Enum.any?(partitions, fn {key, _subgraph} -> key == :service_start end)
    end

    test "partitions graph by target OS" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, target: %{os: "debian"})
      op2 = Operation.new(:package_install, %{package: "redis"}, target: %{os: "redhat"})

      graph = Graph.new(vertices: [op1, op2])

      partitions = Graph.partition_by(graph, fn op -> op.target[:os] end)

      assert length(partitions) == 2
    end
  end

  describe "merge/1" do
    test "merges multiple graphs" do
      op1 = Operation.new(:package_install, %{package: "nginx"}, id: "op1")
      op2 = Operation.new(:package_install, %{package: "redis"}, id: "op2")
      op3 = Operation.new(:service_start, %{service: "nginx"}, id: "op3")

      graph1 = Graph.new(vertices: [op1])
      graph2 = Graph.new(vertices: [op2, op3])

      merged = Graph.merge([graph1, graph2])

      assert Graph.operation_count(merged) == 3
    end

    test "deduplicates operations by ID when merging" do
      op = Operation.new(:package_install, %{package: "nginx"}, id: "op1")

      graph1 = Graph.new(vertices: [op])
      graph2 = Graph.new(vertices: [op])

      merged = Graph.merge([graph1, graph2])

      assert Graph.operation_count(merged) == 1
    end
  end

  describe "empty?/1" do
    test "returns true for empty graph" do
      graph = Graph.new()

      assert Graph.empty?(graph) == true
    end

    test "returns false for non-empty graph" do
      op = Operation.new(:package_install, %{package: "nginx"})
      graph = Graph.new(vertices: [op])

      assert Graph.empty?(graph) == false
    end
  end
end
