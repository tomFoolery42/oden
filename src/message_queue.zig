const std = @import("std");

pub fn MessageQueue(comptime T: type, comptime max_size: u32) type {
    return struct {
        const Self = @This();
        queue:      std.fifo.LinearFifo(T, .{.Static = max_size}),
        condition:  std.Thread.Condition,
        mutex:      std.Thread.Mutex,
        put_mutex:  std.Thread.Mutex,

        pub fn init() Self {
            return .{
                .queue = std.fifo.LinearFifo(T, .{.Static = max_size}).init(),
                .condition = .{},
                .mutex = .{},
                .put_mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.condition.signal();
            self.queue.deinit();
        }

        pub fn get(self: *Self) ?T {
            if (self.queue.readableLength() == 0) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.condition.wait(&self.mutex);
            }

            return self.queue.readItem();
        }

        pub fn put(self: *Self, item: T) !void {
            self.put_mutex.lock();
            defer self.put_mutex.unlock();
            try self.queue.writeItem(item);
            self.condition.signal();
        }
    };
}
