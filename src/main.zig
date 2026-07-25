const std = @import("std");
const c = @import("c_api");
const shrink = @import("shrinkpic");

const MAX_SIZE = shrink.MAX_SIZE;
const WorkerCount = 8;

const Job = struct {
    path: []const u8,
};

const Shared = struct {
    mutex: std.Io.Mutex = .init,
    queue: std.ArrayList(Job),
    done: bool = false,
    allocator: std.mem.Allocator,
};

fn processJpeg(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
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
            const out_path = try std.fmt.allocPrint(allocator, "{s}.shrunk.jpg", .{path});
            defer allocator.free(out_path);
            const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
            defer out_file.close(io);

            var file_writer = out_file.writer(io, &.{});
            try file_writer.interface.writeAll(out_buf[0..out_size]);
            std.debug.print("OK jpeg {s} -> {d} bytes q={d}\n", .{ path, out_size, quality });
            return;
        }
    }
    std.debug.print("FAIL jpeg {s} still >1MB\n", .{path});
}

fn processPng(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
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

    // Scale down until under ~1MB (estimate)
    var scale: f32 = 1.0;
    const max_pixels: u64 = 2_000_000;
    if (@as(u64, width) * height > max_pixels) {
        scale = @sqrt(@as(f32, @floatFromInt(max_pixels)) / @as(f32, @floatFromInt(width * height)));
    }
    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        const sw: u32 = @intFromFloat(@as(f32, @floatFromInt(width)) * scale);
        const sh: u32 = @intFromFloat(@as(f32, @floatFromInt(height)) * scale);
        if (sw < 16 or sh < 16) break;

        // Simple nearest-neighbor downsample
        const srow = sw * 4;
        const scaled = try allocator.alloc(u8, srow * sh);
        defer allocator.free(scaled);
        for (0..sh) |y| {
            const sy = @as(usize, @intFromFloat(@as(f32, @floatFromInt(y)) / scale));
            const src = pixels[sy * row_bytes ..][0..row_bytes];
            const dst = scaled[y * srow ..][0..srow];
            for (0..sw) |x| {
                const sx = @as(usize, @intFromFloat(@as(f32, @floatFromInt(x)) / scale)) * 4;
                @memcpy(dst[x * 4 ..][0..4], src[sx..][0..4]);
            }
        }

        // Quantize to 256 colors (first-seen)
        var palette: [256]c.png_color = undefined;
        var palette_size: c_int = 0;
        var color_map = std.AutoHashMap(u32, u8).init(allocator);
        defer color_map.deinit();

        for (0..sh) |y| {
            const row = scaled[y * srow ..][0..srow];
            var x: usize = 0;
            while (x + 3 < row.len) : (x += 4) {
                const key: u32 = (@as(u32, row[x]) << 16) | (@as(u32, row[x + 1]) << 8) | row[x + 2];
                if (color_map.get(key) == null and palette_size < 256) {
                    try color_map.put(key, @intCast(palette_size));
                    palette[@intCast(palette_size)] = .{ .red = row[x], .green = row[x + 1], .blue = row[x + 2] };
                    palette_size += 1;
                }
            }
        }

        const indexed = try allocator.alloc(u8, sw * sh);
        defer allocator.free(indexed);
        for (0..sh) |y| {
            const row = scaled[y * srow ..][0..srow];
            for (0..sw) |x| {
                const key: u32 = (@as(u32, row[x * 4]) << 16) | (@as(u32, row[x * 4 + 1]) << 8) | row[x * 4 + 2];
                indexed[y * sw + x] = color_map.get(key) orelse 0;
            }
        }

        // Write
        var write_png = c.png_create_write_struct(c.PNG_LIBPNG_VER_STRING, null, null, null);
        if (write_png == null) return error.PngInit;
        defer c.png_destroy_write_struct(&write_png, null);
        const write_info = c.png_create_info_struct(write_png);
        if (write_info == null) return error.PngInit;

        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(allocator);
        const WriteCtx = struct {
            list: *std.ArrayList(u8),
            alloc: std.mem.Allocator,
            fn write(png: ?*c.png_struct, buf: [*c]u8, len: c.png_size_t) callconv(.c) void {
                const context: *@This() = @ptrCast(@alignCast(c.png_get_io_ptr(png)));
                context.list.appendSlice(context.alloc, buf[0..len]) catch {};
            }
        };
        var wctx = WriteCtx{ .list = &out_buf, .alloc = allocator };
        c.png_set_write_fn(write_png, &wctx, WriteCtx.write, null);

        c.png_set_IHDR(write_png, write_info, sw, sh, 8, c.PNG_COLOR_TYPE_PALETTE, c.PNG_INTERLACE_NONE, c.PNG_COMPRESSION_TYPE_DEFAULT, c.PNG_FILTER_TYPE_DEFAULT);
        c.png_set_PLTE(write_png, write_info, &palette, palette_size);
        c.png_write_info(write_png, write_info);

        var idx_rows = try allocator.alloc([*c]u8, sh);
        defer allocator.free(idx_rows);
        for (0..sh) |y| idx_rows[y] = indexed.ptr + y * sw;
        c.png_write_image(write_png, idx_rows.ptr);
        c.png_write_end(write_png, null);

        if (out_buf.items.len <= MAX_SIZE) {
            const out_path = try std.fmt.allocPrint(allocator, "{s}.shrunk.png", .{path});
            defer allocator.free(out_path);
            const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
            defer out_file.close(io);
            var file_writer = out_file.writer(io, &.{});
            try file_writer.interface.writeAll(out_buf.items);
            std.debug.print("OK png {s} -> {d} bytes (palette {d} scale {d})\n", .{ path, out_buf.items.len, palette_size, scale });
            return;
        }
        scale *= 0.7;
    }
    std.debug.print("FAIL png {s} cannot fit under 1MB\n", .{path});
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
            processJpeg(io, shared.allocator, job.path) catch |e| {
                std.debug.print("err jpeg {s}: {}\n", .{ job.path, e });
            };
        } else if (std.mem.eql(u8, ext, ".png")) {
            processPng(io, shared.allocator, job.path) catch |e| {
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
        try shared.queue.append(allocator, .{ .path = full });
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
