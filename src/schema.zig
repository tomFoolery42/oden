pub const ID        = u32;
pub const String    = []const u8;

pub const Image = struct {
    id:         ID,
    description:String,
    filename:   String,
    tags:       String,
};

pub const Searchable = struct {
    value:      String,
    image_id:   ID,
};
