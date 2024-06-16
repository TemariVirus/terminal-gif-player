//! Provides a canvas-like interface for drawing to the terminal.

const std = @import("std");
const kernel32 = windows.kernel32;
const linux = std.os.linux;
const time = std.time;
const unicode = std.unicode;
const windows = std.os.windows;

const ByteList = std.ArrayListUnmanaged(u8);
const File = std.fs.File;
const SIG = linux.SIG;
const Sigaction = linux.Sigaction;

const assert = std.debug.assert;
const sigaction = linux.sigaction;

const is_windows = @import("builtin").os.tag == .windows;
const ESC = "\x1B";
const ST = ESC ++ "\\";
const CSI = ESC ++ "[";
const OSC = ESC ++ "]";

var initialised = false;

var _allocator: std.mem.Allocator = undefined;
var stdout: File = undefined;
var draw_buffer: ByteList = undefined;

var frame_pool: FramePool = undefined;
var last: ?Frame = null;
var current: Frame = undefined;

var canvas_size: Size = undefined;
var terminal_size: Size = undefined;

var init_time: i128 = undefined;
var frames_drawn: usize = undefined;

pub const Pixel = struct {
    const str = "  ";
    const width = 2;
    const height = 1;

    r: u8,
    g: u8,
    b: u8,

    pub fn eql(self: Pixel, other: Pixel) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const Size = struct {
    width: u16,
    height: u16,

    pub fn eql(self: Size, other: Size) bool {
        return self.width == other.width and self.height == other.height;
    }

    pub fn area(self: Size) u32 {
        return @as(u32, self.width) * @as(u32, self.height);
    }

    pub fn bound(self: Size, other: Size) Size {
        return .{
            .width = @min(self.width, other.width),
            .height = @min(self.height, other.height),
        };
    }

    inline fn canvasToTerm(self: Size) Size {
        return Size{
            .width = self.width * Pixel.width,
            .height = self.height * Pixel.height,
        };
    }

    inline fn termToCanvas(self: Size) Size {
        return Size{
            .width = @divTrunc(self.width, Pixel.width),
            .height = @divTrunc(self.height, Pixel.height),
        };
    }
};

const Frame = struct {
    size: Size,
    pixels: []Pixel,

    fn init(allocator: std.mem.Allocator, size: Size) !Frame {
        const pixels = try allocator.alloc(Pixel, size.area());
        return Frame{ .size = size, .pixels = pixels };
    }

    fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    fn termSize(self: Frame) Size {
        return self.size.enlarge(Pixel.width, Pixel.height);
    }

    fn inBounds(self: Frame, x: u16, y: u16) bool {
        return x < self.size.width and y < self.size.height;
    }

    fn get(self: Frame, x: u16, y: u16) Pixel {
        assert(self.inBounds(x, y));
        const index = @as(usize, y) * self.size.width + x;
        return self.pixels[index];
    }

    fn set(self: Frame, x: u16, y: u16, p: Pixel) void {
        assert(self.inBounds(x, y));
        const index = @as(usize, y) * self.size.width + x;
        self.pixels[index] = p;
    }
};

const FramePool = struct {
    frames: []Frame,
    used: []bool,

    fn init(
        allocator: std.mem.Allocator,
        size: Size,
        capacity: u32,
    ) !FramePool {
        const frames = try allocator.alloc(Frame, capacity);
        for (0..capacity) |i| {
            frames[i] = try Frame.init(allocator, size);
        }

        const is_used = try allocator.alloc(bool, capacity);
        for (0..capacity) |i| {
            is_used[i] = false;
        }

        return FramePool{ .frames = frames, .used = is_used };
    }

    fn deinit(self: FramePool, allocator: std.mem.Allocator) void {
        for (0..self.frames.len) |i| {
            self.frames[i].deinit(allocator);
        }

        allocator.free(self.frames);
        allocator.free(self.used);
    }

    /// Allocates a frame of the given size. Returns null if no frames are
    /// free, or if the requested size is larger than the size specified at
    /// initialisation. The pixels of the returned frame are undefined values.
    fn alloc(self: FramePool, size: Size) ?Frame {
        const len = size.area();
        if (len > self.frames[0].size.area()) {
            return null;
        }

        for (0..self.used.len) |i| {
            if (!self.used[i]) {
                self.used[i] = true;
                const frame = self.frames[i];
                // Resize frame to requested size. No need to zero the pixels,
                // as they'll be overwritten when rendering
                return Frame{ .size = size, .pixels = frame.pixels[0..len] };
            }
        }
        return null;
    }

    fn free(self: FramePool, frame: Frame) void {
        for (0..self.frames.len) |i| {
            // Use their pixel arrays to identify frames
            if (self.frames[i].pixels.ptr == frame.pixels.ptr) {
                self.used[i] = false;
                return;
            }
        }
    }
};

const signal = if (is_windows)
    struct {
        extern "c" fn signal(
            sig: c_int,
            func: *const fn (c_int, c_int) callconv(windows.WINAPI) void,
        ) callconv(.C) *anyopaque;
    }.signal
else
    void;

const setConsoleMode = if (is_windows)
    struct {
        extern "kernel32" fn SetConsoleMode(
            console: windows.HANDLE,
            mode: windows.DWORD,
        ) callconv(windows.WINAPI) windows.BOOL;
    }.SetConsoleMode
else
    void;

pub const InitError = error{
    AlreadyInitialised,
    FailedToSetConsoleOutputCP,
    FailedToSetConsoleMode,
};
pub fn init(
    allocator: std.mem.Allocator,
    stdout_file: File,
    width: u16,
    height: u16,
) !void {
    if (initialised) {
        return InitError.AlreadyInitialised;
    }

    _allocator = allocator;
    stdout = stdout_file;

    if (is_windows) {
        _ = signal(SIG.INT, handleExitWindows);
    } else {
        const action = Sigaction{
            .handler = .{ .handler = handleExit },
            .mask = linux.empty_sigset,
            .flags = 0,
        };
        _ = sigaction(SIG.INT, &action, null);
    }

    if (is_windows) {
        const CP_UTF8 = 65001;
        const result = kernel32.SetConsoleOutputCP(CP_UTF8);
        if (result == windows.FALSE) {
            return InitError.FailedToSetConsoleOutputCP;
        }

        const ENABLE_PROCESSED_OUTPUT = 0x1;
        const ENABLE_WRAP_AT_EOL_OUTPUT = 0x2;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x4;
        const ENABLE_LVB_GRID_WORLDWIDE = 0x10;
        const result2 = setConsoleMode(
            stdout.handle,
            ENABLE_PROCESSED_OUTPUT |
                ENABLE_WRAP_AT_EOL_OUTPUT |
                ENABLE_VIRTUAL_TERMINAL_PROCESSING |
                ENABLE_LVB_GRID_WORLDWIDE,
        );
        if (result2 == windows.FALSE) {
            return InitError.FailedToSetConsoleMode;
        }
    }

    canvas_size = Size{ .width = width, .height = height };
    // Use a guess if we can't get the terminal size
    terminal_size = getTerminalSize() orelse Size{ .width = 120, .height = 30 };
    draw_buffer = ByteList{};
    // The actual frame buffers can never be larger than canvas_size,
    // so allocate buffers of that size
    frame_pool = try FramePool.init(_allocator, canvas_size, 2);

    const current_size = canvas_size.bound(terminal_size.termToCanvas());
    current = frame_pool.alloc(current_size).?;

    useAlternateBuffer();
    hideCursor(stdout.writer()) catch {};

    init_time = time.nanoTimestamp();
    frames_drawn = 0;
    initialised = true;
}

pub fn deinit() void {
    if (!initialised) {
        return;
    }
    initialised = false;

    useMainBuffer();
    showCursor(stdout.writer()) catch {};

    frame_pool.deinit(_allocator);
    draw_buffer.deinit(_allocator);

    const duration: u64 = @intCast(time.nanoTimestamp() - init_time);
    const fps = @as(f64, @floatFromInt(frames_drawn)) /
        @as(f64, @floatFromInt(duration)) *
        @as(f64, @floatFromInt(time.ns_per_s));
    std.debug.print(
        "Rendered at {d:.3}fps for {}\n",
        .{ fps, std.fmt.fmtDuration(duration) },
    );
}

fn handleExit(sig: c_int) callconv(.C) void {
    switch (sig) {
        // Handle interrupt
        SIG.INT => {
            deinit();
            std.process.exit(0);
        },
        else => unreachable,
    }
}

fn handleExitWindows(sig: c_int, _: c_int) callconv(.C) void {
    handleExit(sig);
}

pub fn getTerminalSize() ?Size {
    if (is_windows) {
        return getTerminalSizeWindows();
    }

    if (!@hasDecl(linux, "ioctl") or
        !@hasDecl(linux, "T") or
        !@hasDecl(linux.T, "IOCGWINSZ"))
    {
        @compileError("ioctl not available; cannot get terminal size.");
    }

    var size: linux.winsize = undefined;
    const result = linux.ioctl(
        linux.STDOUT_FILENO,
        linux.T.IOCGWINSZ,
        @intFromPtr(&size),
    );
    if (@as(isize, @bitCast(result)) == -1) {
        return null;
    }

    return Size{
        .width = size.ws_col,
        .height = size.ws_row,
    };
}

fn getTerminalSizeWindows() ?Size {
    var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    const result = kernel32.GetConsoleScreenBufferInfo(stdout.handle, &info);
    if (result == windows.FALSE) {
        return null;
    }

    return Size{
        .width = @bitCast(info.dwSize.X),
        .height = @bitCast(info.dwSize.Y),
    };
}

pub fn setCanvasSize(width: u16, height: u16) !void {
    canvas_size = Size{ .width = width, .height = height };
    frame_pool.deinit(_allocator);
    // The actual frame buffers can never be larger than canvas_size,
    // so allocate that much
    frame_pool = try FramePool.init(_allocator, canvas_size, 2);

    const actual_size = canvas_size.bound(terminal_size);
    last = null;
    current = frame_pool.alloc(actual_size).?;
}

pub fn actualSize() Size {
    return current.size;
}

pub fn setTitle(title: []const u8) void {
    stdout.writeAll(OSC ++ "0;") catch {};
    stdout.writeAll(title) catch {};
    stdout.writeAll(ST) catch {};
}

fn useAlternateBuffer() void {
    stdout.writeAll(CSI ++ "?1049h") catch {};
}

fn useMainBuffer() void {
    stdout.writeAll(CSI ++ "?1049l") catch {};
}

pub fn drawPixel(x: u16, y: u16, color: Pixel) bool {
    if (!current.inBounds(x, y)) {
        return false;
    }
    current.set(x, y, color);
    return true;
}

pub fn render() !void {
    defer frames_drawn += 1;

    const old_terminal_size = terminal_size;
    terminal_size = getTerminalSize() orelse terminal_size;
    const draw_size = current.size.bound(terminal_size.termToCanvas());

    const assume_wrap = draw_size.canvasToTerm().width >= terminal_size.width;
    const draw_diff = old_terminal_size.eql(terminal_size) and
        last != null and
        last.?.size.eql(current.size);

    const writer = draw_buffer.writer(_allocator);
    var last_x: u16 = 0;
    var last_y: u16 = 0;
    if (draw_diff) {
        // Find first difference
        for (0..current.pixels.len) |i| {
            if (!last.?.pixels[i].eql(current.pixels[i])) {
                last_x = @intCast(i % current.size.width);
                last_y = @intCast(i / current.size.width);
                break;
            }
        } else {
            // No diff to draw, advance and return
            advanceBuffers();
            return;
        }
    } else {
        // First frame, or either the canvas or terminal was resized,
        // so clear the screen and re-draw from scratch
        try clearScreen(writer);
        // Resizing the terminal may cause the cursor to be shown,
        // so hide it again
        try hideCursor(writer);
    }
    try setCursorPos(writer, last_x, last_y);

    var last_color = current.pixels[toCurrentIndex(last_x, last_y)];
    try setColor(writer, last_color);

    for (last_x..draw_size.width) |x| {
        const i = toCurrentIndex(@intCast(x), last_y);
        const color = current.pixels[i];

        if (draw_diff and last.?.pixels[i].eql(color)) {
            continue;
        }

        try setColor(writer, color);
        try cursorDiff(
            writer,
            last_x,
            last_y,
            @intCast(x),
            last_y,
            assume_wrap,
        );
        last_color = color;
        last_x = @intCast(x);

        try writer.writeAll(Pixel.str);
    }
    for (last_y + 1..draw_size.height) |y| {
        for (0..draw_size.width) |x| {
            const i = toCurrentIndex(@intCast(x), @intCast(y));
            const pixel = current.pixels[i];

            if (draw_diff and last.?.pixels[i].eql(pixel)) {
                continue;
            }

            try setColor(writer, pixel);
            try cursorDiff(
                writer,
                last_x,
                last_y,
                @intCast(x),
                @intCast(y),
                assume_wrap,
            );
            last_color = pixel;
            last_x = @intCast(x);
            last_y = @intCast(y);

            try writer.writeAll(Pixel.str);
        }
    }

    // Reset colors at the end so that the area outside the canvas stays black
    try resetColors(writer);
    stdout.writeAll(draw_buffer.items[0..draw_buffer.items.len]) catch {};

    advanceBuffers();
}

inline fn cursorDiff(
    writer: anytype,
    last_x: u16,
    last_y: u16,
    x: u16,
    y: u16,
    assume_wrap: bool,
) !void {
    // We're printing a character anyway, so no need to advance cursor by 1
    // However, if we're at the end of a line and can't wrap, we need to move
    // the cursor ourselves
    if (last_x + 1 == x and last_y == y) {
        return;
    }
    if (assume_wrap and
        last_x == current.size.width - 1 and
        x == 0 and
        last_y + 1 == y)
    {
        return;
    }

    try setCursorPos(writer, x, y);
}

inline fn toCurrentIndex(x: u16, y: u16) usize {
    return @as(usize, y) * @as(usize, current.size.width) + @as(usize, x);
}

fn advanceBuffers() void {
    const size = canvas_size.bound(terminal_size.termToCanvas());
    if (last) |l| {
        frame_pool.free(l);
    }
    last = current;
    current = frame_pool.alloc(size).?;
    draw_buffer.items.len = 0; // Clear buffer without freeing
}

fn clearScreen(writer: anytype) !void {
    try writer.writeAll(CSI ++ "2J");
}

fn resetColors(writer: anytype) !void {
    try writer.writeAll(CSI ++ "m");
}

fn setColor(writer: anytype, color: Pixel) !void {
    // Sets the background color only; we don't need the foreground color
    try writer.print(CSI ++ "48;2;{};{};{}m", .{ color.r, color.g, color.b });
}

fn resetCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "H");
}

fn setCursorPos(writer: anytype, x: u16, y: u16) !void {
    try writer.print(CSI ++ "{};{}H", .{ y + 1, x * Pixel.width + 1 });
}

fn showCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "?25h");
}

fn hideCursor(writer: anytype) !void {
    try writer.writeAll(CSI ++ "?25l");
}
