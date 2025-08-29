const std = @import("std");

pub fn AtomicPool(comptime Item: type) type {
    const MemoryPool = std.heap.MemoryPoolAligned(Item, @alignOf(Item));

    return struct {
        const Self = @This();
        const ItemPtr = *Item;

        pool:   MemoryPool,
        mutex:  std.Thread.Mutex,

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .pool = MemoryPool.init(alloc),
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pool.deinit();
        }

        pub fn create(self: *Self) !ItemPtr {
            self.mutex.lock();
            defer self.mutex.unlock();
            return try self.pool.create();
        }

        pub fn destroy(self: *Self, ptr: ItemPtr) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pool.destroy(ptr);
        }
    };
}
