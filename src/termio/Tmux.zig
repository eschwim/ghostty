const Tmux = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_tmux);

const tmux_enabled = terminal.options.tmux_control_mode;
const Viewer = if (tmux_enabled) terminal.tmux.Viewer else void;

alloc: Allocator,
pane_id: usize,
active: bool = true,

/// The mailbox for sending commands to the control client's termio.
control_mailbox: *termio.Mailbox,

/// The viewer that owns our pane terminal.
viewer: if (tmux_enabled) *Viewer else void,

/// The control surface's renderer mutex. Required for safe access
/// to the viewer's command queue from the app thread.
control_mutex: if (tmux_enabled) *std.Thread.Mutex else void,

pub fn init(alloc: Allocator, cfg: Config) Tmux {
    return .{
        .alloc = alloc,
        .pane_id = cfg.pane_id,
        .control_mailbox = cfg.control_mailbox,
        .viewer = if (tmux_enabled) cfg.viewer else {},
        .control_mutex = if (tmux_enabled) cfg.control_mutex else {},
    };
}

pub fn deinit(self: *Tmux) void {
    _ = self;
}

pub fn initTerminal(self: *Tmux, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *Tmux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .tmux = .{} };
}

pub fn threadExit(self: *Tmux, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *Tmux,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = td;
    if (focused) {
        var buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "select-pane -t %{d}\n", .{self.pane_id}) catch return;
        self.sendControlCommand(cmd);
    }
}

pub fn resize(
    self: *Tmux,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
    // The control surface sends refresh-client -C with the total
    // window size. Individual pane surfaces must NOT send it, as
    // their smaller split dimensions would override the correct
    // total size, causing tmux to miscalculate the layout.
}

/// Write user input to the tmux pane via send-keys -H (hex-encoded).
pub fn queueWrite(
    self: *Tmux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    _ = linefeed;
    if (data.len == 0) return;

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    try buf.writer.print("send-keys -t %{d} -H", .{self.pane_id});
    for (data) |byte| {
        try buf.writer.print(" {x:0>2}", .{byte});
    }
    try buf.writer.writeByte('\n');

    self.sendControlCommand(buf.writer.buffered());
}

pub fn getProcessInfo(self: *Tmux, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub fn sendControlCommand(self: *Tmux, cmd: []const u8) void {
    const msg = termio.Message.writeReq(self.alloc, cmd) catch {
        log.warn("failed to create write request for tmux command", .{});
        return;
    };
    self.control_mailbox.send(msg, null);
    self.control_mailbox.notify();
}

/// Queue a tmux command through the viewer's command queue so the
/// viewer properly tracks its %begin/%end response. This must be
/// used for commands like new-window, kill-pane, etc. that produce
/// block responses. Using sendControlCommand for such commands
/// would corrupt the viewer's command queue.
pub fn queueTmuxCommand(self: *Tmux, cmd: []const u8) void {
    if (comptime !tmux_enabled) return;
    const viewer = self.viewer;
    const mutex = self.control_mutex;

    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| self.alloc.free(line);
        lines.deinit(self.alloc);
    }

    var it = std.mem.splitScalar(u8, cmd, '\n');
    while (it.next()) |line_raw| {
        if (line_raw.len == 0) continue;
        const line = self.alloc.alloc(u8, line_raw.len + 1) catch {
            log.warn("failed to allocate tmux command", .{});
            return;
        };
        @memcpy(line[0..line_raw.len], line_raw);
        line[line_raw.len] = '\n';
        lines.append(self.alloc, line) catch {
            self.alloc.free(line);
            log.warn("failed to allocate tmux command", .{});
            return;
        };
    }

    if (lines.items.len == 0) return;

    const first_to_send = lines.items[0];

    mutex.lock();
    defer mutex.unlock();

    const was_empty = viewer.command_queue.empty();
    viewer.command_queue.ensureUnusedCapacity(self.alloc, lines.items.len) catch {
        log.warn("failed to allocate tmux command", .{});
        return;
    };

    const queued_count = lines.items.len;
    for (lines.items) |line| {
        viewer.command_queue.appendAssumeCapacity(.{ .user = line });
    }
    lines.clearRetainingCapacity();

    if (was_empty) {
        const msg = termio.Message.writeReq(self.alloc, first_to_send) catch {
            log.warn("failed to send queued tmux command, removing from queue", .{});
            for (0..queued_count) |_| {
                if (viewer.command_queue.first()) |entry| entry.deinit(self.alloc);
                viewer.command_queue.deleteOldest(1);
            }
            return;
        };
        self.control_mailbox.send(msg, null);
        self.control_mailbox.notify();
    }
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const Config = struct {
    pane_id: usize,
    control_mailbox: *termio.Mailbox,
    viewer: if (tmux_enabled) *Viewer else void = if (tmux_enabled) undefined else {},
    control_mutex: if (tmux_enabled) *std.Thread.Mutex else void = if (tmux_enabled) undefined else {},
};
