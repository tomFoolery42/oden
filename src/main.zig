const Database = @import("database.zig");
const event = @import("events.zig");
const queues = @import("message_queue.zig");
const schema = @import("schema.zig");
const socket = @import("socket.zig");

const ai = @import("zig_ai");
const Allocator = std.mem.Allocator;
const fr = @import("fridge");
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;


pub const log_level: std.log.Level = .info;
const EventQueue = queues.MessageQueue(event.Event, 100);
const ID = schema.ID;
const Socket = socket(event.Event);
const String = schema.String;

const Config = struct {
    ai_url:     String,
    database:   String,
    metadata:   [:0]const u8,
};


fn socketHandle() void {
    var running = true;
    while (running) {
        running = false;
    }
}

fn openConfig(alloc: std.mem.Allocator, config_file: []const u8) !std.json.Parsed(Config) {
    var file = try std.fs.cwd().openFile(config_file, .{});
    defer file.close();

    const json = try file.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(json);
    return try std.json.parseFromSlice(Config, alloc, json, .{.allocate = .alloc_always, .ignore_unknown_fields = true});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const config = try openConfig(alloc, "config.json");
    defer config.deinit();
    var database = try Database.init(alloc, config.value.ai_url, config.value.database, config.value.metadata);
    defer database.deinit();
    var queue = EventQueue.init();
    defer queue.deinit();

    var running = true;
    while (running) {
        if (queue.get()) |cmd| {
            switch (cmd) {
                .Bail   => running = false,
                .Delete => |to_delete| {
                    for (to_delete) |id| {
                        try database.delete(id);
                    }
                },
                .Fetch => |filter| {
                    const request = switch (filter.value) {
                        .description    => |desc| database.like("description", desc),
                        .filename       => |name| database.like("filename", name),
                        .tags           => |tags| database.like("tags", tags),
                    };

                    if (request) |success| {
                        std.log.info("parsed request successfully: {s}", .{std.json.fmt(success, .{})});
                    }
                    else |err| {
                        std.log.err("failed to parse response {s}", .{std.json.fmt(err, .{})});
                    }
                },
                .Insert => |to_insert| {
                    for (to_insert) |next| {
                        _ = next;
                        //_ = try insert(alloc, &database, &client, next);
                    }
                },
                else => {},
            }
        }
        else {running = false;}
    }
}

test "init" {
    std.testing.log_level = std.log.Level.debug;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var database = try Database.init(alloc, "https://some.url/v1", "database", "database/test.sqlite");
    defer database.deinit();

    _ = try database.insert("pictures/meme/1047646.jpg");
    _ = try database.insert("pictures/meme/134664f.jpg");
    _ = try database.insert("pictures/meme/2323e70.jpg");
    _ = try database.insert("pictures/meme/3361566.jpg");
    _ = try database.insert("pictures/meme/789bd0c.jpg");

    std.log.info("inserted images", .{});
    for (try database.findAll()) |image| {
        std.log.info("Image: {s}", .{std.json.fmt(image, .{})});
    }
}

test "search" {
    std.testing.log_level = std.log.Level.debug;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var database = try Database.init(alloc, "https://some.url/v1", "database", "database/test.sqlite");
    defer database.deinit();

    std.log.info("basic search", .{});
    for (try database.findAll()) |image| {
        std.log.info("Image: {}", .{std.json.fmt(image, .{})});
    }

    std.log.info("col search", .{});
    const results = try database.like("tags", "meme");
    std.log.info("search: {s}\t found: {s}", .{"meme", std.json.fmt(results, .{})});
}

test "generate" {
    std.testing.log_level = std.log.Level.debug;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var database = try Database.init(alloc, "https://some.url/v1", "database", "database/test.sqlite");
    defer database.deinit();

    std.log.info("grab all memes about spongebob", .{});
    const bases = try database.like("tags", "Spongebob");
    std.log.info("Found {d} memes of spongebob", .{bases.len});

    //todo implement comfyui api
}
