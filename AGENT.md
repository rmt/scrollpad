# Purpose

This document defines coding conventions and tooling for the TUI repository.
Follow these rules for new code, reviews, and PRs.

# Code Structure

scrollpad.nim: the scrolling terminal implementation
example.nim: an example of how to use scrollpad as a module
myterm.nim: an early experiment
getch.c & key.nim: raw keyboard event handling

# Coding Conventions

## Code layout (required order)

A Nim source file must follow this order (exactly):
1. imports
2. type definitions
3. constants
4. variables
5. procedures
6. when isMainModule (optional)

## Naming & Style

- Use short descriptive names (camelCase for procs/vars, PascalCase for consts)
- Group related functions together
- Prefer functions <= 25 lines. If longer, split into helpers.
- Keep each function focused and testable.
- Ensure that error handling is implemented to manage unexpected situations gracefully.

## Formatting & Tools

- Use 2-space indentation.
- Align `of` with `case`
- Run `nimpretty` or `nim fmt` (if available) before committing
- Use `make scrollpad` to build the project
- Add an editor config or formatter config to enforce whitespace rules
- Use consistent indentation and spacing to enhance code readability.
- When modifying lines, keep the same indent.

## Comments & Documentation

- Include comments to explain complex logic or decisions made in the code, but
  avoid over-commenting obvious code.
- Review and update documentation to reflect any changes made to the codebase.

## Tests & CI

- Write unit tests for public helpers

# Notes

- Keep changes minimal and readable
- Regularly refactor for clarity and remove duplication
