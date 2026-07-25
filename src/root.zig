const std = @import("std");
const c = @import("c_api");

pub const ImageType = enum { jpeg, png, unknown };

pub const ImageFile = struct { path: []const u8, type: ImageType };

pub fn scanDirectory(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(ImageFile) {
    var list = std.ArrayList(ImageFile).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item.path);
        list.deinit();
    }

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            var img_type = ImageType.unknown;

            if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) {
                img_type = .jpeg;
            } else if (std.ascii.eqlIgnoreCase(ext, ".png")) {
                img_type = .png;
            }

            if (img_type != .unknown) {
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                try list.append(.{ .path = full_path, .type = img_type });
            }
        }
    }
    return list;
}
