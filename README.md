# shrinkpic
Multi-threaded tool that shrinks JPEG/PNG images to ≤ 1 MB while preserving the best possible quality.

## Requirements

- Zig 0.16
- libpng
- libjpeg-turbo

### macOS
```bash
brew install zig libpng jpeg-turbo
```

### Ubuntu/Debian
```bash
sudo apt install zig libpng-dev libturbojpeg0-dev
```

## Build

```bash
git clone https://github.com/youruser/shrinkpic.git
cd shrinkpic
zig build -Doptimize=ReleaseFast
```

Binary: `zig-out/bin/shrinkpic`

## Usage

```bash
./zig-out/bin/shrinkpic <input_dir> [output_dir]
```

- Processes all `.jpg` / `.jpeg` / `.png` in `input_dir`
- Writes `*.shrunk.jpg` into `output_dir` (created if missing)
- If `output_dir` is omitted, files are written next to the originals

Example:
```bash
./zig-out/bin/shrinkpic ./photos ./photos_small
```
