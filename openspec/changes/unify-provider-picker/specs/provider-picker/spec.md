## ADDED Requirements

### Requirement: Provider list renders through the shared modal list component

The `/provider` picker list phase SHALL render using the shared `src/modal_list.zig` component, identical in format to the `/model` picker: a centered rounded modal with a bold title row, an `esc` hint, a per-row `❯` selection cursor, bold cyan selected row text, and scroll when the result set exceeds the visible area.

#### Scenario: Selection cursor is visible

- **WHEN** the provider picker list is open with one or more providers
- **THEN** the currently selected row is prefixed with `❯` and rendered in bold cyan, and non-selected rows are prefixed with two spaces in muted text

#### Scenario: Results scroll when overflowing

- **WHEN** the filtered provider list is longer than the modal's visible rows
- **THEN** the modal SHALL scroll so the selected row remains visible (the window follows the selection)

#### Scenario: Consistent title and escape hint

- **WHEN** the provider list modal is rendered
- **THEN** the title row shows a bold title and the right side shows the `esc` hint, matching the model picker layout

### Requirement: Provider list supports live search filtering

The provider picker list phase SHALL expose a search query row (with a `Search...` placeholder when empty) that filters the displayed providers by case-insensitive substring match against the provider name. Typing SHALL update the query and re-filter results in real time.

#### Scenario: Empty query shows all providers

- **WHEN** the provider list is open and the query is empty
- **THEN** all configured providers are displayed

#### Scenario: Typing filters providers

- **WHEN** the user types a query substring while in the list phase
- **THEN** only providers whose name contains the query (case-insensitive) remain in the results, and the selection is reset to the first result

#### Scenario: Backspace edits the query

- **WHEN** the user presses backspace while in the list phase and the query is non-empty
- **THEN** the last query character is removed and the results are re-filtered

#### Scenario: No matches shows empty message

- **WHEN** the query matches no provider names
- **THEN** the modal shows the empty message in place of the item list

### Requirement: Selection navigates the filtered result set

Up/down navigation in the list phase SHALL move the selection within the current filtered result set, clamped to the result bounds, never into the original unfiltered provider array.

#### Scenario: Move down clamps to last result

- **WHEN** the selection is on the last filtered result and the user moves down
- **THEN** the selection stays on the last result

#### Scenario: Selection resets on filter change

- **WHEN** the query changes (typed or backspaced) and the result set updates
- **THEN** the selection is reset to index 0 of the new result set

### Requirement: API key entry phase is preserved

Selecting a provider (Enter) in the list phase SHALL transition to the existing API-key entry phase. The key-entry phase SHALL remain a bespoke text-input modal (not a `modal_list`) and its rendering, backspace, paste, save-on-Enter, and escape-to-cancel behavior SHALL be unchanged from before this change.

#### Scenario: Enter transitions to key entry

- **WHEN** the user presses Enter while in the list phase with a provider selected
- **THEN** the picker transitions to the key_input phase for the selected provider

#### Scenario: Key entry phase rendering unchanged

- **WHEN** the picker is in the key_input phase
- **THEN** the modal renders the provider name, the API key input (or `Enter API key...` placeholder), and the `Enter to save   esc to cancel` hint exactly as before this change

#### Scenario: Escape cancels from key entry

- **WHEN** the user presses escape during the key_input phase
- **THEN** the picker closes without saving, identical to prior behavior

### Requirement: Selected provider resolves from the filtered set

The provider chosen for API-key entry SHALL be the provider at the current selection index of the filtered result set, so that filtering cannot desync the cursor from the resolved provider.

#### Scenario: Enter resolves to the highlighted provider

- **WHEN** a query is active and the user presses Enter on the highlighted result
- **THEN** the API-key entry phase opens for the provider indicated by the highlighted (filtered) row, not the original array index
