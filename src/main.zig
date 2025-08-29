const event = @import("events.zig");
const queues = @import("message_queue.zig");
const schema = @import("schema.zig");
const socket = @import("socket.zig");

const std = @import("std");
const fr = @import("fridge");

const EventQueue = queues.MessageQueue(event.Event, 100);
const Socket = socket(event.Event);


fn socketHandle() void {
    var running = true;
    while (running) {
        running = false;
    }
}

fn databaseInit(db: *fr.Session) !void {
    try db.conn.execAll(
        \\CREATE TABLE Image (
        \\  id INTEGER PRIMARY KEY,
        \\  description TEXT NOT NULL,
        \\  filename TEXT NOT NULL,
        \\  tags TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE Description (
        \\  value TEXT PRIMARY KEY,
        \\  image_id INTEGER
        \\);
        \\
        \\CREATE TABLE Filename (
        \\  value TEXT UNIQUE PRIMARY KEY,
        \\  image_id INTEGER
        \\);
        \\
        \\CREATE TABLE Tag (
        \\  value TEXT PRIMARY KEY,
        \\  image_id INTEGER
        \\);
    );

    // initial integrity check. If a file is missing, report and remove
    for (try db.query(schema.Image).findAll()) |image| {
        if (exists(image.filename) == false) {
            std.log.warn("missing {s}. Removing from database", .{image.filename});
            try db.delete(schema.Image, image.id);
        }
    }
}

fn exists(filename: schema.String) bool {
    const file = std.fs.cwd().openFile(filename, .{}) catch {
        return false;
    };
    defer file.close();

    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var db = try fr.Session.open(fr.SQLite3, alloc, .{ .filename = "database/metadata.sqlite" });
    defer db.deinit();
    databaseInit(&db) catch {
        std.log.debug("Figure out if there is a way to verify db being created other than catch.", .{});
    };
    var queue = EventQueue.init();
    defer queue.deinit();

    var running = true;
    while (running) {
        if (queue.get()) |cmd| {
            switch (cmd) {
                .Bail   => running = false,
                .Delete => |to_delete| {
                    for (to_delete) |id| {
                        if (db.query(schema.Image).find(id)) |found| {
                            if (found) |image| {
                                _ = try std.process.Child.run(.{.allocator = alloc, .argv = &.{"rm ", image.filename}});
                                _ = try db.delete(schema.Image, id);
                            }
                        }
                        else |_| {
                            std.log.info("no image with id {d}", .{id});
                        }
                    }
                },
                .Fetch => |filter| {
                    const request = switch (filter.value) {
                        .description    => |desc| ret: {
                            const filtering = std.fmt.allocPrint(alloc, "%{s}%", .{desc});
                            defer alloc.free(filtering);
                            break :ret db.query(schema.Image).whereRaw("description LIKE", desc);
                        },
                        .filename       => |name| ret: {
                            const filtering = std.fmt.allocPrint(alloc, "%{s}%", .{name});
                            defer alloc.free(filtering);
                            break :ret db.query(schema.Image).whereRaw("filename LIKE", name);
                        },
                        .tags           => |tags| ret: {
                            const filtering = std.fmt.allocPrint(alloc, "%{s}%", .{tags});
                            defer alloc.free(filtering);
                            break :ret db.query(schema.Image).whereRaw("tags LIKE", tags);
                        },
                    };

                    std.log.info("found: {s}", .{std.json.fmt(try request.findAll(), .{})});
                },
                .Insert => |to_insert| {
                    for (to_insert) |next| {
                        _ = try db.insert(schema.Image, next);
                    }
                },
                else => {},
            }
        }
        else {running = false;}
    }
}

test "search test" {
    std.testing.log_level = .info;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var db = try fr.Session.open(fr.SQLite3, alloc, .{ .filename = "database/test.sqlite" });
    defer db.deinit();
    try databaseInit(&db);


    var id = try db.insert(schema.Image, .{.filename = "test.jpg", .description = "test image with stuff", .tags="great,another,og"});
    std.log.info("id: {}", .{id});
    id = try db.insert(schema.Image, .{.filename = "another.jpg", .description = "another image", .tags="awesome,another,better"});
    std.log.info("id: {}", .{id});
    id = try db.insert(schema.Image, .{.filename = "bigboy.jpg", .description = "big boy image", .tags="great,awesome,better"});
    std.log.info("id: {}", .{id});

    std.log.info("basic search", .{});
    for (try db.query(schema.Image).findAll()) |image| {
        std.log.info("Image: {}", .{std.json.fmt(image, .{})});
    }

    std.log.info("col search", .{});
    const request = db.query(schema.Image).whereRaw("tags LIKE ?", "%better%");
    std.log.info("search: {s}\t found: {s}", .{"better", std.json.fmt(try request.findAll(), .{})});
}
