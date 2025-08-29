const atomic = @import("memory_pool.zig");

const std = @import("std");
const base64 = std.base64;
const posix = std.posix;


pub fn Client(comptime T: type) type {
    return struct {
        const AtomicPool = atomic.AtomicPool(T);
        const Self = @This();

        alloc:          std.mem.Allocator,
        message_pool:   AtomicPool,
        s:              std.net.Stream,
        write_mutex:    std.Thread.Mutex,

        pub fn init(alloc: std.mem.Allocator, message_pool: AtomicPool, path: []const u8) !Self {
            return .{
                .alloc = alloc,
                .message_pool = message_pool,
                .s  = try std.net.connectUnixSocket(path),
                .write_mutex = .{},
            };
        }

        pub fn close(self: *Self) void {
            self.s.close();
        }

        pub fn read(self: *Self) !*T {
            var length_ptr: [2]u8 = undefined;
            _ = try self.s.read(&length_ptr);
            const length: u16 = std.mem.readInt(u16, &length_ptr, .big);

            const buffer = try self.alloc.alloc(u8, length);
            defer self.alloc.free(buffer);
            _ = try self.s.read(buffer);

            const decoded_length: u16 = @intCast(try base64.standard.Decoder.calcSizeForSlice(buffer));
            const decoded = try self.alloc.alloc(u8, decoded_length);
            defer self.alloc.free(decoded);
            _ = try base64.standard.Decoder.decode(decoded, buffer);
//            std.debug.print("raw buffer: {s}\n", .{decoded});
            const decoded_event = try self.message_pool.create();
            decoded_event.* = try std.json.parseFromSliceLeaky(T, self.alloc, decoded, .{.allocate = .alloc_always});

            return decoded_event;
        }

        pub fn timeoutSet(self: *Self, timeout_s: isize) !void {
            const timeout: posix.timeval = .{.sec = timeout_s, .usec = 0};
            try posix.setsockopt(self.s.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        }

        pub fn write(self: *Self, m: T) !void {
            const message = try std.fmt.allocPrint(self.alloc, "{s}", .{std.json.fmt(m, .{})});
            defer self.alloc.free(message);

            const encoded_length: u16 = @intCast(base64.standard.Encoder.calcSize(message.len));
            const encoded = try self.alloc.alloc(u8, encoded_length + 2);
            defer self.alloc.free(encoded);
            _ = base64.standard.Encoder.encode(encoded[2..], message);
            std.mem.writeInt(u16, encoded[0..2], encoded_length, .big);

            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            _ = try self.s.write(encoded);
        }
    };
}

pub fn Server(comptime T: type) type {
    return struct {
        const AtomicPool = atomic.AtomicPool(T);
        const Self = @This();

        alloc:          std.mem.Allocator,
        message_pool:   AtomicPool,
        path:           []const u8,
        server:         std.net.Server,

        pub fn init(alloc: std.mem.Allocator, pool: AtomicPool, path: []const u8) !Self {
            return .{
                .alloc = alloc,
                .message_pool = pool,
                .path = path,
                .server = try std.net.Address.listen(try std.net.Address.initUnix(path), .{.kernel_backlog = 10}),
            };
        }

        pub fn deinit(self: *Self) void {
            self.server.deinit();
            std.fs.deleteFileAbsolute(self.path) catch {};
//            self.message_pool.deinit();
        }

        pub fn accept(self: *Self, timeout_s: isize) !*Client(T) {
            const connection = try self.server.accept();
            const client = try self.alloc.create(Client(T));
            client.* = .{
                .alloc = self.alloc,
                .message_pool = self.message_pool,
                .s = connection.stream,
                .write_mutex = .{},
            };

            const timeout: posix.timeval = .{.sec = timeout_s, .usec = 0};
            try posix.setsockopt(client.s.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));

            return client;
        }
    };
}
