# shrinkpic

Multi-threaded tool written in Zig 0.16 that downscales and compresses images to a target file size (default: 200 KB) while preserving the best possible photographic quality.

## Features

- **Universal Input**: Accepts any major image format (JPEG, PNG, BMP, TGA, GIF, etc.) thanks to `stb_image`.
- **Photo-Grade Downscaling**: High-quality linear resizing down to a web-optimized 1920px (if bigger) using `stb_image_resize2`.
- **Modern Optimization**: Supports exporting to next-gen **WebP** format (default) or progressive **JPEG** (`libjpeg-turbo`).
- **Metadata Stripping**: Automatically purges heavy EXIF, GPS, and IPTC data to maximize visual byte allocation.
- **Smart Concurrency**: Dynamic multi-threaded thread pool with safety bounds.

## Requirements

- Zig 0.16
- libwebp
- jpeg-turbo (libjpeg-turbo)

### macOS

```bash
brew install zig webp jpeg-turbo
```

### Ubuntu/Debian

```bash
sudo apt install zig libwebp-dev libturbojpeg0-dev
```

### Windows

- Zig 0.16 (winget / scoop / choco / download ufficiale)
- libwebp + libjpeg-turbo (via vcpkg o MSYS2)

```bash
# Zig
winget install zig.zig
# oppure
scoop install zig
# oppure
choco install zig

# Dipendenze (vcpkg)
vcpkg install libwebp libjpeg-turbo
```

_Note: `stb_image` and `stb_image_resize2` are header-only and vendorcompiled inside the binary, no system installation required._

## Build

```bash
git clone https://github.com/ricbuz94/shrinkpic
cd shrinkpic

zig build -Doptimize=ReleaseSafe
# Maximum safety. It keeps runtime checks (like out-of-bounds or
# overflows) active. If a bug occurs, it triggers a clean panic.
#
# or
#
zig build -Doptimize=ReleaseFast
# Maximum speed. It removes all safety checks to optimize hardware
# and loops (SIMD). If a bug occurs, it leads to Undefined Behavior.
```

Binary destination: `zig-out/bin/shrinkpic` (Windows: `zig-out\bin\shrinkpic.exe`)

## Usage

```bash
./zig-out/bin/shrinkpic <input_dir> [output_dir] [options]
```

Windows:

```bash
.\zig-out\bin\shrinkpic.exe <input_dir> [output_dir] [options]
```

### Arguments

- `<input_dir>`: The directory containing source images. Processes files concurrently (automatically skips system files like `.DS_Store`).
- `[output_dir]`: Destination directory (created automatically if missing). If omitted, output files are written alongside the originals.

### Options

- `--size=<dimension>`: Target maximum file size. Supports **MB/mb** or **KB/kb** (case-insensitive). _Default: `200kb`_.
- `--jpeg`: Forces output conversion to progressive JPEG instead of the default WebP.
- `--workers=<1-8>`: Sets the number of concurrent worker threads. Throws an error if set outside the 1–8 range. _Default: `4`_.

### Examples

**Standard WebP optimization (Max 150 KB, using 8 threads):**

```bash
./zig-out/bin/shrinkpic ./photos ./web_ready --size=150KB --workers=8
```

**Force Progressive JPEG conversion (Max 200 KB):**

```bash
./zig-out/bin/shrinkpic ./raw_images ./wp_upload --size=200kb --jpeg
```
