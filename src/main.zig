const std = @import("std");
const c = @import("c_api");
const Io = std.Io;

const shrinkpic = @import("shrinkpic");
const compress = @import("compress.zig");

const CompressionJob = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    file_type: shrinkpic.ImageType,
    wait_group: *std.Thread.WaitGroup,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Uso: {s} <path_cartella_immagini>\n", .{args[0]});
        std.process.exit(1);
    }

    const target_dir = args[1];
    std.debug.print("Scansione della cartella: {s}...\n", .{target_dir});

    var files = try shrinkpic.scanDirectory(allocator, target_dir);
    defer {
        for (files.items) |f| allocator.free(f.path);
        files.deinit();
    }

    if (files.items.len == 0) {
        std.debug.print("Nessun file JPEG/PNG trovato superiore ai criteri.\n", .{});
        return;
    }

    std.debug.print("Trovate {} immagini da elaborare.\n", .{files.items.len});

    for (files.items) |img| {
        switch (img.type) {
            .jpeg => {
                compress.compressJpegInPlace(allocator, img.path) catch |err| {
                    std.debug.print("Errore durante l'elaborazione di {s}: {}\n", .{ img.path, err });
                };
            },
            .png => {
                std.debug.print("Salto PNG (Logica Quantizzazione PNG-8 pianificata): {s}\n", .{img.path});
            },
            .unknown => unreachable,
        }
    }

    std.debug.print("Processo di ottimizzazione completato con successo!\n", .{});
}
