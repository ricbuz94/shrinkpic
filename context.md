# Contesto di Progetto: ShrinkPic (Image Shrinker in Zig)

Questo documento funge da memoria storica e contesto per i modelli linguistici (LLM) incaricati di generare codice per lo sviluppo del software "ShrinkPic".

## 1. Visione del Progetto & Obiettivi

- **Scopo**: Sviluppare un'utilità a riga di comando (CLI) ad alte prestazioni in locale.
- **Obiettivo**: Ridurre il peso in byte (_file size_ o _bit_) di intere cartelle piene di immagini pesanti (PNG, JPEG, JPG), convertendole se necessario e assicurandosi che ogni file di output sia **inferiore o uguale a 1MB** ($P \le 1\text{ MB}$).
- **Caso d'uso reale**: Ottimizzare in blocco le foto sul computer locale prima di caricarle come allegati su WordPress o Symfony. Questo permette a WordPress di generare le miniature (_sizes_) partendo da file sorgente già leggeri, velocizzando i server PHP ed evitando crash di `Memory Limit` o `Time Out`.

## 2. Requisiti Tecnologici & Vincoli Rigidi (Aggiornati al 2026)

- **Linguaggio**: **Zig 0.16.0** (e versioni stabili correnti).
- **ZLS**: Abilitato e allineato rigidamente alla versione 0.16.0.
- **Regole Sintattiche Tassative**:
    - **Interazione C**: `@cImport` e `@cInclude` sono stati **completamente rimossi** dal linguaggio. Tutta la traduzione del codice C avviene a livello di _Build System_ tramite `addTranslateC` esportato come modulo nativo Zig denominato `"c_api"`.
    - **Input/Output**: `std.io.getStdOut` e la vecchia struct `std.io` sono state eliminate. Per stampe di log/debug si usa esclusivamente `std.debug.print` (o l'interfaccia I/O di `std.process.Init`).
    - **Build System**: Non usare parametri piatti (`.target`, `.optimize`) all'interno di `b.addExecutable`. Devono essere inseriti obbligatoriamente dentro `b.createModule` associato alla proprietà `.root_module`.
    - **Linking**: `linkLibC` e `linkSystemLibrary` non sono funzioni del compilatore piatto `exe` ma appartengono alla gestione dei moduli.

## 3. Scelte Architetturali Condivise

1. **Librerie di Compressione**: Sfruttare il superpotere di Zig 0.16 nel compilare e linkare il codice C a costo zero (senza overhead a differenza di Go/cgo).
    - Per i JPEG: Uso di **`libjpeg-turbo`** (veloce grazie a ottimizzazioni hardware SIMD).
    - Per i PNG: Uso di **`libpng`**.
2. **Logica di Restrizione Peso (<1MB)**:
    - **JPEG**: Loop iterativo in RAM riducendo progressivamente il parametro qualità (es. 90%, 85%, 80%) finché il buffer codificato non scende sotto la soglia di 1MB.
    - **PNG**: Poiché il PNG è _lossless_, se il file eccede 1MB dopo la compressione massima, si valuterà in futuro la quantizzazione del colore (PNG-24 ➔ PNG-8 con tavolozza a 256 colori).

---

## 4. Configurazione Corrente del Build System (`build.zig`)

Il file di build è stato validato, non presenta errori sintattici su Zig 0.16 ed è così strutturato:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("shrinkpic", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/imports.h"),
        .target = target,
        .optimize = optimize,
    });

    translate_c.linkSystemLibrary("turbojpeg", .{});
    translate_c.linkSystemLibrary("png", .{});

    const c_mod = translate_c.createModule();
    c_mod.linkSystemLibrary("turbojpeg", .{});
    c_mod.linkSystemLibrary("png", .{});

    const exe = b.addExecutable(.{
        .name = "shrinkpic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "shrinkpic", .module = mod },
                .{ .name = "c_api", .module = c_mod },
            },
        }),
    });

    exe.root_module.linkSystemLibrary("turbojpeg", .{});
    exe.root_module.linkSystemLibrary("png", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
```

## 5. Stato dell'Arte del Codice Sorgente

- I file `src/imports.h` (contenente `#include <turbojpeg.h>` e `#include <png.h>`) e `src/main.zig` comunicano correttamente.
- Il test di inizializzazione di TurboJPEG e la lettura delle costanti di LibPNG tramite il modulo `"c_api"` funzionano al 100% con `zig build run`.

## 6. Prossimi Passi Concordati

1. Implementare la lettura sequenziale o parallela dei file all'interno di una cartella passata come argomento alla CLI.
2. Sviluppare la decodifica dell'immagine in pixel grezzi (_raw pixels_) e il loop di compressione condizionale basato sulla dimensione del file finale.
