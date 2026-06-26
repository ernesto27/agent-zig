# session-export

## Purpose

Allow users to export the current session's conversation to a self-contained, view-only HTML file from within the TUI.

## Requirements

### Requirement: Export command availability

The system SHALL expose an `/export` slash command in the command picker that exports the current session's conversation to an HTML file.

#### Scenario: Command is listed

- **WHEN** the user opens the command picker and types `/export`
- **THEN** an `export` entry is shown with a description indicating it saves the conversation as HTML

#### Scenario: Command is invoked

- **WHEN** the user selects the `export` command
- **THEN** the system generates an HTML file from the current conversation and writes it to the current project directory

### Requirement: Conversation content

The exported HTML SHALL contain every user and assistant message from the current session, in chronological order, preserving the message text.

#### Scenario: User and assistant turns are rendered

- **WHEN** a session contains alternating user and assistant messages
- **THEN** each message appears in the HTML in the same order it occurred
- **AND** user messages are visually distinguished from assistant messages

#### Scenario: Empty conversation

- **WHEN** the user runs `/export` with no messages in the session
- **THEN** the system show message indicating taht session is empty

### Requirement: Self-contained view-only output

The exported HTML SHALL be a single self-contained file that renders correctly in a browser with no external assets, no network requests, and no interactive features such as a search box.

#### Scenario: Opens without external dependencies

- **WHEN** the exported HTML file is opened in a browser while offline
- **THEN** the page renders with its styling intact and displays the full conversation

#### Scenario: No search or interactive controls

- **WHEN** the user views the exported HTML
- **THEN** the page presents a static, readable layout with no search field or other interactive controls

### Requirement: Output location and feedback

The system SHALL write the exported file into the current project directory and SHALL report the resulting file path to the user inside the TUI.

#### Scenario: File saved to project directory

- **WHEN** the export completes successfully
- **THEN** the HTML file is created in the process working directory with a recognizable name
- **AND** a notice showing the saved file path is appended to the conversation view

#### Scenario: Special characters are escaped

- **WHEN** a message contains HTML-significant characters such as `<`, `>`, or `&`
- **THEN** those characters are escaped in the output so they display as literal text rather than affecting the page structure
