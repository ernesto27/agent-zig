# Plan: Invalid API Key Crash

- **Date:** 2026-06-26
- **Domain(s):** backend / TUI
- **Author:** plan-from-spec
- **Status:** Implement

## 1. Summary

Fix the TUI crash that happens after a user saves an invalid API key and then sends a request. Saving the key can remain a simple persistence action; the request-time provider error must be handled without panicking in Zig's HTTP reader, converted into a clear user-visible error message, logged without secrets, and leave the TUI in a clean non-loading state.

## 2. Scope

### In scope
- Request-time invalid API key handling for Anthropic-compatible providers, including DeepSeek, at the failing `src/llm/anthropic.zig` non-200 streaming response path.
- Equivalent non-200 streaming error-body handling review/fix for OpenAI and Gemini, because both use the same `response.reader(...).takeDelimiter('\n')` pattern.
- A shared, bounded helper for reading provider error bodies safely after response headers.
- A typed LLM error mapping that can distinguish provider HTTP/auth failures from generic transport failures.
- TUI error rendering that shows a useful message such as invalid API key / provider authentication failed, without exposing the key.
- Focused tests for error classification/body extraction and TUI request-error behavior where practical.
- Verification with `zig build test`.

### Out of scope / non-goals
- Pre-validating API keys during `/provider` save.
- Preventing invalid keys from being persisted.
- Changing the provider picker UX beyond preserving the existing save flow.
- Logging full provider error responses if they could include sensitive data.
- Redesigning the LLM client API beyond the minimum needed for robust request errors.

## 3. Resolved decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Does the bug happen during save or request? | Request. User confirmed save works; crash happens after saving an invalid API key and sending a request. |
| 2 | Should `/provider` validate keys before saving? | No. Keep save behavior simple; validation remains request-time. |
| 3 | Which crash path is confirmed? | `src/llm/anthropic.zig:143` in the non-200 branch reads the error body with `err_reader.takeDelimiter('\n')` and panics in std HTTP reader state: `access of union field 'body_remaining_content_length' while field 'ready' is active`. |
| 4 | Should the fix be Anthropic-only? | No. Fix Anthropic first, then apply the same safe error-body pattern to OpenAI and Gemini because their streaming non-200 branches use the same line-by-line reader pattern. |
| 5 | What should users see? | A visible assistant error message explaining that the provider rejected the request, with auth-specific wording for 401/403, and no API key value. |
| 6 | What should logs include? | Provider name, HTTP status, and a bounded sanitized response snippet. Never log request headers or API key values. |
| 7 | What happens to loading state? | The request ends with `.request_failed`; `onFinished` stops loading, clears status, resets cancellation, and wakes the UI. |
| 8 | Testing expectation? | Add focused unit tests for new pure helpers/error mapping and run `zig build test`. Manual invalid-key TUI verification remains useful because the exact std HTTP panic requires a real provider-style response path. |

## 4. Design

### Current failure

The confirmed stack trace shows an invalid-key provider response enters the streaming Anthropic non-200 branch:

- `src/llm/anthropic.zig:143` reads the error body by repeatedly calling `err_reader.takeDelimiter('\n')`.
- Zig std HTTP panics inside `std.http` because the reader state is `ready` while `contentLengthStream` expects `body_remaining_content_length`.
- The panic happens in the request thread, so normal `agent_loop` error handling never gets a chance to render a graceful error.

OpenAI and Gemini currently have the same structural non-200 pattern, so they should be fixed in the same pass even if the reported crash is Anthropic/DeepSeek.

### Safe provider-error handling

Add a small shared helper in `src/llm/client.zig` for bounded response-body extraction after headers. The helper should avoid delimiter-based iteration on the std HTTP reader. Preferred shape:

```zig
pub const ProviderHttpError = struct {
    status: std.http.Status,
    provider_name: []const u8,
    body_snippet: []const u8,
};

pub fn readErrorBodySnippet(
    allocator: std.mem.Allocator,
    response_reader: *std.Io.Reader,
    max_bytes: usize,
) ![]u8 { ... }
```

Implementation details:
- Read raw bytes into a fixed maximum, e.g. 4096 or 8192 bytes.
- Do not split by newline.
- Treat body-read failures as non-fatal for the original HTTP error: log that the body could not be read and continue with an empty snippet.
- Return allocator-owned snippet for logging and message construction.

If the Zig 0.15.2 HTTP reader still panics through direct reads in this state, use the safer alternative: do not read the error body at all for streaming non-200 responses, and log only provider/status. The key requirement is that non-200 handling never touches an unstable reader state.

### Error type and mapping

Introduce a narrow LLM request error set in `src/llm/client.zig` or a provider-local equivalent:

```zig
pub const RequestError = error{
    ProviderAuthenticationFailed,
    ProviderHttpRequestFailed,
    RequestCancelled,
};
```

Mapping:
- 401 and 403 -> `error.ProviderAuthenticationFailed`
- Other non-200 statuses -> `error.ProviderHttpRequestFailed`
- Preserve `error.RequestCancelled`
- Transport, parse, allocation, and existing errors can continue through the broader error union as needed.

Anthropic, OpenAI, and Gemini streaming request functions should:
- Log provider/status/snippet.
- Return the mapped error.
- Avoid continuing into SSE parsing after non-200.

### TUI error rendering

Update `App.onRequestError` in `src/App.zig` to convert request errors into useful UI text:

- `ProviderAuthenticationFailed`: "Provider authentication failed. Check the API key for <provider> with /provider."
- `ProviderHttpRequestFailed`: "Provider request failed. Check ~/.config/agent-zig/agent.log for details."
- Existing fallback: keep a generic service/network failure message.

Also remove the unsafe allocation fallback:

```zig
last.content = self.alloc.dupe(u8, "...") catch "";
```

`Messages.freeMessages` frees `last.content`, so storing a string literal on allocation failure is unsafe. If allocating the error text fails, keep a pre-allocated empty assistant placeholder or avoid replacing content rather than assigning static memory that will later be freed.

## 5. Interfaces & contracts

### `/provider` save

Input: user selects provider and enters any non-empty key.

Contract:
- Persist the key exactly as today.
- Do not call the provider during save.
- Do not reject syntactically arbitrary keys.

### LLM streaming request

Input: current history, tools, system prompt, configured provider/model/key.

Contract:
- 200 response: existing streaming/SSE behavior unchanged.
- 401/403 response: return `ProviderAuthenticationFailed`, log bounded provider/status information, no panic.
- Other non-200 response: return `ProviderHttpRequestFailed`, log bounded provider/status information, no panic.
- Request cancellation remains `RequestCancelled`.

### TUI request error

Input: error returned by `agent_loop`.

Contract:
- Replace the assistant placeholder with an allocated error message when possible.
- Mark the message as `is_error = true`.
- Stop loading and redraw through existing `onFinished`.
- Never expose the API key.

## 6. Behavior & states

State flow:

1. User saves an invalid API key via `/provider`.
2. Config write succeeds; selected provider state remains usable.
3. User sends a prompt.
4. Provider returns 401/403 or equivalent invalid-key HTTP response.
5. Provider client maps the response to `ProviderAuthenticationFailed` without reading the body in an unsafe way.
6. `agent_loop` catches the error, calls `App.onRequestError`, and returns `.request_failed`.
7. `App.onFinished` stops loading and wakes the TUI.
8. UI shows an error assistant message and remains interactive.

Edge cases:
- Empty API key before request still uses existing `Missing API key` preflight in `input_handler.zig`.
- Non-auth provider failures use a generic provider request failure message.
- Error body larger than the cap is truncated in logs.
- If body extraction itself fails, request handling still returns the mapped HTTP error.
- No partial provider response should be added to LLM history on failure.

## 7. Implementation tasks

- [x] Task 1 - Add request-error mapping helpers in `src/llm/client.zig`: status-to-error mapping, safe/bounded snippet support if viable, and display-message helper if it belongs centrally.
- [x] Task 2 - Replace the Anthropic streaming non-200 branch in `src/llm/anthropic.zig` so it never uses `takeDelimiter` for error bodies and returns auth-specific errors for 401/403.
- [x] Task 3 - Apply the same non-200 branch fix to `src/llm/openai.zig`.
- [x] Task 4 - Apply the same non-200 branch fix to `src/llm/gemini.zig`.
- [x] Task 5 - Update `App.onRequestError` in `src/App.zig` to render auth/provider errors clearly and remove the unsafe string-literal fallback.
- [ ] Task 6 - Skipped (no tests per project preference).
- [ ] Task 7 - Skipped (no tests per project preference).
- [x] Task 8 - Run `zig build test`.
- [ ] Task 9 - Manually verify with an invalid API key: save via `/provider`, send a request, confirm no crash, loading stops, and the TUI shows the authentication error.

## 8. Testing

- **Unit tests**
  - 401 maps to `ProviderAuthenticationFailed`.
  - 403 maps to `ProviderAuthenticationFailed`.
  - 400/404/429/500 map to `ProviderHttpRequestFailed` or the chosen non-auth provider error.
  - Error display text never includes the configured API key.
  - `App.onRequestError` or an extracted helper returns allocator-owned content and marks the message as error.

- **Integration tests**
  - Run `zig build test` to exercise both root and app test executables.
  - If a local mock HTTP server is extended, add a streaming endpoint that returns 401 and verify the LLM client returns `ProviderAuthenticationFailed` without panic.
  - Manual TUI integration: save an invalid key, send a prompt, and confirm the app remains open and interactive.

## 9. Acceptance criteria

- Invalid saved API key no longer crashes the TUI.
- The confirmed panic path in `src/llm/anthropic.zig` is removed or made unreachable.
- Anthropic/DeepSeek, OpenAI, and Gemini non-200 streaming branches use the same safe error handling policy.
- TUI displays an actionable authentication/provider error and stops the loading spinner.
- Logs include provider/status context but no API key.
- `zig build test` passes.

## 10. Risks & open items

- Zig 0.15.2 std HTTP reader behavior may make all error-body reads unsafe after certain streaming non-200 responses. If so, skip body extraction for streaming errors and log only provider/status.
- A full automated reproduction may require a mock server that matches std HTTP's exact response state. If that is too costly, keep the automated coverage on pure error mapping and rely on manual invalid-key TUI verification for the panic regression.
