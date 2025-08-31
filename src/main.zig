const event = @import("events.zig");
const queues = @import("message_queue.zig");
const schema = @import("schema.zig");
const socket = @import("socket.zig");

const ai = @import("zig_ai");
const Allocator = std.mem.Allocator;
const fr = @import("fridge");
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;


const BUF_SIZE = 16;
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

fn databaseInit(alloc: Allocator, db: *fr.Session, client: *ai.Client) !void {
    db.conn.execAll(
        \\CREATE TABLE Image (
        \\  id INTEGER PRIMARY KEY,
        \\  description TEXT NOT NULL,
        \\  filename TEXT NOT NULL,
        \\  tags TEXT NOT NULL
        \\);
    ) catch {std.log.info("table already exists", .{});};

    // initial integrity check. If a file is missing, report and remove
    for (try db.query(schema.Image).findAll()) |image| {
        if (exists(image.filename) == false) {
            std.log.warn("missing {s}. Removing from database", .{image.filename});
            try db.delete(schema.Image, image.id);
        }
    }

    // add any image that is just in the database folder into the metadata sql
    var dir = try std.fs.cwd().openDir("database", .{.iterate = true});
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |next| {
        const ext = std.fs.path.extension(next.basename);
        if (std.mem.eql(u8, ext, ".jpg")) {
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{"database", next.basename});
            defer alloc.free(path);
            _ = try insert(alloc, db, client, path);
        }
    }
}

fn description_generate(alloc: Allocator, client: *ai.Client, filename: String) !String {
    const file = try std.fs.cwd().openFile(filename, .{});
    const messages: []const ai.Message = &.{
        .system("You are the worlds greatest radio host. Your usage of words to describe images are unmatched. Please apply your abilities to the following image. Try to keep it under 2 paragraphs."),
        try .image(alloc, "Please write a description of this image", file),
    };
    defer {
        for (messages) |next| {
            for (next.content) |content| {
                switch (content) {
                    .Image => |image| alloc.free(image.image_url),
                    else => {},
                }
            }
        }
    }

    const response = try client.chat(.{
        .model = "gemma3:4b",
        .messages = messages,
        .max_tokens = 10000,
        .temperature = 0.7
    }, false);
    defer response.deinit();

    return response.value.choices[0].message.content;
}

fn exists(filename: String) bool {
    if (std.fs.cwd().openFile(filename, .{})) |file| {
        defer file.close();
        return true;
    }
    else |_| {return false;}
}

fn insert(alloc: Allocator, db: *fr.Session, client: *ai.Client, og_path: String) !ID {
    std.log.info("inserting {s}", .{og_path});
    const file = try std.fs.cwd().openFile(og_path, .{});
    defer file.close();
    const extension = std.fs.path.extension(og_path);
    const digest = try sha256_digest(file);
    const hashed_name = try std.fmt.allocPrint(alloc, "database/{s}{s}", .{std.fmt.fmtSliceHexLower(&digest), extension});
    defer alloc.free(hashed_name);
    try std.fs.cwd().copyFile(og_path, std.fs.cwd(), hashed_name, .{});
    const description = try description_generate(alloc, client, hashed_name);
    defer alloc.free(description);
    const tags = try tags_generate(alloc, client, hashed_name);
    defer alloc.free(tags);
    return db.insert(schema.Image, .{
        .filename = hashed_name,
        .description = description,
        .tags = tags,
    });
}

fn open_config(alloc: std.mem.Allocator, config_file: []const u8) !std.json.Parsed(Config) {
    var file = try std.fs.cwd().openFile(config_file, .{});
    defer file.close();

    const json = try file.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(json);
    return try std.json.parseFromSlice(Config, alloc, json, .{.allocate = .alloc_always, .ignore_unknown_fields = true});
}

fn sha256_digest(file: std.fs.File) ![Sha256.digest_length]u8 {
    var sha256 = Sha256.init(.{});
    const rdr = file.reader();

    var buf: [BUF_SIZE]u8 = undefined;
    var n = try rdr.read(&buf);
    while (n != 0) {
        sha256.update(buf[0..n]);
        n = try rdr.read(&buf);
    }

    return sha256.finalResult();
}

fn tags_generate(alloc: Allocator, client: *ai.Client, filename: String) !String {
    const file = try std.fs.cwd().openFile(filename, .{});
    const messages: []const ai.Message = &.{
        .system("You are the worlds greatest tag generator. You generate tags to give breif descriptions of images. Give a list of tags that would apply to the following image. Your response should be in the form of a comma separated list."),
        try .image(alloc, "Please write a description of this image", file),
    };
    defer {
        for (messages) |next| {
            for (next.content) |content| {
                switch (content) {
                    .Image => |image| alloc.free(image.image_url),
                    else => {},
                }
            }
        }
    }

    const response = try client.chat(.{
        .model = "gemma3:4b",
        .messages = messages,
        .max_tokens = 10000,
        .temperature = 0.7
    }, false);
    defer response.deinit();

    return response.value.choices[0].message.content;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const config = try open_config(alloc, "config.json");
    defer config.deinit();
    var client = try ai.Client.init(alloc, config.value.ai_url, "ollama", null);
    defer client.deinit();

    var db = try fr.Session.open(fr.SQLite3, alloc, .{ .filename = config.value.metadata });
    defer db.deinit();
    databaseInit(alloc, &db, &client) catch |err| {
        std.log.debug("Figure out if there is a way to verify db being created other than catch.\n{s}", .{std.json.fmt(err, .{})});
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
//                .Fetch => |filter| {
//                    const request = switch (filter.value) {
//                        .description    => |desc| ret: {
//                            const filtering = std.fmt.allocPrint(alloc, "%{s}%", .{desc});
//                            defer alloc.free(filtering);
//                            break :ret db.query(schema.Image).whereRaw("description LIKE", desc);
//                        },
//                        .filename       => |name| ret: {
//                            const filtering = std.fmt.allocPrint(alloc, "%{s}%", .{name});
//                            defer alloc.free(filtering);
//                            break :ret db.query(schema.Image).whereRaw("filename LIKE", name);
//                        },
//                        .tags           => |tags| ret: {
//                            const filtering = std.fmt.allocPrint(alloc, "%{s}%", .{tags});
//                            defer alloc.free(filtering);
//                            break :ret db.query(schema.Image).whereRaw("tags LIKE", tags);
//                        },
//                    };
//
//                    std.log.info("found: {s}", .{std.json.fmt(try request.findAll(), .{})});
//                },
                .Insert => |to_insert| {
                    for (to_insert) |next| {
                        _ = try db.insert(schema.Image, next);
                        //_ = try insert(alloc, &db, &client, next);
                    }
                },
                else => {},
            }
        }
        else {running = false;}
    }
}

test "search test" {
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
