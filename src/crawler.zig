const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const RobotsTxt = @import("robots_txt.zig");
const UrlQueue = @import("url_queue.zig");

pub const CrawlerConfig = struct {
    max_connections: u16 = 10,
    politeness_delay_ms: u32 = 1000,
    max_depth: u16 = 3,
    user_agent: []const u8 = "ZigSearchBot/1.0",
};

pub const WebCrawler = struct {
    allocator: *Allocator,
    max_connections: u16,
    politeness_delay_ms: u32,
    max_depth: u16,
    user_agent: []const u8,

    url_queue: UrlQueue,
    visited_urls: std.StringHashMap(void),
    robots_cache: std.StringHashMap(*RobotsTxt),
    active_connections: u16,

    downloaded_pages: std.StringHashMap([]const u8),

    mutex: std.Thread.Mutex,

    pub fn init(allocator: *Allocator, config: CrawlerConfig) !WebCrawler {
        const url_queue = try UrlQueue.init(allocator);

        return WebCrawler{
            .allocator = allocator,
            .max_connections = config.max_connections,
            .politeness_delay_ms = config.politeness_delay_ms,
            .max_depth = config.max_depth,
            .user_agent = try allocator.dupe(u8, config.user_agent),
            .url_queue = url_queue,
            .visited_urls = std.StringHashMap(void).init(allocator),
            .robots_cache = std.StringHashMap(*RobotsTxt).init(allocator),
            .active_connections = 0,
            .downloaded_pages = std.StringHashMap([]const u8).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *WebCrawler) void {
        self.allocator.free(self.user_agent);
        self.url_queue.deinit();

        var robots_it = self.robots_cache.iterator();
        while (robots_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.robots_cache.deinit();

        self.visited_urls.deinit();

        var pages_it = self.downloaded_pages.iterator();
        while (pages_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.downloaded_pages.deinit();
    }

    pub fn addSeed(self: *WebCrawler, url: []const u8, depth: u16) !void {
        const url_copy = try self.allocator.dupe(u8, url);
        try self.url_queue.push(url_copy, depth);
    }

    pub fn start(self: *WebCrawler) !void {
        const thread_count = 8; // Number of worker threads
        const threads: [thread_count]std.Thread = undefined;

        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{ self, 0 });
        }

        for (threads) |thread| {
            thread.join();
        }
    }

    fn workerThread(self: *WebCrawler) !void {
        while (true) {
            self.mutex.lock();

            const maybe_url_info = self.url_queue.tryPop();

            self.mutex.unlock();

            if (maybe_url_info) |url_info| {
                if (url_info.depth > self.max_depth) {
                    self.allocator.free(url_info.url);
                    continue;
                }

                try self.crawlUrl(url_info.url, url_info.depth);
                self.allocator.free(url_info.url);
            } else {
                break;
            }

            std.time.sleep(self.politeness_delay_ms * std.time.ns_per_ms);
        }
    }

    fn crawlUrl(self: *WebCrawler, url: []const u8, depth: u16) !void {
        const domain = try extractDomain(self.allocator, url);
        defer self.allocator.free(domain);

        self.mutex.lock();
        const can_crawl = try self.checkRobotsTxt(domain, url);
        self.mutex.unlock();

        if (!can_crawl) {
            std.debug.print("Skipping {s} due to robots.txt rules\n", .{url});
            return;
        }

        const page_content = try self.downloadPage(url);
        defer self.allocator.free(page_content);

        try self.extractAndQueueLinks(url, page_content, depth + 1);

        self.mutex.lock();
        defer self.mutex.unlock();

        const url_copy = try self.allocator.dupe(u8, url);
        const content_copy = try self.allocator.dupe(u8, page_content);
        try self.downloaded_pages.put(url_copy, content_copy);
    }

    fn checkRobotsTxt(self: *WebCrawler, domain: []const u8, url: []const u8) !bool {
        if (self.robots_cache.get(domain)) |robots| {
            return robots.isAllowed(url, self.user_agent);
        }

        const robots_url = try std.fmt.allocPrint(self.allocator, "http://{s}/robots.txt", .{domain});
        defer self.allocator.free(robots_url);

        const robots_content = download(self.allocator, robots_url) catch |err| {
            if (err == error.FileNotFound) {
                const robots = try self.allocator.create(RobotsTxt);
                robots.* = try RobotsTxt.init(self.allocator, "");
                try self.robots_cache.put(try self.allocator.dupe(u8, domain), robots);
                return true;
            }
            return err;
        };
        defer self.allocator.free(robots_content);

        var robots = try self.allocator.create(RobotsTxt);
        robots.* = try RobotsTxt.init(self.allocator, robots_content);
        try self.robots_cache.put(try self.allocator.dupe(u8, domain), robots);

        return robots.isAllowed(url, self.user_agent);
    }

    fn downloadPage(self: *WebCrawler, url: []const u8) ![]const u8 {
        self.mutex.lock();
        while (self.active_connections >= self.max_connections) {
            self.mutex.unlock();
            std.time.sleep(10 * std.time.ns_per_ms);
            self.mutex.lock();
        }
        self.active_connections += 1;
        self.mutex.unlock();

        const result = download(self.allocator, url) catch |err| {
            self.mutex.lock();
            self.active_connections -= 1;
            self.mutex.unlock();
            return err;
        };

        self.mutex.lock();
        self.active_connections -= 1;
        self.mutex.unlock();

        return result;
    }

    fn extractAndQueueLinks(self: *WebCrawler, base_url: []const u8, content: []const u8, depth: u16) !void {
        var link_start: usize = 0;

        while (true) {
            link_start = std.mem.indexOf(u8, content[link_start..], "href=\"") orelse break;
            link_start += 6; // Skip "href=\"" prefix

            const link_end = std.mem.indexOf(u8, content[link_start..], "\"") orelse break;
            const link = content[link_start .. link_start + link_end];

            if (isValidUrl(link)) {
                const absolute_url = try resolveUrl(self.allocator, base_url, link);
                defer self.allocator.free(absolute_url);

                self.mutex.lock();
                const url_exists = self.visited_urls.contains(absolute_url);
                if (!url_exists) {
                    const url_copy = try self.allocator.dupe(u8, absolute_url);
                    try self.visited_urls.put(url_copy, {});
                    try self.url_queue.push(try self.allocator.dupe(u8, absolute_url), depth);
                }
                self.mutex.unlock();
            }

            link_start += link_end + 1;
        }
    }
};

fn download(allocator: *Allocator, url: []const u8) ![]const u8 {
    var client = http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();
    try headers.append("User-Agent", "ZigSearchBot/1.0");

    var request = try client.request(.GET, uri, headers, .{});
    defer request.deinit();
    try request.start();
    try request.wait();

    if (request.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    var body = ArrayList(u8).init(allocator);
    defer body.deinit();

    try request.response.reader().readAllArrayList(&body, 10 * 1024 * 1024); // 10MB limit

    return body.toOwnedSlice();
}

fn extractDomain(allocator: *Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    return allocator.dupe(u8, uri.host.?);
}

fn isValidUrl(url: []const u8) bool {
    return mem.startsWith(u8, url, "http://") or
        mem.startsWith(u8, url, "https://") or
        !mem.startsWith(u8, url, "#") and
            !mem.startsWith(u8, url, "javascript:");
}

fn resolveUrl(allocator: *Allocator, base: []const u8, relative: []const u8) ![]const u8 {
    if (mem.startsWith(u8, relative, "http://") or mem.startsWith(u8, relative, "https://")) {
        return allocator.dupe(u8, relative);
    }

    const base_uri = try std.Uri.parse(base);

    if (mem.startsWith(u8, relative, "/")) {
        // Absolute path
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{
            base_uri.scheme,
            base_uri.host.?,
            relative,
        });
    } else {
        const last_slash = std.mem.lastIndexOf(u8, base, "/") orelse 0;
        const base_path = base[0 .. last_slash + 1];

        return std.fmt.allocPrint(allocator, "{s}{s}", .{
            base_path,
            relative,
        });
    }
}
