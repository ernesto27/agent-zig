pub const WebSearchParams = struct {
    query: []const u8,
    max_results: usize = 5,
    topic: []const u8 = "general",
    search_depth: []const u8 = "basic",
};

pub const WebExtractParams = struct {
    urls: []const []const u8,
    format: []const u8 = "markdown",
    extract_depth: []const u8 = "basic",
};

pub const TavilySearchRequest = struct {
    query: []const u8,
    max_results: usize = 5,
    topic: []const u8 = "general",
    search_depth: []const u8 = "basic",
};

pub const TavilyExtractRequest = struct {
    urls: []const []const u8,
    format: []const u8 = "markdown",
    extract_depth: []const u8 = "basic",
};

pub const TavilySearchResult = struct {
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    content: ?[]const u8 = null,
    score: ?f64 = null,
};

pub const TavilySearchResponse = struct {
    query: ?[]const u8 = null,
    answer: ?[]const u8 = null,
    results: []const TavilySearchResult = &.{},
};

pub const TavilyExtractResult = struct {
    url: ?[]const u8 = null,
    content: ?[]const u8 = null,
    raw_content: ?[]const u8 = null,
    favicon: ?[]const u8 = null,
};

pub const TavilyExtractResponse = struct {
    results: []const TavilyExtractResult = &.{},
    failed_results: []const []const u8 = &.{},
};

pub const WebSearchResult = struct {
    title: []const u8,
    url: []const u8,
    content: []const u8,
    score: ?f64 = null,
};

pub const WebSearchOutput = struct {
    query: []const u8,
    answer: ?[]const u8 = null,
    results: []const WebSearchResult,
};

pub const WebExtractResult = struct {
    url: []const u8,
    content: []const u8,
    favicon: ?[]const u8 = null,
};

pub const WebExtractOutput = struct {
    results: []const WebExtractResult,
    failed_results: []const []const u8 = &.{},
};
