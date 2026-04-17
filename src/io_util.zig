const std = @import("std");

pub const Stdout = struct {
    buffer: [4096]u8 = undefined,
    writer: std.fs.File.Writer,

    pub fn init(self: *Stdout) void {
        self.writer = std.fs.File.stdout().writer(&self.buffer);
    }

    pub fn out(self: *Stdout) *std.Io.Writer {
        return &self.writer.interface;
    }
};
