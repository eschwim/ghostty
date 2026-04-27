const std = @import("std");
const Allocator = std.mem.Allocator;
const Layout = @import("layout.zig").Layout;
const Viewer = @import("viewer.zig").Viewer;

const log = std.log.scoped(.tmux_controller);

pub const Controller = struct {
    alloc: Allocator,

    /// The viewer we are controlling. Owned by the control client's
    /// stream handler, not by us.
    viewer: *Viewer,

    /// Track the last known set of pane IDs so we can detect changes.
    known_pane_ids: std.AutoArrayHashMapUnmanaged(usize, void),

    /// Track the last known set of window IDs.
    known_window_ids: std.AutoArrayHashMapUnmanaged(usize, void),

    /// Cached active pane ID, updated during syncWindows. This avoids
    /// accessing the viewer from the main thread without the mutex.
    active_pane_id: ?usize = null,

    pub fn init(alloc: Allocator, viewer: *Viewer) Controller {
        return .{
            .alloc = alloc,
            .viewer = viewer,
            .known_pane_ids = .empty,
            .known_window_ids = .empty,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.known_pane_ids.deinit(self.alloc);
        self.known_window_ids.deinit(self.alloc);
    }

    /// Return the cached active pane ID. Safe to call from any thread
    /// since it reads a field set by syncWindows (which runs under mutex).
    pub fn activePaneId(self: *const Controller) ?usize {
        return self.active_pane_id;
    }

    /// Called when the viewer's window/pane state has changed.
    /// Must be called while holding the renderer mutex.
    /// Returns the pane ID that should be the "active" (rendered) pane,
    /// or null if there are no panes.
    pub fn syncWindows(self: *Controller) ?usize {
        const viewer = self.viewer;

        if (viewer.windows.items.len == 0) {
            self.known_window_ids.clearRetainingCapacity();
            self.known_pane_ids.clearRetainingCapacity();
            self.active_pane_id = null;
            return null;
        }

        var new_windows: usize = 0;
        for (viewer.windows.items) |window| {
            if (!self.known_window_ids.contains(window.id)) {
                new_windows += 1;
            }
        }
        if (new_windows > 0) {
            log.info("tmux: {d} new window(s), total {d}", .{
                new_windows,
                viewer.windows.items.len,
            });
        }

        self.known_window_ids.clearRetainingCapacity();
        self.known_pane_ids.clearRetainingCapacity();
        for (viewer.windows.items) |window| {
            self.known_window_ids.put(self.alloc, window.id, {}) catch |err| {
                log.warn("tmux: failed to track window id={d}: {}", .{ window.id, err });
                continue;
            };
            self.collectPaneIds(window.layout);
        }

        log.info("tmux: synced {d} windows, {d} panes", .{
            self.known_window_ids.count(),
            self.known_pane_ids.count(),
        });

        const first_window = viewer.windows.items[0];
        self.active_pane_id = first_window.layout.firstPaneId();
        return self.active_pane_id;
    }

    fn collectPaneIds(self: *Controller, layout: Layout) void {
        switch (layout.content) {
            .pane => |id| {
                self.known_pane_ids.put(self.alloc, id, {}) catch |err| {
                    log.warn("tmux: failed to track pane id={d}: {}", .{ id, err });
                };
            },
            .horizontal, .vertical => |children| {
                for (children) |child| self.collectPaneIds(child);
            },
        }
    }
};
