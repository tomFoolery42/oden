const schema = @import("schema.zig");

pub const Event = union(enum) {
    Bail,
    Delete:     []schema.ID,
    Fetch:      Filter,
    Found:      []schema.Image,
    Generate:   schema.String,
    Generated:  schema.Image,
    Insert:     []schema.Image,
    Update:     []schema.Image,
};

pub const Filter = struct {
    value: FilterValue,
    limit: u64
};

const FilterValue = union(enum) {
    description:    schema.String,
    filename:       schema.String,
    tags:           schema.String,
};
