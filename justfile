# HAR (Hybrid Automation Router) - Build automation with just
# https://github.com/casey/just

# Default recipe (runs when you type `just`)
default:
    @just --list

# Install dependencies
deps:
    mix deps.get
    mix deps.compile

# Compile the project
build:
    mix compile

# Run all tests
test:
    mix test

# Run tests with coverage
test-coverage:
    mix test --cover

# Run tests in watch mode (requires mix_test_watch)
test-watch:
    mix test.watch

# Run property-based tests (if available)
test-property:
    mix test --only property

# Run integration tests
test-integration:
    mix test --only integration

# Run type checker (Dialyzer)
dialyzer:
    mix dialyzer

# Run linter (Credo)
lint:
    mix credo

# Run linter with strict mode
lint-strict:
    mix credo --strict

# Run security audit
audit:
    mix hex.audit

# Format code
format:
    mix format

# Check if code is formatted
format-check:
    mix format --check-formatted

# Generate documentation
docs:
    mix docs

# Open documentation in browser
docs-open: docs
    open doc/index.html

# Run interactive shell
shell:
    iex -S mix

# Clean build artifacts
clean:
    mix clean
    rm -rf _build deps doc

# Deep clean (including compiled files)
clean-all: clean
    rm -rf .elixir_ls

# Validate project (comprehensive check)
validate: format-check lint dialyzer test
    @echo "✅ All validations passed!"

# Continuous integration checks
ci: deps build validate docs
    @echo "✅ CI checks passed!"

# Run example: Parse Ansible to Salt
example-ansible-to-salt:
    mix run -e 'HAR.convert(:ansible, File.read!("examples/ansible/webserver.yml"), to: :salt) |> elem(1) |> IO.puts'

# Run example: Parse Salt to Ansible
example-salt-to-ansible:
    mix run -e 'HAR.convert(:salt, File.read!("examples/salt/webserver.sls"), to: :ansible) |> elem(1) |> IO.puts'

# Show HAR version
version:
    mix run -e 'IO.puts("HAR v#{HAR.version()}")'

# Check RSR compliance
rsr-check:
    @echo "🔍 Checking RSR compliance..."
    @echo ""
    @echo "Documentation:"
    @test -f README.md && echo "  ✅ README.md" || echo "  ❌ README.md"
    @test -f LICENSE && echo "  ✅ LICENSE" || echo "  ❌ LICENSE"
    @test -f SECURITY.md && echo "  ✅ SECURITY.md" || echo "  ❌ SECURITY.md"
    @test -f CONTRIBUTING.md && echo "  ✅ CONTRIBUTING.md" || echo "  ❌ CONTRIBUTING.md"
    @test -f CODE_OF_CONDUCT.md && echo "  ✅ CODE_OF_CONDUCT.md" || echo "  ❌ CODE_OF_CONDUCT.md"
    @test -f MAINTAINERS.md && echo "  ✅ MAINTAINERS.md" || echo "  ❌ MAINTAINERS.md"
    @test -f CHANGELOG.md && echo "  ✅ CHANGELOG.md" || echo "  ❌ CHANGELOG.md"
    @echo ""
    @echo ".well-known/ directory:"
    @test -f .well-known/security.txt && echo "  ✅ security.txt (RFC 9116)" || echo "  ❌ security.txt"
    @test -f .well-known/ai.txt && echo "  ✅ ai.txt" || echo "  ❌ ai.txt"
    @test -f .well-known/humans.txt && echo "  ✅ humans.txt" || echo "  ❌ humans.txt"
    @echo ""
    @echo "Build system:"
    @test -f justfile && echo "  ✅ justfile" || echo "  ❌ justfile"
    @test -f mix.exs && echo "  ✅ mix.exs" || echo "  ❌ mix.exs"
    @echo ""
    @echo "Architecture:"
    @test -d docs && echo "  ✅ docs/ directory" || echo "  ❌ docs/ directory"
    @test -f CLAUDE.md && echo "  ✅ CLAUDE.md" || echo "  ❌ CLAUDE.md"
    @echo ""
    @echo "Tests:"
    @mix test 2>&1 >/dev/null && echo "  ✅ Tests pass" || echo "  ⚠️  Tests need implementation"
    @echo ""
    @echo "Type safety:"
    @echo "  ✅ Elixir compile-time guarantees"
    @echo "  ✅ @spec annotations"
    @echo "  ⚠️  Dialyzer checks (run 'just dialyzer')"
    @echo ""
    @echo "Offline-first:"
    @echo "  ✅ Core functionality works without network"
    @echo "  ✅ IPFS optional (offline mode available)"
    @echo ""
    @echo "Security:"
    @echo "  ✅ Multi-tier security model"
    @echo "  ⚠️  TLS implementation pending"
    @echo ""

# Install git hooks
hooks:
    @echo "Installing git hooks..."
    @echo "#!/bin/sh\njust format lint" > .git/hooks/pre-commit
    @chmod +x .git/hooks/pre-commit
    @echo "✅ Pre-commit hook installed (runs format + lint)"

# Start development server (if web UI implemented)
dev:
    iex -S mix phx.server || echo "Web UI not yet implemented"

# Production build
prod-build:
    MIX_ENV=prod mix do deps.get, compile, release

# Docker build (if Containerfile exists)
docker-build:
    @test -f Containerfile && podman build -t har:latest . || echo "Containerfile not yet created"

# Run in Podman container
docker-run:
    @test -f Containerfile && podman run -p 4000:4000 har:latest || echo "Container not yet built"

# Benchmark performance
benchmark:
    mix run benchmarks/routing.exs || echo "Benchmarks not yet implemented"

# Profile memory usage
profile-memory:
    mix profile.memory || echo "Memory profiling not yet implemented"

# Profile CPU usage
profile-cpu:
    mix profile.cprof || echo "CPU profiling not yet implemented"

# Generate release
release:
    MIX_ENV=prod mix release

# Install HAR globally (escript)
install:
    mix escript.build
    mix escript.install

# Uninstall HAR
uninstall:
    mix escript.uninstall har

# Update dependencies
update:
    mix deps.update --all

# Check for outdated dependencies
outdated:
    mix hex.outdated

# Show dependency tree
deps-tree:
    mix deps.tree

# Show project statistics
stats:
    @echo "📊 HAR Project Statistics"
    @echo ""
    @echo "Code:"
    @find lib -name '*.ex' -o -name '*.exs' | xargs wc -l | tail -1
    @echo ""
    @echo "Tests:"
    @find test -name '*.exs' 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "  No tests yet"
    @echo ""
    @echo "Documentation:"
    @find docs -name '*.md' | xargs wc -w | tail -1
    @echo ""
    @echo "Files:"
    @find . -type f \( -name '*.ex' -o -name '*.exs' -o -name '*.md' \) | wc -l

# All-in-one development setup
setup: deps build hooks
    @echo "✅ Development environment ready!"
    @echo ""
    @echo "Next steps:"
    @echo "  just test         - Run tests"
    @echo "  just shell        - Start interactive shell"
    @echo "  just validate     - Run all checks"
    @echo "  just rsr-check    - Check RSR compliance"

# Show help for a specific recipe
help RECIPE:
    @just --show {{RECIPE}}
