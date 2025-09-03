const schema = @import("schema.zig");

const ai = @import("zig_ai");
const Allocator = std.mem.Allocator;
const fr = @import("fridge");
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const ID = schema.ID;
const BUF_SIZE = 16;
const DatabaseError = error{
    NotFound,
};
const Self = @This();
const String = schema.String;

const description_system = "You are the worlds greatest meme smith. Your usage of words to describe images are unmatched. Please apply your abilities to the following image. If there are any words on the image, take note of them. If there are any recognizable characters, take note of them. Other than that, try to keep your description under 1 paragraph.";
const model = "gemma3:4b";
const tags_system = "You are the worlds greatest meme smith. You generate tags to give breif descriptions of images. Give a list of tags that would apply to the following image. Your response should be in the form of a comma separated list.";

alloc: Allocator,
client: ai.Client,
database_root: String,
db: fr.Session,

pub fn init(alloc: Allocator, ollama_url: String, database_root: String, metadata: [:0]const u8) !*Self {
    var self = try alloc.create(Self);
    self.* = .{
        .alloc = alloc,
        .client = try ai.Client.init(alloc, ollama_url, "ollama", null),
        .database_root = database_root,
        .db = try fr.Session.open(fr.SQLite3, alloc, .{ .filename = metadata }),
    };
    
    self.db.conn.execAll(
        \\CREATE TABLE Image (
        \\  id INTEGER PRIMARY KEY,
        \\  description TEXT NOT NULL,
        \\  filename TEXT NOT NULL,
        \\  tags TEXT NOT NULL
        \\);
    ) catch {std.log.info("table already exists", .{});};
    self.db.conn.execAll(
        \\CREATE TABLE hash (
        \\  id TEXT PRIMARY KEY,
        \\  image_id INTEGER
        \\);
    ) catch {std.log.info("hash table already exists", .{});};

    // initial integrity check. If a file is missing, report and remove
    for (try self.db.query(schema.Image).findAll()) |image| {
        if (exists(image.filename) == false) {
            std.log.warn("missing {s}. Removing from database", .{image.filename});
            try self.delete(image.id);
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
            _ = try self.insert(path);
        }
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
    self.db.deinit();
    self.alloc.destroy(self);
}

pub fn delete(self: *Self, id: ID) !void {
    if (self.db.query(schema.Image).find(id)) |found| {
        if (found) |image| {
            _ = try std.process.Child.run(.{.allocator = self.alloc, .argv = &.{"rm ", image.filename}});
            _ = try self.db.delete(schema.Image, id);
        }
    }
    else |_| {
        std.log.info("no image with id {d}", .{id});
    }
}

fn descriptionGenerate(self: *Self, filename: String) !String {
    const file = try std.fs.cwd().openFile(filename, .{});
    const messages: []const ai.Message = &.{
        .system(description_system),
        try .image(self.alloc, "Please write a description of this image", file),
    };
    defer {
        for (messages) |next| {
            next.deinit();
        }
    }

    const response = try self.client.chat(.{
        .model = model,
        .messages = messages,
        .max_tokens = 10000,
        .temperature = 0.7
    }, false);
    defer response.deinit();

    return self.alloc.dupe(u8, response.value.choices[0].message.content);
}

fn exists(filename: String) bool {
    if (std.fs.cwd().openFile(filename, .{})) |file| {
        defer file.close();
        return true;
    }
    else |_| {return false;}
}

pub fn findAll(self: *Self) ![]const schema.Image {
    return try self.db.query(schema.Image).findAll();
}

pub fn insert(self: *Self, og_path: String) !ID {
    std.log.info("inserting {s}", .{og_path});
    const file = try std.fs.cwd().openFile(og_path, .{});
    defer file.close();
    const extension = std.fs.path.extension(og_path);
    const digest = try sha256Digest(file);
    const hashed = try std.fmt.allocPrint(self.alloc, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
    defer self.alloc.free(hashed);
    const hashed_name = try std.fmt.allocPrint(self.alloc, "{s}/{s}{s}", .{self.database_root, hashed, extension});
    defer self.alloc.free(hashed_name);

    const existing = try self.db.query(schema.Hash).find(hashed);
    if (existing) |hash| {
        if (try self.db.query(schema.Image).find(hash.image_id)) |found| {
            return found.id;
        }
        else {
            return DatabaseError.NotFound;
        }
    }
    else {
        try std.fs.cwd().copyFile(og_path, std.fs.cwd(), hashed_name, .{});
        const description = try self.descriptionGenerate(hashed_name);
        defer self.alloc.free(description);
        const tags = try self.tagsGenerate(hashed_name);
        defer self.alloc.free(tags);

        return self.db.insert(schema.Image, .{
            .filename = hashed_name,
            .description = description,
            .tags = tags,
        });
    }
}

pub fn like(self: *Self, field: String, target: String) ![]const schema.Image {
    const query = try std.fmt.allocPrint(self.alloc, "{s} LIKE ?", .{field});
    defer self.alloc.free(query);
    const search = try std.fmt.allocPrint(self.alloc, "%{s}%", .{target});
    defer self.alloc.free(search);
    const request = self.db.query(schema.Image).whereRaw(query, search);
    return request.findAll();
}

fn sha256Digest(file: std.fs.File) ![Sha256.digest_length]u8 {
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

fn tagsGenerate(self: *Self, filename: String) !String {
    const file = try std.fs.cwd().openFile(filename, .{});
    const messages: []const ai.Message = &.{
        .system(tags_system),
        try .image(self.alloc, "Please write a description of this image", file),
    };
    defer {
        for (messages) |next| {
            next.deinit();
        }
    }

    const response = try self.client.chat(.{
        .model = model,
        .messages = messages,
        .max_tokens = 10000,
        .temperature = 0.7
    }, false);
    defer response.deinit();

    return self.alloc.dupe(u8, response.value.choices[0].message.content);
}

pub fn where(self: *Self, field: String, target: String) ![]const schema.Image {
    const query = try std.fmt.allocPrint(self.alloc, "{s} = ?", .{field});
    defer self.alloc.free(query);
    const request = self.db.query(schema.Image).where(query, target);
    return request.findAll();
}
