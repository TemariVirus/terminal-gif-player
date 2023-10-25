const std = @import("std");
const time = std.time;
const terminal = @import("terminal.zig");

const zigimg = @import("zigimg");
const Image = zigimg.Image;
const Animation = Image.Animation;
const AnimationFrame = Image.AnimationFrame;
const PixelStorageIterator = zigimg.color.PixelStorageIterator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.skip(); // Skip executable name
    defer args.deinit();

    // Get first valid GIF
    std.debug.print("Initialising...\n", .{});
    var has_args = false;
    var gif: Image = while (args.next()) |arg| {
        has_args = true;
        const img = Image.fromFilePath(allocator, arg) catch continue;
        if (img.isAnimation()) {
            break img;
        }
    } else {
        if (has_args) {
            std.debug.print("File was not a GIF\n", .{});
        } else {
            std.debug.print("Usage: term-gif-player[.exe] <file>\n", .{});
        }
        return;
    };
    defer gif.deinit();

    try terminal.init(
        allocator,
        std.io.getStdOut(),
        @intCast(gif.width),
        @intCast(gif.height),
    );
    defer terminal.deinit();

    terminal.setTitle("GIF Player");

    try drawAnimation(gif.animation, @intCast(gif.width));
}

fn drawAnimation(animation: Animation, width: u16) !void {
    const frames = animation.frames.items;
    const loop_count = animation.loop_count;

    var i: i32 = 0;
    // Keep track of total time passed so frame timing doesn't drift over time.
    while (loop_count == Image.AnimationLoopInfinite or
        i < loop_count) : (i +%= 1)
    {
        var end = std.time.nanoTimestamp();
        for (frames) |frame| {
            end += @intFromFloat(frame.duration * time.ns_per_s);
            // Skip this frame if it's already too late
            if (end - time.nanoTimestamp() <= 0) {
                continue;
            }

            try drawFrame(frame, width);

            const timeout = end - time.nanoTimestamp();
            if (timeout <= 0) {
                continue;
            }
            time.sleep(@as(u64, @intCast(timeout)));
        }
    }
}

fn drawFrame(frame: AnimationFrame, width: u16) !void {
    // Only draw the pixels that will be shown
    const size = terminal.actualSize();
    var pixels = PixelStorageIterator.init(&frame.pixels);
    for (0..size.height) |y| {
        for (0..size.width) |x| { // 1 pixel is represented by 2 characters
            // Skip to (x, y) coordinate
            pixels.current_index = y * width + x;
            const p = pixels.next().?.toRgba32();

            const pixel = terminal.Pixel{ .r = p.r, .g = p.g, .b = p.b };
            _ = terminal.drawPixel(@intCast(x), @intCast(y), pixel);
        }
    }
    try terminal.render();
}
