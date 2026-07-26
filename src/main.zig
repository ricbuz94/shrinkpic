const std = @import("std");
const c = @import("c_api");
const shrink = @import("shrinkpic");

const log = std.log.scoped(.sp);

var WorkerCount: usize = shrink.DEFAULT_WORKER_COUNT;
var MaxSize: usize = shrink.DEFAULT_MAX_SIZE;
var ForceJpeg: bool = shrink.DEFAULT_FORCE_JPEG;

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

fn compressAnyToWebP(io: anytype, allocator: std.mem.Allocator, path: []const u8, out_dir: []const u8) !void {
    const max_pixel_dim: c_int = 1920;

    // -------------------------------------------------------------------------
    // FASE 1: LETTURA UNIVERSALE (stb_image)
    // -------------------------------------------------------------------------
    const c_path = try allocator.dupeZ(u8, path);
    defer allocator.free(c_path);

    var width: c_int = 0;
    var height: c_int = 0;
    var comp: c_int = 0;
    if (c.stbi_info(c_path.ptr, &width, &height, &comp) == 0) {
        std.log.warn("Saltato file non supportato o non valido: {s}", .{path});
        return;
    }

    const req_channels: c_int = if (comp == 4) 4 else 3;
    const pixel_layout: c_uint = if (req_channels == 4) c.STBIR_RGBA else c.STBIR_RGB;

    const raw_pixels = c.stbi_load(c_path.ptr, &width, &height, &comp, req_channels) orelse return error.ImageLoadFailed;
    if (raw_pixels == null) {
        std.log.warn("SKIPPED file {s} is not a valid image", .{path});
        return;
    }
    defer c.stbi_image_free(raw_pixels);

    var final_pixels_ptr: [*]const u8 = @ptrCast(raw_pixels);
    var final_width = width;
    var final_height = height;

    var resized_buffer: ?[]u8 = null;
    defer {
        if (resized_buffer) |buf| allocator.free(buf);
    }

    // -------------------------------------------------------------------------
    // FASE 2: RIDIMENSIONAMENTO PROFESSIONALE (stb_image_resize2)
    // -------------------------------------------------------------------------
    if (width > max_pixel_dim or height > max_pixel_dim) {
        const w: u64 = @intCast(width);
        const h: u64 = @intCast(height);
        const max_dim: u64 = @intCast(max_pixel_dim);

        if (w >= h) {
            final_width = max_pixel_dim;
            final_height = @intCast(h * max_dim / w);
        } else {
            final_height = max_pixel_dim;
            final_width = @intCast(w * max_dim / h);
        }

        const new_size = @as(usize, @intCast(final_width * final_height * req_channels));
        resized_buffer = try allocator.alloc(u8, new_size);

        const resize_result = c.stbir_resize_uint8_linear(
            raw_pixels,
            width,
            height,
            0,
            resized_buffer.?.ptr,
            final_width,
            final_height,
            0,
            pixel_layout,
        );

        if (resize_result == null) {
            std.log.err("FAIL resizing {s}", .{path});
            return error.ImageResizeFailed;
        }
        final_pixels_ptr = resized_buffer.?.ptr;
    }

    // -------------------------------------------------------------------------
    // FASE 3: COMPRESSIONE E SCRITTURA (libwebp)
    // -------------------------------------------------------------------------
    if (ForceJpeg) {
        const ch = c.tjInitCompress() orelse return error.TjInit;
        defer _ = c.tjDestroy(ch);

        var quality: c_int = 90;
        while (quality >= 20) : (quality -= 5) {
            var out_buf: [*c]u8 = null;
            var out_size: c_ulong = 0;

            const pixel_format = if (req_channels == 4) c.TJPF_RGBA else c.TJPF_RGB;
            const flags: c_int = c.TJFLAG_PROGRESSIVE | c.TJFLAG_ACCURATEDCT;
            if (c.tjCompress2(ch, final_pixels_ptr, final_width, 0, final_height, pixel_format, &out_buf, &out_size, c.TJSAMP_420, quality, flags) != 0) {
                return error.TjCompress;
            }
            defer _ = c.tjFree(out_buf);

            if (out_size <= MaxSize) {
                const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.shrunk.jpg", .{ out_dir, std.fs.path.stem(path) });
                defer allocator.free(out_path);

                const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
                defer out_file.close(io);
                var file_writer = out_file.writer(io, &.{});
                try file_writer.interface.writeAll(out_buf[0..out_size]);

                var size_buf: [32]u8 = undefined;
                const formatted_size = try formatSize(out_size, &size_buf);
                log.info("OK {s} -> {s} (JPEG {d}x{d}, q={d})", .{ path, formatted_size, final_width, final_height, quality });
                return;
            }
        }
    } else {
        var quality: f32 = 90.0;
        while (quality >= 50.0) : (quality -= 5.0) {
            var out_buf: [*]u8 = undefined;

            const out_size = c.WebPEncodeRGB(final_pixels_ptr, final_width, final_height, final_width * req_channels, quality, @ptrCast(&out_buf));
            if (out_size == 0) return error.WebPCompressionFailed;
            defer c.WebPFree(out_buf);

            if (out_size <= MaxSize) {
                const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.webp", .{ out_dir, std.fs.path.stem(path) });
                defer allocator.free(out_path);

                const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
                defer out_file.close(io);
                var file_writer = out_file.writer(io, &.{});
                try file_writer.interface.writeAll(out_buf[0..out_size]);

                var size_buf: [32]u8 = undefined;
                const formatted_size = try formatSize(out_size, &size_buf);

                log.info("OK {s} -> {s} (WebP {d}x{d}, q={d:.0})", .{ path, formatted_size, final_width, final_height, quality });
                return;
            }
        }
    }
    var max_size_buf: [32]u8 = undefined;
    const formatted_max_size = try formatSize(MaxSize, &max_size_buf);
    log.warn("WARNING {s} still > {s}", .{ path, formatted_max_size });
}

fn worker(io: anytype, shared: *Shared) void {
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

        compressAnyToWebP(io, shared.allocator, job.path, job.out_dir) catch |e| {
            log.err("❌ err {s}: {}", .{ job.path, e });
        };
    }
}

fn parseSize(size_str: []const u8) !u64 {
    if (size_str.len < 3) return error.InvalidSizeFormat;
    const unit_idx = size_str.len - 2;
    const number_part = size_str[0..unit_idx];
    const unit_part = size_str[unit_idx..];
    const value = std.fmt.parseInt(u64, number_part, 10) catch return error.InvalidSizeNumber;
    if (std.ascii.eqlIgnoreCase(unit_part, "mb")) {
        return value * 1024 * 1024;
    } else if (std.ascii.eqlIgnoreCase(unit_part, "kb")) {
        return value * 1024;
    } else {
        return error.UnknownSizeUnit;
    }
}

pub fn formatSize(bytes: usize, buf: []u8) ![]const u8 {
    const one_mb = 1024 * 1024;
    const one_kb = 1024;

    if (bytes >= one_mb) {
        const mb_val = @as(f32, @floatFromInt(bytes)) / @as(f32, @floatFromInt(one_mb));
        return std.fmt.bufPrint(buf, "{d:.2} MB", .{mb_val});
    } else {
        const kb_val = bytes / one_kb;
        return std.fmt.bufPrint(buf, "{d} KB", .{kb_val});
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2) {
        log.warn("⚠️ usage: shrinkpic <in-dir> [out-dir] --size=<dimensione>(MB|KB)", .{});
        return;
    }

    var dir_path: ?[]const u8 = null;
    var out_dir_opt: ?[]const u8 = null;
    var max_size_parsed: ?u64 = null;
    var force_jpeg: bool = false;
    var worker_count: ?usize = null;
    var positional_count: usize = 0;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--size=")) {
            const size_str = arg["--size=".len..];
            max_size_parsed = parseSize(size_str) catch |err| {
                log.err("❌ --size is in the wrong format: {}", .{err});
                return err;
            };
        } else if (std.mem.startsWith(u8, arg, "--workers=")) {
            const workers_str = arg["--workers=".len..];
            const parsed_count: usize = std.fmt.parseInt(usize, workers_str, 10) catch {
                log.err("❌ --workers has to be a valid integer", .{});
                return error.InvalidWorkersNumber;
            };

            if (parsed_count < 1 or parsed_count > 8) {
                log.err("❌ --workers should be between 1 and 8 (submitted: {d})", .{parsed_count});
                return error.InvalidWorkersCount;
            }

            worker_count = parsed_count;
        } else if (std.mem.eql(u8, arg, "--jpeg")) {
            force_jpeg = true;
        } else {
            if (positional_count == 0) {
                dir_path = arg;
                positional_count += 1;
            } else if (positional_count == 1) {
                out_dir_opt = arg;
                positional_count += 1;
            } else {
                log.err("❌ too much positional arguments", .{});
                return error.TooManyArguments;
            }
        }
    }

    const final_dir_path = dir_path orelse {
        log.warn("⚠️ missing <in-dir>", .{});
        return error.MissingInDir;
    };

    const out_dir = out_dir_opt orelse final_dir_path;
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    WorkerCount = worker_count orelse shrink.DEFAULT_WORKER_COUNT;
    MaxSize = max_size_parsed orelse shrink.DEFAULT_MAX_SIZE;
    ForceJpeg = force_jpeg or shrink.DEFAULT_FORCE_JPEG;

    var shared = Shared{
        .queue = std.ArrayList(Job).empty,
        .allocator = allocator,
    };
    defer shared.queue.deinit(allocator);

    var dir = try std.Io.Dir.cwd().openDir(io, final_dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;

        const full = try std.fs.path.join(allocator, &.{ final_dir_path, entry.name });
        try shared.queue.append(allocator, .{ .path = full, .out_dir = out_dir });
    }

    const threads = try allocator.alloc(std.Thread, WorkerCount);
    defer allocator.free(threads);

    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{ io, &shared });
    }

    try shared.mutex.lock(io);
    shared.done = true;
    shared.mutex.unlock(io);

    for (threads) |t| t.join();

    for (shared.queue.items) |j| allocator.free(j.path);
}
