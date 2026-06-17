# Repository Guidelines

## Build, Test, and Development Commands

- `zig build --summary all`: build the debug binary at `zig-out/bin/zoreman`.
- `zig build -Doptimize=ReleaseSafe --summary all`: produce a release-safe build.
- `zig build test`: run Zig unit tests from `src/tests.zig`.
- `zig build run -- start`: build and run zoreman with arguments after `--`.
- `zig fmt --check build.zig src/*.zig`: verify formatting before review.

## Coding Style & Naming Conventions

Follow `zig fmt` output. Use four-space indentation, `snake_case` for functions, variables, and files, and `PascalCase` for public types such as structs. Keep modules focused: CLI parsing should stay in CLI/config modules, process lifecycle logic in `supervisor.zig`, and wire protocol details in `rpc_proto.zig`.

## Testing Guidelines

Add tests for parser, config, environment, supervisor, and RPC behavior when touching those areas. Prefer small unit tests for pure logic and temporary-directory integration tests for CLI or process behavior. Name tests by behavior, for example `test "procfile skips comments"` or `test "run status marks running processes"`. Every fix for a reproduced bug should include a regression test.

## Commit & Pull Request Guidelines

Recent history uses short imperative summaries such as `Migrate to Zig 0.16` and `Bump version`; follow that style. Commit messages should be one sentence, capitalized, and without Conventional Commit prefixes. Keep commits scoped to one logical change. Pull requests should include a concise description, linked issue if any, test commands run, and notes about behavior changes. Include terminal output snippets for CLI-visible changes; screenshots are not required.

## Agent-Specific Notes

Preserve user work in the tree. Do not revert unrelated changes. Never commit or push unless the user explicitly asks; if asked to commit, do not also push unless asked. Continue using `cova` for CLI parsing; fix configuration, adapters, or tests rather than replacing it.
