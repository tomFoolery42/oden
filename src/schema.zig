pub const ID        = u32;
pub const String    = []const u8;

pub const Image = struct {
    id:         ID,
    description:String,
    filename:   String,
    tags:       String,
};

pub const Hash = struct {
    id:         String, // should be called hash. Just easier to work with fridge if I use the hash as named id
    image_id:   ID,
};

pub const Searchable = struct {
    value:      String,
    image_id:   ID,
};
