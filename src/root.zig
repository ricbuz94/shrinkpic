const std = @import("std");

pub const DEFAULT_WORKER_COUNT: usize = 8;
pub const DEFAULT_MAX_SIZE: usize = 200 * 1024; // 200 KB
pub const DEFAULT_FORCE_JPEG: bool = false;
