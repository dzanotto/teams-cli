# Repository Guidelines

## Project Structure & Module Organization

This dependency-free Swift package targets macOS 13+ and requires Swift 6+.
- `Sources/TeamsCLI/`: process entry point, argument parsing, help, text/JSON output, and exit codes.
- `Sources/TeamsCore/`: Accessibility readers, state classifiers, control-specific controllers, and shared action/focus handling.
- `Tests/TeamsCoreTests/`: XCTest suites with fake backends and scripted Accessibility observations.
- `Tests/TeamsCLITests/`: CLI contracts with fake command handlers and executable smoke tests.
- `Package.swift`: package targets; `README.md`: command contracts and validation evidence. Build artifacts belong in ignored `.build/`; there is no asset directory.

## Build, Test, and Development Commands

Run from the repository root:
- `swift build`: build the debug executable.
- `swift build -c release`: build `.build/release/teams-cli`.
- `swift run teams-cli --help`: build and inspect CLI usage without changing Teams state.
- `swift test`: run all automated tests.
- `swift test --filter HandControllerTests`: run a focused XCTest suite.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, same-line opening braces, `UpperCamelCase` types, and `lowerCamelCase` functions/properties. Name files after their primary type or responsibility, such as `HandController.swift`. Keep CLI presentation in `TeamsCLI` and reusable behavior in `TeamsCore`; reuse shared media infrastructure. Preserve documented snake_case JSON keys and reason strings. No formatter or linter is configured.

## Testing Guidelines

Use XCTest classes named `<Feature>Tests` and descriptive `test...` methods. Exercise behavior through fake backends and virtual time where appropriate. Cover state transitions, no-ops, held/ambiguous calls, incomplete reads, target replacement, focus changes, timeouts, and uncertain outcomes. No numeric coverage threshold is configured. Run `swift test` and a release build for code changes; distinguish automated evidence from live validation.

## Commit & Pull Request Guidelines

History uses concise imperative subjects, such as `Add hand toggle command with verified state changes`; follow that style. Keep commits focused. PRs should explain the behavior change, relevant issues, checks run, and remaining limitations. Update `README.md` and CLI help when commands, JSON, or exit codes change.

## Accessibility & Action Safety

Preserve focus for microphone, camera, and hand actions; call end permits focus changes. Never activate Teams, inject input, restore focus, or retry an uncertain press. Preserve shared locking, target identity checks, bounded polling, and two consecutive verification observations. AXPress success alone cannot confirm completion. Live state-changing validation requires explicit user authorization; use automated tests by default.
