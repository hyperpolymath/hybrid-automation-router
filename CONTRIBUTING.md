# Contributing to HAR

Thank you for your interest in contributing to HAR (Hybrid Automation Router)! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [How to Contribute](#how-to-contribute)
- [Coding Standards](#coding-standards)
- [Testing Guidelines](#testing-guidelines)
- [Documentation](#documentation)
- [Commit Messages](#commit-messages)
- [Pull Request Process](#pull-request-process)
- [Community](#community)

## Code of Conduct

This project adheres to a Code of Conduct (see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)). By participating, you are expected to uphold this code.

## Getting Started

### Prerequisites

- Elixir 1.15+ and Erlang/OTP 26+
- Git
- Basic understanding of infrastructure automation (Ansible, Salt, or Terraform)
- Familiarity with Elixir or functional programming helpful but not required

### Development Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/hybrid-automation-router
cd hybrid-automation-router

# Install dependencies
mix deps.get

# Compile the project
mix compile

# Run tests
mix test

# Run type checker
mix dialyzer

# Run linter
mix credo

# Start interactive shell
iex -S mix
```

## How to Contribute

### Ways to Contribute

1. **Code Contributions**
   - Add support for new IaC tools (parsers/transformers)
   - Improve routing algorithms
   - Performance optimizations
   - Bug fixes

2. **Documentation**
   - Improve existing docs
   - Add tutorials and guides
   - Translate documentation
   - Fix typos or clarify explanations

3. **Testing**
   - Write unit tests
   - Add integration tests
   - Property-based testing
   - Performance benchmarks

4. **Design & UX**
   - CLI interface improvements
   - Web dashboard design
   - Error message clarity
   - User experience feedback

5. **Community**
   - Answer questions in discussions
   - Write blog posts or tutorials
   - Give talks about HAR
   - Help with code reviews

### Finding Issues to Work On

- Look for issues labeled `good first issue` for beginners
- Issues labeled `help wanted` are ready for contribution
- Check the [Project Board](../../projects) for planned features

## Coding Standards

### Elixir Style Guide

Follow the [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide):

```elixir
# Good
def parse(content, opts \\ []) do
  with {:ok, yaml} <- YamlElixir.read_from_string(content),
       {:ok, operations} <- extract_operations(yaml) do
    {:ok, operations}
  end
end

# Bad (inconsistent style, no docs)
def parse(c,o\\[]),do: YamlElixir.read_from_string(c)|>extract_operations()
```

### Key Conventions

1. **Module Organization**
   - Public API functions first
   - Private functions at bottom
   - Group related functions together

2. **Naming**
   - `snake_case` for variables and functions
   - `CamelCase` for modules
   - Descriptive names (avoid abbreviations)

3. **Documentation**
   - All public functions need `@doc`
   - Include `@spec` for type contracts
   - Provide examples in `@doc`

4. **Error Handling**
   - Use `{:ok, result}` and `{:error, reason}` tuples
   - Pattern match on expected cases
   - Let it crash for unexpected errors (supervision trees)

### Example Module

```elixir
defmodule HAR.DataPlane.Parsers.Example do
  @moduledoc """
  Parser for Example IaC tool.

  Converts Example configuration to HAR semantic graph.
  """

  @behaviour HAR.DataPlane.Parser

  alias HAR.Semantic.{Graph, Operation}

  @doc """
  Parse Example configuration to semantic graph.

  ## Examples

      iex> parse("example config")
      {:ok, %Graph{}}

      iex> parse("invalid")
      {:error, :parse_failed}
  """
  @spec parse(String.t(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  def parse(content, opts \\ []) do
    # Implementation
  end

  # Private functions
  defp extract_operations(config) do
    # Implementation
  end
end
```

## Testing Guidelines

### Test Structure

```elixir
defmodule HAR.Semantic.GraphTest do
  use ExUnit.Case
  doctest HAR.Semantic.Graph

  alias HAR.Semantic.{Graph, Operation, Dependency}

  describe "new/1" do
    test "creates empty graph" do
      graph = Graph.new()
      assert Graph.empty?(graph)
    end

    test "creates graph with operations" do
      op = Operation.new(:package_install, %{package: "nginx"})
      graph = Graph.new(vertices: [op])
      assert Graph.operation_count(graph) == 1
    end
  end

  describe "topological_sort/1" do
    test "sorts operations by dependencies" do
      # Test implementation
    end

    test "detects circular dependencies" do
      # Test implementation
    end
  end
end
```

### Test Coverage

- Aim for >80% coverage on critical paths
- 100% coverage on security-sensitive code
- All public APIs must have tests
- Include edge cases and error conditions

### Running Tests

```bash
# All tests
mix test

# Single file
mix test test/semantic/graph_test.exs

# Single test
mix test test/semantic/graph_test.exs:42

# With coverage
mix test --cover

# Watch mode (with mix_test_watch)
mix test.watch
```

## Documentation

### Types of Documentation

1. **Code Documentation** (`@moduledoc`, `@doc`)
   - Module purpose and overview
   - Function behavior and examples
   - Type specifications

2. **Architecture Docs** (`docs/`)
   - Design decisions
   - System architecture
   - Integration guides

3. **User Guides** (`README.md`, tutorials)
   - Getting started
   - How-to guides
   - Examples and recipes

### Documentation Standards

- Write in clear, concise English
- Include code examples
- Link to related documentation
- Keep docs up-to-date with code

### Generating Docs

```bash
# Generate HTML documentation
mix docs

# View in browser
open doc/index.html
```

## Commit Messages

### Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style (formatting, no logic change)
- `refactor`: Code refactoring
- `perf`: Performance improvement
- `test`: Adding or updating tests
- `chore`: Build process, dependencies, etc.

### Examples

```
feat(parser): add Terraform HCL parser

- Implement HCL parsing via external terraform command
- Extract resources and dependencies
- Map to semantic graph operations

Closes #42
```

```
fix(routing): handle empty routing table gracefully

Previously crashed on empty YAML file. Now returns
default passthrough route.

Fixes #123
```

### Guidelines

- Use imperative mood ("add" not "added")
- First line ≤50 characters
- Body wrapped at 72 characters
- Reference issues/PRs in footer
- Explain *why*, not just *what*

## Pull Request Process

### Before Submitting

1. ✅ Tests pass (`mix test`)
2. ✅ Linter passes (`mix credo`)
3. ✅ Dialyzer passes (`mix dialyzer`)
4. ✅ Documentation updated
5. ✅ CHANGELOG.md updated (if user-facing)
6. ✅ Commits follow commit message guidelines

### PR Template

```markdown
## Description
Brief description of changes.

## Motivation
Why is this change needed?

## Changes
- List of changes made
- ...

## Testing
How was this tested?

## Screenshots (if applicable)
...

## Checklist
- [ ] Tests pass
- [ ] Docs updated
- [ ] CHANGELOG.md updated
- [ ] No breaking changes (or documented)
```

### Review Process

1. **Automated Checks**
   - CI runs tests, linter, type checker
   - Must pass before review

2. **Code Review**
   - At least one maintainer approval required
   - Address all review comments
   - Squash commits if needed

3. **Merge**
   - Maintainer merges when ready
   - PR author may merge if maintainer approved

### After Merge

- Delete feature branch
- Close related issues
- Update documentation site (if applicable)

## Community

### Communication Channels

- **GitHub Discussions:** Questions, ideas, show-and-tell
- **GitHub Issues:** Bug reports, feature requests
- **Discord:** Real-time chat (coming soon)

### Getting Help

- Read the [documentation](docs/)
- Search existing issues
- Ask in GitHub Discussions
- Join community calls (schedule TBD)

### Recognition

Contributors are recognized in:
- [MAINTAINERS.md](MAINTAINERS.md) (for core contributors)
- [CHANGELOG.md](CHANGELOG.md) (for specific contributions)
- Release notes
- Annual contributor report

## Adding Support for New Tools

### Parser Implementation

1. Create module: `lib/har/data_plane/parsers/your_tool.ex`
2. Implement `HAR.DataPlane.Parser` behaviour
3. Add pattern matching to normalize operations
4. Write tests in `test/data_plane/parsers/your_tool_test.exs`
5. Add example config in `examples/your_tool/`
6. Update documentation

### Transformer Implementation

1. Create module: `lib/har/data_plane/transformers/your_tool.ex`
2. Implement `HAR.DataPlane.Transformer` behaviour
3. Map operation types to target format
4. Write tests
5. Add example output
6. Update documentation

### Routing Rules

Add patterns to `priv/routing_table.yaml`:

```yaml
- pattern:
    operation: package_install
    target:
      os: your_os
  backends:
    - name: your_backend
      priority: 100
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

## Questions?

Don't hesitate to ask! We're here to help:
- Open a [GitHub Discussion](../../discussions)
- Comment on related issues
- Reach out to maintainers

Thank you for contributing to HAR! 🚀
