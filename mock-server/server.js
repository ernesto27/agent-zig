const http = require("http");
const PORT = 9999;

const responses = {
  hello: "Hello! I'm Zigent, your AI coding assistant. How can I help you today?",
  zig: "Zig is a systems programming language designed for performance and safety. It features manual memory management with allocators, comptime for compile-time metaprogramming, and seamless C interop.",
  vaxis: "libvaxis is a terminal UI library for Zig. It provides a virtual screen buffer, event handling for keyboard and mouse input, and widgets like text fields and scroll views.",
  help: "I can help with coding tasks! Try asking me about Zig, vaxis, memory management, or any programming topic.",
  error: "Zig uses error unions for error handling. Functions return either a value or an error. Use try, catch, or if/else to handle them. Errors are values, not exceptions.",
  memory: "Zig uses manual memory management with allocators. There's no garbage collector. You pass an allocator to functions that need heap memory, giving you full control over allocation.",
};
const DEFAULT_RESPONSE = "I'm Zigent's mock AI. I received your message and I'm responding with this hardcoded reply. In the future, I'll be connected to a real LLM!";

function pickResponse(userMessage) {
  const lower = userMessage.toLowerCase();
  for (const [keyword, response] of Object.entries(responses)) {
    if (lower.includes(keyword)) return response;
  }
  return DEFAULT_RESPONSE;
}

function readBody(req) {
  return new Promise((resolve) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => resolve(body));
  });
}

function json(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    return json(res, 200, { status: "ok", service: "zigent-mock-llm" });
  }

  if (req.method === "POST" && req.url === "/v1/messages") {
    const body = await readBody(req);
    let payload;
    try {
      payload = JSON.parse(body);
    } catch {
      return json(res, 400, { error: { message: "Invalid JSON" } });
    }

    const msgs = payload.messages || [];
    const lastMsg = msgs.length > 0 ? msgs[msgs.length - 1].content : "";
    const userText = typeof lastMsg === "string" ? lastMsg : "";
    const responseText = pickResponse(userText);
    const msgId = "msg_mock_" + Date.now();
    const model = payload.model || "mock-model";

    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    // Non-streaming
    if (!payload.stream) {
      await sleep(1000);
      return json(res, 200, {
        id: msgId,
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: responseText }],
        model,
        stop_reason: "end_turn",
        stop_sequence: null,
        usage: { input_tokens: userText.length, output_tokens: responseText.length },
      });
    }

    // Streaming
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    });

    const sse = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);

    (async () => {
      sse("message_start", {
        type: "message_start",
        message: {
          id: msgId, type: "message", role: "assistant", content: [],
          model, stop_reason: null, stop_sequence: null,
          usage: { input_tokens: userText.length, output_tokens: 0 },
        },
      });

      await sleep(200);

      sse("content_block_start", {
        type: "content_block_start", index: 0,
        content_block: { type: "text", text: "" },
      });

      await sleep(100);

      const words = responseText.split(" ");
      for (let i = 0; i < words.length; i++) {
        const word = words[i] + (i < words.length - 1 ? " " : "");
        sse("content_block_delta", {
          type: "content_block_delta", index: 0,
          delta: { type: "text_delta", text: word },
        });
        await sleep(200);
      }

      await sleep(150);

      sse("content_block_stop", { type: "content_block_stop", index: 0 });

      await sleep(100);

      sse("message_delta", {
        type: "message_delta",
        delta: { stop_reason: "end_turn", stop_sequence: null },
        usage: { output_tokens: responseText.length },
      });

      await sleep(100);

      sse("message_stop", { type: "message_stop" });
      res.end();
    })();

    return;
  }

  json(res, 404, { error: { message: "Not found" } });
});

server.listen(PORT, () => {
  console.log(`\nZigent Mock LLM Server running on http://localhost:${PORT}`);
  console.log(`\nEndpoints:`);
  console.log(`  POST http://localhost:${PORT}/v1/messages`);
  console.log(`  GET  http://localhost:${PORT}/health`);
  console.log(`\nTest non-streaming:`);
  console.log(`  curl -s http://localhost:${PORT}/v1/messages -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hello"}]}'`);
  console.log(`\nTest streaming:`);
  console.log(`  curl -s http://localhost:${PORT}/v1/messages -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hello"}],"stream":true}'`);
});
