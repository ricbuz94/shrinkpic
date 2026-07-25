const std = @import("std");
const c = @import("c_api");
const shrink = @import("shrinkpic");

const MAX_SIZE = shrink.MAX_SIZE;
const WorkerCount = 8;

const Job = struct {
    path: []const u8,
    out_dir: []const u8,
};

const Shared = struct {
    mutex: std.Io.Mutex = .init,
    queue: std.ArrayList(Job),
    done: bool = false,
    allocator: std.mem.Allocator,
};

fn compressJpeg(io: std.Io, allocator: std.mem.Allocator, path: []const u8, pixels: []const u8, width: c_int, height: c_int, subsamp: c_int, out_dir: []const u8) !void {
    const ch = c.tjInitCompress();
    if (ch == null) return error.TjInit;
    defer _ = c.tjDestroy(ch);

    var quality: c_int = 90;
    while (quality >= 20) : (quality -= 5) {
        var out_buf: [*c]u8 = null;
        var out_size: c_ulong = 0;
        if (c.tjCompress2(ch, pixels.ptr, width, 0, height, c.TJPF_RGB, &out_buf, &out_size, subsamp, quality, 0) != 0)
            return error.TjCompress;
        defer _ = c.tjFree(out_buf);

        if (out_size <= MAX_SIZE) {
            const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.shrunk.jpg", .{ out_dir, std.fs.path.stem(path) });
            defer allocator.free(out_path);
            const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
            defer out_file.close(io);
            var file_writer = out_file.writer(io, &.{});
            try file_writer.interface.writeAll(out_buf[0..out_size]);
            std.debug.print("OK {s} -> {d} bytes q={d}\n", .{ path, out_size, quality });
            return;
        }
    }
    std.debug.print("FAIL {s} still >1MB\n", .{path});
}

fn processJpeg(io: std.Io, allocator: std.mem.Allocator, path: []const u8, out_dir: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});

    const data = try file_reader.interface.allocRemaining(allocator, .limited(50 * 1024 * 1024));
    defer allocator.free(data);

    const handle = c.tjInitDecompress();
    if (handle == null) return error.TjInit;
    defer _ = c.tjDestroy(handle);

    var width: c_int = 0;
    var height: c_int = 0;
    var subsamp: c_int = 0;
    var colorspace: c_int = 0;
    if (c.tjDecompressHeader3(handle, data.ptr, @intCast(data.len), &width, &height, &subsamp, &colorspace) != 0)
        return error.TjHeader;

    const pixels = try allocator.alloc(u8, @intCast(width * height * 3));
    defer allocator.free(pixels);

    if (c.tjDecompress2(handle, data.ptr, @intCast(data.len), pixels.ptr, width, 0, height, c.TJPF_RGB, 0) != 0)
        return error.TjDecompress;

    try compressJpeg(io, allocator, path, pixels, width, height, subsamp, out_dir);
}

fn processPng(io: std.Io, allocator: std.mem.Allocator, path: []const u8, out_dir: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    const data = try file_reader.interface.allocRemaining(allocator, .limited(50 * 1024 * 1024));
    defer allocator.free(data);

    var png_ptr = c.png_create_read_struct(c.PNG_LIBPNG_VER_STRING, null, null, null);
    if (png_ptr == null) return error.PngInit;
    defer c.png_destroy_read_struct(&png_ptr, null, null);

    const info_ptr = c.png_create_info_struct(png_ptr);
    if (info_ptr == null) return error.PngInit;

    var offset: usize = 0;
    const ReadCtx = struct {
        data: []const u8,
        offset: *usize,
        fn read(png: ?*c.png_struct, buf: [*c]u8, len: c.png_size_t) callconv(.c) void {
            const ctx: *@This() = @ptrCast(@alignCast(c.png_get_io_ptr(png)));
            const remaining = ctx.data.len - ctx.offset.*;
            const n = @min(remaining, len);
            @memcpy(buf[0..n], ctx.data[ctx.offset.*..][0..n]);
            ctx.offset.* += n;
        }
    };
    var ctx = ReadCtx{ .data = data, .offset = &offset };
    c.png_set_read_fn(png_ptr, &ctx, ReadCtx.read);

    c.png_read_info(png_ptr, info_ptr);
    const width = c.png_get_image_width(png_ptr, info_ptr);
    const height = c.png_get_image_height(png_ptr, info_ptr);
    const color_type = c.png_get_color_type(png_ptr, info_ptr);
    const bit_depth = c.png_get_bit_depth(png_ptr, info_ptr);

    if (bit_depth == 16) c.png_set_strip_16(png_ptr);
    if (color_type == c.PNG_COLOR_TYPE_PALETTE) c.png_set_palette_to_rgb(png_ptr);
    if (color_type == c.PNG_COLOR_TYPE_GRAY and bit_depth < 8) c.png_set_expand_gray_1_2_4_to_8(png_ptr);
    if (c.png_get_valid(png_ptr, info_ptr, c.PNG_INFO_tRNS) != 0) c.png_set_tRNS_to_alpha(png_ptr);
    if (color_type == c.PNG_COLOR_TYPE_RGB or color_type == c.PNG_COLOR_TYPE_GRAY or color_type == c.PNG_COLOR_TYPE_PALETTE)
        c.png_set_filler(png_ptr, 0xFF, c.PNG_FILLER_AFTER);
    if (color_type == c.PNG_COLOR_TYPE_GRAY or color_type == c.PNG_COLOR_TYPE_GRAY_ALPHA)
        c.png_set_gray_to_rgb(png_ptr);

    c.png_read_update_info(png_ptr, info_ptr);

    const row_bytes = c.png_get_rowbytes(png_ptr, info_ptr);
    const pixels = try allocator.alloc(u8, @intCast(row_bytes * height));
    defer allocator.free(pixels);

    var row_ptrs = try allocator.alloc([*c]u8, @intCast(height));
    defer allocator.free(row_ptrs);
    for (0..height) |y| row_ptrs[y] = pixels.ptr + y * row_bytes;

    c.png_read_image(png_ptr, row_ptrs.ptr);
    c.png_read_end(png_ptr, null);

    // RGBA → RGB
    const rgb = try allocator.alloc(u8, @intCast(width * height * 3));
    defer allocator.free(rgb);

    const px = @as(usize, @intCast(width * height));
    var i: usize = 0;
    var j: usize = 0;
    while (i < px) : (i += 1) {
        rgb[j] = pixels[i * 4];
        rgb[j + 1] = pixels[i * 4 + 1];
        rgb[j + 2] = pixels[i * 4 + 2];
        j += 3;
    }

    try compressJpeg(io, allocator, path, rgb, @intCast(width), @intCast(height), c.TJSAMP_420, out_dir);
}

fn worker(io: std.Io, shared: *Shared) void {
    while (true) {
        shared.mutex.lockUncancelable(io);

        if (shared.queue.items.len == 0) {
            if (shared.done) {
                shared.mutex.unlock(io);
                return;
            }
            shared.mutex.unlock(io);
            var ts = std.posix.timespec{ .sec = 0, .nsec = 1_000_000 };
            _ = std.posix.system.nanosleep(&ts, &ts);
            continue;
        }

        const job = shared.queue.orderedRemove(0);
        shared.mutex.unlock(io);

        const ext = std.fs.path.extension(job.path);

        if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
            processJpeg(io, shared.allocator, job.path, job.out_dir) catch |e| {
                std.debug.print("err jpeg {s}: {}\n", .{ job.path, e });
            };
        } else if (std.mem.eql(u8, ext, ".png")) {
            processPng(io, shared.allocator, job.path, job.out_dir) catch |e| {
                std.debug.print("err png {s}: {}\n", .{ job.path, e });
            };
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2) {
        std.debug.print("usage: shrinkpic <dir>\n", .{});
        return;
    }

    const dir_path = args[1];

    const out_dir = if (args.len >= 3) args[2] else dir_path;
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var shared = Shared{
        .queue = std.ArrayList(Job).empty,
        .allocator = allocator,
    };
    defer shared.queue.deinit(allocator);

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        try shared.queue.append(allocator, .{ .path = full, .out_dir = out_dir });
    }

    var threads: [WorkerCount]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{ io, &shared });
    }

    try shared.mutex.lock(io);
    shared.done = true;
    shared.mutex.unlock(io);

    for (threads) |t| t.join();

    for (shared.queue.items) |j| allocator.free(j.path);
    std.debug.print("done\n", .{});
}
