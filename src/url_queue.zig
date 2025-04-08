const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const UrlInfo = struct {
    url: []const u8,
    depth: u16,
};

pub const UrlQueue = struct {
    allocator: *Allocator,
    queue: ArrayList(UrlInfo),

    pub fn init(allocator: *Allocator) !UrlQueue {
        return UrlQueue{
            .allocator = allocator,
            .queue = ArrayList(UrlInfo).init(allocator),
        };
    }
    pub fn deinit(self: *UrlQueue) void {
        for (self.queue.items) |item| {
            self.allocator.free(item.url);
        }
        self.queue.deinit();
    }

    pub fn push(self: *UrlQueue, url: []const u8, depth: u16) !void {
        const url_info = UrlInfo{
            .url = url,
            .depth = depth,
        };
        try self.queue.append(url_info);
    }

    pub fn pop(self: *UrlQueue) !UrlInfo {
        if (self.queue.items.len == 0) {
            return error.EmptyQueue;
        }
        return self.queue.orderedRemove(0);
    }

    pub fn tryPop(self: *UrlQueue) ?UrlInfo {
        if (self.queue.items.len == 0) {
            return null;
        }
        return self.queue.orderedRemove(0);
    }

    pub fn isEmpty(self: UrlQueue) usize {
        return self.queue.items.len;
    }
};
