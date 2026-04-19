# Zigent

Terminal-based AI coding agent written in Zig.

## Build

```bash
zig build
```

## Run

```bash
zig build run
```

## Test

```bash
zig build test
```

## Tavily API key

`web_search` and `web_extract` read the Tavily API key from a build flag.

Build with key:

```bash
zig build -Dtavily-api-key="tvly-..."
```

Run with key:

```bash
zig build run -Dtavily-api-key="tvly-..."
```

Test with key:

```bash
zig build test -Dtavily-api-key="tvly-..."
```

If the flag is omitted, Tavily-backed tools return a missing API key error at runtime.
