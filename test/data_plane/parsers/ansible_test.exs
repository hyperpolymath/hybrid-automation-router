defmodule HAR.DataPlane.Parsers.AnsibleTest do
  use ExUnit.Case

  alias HAR.DataPlane.Parsers.Ansible
  alias HAR.Semantic.{Graph, Operation}

  describe "parse/2" do
    test "parses simple playbook with single task" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Install nginx
            apt:
              name: nginx
              state: present
      """

      {:ok, graph} = Ansible.parse(yaml)

      assert Graph.operation_count(graph) == 1
      op = hd(graph.vertices)
      assert op.type == :package_install
      assert op.params.package == "nginx"
      assert op.metadata.task_name == "Install nginx"
    end

    test "parses playbook with multiple tasks" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Install nginx
            apt:
              name: nginx
              state: present
          - name: Start nginx
            service:
              name: nginx
              state: started
      """

      {:ok, graph} = Ansible.parse(yaml)

      assert Graph.operation_count(graph) == 2

      ops = graph.vertices
      assert Enum.any?(ops, fn op -> op.type == :package_install end)
      assert Enum.any?(ops, fn op -> op.type == :service_start end)
    end

    test "creates sequential dependencies between tasks" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Install nginx
            apt:
              name: nginx
              state: present
          - name: Start nginx
            service:
              name: nginx
              state: started
      """

      {:ok, graph} = Ansible.parse(yaml)

      assert Graph.dependency_count(graph) == 1
      dep = hd(graph.edges)
      assert dep.type == :sequential
    end

    test "handles package state: present" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Install nginx
            apt:
              name: nginx
              state: present
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.params.state == :install
    end

    test "handles package state: absent" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Remove nginx
            apt:
              name: nginx
              state: absent
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.params.state == :remove
    end

    test "handles package state: latest" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Upgrade nginx
            apt:
              name: nginx
              state: latest
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.params.state == :upgrade
    end

    test "handles service started state" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Start nginx
            service:
              name: nginx
              state: started
              enabled: yes
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.type == :service_start
      assert op.params.service == "nginx"
      assert op.params.state == :start
      assert op.params.enabled == "yes"
    end

    test "handles copy module" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Copy config
            copy:
              src: nginx.conf
              dest: /etc/nginx/nginx.conf
              mode: '0644'
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.type == :file_copy
      assert op.params.source == "nginx.conf"
      assert op.params.destination == "/etc/nginx/nginx.conf"
      assert op.params.mode == "0644"
    end

    test "handles file module" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Create directory
            file:
              path: /var/www/html
              state: directory
              mode: '0755'
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.type == :file_write
      assert op.params.path == "/var/www/html"
    end

    test "handles user module" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Create user
            user:
              name: deployer
              shell: /bin/bash
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.type == :user_create
      assert op.params.name == "deployer"
      assert op.params.shell == "/bin/bash"
    end

    test "handles command module" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Run command
            command: systemctl status nginx
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.type == :command_run
      assert op.params.command =~ "systemctl"
    end

    test "extracts target information" do
      yaml = """
      - hosts: production
        tasks:
          - name: Install nginx
            apt:
              name: nginx
              state: present
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.metadata.hosts == "production"
      assert op.target.environment == :prod
    end

    test "sets metadata with source information" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Install nginx
            apt:
              name: nginx
              state: present
      """

      {:ok, graph} = Ansible.parse(yaml)
      op = hd(graph.vertices)

      assert op.metadata.source == :ansible
      assert is_map(op.metadata.original_task)
    end

    test "returns error for invalid YAML" do
      yaml = """
      invalid: [yaml: content
      """

      assert {:error, {:yaml_parse_error, _}} = Ansible.parse(yaml)
    end
  end

  describe "validate/1" do
    test "validates correct YAML" do
      yaml = """
      - hosts: webservers
        tasks:
          - name: Install nginx
            apt:
              name: nginx
      """

      assert :ok = Ansible.validate(yaml)
    end

    test "fails validation for invalid YAML" do
      yaml = "invalid: [yaml"

      assert {:error, {:yaml_parse_error, _}} = Ansible.validate(yaml)
    end
  end
end
