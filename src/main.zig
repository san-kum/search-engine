const std = @import("std");
const WebCrawler = @import("crawler.zig").WebCrawler;
const CrawlerConfig = @import("crawler.zig").CrawlerConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = CrawlerConfig{
        .max_connections = 8,
        .politeness_delay_ms = 500,
        .max_depth = 2,
        .user_agent = "ZigSearchBot/1.0",
    };

    var crawler = try WebCrawler.init(&allocator, config);
    defer crawler.deinit();

    try crawler.addSeed("https://example.com", 0);
    try crawler.addSeed("https://zig.news", 0);

    std.debug.print("Starting crawler...\n", .{});

    try crawler.start();

    std.debug.print("Crawling complete. Downloaded {} pages.\n", .{crawler.downloaded_pages.count()});

    var it = crawler.downloaded_pages.iterator();
    while (it.next()) |entry| {
        std.debug.print("URL: {s}, Size: {} bytes\n", .{ entry.key_ptr.*, entry.value_ptr.*.len });
    }
}
