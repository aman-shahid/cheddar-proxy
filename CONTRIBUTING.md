# Contributing to Cheddar Proxy

Thank you for your interest in contributing to Cheddar Proxy! We welcome contributions from the community and are grateful for any help you can provide.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [How to Contribute](#how-to-contribute)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Reporting Bugs](#reporting-bugs)
- [Suggesting Features](#suggesting-features)
- [Community](#community)

## Community Expectations

Please be respectful, inclusive, and considerate in all interactions. We expect contributors to welcome differing viewpoints, accept constructive feedback, and focus on what is best for the community.

## Getting Started

Cheddar Proxy is a cross-platform network traffic inspector built with:

- **Rust** - Core proxy engine (`core/`)
- **Flutter** - Desktop UI (`ui/`)
- **MCP** - Model Context Protocol for AI agent integration

### Prerequisites

Before contributing, ensure you have:

- **Rust** (latest stable) - [Install Rust](https://rustup.rs/)
- **Flutter** (3.19+) - [Install Flutter](https://flutter.dev/docs/get-started/install)
- **Xcode** (macOS) or **Visual Studio** (Windows) for native builds
- **Git** for version control

## Development Setup

### 1. Clone the Repository

```bash
git clone https://github.com/aman-shahid/cheddarproxy.git
cd cheddarproxy
```

### 2. Build the Rust Core

```bash
cd core
cargo build
```

### 3. Set Up Flutter

```bash
cd ui
flutter pub get
```

### 4. Generate Rust-Flutter Bindings

```bash
# From the project root
./scripts/build_rust.sh
```

### 5. Run the Application

```bash
cd ui
flutter run -d macos  # or -d windows, -d linux
```

## How to Contribute

### Types of Contributions

We welcome many types of contributions:

- 🐛 **Bug fixes** - Fix issues and improve stability
- ✨ **New features** - Add new functionality
- 📝 **Documentation** - Improve docs, add examples
- 🧪 **Tests** - Add or improve test coverage
- 🎨 **UI/UX improvements** - Enhance the user interface
- 🔧 **Build/tooling** - Improve the development experience
- 🌐 **Translations** - Help localize the app

### Finding Issues to Work On

- Look for issues labeled `good first issue` for beginner-friendly tasks
- Check `help wanted` for issues where we need community help
- Browse open issues and comment if you'd like to work on one

## Pull Request Process

### 1. Fork and Branch

```bash
# Fork the repository on GitHub, then:
git clone https://github.com/YOUR-USERNAME/cheddarproxy.git
cd cheddarproxy
git checkout -b feature/your-feature-name
```

### 2. Make Your Changes

- Write clean, readable code
- Follow the coding standards (see below)
- Add tests for new functionality
- Update documentation as needed

### 3. Test Your Changes

```bash
# Run Rust tests
cd core
cargo test

# Run Flutter tests (if applicable)
cd ui
flutter test
```

### 4. Commit Your Changes

Write clear, descriptive commit messages:

```bash
git commit -m "feat: add WebSocket message filtering"
```

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `style:` - Code style changes (formatting, etc.)
- `refactor:` - Code refactoring
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks

### 5. Push and Create PR

```bash
git push origin feature/your-feature-name
```

Then create a Pull Request on GitHub with:

- A clear title describing the change
- A description explaining what and why
- Reference to any related issues (e.g., "Fixes #123")
- Screenshots for UI changes

### 6. Review Process

- Maintainers will review your PR
- Address any requested changes
- Once approved, your PR will be merged

## Coding Standards

### Rust

- Follow [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)
- Use `cargo fmt` for formatting
- Use `cargo clippy` for linting
- Write documentation comments for public APIs
- Include unit tests for new functionality

```rust
/// Parses an HTTP request from raw bytes.
/// 
/// # Arguments
/// * `data` - Raw HTTP request bytes
/// 
/// # Returns
/// Parsed request or error if malformed
pub fn parse_request(data: &[u8]) -> Result<Request, ParseError> {
    // Implementation
}
```

### Flutter/Dart

- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart)
- Use `dart format` for formatting
- Use `dart analyze` for linting
- Prefer composition over inheritance
- Keep widgets focused and reusable

```dart
/// Widget that displays a single HTTP transaction row.
class TransactionRow extends StatelessWidget {
  final HttpTransaction transaction;
  final VoidCallback? onTap;

  const TransactionRow({
    required this.transaction,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // Implementation
  }
}
```

### General Guidelines

- Keep functions/methods small and focused
- Use meaningful variable and function names
- Comment complex logic, but prefer self-documenting code
- Handle errors gracefully
- Consider performance implications

## Reporting Bugs

When reporting bugs, please include:

1. **Description** - What happened?
2. **Expected behavior** - What should have happened?
3. **Steps to reproduce** - How can we recreate the issue?
4. **Environment** - OS, version, etc.
5. **Screenshots/logs** - If applicable

Use the bug report template when creating issues.

## Suggesting Features

We love feature suggestions! When proposing new features:

1. **Check existing issues** - It may already be suggested
2. **Describe the problem** - What pain point does this solve?
3. **Propose a solution** - How would you like it to work?
4. **Consider alternatives** - Are there other approaches?

Use the feature request template when creating issues.

## Project Structure

```
cheddarproxy/
├── core/      # Rust proxy engine
│   ├── src/
│   │   ├── api/            # FFI API for Flutter
│   │   ├── mcp/            # MCP server implementation
│   │   ├── proxy/          # HTTP/HTTPS proxy logic
│   │   └── storage/        # HAR export/import
│   └── Cargo.toml
├── ui/   # Flutter desktop app
│   ├── lib/
│   │   ├── core/           # Core models and utilities
│   │   ├── features/       # Feature-specific widgets
│   │   └── widgets/        # Reusable widgets
│   └── pubspec.yaml
├── docs/                   # Documentation
├── scripts/                # Build and utility scripts
└── README.md
```

## Community

- **GitHub Issues** - Bug reports and feature requests
- **GitHub Discussions** - Questions and general discussion
- **Pull Requests** - Code contributions

## License

By contributing to Cheddar Proxy, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to Cheddar Proxy! 🧀
