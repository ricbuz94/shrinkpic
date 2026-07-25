const std = @import("std");
const c = @import("c_api");

const MAX_FILE_SIZE = 1 * 1024 * 1024; // 1 MB

pub fn compressJpegInPlace(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // 1. Legge il file originale in un buffer
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();

    // Se è già sotto 1MB, non facciamo nulla
    if (file_size <= MAX_FILE_SIZE) return;

    const src_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(src_buffer);
    _ = try file.readAll(src_buffer);

    // 2. Decompressione dei pixel grezzi usando TurboJPEG
    const decompressor = c.tjInitDecompress() orelse return error.TurboJpegInitFailed;
    defer _ = c.tjDestroy(decompressor);

    var width: c_int = 0;
    var height: c_int = 0;
    var jpeg_sub_samp: c_int = 0;
    var color_space: c_int = 0;

    if (c.tjDecompressHeader3(decompressor, src_buffer.ptr, @intCast(src_buffer.len), &width, &height, &jpeg_sub_samp, &color_space) != 0) {
        return error.TurboJpegHeaderError;
    }

    const raw_buffer = try allocator.alloc(u8, @intCast(width * height * 3)); // RGB
    defer allocator.free(raw_buffer);

    if (c.tjDecompress2(decompressor, src_buffer.ptr, @intCast(src_buffer.len), raw_buffer.ptr, width, 0, height, c.TJPF_RGB, 0) != 0) {
        return error.TurboJpegDecompressError;
    }

    // 3. Loop Iterativo di Compressione per target < 1MB
    const compressor = c.tjInitTransform() orelse return error.TurboJpegAllocFailed;
    defer _ = c.tjDestroy(compressor);

    var quality: c_int = 90;
    var compressed_buf: [*c]u8 = null;
    var compressed_size: c_ulong = 0;

    while (quality >= 10) : (quality -= 5) {
        if (compressed_buf != null) {
            c.tjFree(compressed_buf);
            compressed_buf = null;
        }

        if (c.tjCompress2(compressor, raw_buffer.ptr, width, 0, height, c.TJPF_RGB, &compressed_buf, &compressed_size, jpeg_sub_samp, quality, 0) != 0) {
            return error.TurboJpegCompressError;
        }

        if (compressed_size <= MAX_FILE_SIZE) break;
    }

    // 4. Scrittura del file ottimizzato sovrascrivendo l'originale
    if (compressed_buf != null and compressed_size <= MAX_FILE_SIZE) {
        defer c.tjFree(compressed_buf);
        const write_file = try std.fs.cwd().createFile(file_path, .{});
        defer write_file.close();
        try write_file.writeAll(compressed_buf[0..compressed_size]);
        std.debug.print("Ottimizzato: {s} (Qualità: {}, Dimensione: {} KB)\n", .{ file_path, quality, compressed_size / 1024 });
    } else {
        if (compressed_buf != null) c.tjFree(compressed_buf);
        return error.CompressionTargetFailed;
    }
}

/// Converte un PNG RGBA in un PNG indicizzato a 8-bit (256 colori) per ridurne il peso
pub fn compressPngTo8BitInPlace(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // 1. Apertura e validazione del file PNG originale
    const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    defer file.close();

    if (try file.getEndPos() <= MAX_FILE_SIZE) return;

    var c_file = c.fopen(file_path.ptr, "rb") orelse return error.FileOpenError;
    defer _ = c.fclose(c_file);

    const png_ptr = c.png_create_read_struct(c.PNG_LIBPNG_VER_STRING, null, null, null) orelse return error.PngInitError;
    const info_ptr = c.png_create_info_struct(png_ptr) orelse return error.PngInfoError;
    defer c.png_destroy_read_struct(&png_ptr, &info_ptr, null);

    if (c.setjmp(c.png_jmpbuf(png_ptr)) != 0) return error.PngReadError;
    c.png_init_io(png_ptr, c_file);
    c.png_read_info(png_ptr, info_ptr);

    const width = c.png_get_image_width(png_ptr, info_ptr);
    const height = c.png_get_image_height(png_ptr, info_ptr);
    const color_type = c.png_get_color_type(png_ptr, info_ptr);

    // Forza la conversione in RGBA a 8-bit per canale se non lo è già
    if (color_type == c.PNG_COLOR_TYPE_PALETTE) c.png_set_palette_to_rgb(png_ptr);
    if (color_type == c.PNG_COLOR_TYPE_GRAY and c.png_get_bit_depth(png_ptr, info_ptr) < 8) c.png_set_expand_gray_1_2_4_to_8(png_ptr);
    if (c.png_get_valid(png_ptr, info_ptr, c.PNG_INFO_tRNS) != 0) c.png_set_tRNS_to_alpha(png_ptr);
    if (color_type == c.PNG_COLOR_TYPE_RGB or color_type == c.PNG_COLOR_TYPE_GRAY) c.png_set_add_alpha(png_ptr, 0xFF, c.PNG_FILLER_AFTER);

    c.png_read_update_info(png_ptr, info_ptr);

    // Allocazione buffer per le righe RGBA
    const row_pointers = try allocator.alloc([*c]u8, height);
    defer allocator.free(row_pointers);
    for (0..height) |i| {
        row_pointers[i] = (try allocator.alloc(u8, width * 4)).ptr;
    }
    defer {
        for (row_pointers) |ptr| {
            const casted: [*]u8 = @ptrCast(ptr);
            allocator.free(casted[0..(width * 4)]);
        }
    }

    c.png_read_image(png_ptr, row_pointers.ptr);
    _ = c.fclose(c_file);
    c_file = null; // Rilascia l'handle in lettura prima di sovrascrivere

    // 2. Generazione di una Palette di colori a 8-bit (Quantizzazione di base)
    // Nota: Per una quantizzazione perfetta si usa solitamente libimagequant.
    // Questa logica mappa i pixel RGBA in una tavolozza indicizzata fissa/adattiva a 256 colori.
    var palette: [256]c.png_color = undefined;
    var trans_alpha: [256]u8 = undefined;

    // Popolamento di una tavolozza di fallback geometrica (color cube) comprensiva di canale alpha
    for (0..256) |i| {
        palette[i] = .{
            .red = @intCast((i & 0xE0)),
            .green = @intCast((i & 0x1C) << 3),
            .blue = @intCast((i & 0x03) << 6),
        };
        trans_alpha[i] = if (i == 0) 0 else 255; // Mantiene indice 0 come trasparente trasparente
    }

    // 3. Riscrittura del file come PNG Indicizzato (PNG-8)
    const w_file = c.fopen(file_path.ptr, "wb") orelse return error.FileWriteError;
    defer _ = c.fclose(w_file);

    const write_ptr = c.png_create_write_struct(c.PNG_LIBPNG_VER_STRING, null, null, null) orelse return error.PngInitError;
    const write_info_ptr = c.png_create_info_struct(write_ptr) orelse return error.PngInfoError;
    defer c.png_destroy_write_struct(&write_ptr, &write_info_ptr);

    if (c.setjmp(c.png_jmpbuf(write_ptr)) != 0) return error.PngWriteError;
    c.png_init_io(write_ptr, w_file);

    c.png_set_IHDR(
        write_ptr,
        write_info_ptr,
        width,
        height,
        8, // 8 bit per pixel
        c.PNG_COLOR_TYPE_PALETTE,
        c.PNG_INTERLACE_NONE,
        c.PNG_COMPRESSION_TYPE_DEFAULT,
        c.PNG_FILTER_TYPE_DEFAULT,
    );

    c.png_set_PLTE(write_ptr, write_info_ptr, &palette, 256);
    c.png_set_tRNS(write_ptr, write_info_ptr, &trans_alpha, 256, null);
    c.png_write_info(write_ptr, write_info_ptr);

    // Mappatura dei pixel RGBA originali sull'indice di colore più vicino
    const quantized_rows = try allocator.alloc([*c]u8, height);
    defer allocator.free(quantized_rows);
    for (0..height) |y| {
        const q_row = try allocator.alloc(u8, width);
        for (0..width) |x| {
            const r = row_pointers[y][x * 4 + 0];
            const g = row_pointers[y][x * 4 + 1];
            const b = row_pointers[y][x * 4 + 2];
            const a = row_pointers[y][x * 4 + 3];

            if (a < 128) {
                q_row[x] = 0; // Mappa su indice trasparente
            } else {
                // Algoritmo di compressione colore veloce (Euclidean distance ridotta)
                const r_idx = (@as(u8, r) & 0xE0);
                const g_idx = (@as(u8, g) & 0x1C) >> 3;
                const b_idx = (@as(u8, b) & 0x03) >> 6;
                q_row[x] = @intCast(r_idx | (g_idx << 3) | b_idx);
            }
        }
        quantized_rows[y] = q_row.ptr;
    }
    defer {
        for (quantized_rows) |ptr| {
            const casted: [*]u8 = @ptrCast(ptr);
            allocator.free(casted[0..width]);
        }
    }

    c.png_write_image(write_ptr, quantized_rows.ptr);
    c.png_write_end(write_ptr, null);
}
