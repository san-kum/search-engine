const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const RobotRule = struct {
    path: []const u8,
    allow: bool,

    fn init(allocator: *Allocator, path: []const u8, allow: bool) !RobotRule {
        return RobotRule{
            .path = try allocator.dupe(u8, path),
            .allow = allow,
        };
    }

    fn deinit(self: RobotRule, allocator: *Allocator) void {
        allocator.free(self.path);
    }

    fn matches(self: RobotRule, path: []const u8) bool {
        return std.mem.startsWith(u8, path, self.path);
    }
};

const UserAgentSection = struct {
    user_agent: []const u8,
    rules: ArrayList(RobotRule),

    fn init(allocator: *Allocator, user_agent: []const u8) !UserAgentSection {
        return UserAgentSection{
            .user_agent = try allocator.dupe(u8, user_agent),
            .rules = ArrayList(RobotRule).init(allocator),
        };
    }

    fn deinit(self: *UserAgentSection, allocator: *Allocator) void {
        allocator.free(self.user_agent);
        for (self.rules.items) |*rule| {
            rule.deinit(allocator);
        }
        self.rules.deinit();
    }

    fn addRule(self: *UserAgentSection, allocator: *Allocator, path: []const u8, allow: bool) !void {
        const rule = try RobotRule.init(allocator, path, allow);
        try self.rules.append(rule);
    }

    fn isAllowed(self: UserAgentSection, path: []const u8) bool {
        var most_specific_match: ?RobotRule = null;
        var most_specific_length: usize = 0;

        for (self.rules.items) |rule| {
            if (rule.matches(path) and rule.path.len > most_specific_length) {
                most_specific_match = rule;
                most_specific_length = rule.path.len;
            }
        }
        return if (most_specific_match) |rule| rule.allow else true;
    }
};

pub const RobotsTxt = struct {
    allocator: *Allocator,
    sections: ArrayList(UserAgentSection),

    pub fn init(allocator: *Allocator, content: []const u8) !RobotsTxt {
        var robots = RobotsTxt{
            .allocator = allocator,
            .sections = ArrayList(UserAgentSection).init(allocator),
        };
        try robots.parse(content);
        return robots;
    }

    pub fn deinit(self: *RobotsTxt) void {
        for (self.sections.items) |*section| {
            section.deinit(self.allocator);
        }
        self.sections.deinit();
    }

    fn parse(self: *RobotsTxt, content: []const u8) !void {
        var lines = std.mem.split(u8, content, "\n");
        var current_section: ?*UserAgentSection = null;

        while (lines.next()) |line| {
            var trimmed_line = std.mem.trim(u8, line, " \t\r");
            if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
                continue;
            }
            const colon = std.mem.indexOf(u8, trimmed_line, ":") orelse continue;
            const field = std.mem.trim(u8, trimmed_line[0..colon], " \t");
            const value = std.mem.trim(u8, trimmed_line[colon + 1 ..], " \t");

            if (std.mem.eql(u8, field, "User-agent")) {
                const section = try UserAgentSection.init(self.allocator, value);
                try self.sections.append(section);
                current_section = &self.sections.items[self.sections.items.len - 1];
            } else if (current_section != null) {
                if (std.mem.eql(u8, field, "Disallow")) {
                    try current_section.?.addRule(self.allocator, value, false);
                } else if (std.mem.eql(u8, field, "Allow")) {
                    try current_section.?.addRule(self.allocator, value, true);
                }
            }
        }

        if (self.sections.items.len == 0) {
            const section = try UserAgentSection.init(self.allocator, "*");
            try self.sections.append(section);
        }
    }

    pub fn isAllowed(self: RobotsTxt, url: []const u8, user_output: []const u8) bool {
        const path_start = blk: {
            const protocol_end = std.mem.indexOf(u8, url, "://") orelse 0;
            const domain_start = if (protocol_end > 0) protocol_end + 3 orelse 0;
            const domain_end = std.mem.indexOfPos(u8, url, domain_start, "/") orelse url.len;
            break :blk domain_end;
        };

        const path = if (path_start < url.len) url[path_start..] else "/";

        for (self.sections.items) |section| {
            if (std.mem.eql(u8, section.user_agent, user_output)) {
                return section.isAllowed(path);
            }
        }
        for (self.sections.items) |section| {
            if (std.mem.eql(u8, section.user_agent, "*")) {
                return section.isAllowed(path);
            }
        }
        return true;
    }
};
