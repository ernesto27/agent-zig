# system-prompt

## Purpose

Load and assemble the base system prompt sent to the LLM, including project-local override resolution and context-file layering.

## Requirements

### Requirement: Project-local system prompt override

The system SHALL allow a project to replace the built-in base system prompt (`src/prompts/system.txt`) by placing a `SYSTEM.md` file in the current working directory.

#### Scenario: Override replaces built-in prompt

- **WHEN** a `SYSTEM.md` file exists in the current working directory
- **THEN** the system SHALL use the contents of `SYSTEM.md` as the base system prompt in place of `src/prompts/system.txt`

#### Scenario: No override falls back to built-in prompt

- **WHEN** no `SYSTEM.md` file exists in the current working directory
- **THEN** the system SHALL use the contents of `src/prompts/system.txt` as the base system prompt, unchanged from prior behavior

### Requirement: AGENTS.md appended after override

The system SHALL append `AGENTS.md` to the base system prompt regardless of whether the base came from `SYSTEM.md` or `src/prompts/system.txt`.

#### Scenario: AGENTS.md appended when override is active

- **WHEN** both `SYSTEM.md` and `AGENTS.md` exist in the current working directory
- **THEN** the assembled base system prompt SHALL be `<SYSTEM.md content>` followed by `"\n\n"` followed by `<AGENTS.md content>`

#### Scenario: AGENTS.md appended when no override

- **WHEN** `SYSTEM.md` does not exist and `AGENTS.md` exists in the current working directory
- **THEN** the assembled base system prompt SHALL be `<system.txt content>` followed by `"\n\n"` followed by `<AGENTS.md content>` (unchanged from prior behavior)

### Requirement: Override resolution is cwd-only

The system SHALL resolve `SYSTEM.md` only from the current working directory, with no parent-directory walk.

#### Scenario: Override not found in parent directory

- **WHEN** `SYSTEM.md` exists in a parent directory but not in the current working directory
- **THEN** the system SHALL NOT use that file and SHALL fall back to `src/prompts/system.txt`

### Requirement: Override read errors are non-fatal

The system SHALL NOT abort startup if `SYSTEM.md` exists but cannot be read.

#### Scenario: Unreadable SYSTEM.md falls back

- **WHEN** `SYSTEM.md` exists in the current working directory but cannot be read
- **THEN** the system SHALL log the error and SHALL fall back to `src/prompts/system.txt` as the base system prompt
