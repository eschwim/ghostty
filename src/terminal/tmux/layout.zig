const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// A tmux layout.
///
/// This is a tree structure so by definition it pretty much needs to be
/// allocated. We leave allocation up to the user of this struct, but
/// a general recommendation is to use an arena allocator for simplicity
/// in freeing the entire layout at once.
pub const Layout = struct {
    /// Width, height of the node
    width: usize,
    height: usize,

    /// X and Y offset from the top-left corner of the window.
    x: usize,
    y: usize,

    /// The content of this node, either a pane (leaf) or more nodes
    /// (split) horizontally or vertically.
    content: Content,

    pub const Content = union(enum) {
        pane: usize,
        horizontal: []const Layout,
        vertical: []const Layout,
    };

    /// Return the ID of the first leaf pane in this layout tree
    /// (depth-first, leftmost).
    pub fn firstPaneId(self: Layout) ?usize {
        switch (self.content) {
            .pane => |id| return id,
            .horizontal, .vertical => |children| {
                for (children) |child| {
                    if (child.firstPaneId()) |id| return id;
                }
                return null;
            },
        }
    }

    /// Find the leaf layout node for a given pane ID.
    pub fn findPane(self: Layout, pane_id: usize) ?Layout {
        switch (self.content) {
            .pane => |id| return if (id == pane_id) self else null,
            .horizontal, .vertical => |children| {
                for (children) |child| {
                    if (child.findPane(pane_id)) |found| return found;
                }
                return null;
            },
        }
    }

    /// Compute the total window size by walking the layout tree.
    /// Leaf pane sizes come from pane_surfaces; border space is
    /// derived from the existing layout dimensions.
    pub fn computeTotalSize(
        self: Layout,
        comptime Surface: type,
        pane_surfaces: *const std.AutoArrayHashMapUnmanaged(usize, *Surface),
    ) struct { width: usize, height: usize } {
        switch (self.content) {
            .pane => |id| {
                if (pane_surfaces.get(id)) |surface| {
                    const grid = surface.size.grid();
                    return .{ .width = grid.columns, .height = grid.rows };
                }
                return .{ .width = self.width, .height = self.height };
            },
            .horizontal => |children| {
                var child_width_sum: usize = 0;
                var new_width: usize = 0;
                var height: usize = 0;
                for (children) |child| {
                    child_width_sum += child.width;
                    const cs = child.computeTotalSize(Surface, pane_surfaces);
                    new_width += cs.width;
                    height = @max(height, cs.height);
                }
                const borders = self.width -| child_width_sum;
                return .{ .width = new_width + borders, .height = height };
            },
            .vertical => |children| {
                var child_height_sum: usize = 0;
                var width: usize = 0;
                var new_height: usize = 0;
                for (children) |child| {
                    child_height_sum += child.height;
                    const cs = child.computeTotalSize(Surface, pane_surfaces);
                    width = @max(width, cs.width);
                    new_height += cs.height;
                }
                const borders = self.height -| child_height_sum;
                return .{ .width = width, .height = new_height + borders };
            },
        }
    }

    /// Collect all pane IDs from this layout tree in depth-first order.
    pub fn collectPaneIds(self: Layout, list: *std.ArrayListUnmanaged(usize), alloc: Allocator) Allocator.Error!void {
        switch (self.content) {
            .pane => |id| {
                try list.append(alloc, id);
            },
            .horizontal, .vertical => |children| {
                for (children) |child| {
                    try child.collectPaneIds(list, alloc);
                }
            },
        }
    }

    /// A pane entry with its split direction relative to the previous pane.
    pub const PaneEntry = struct {
        pane_id: usize,
        /// null for the first pane (created as a tab, not a split)
        direction: ?SplitDirection = null,
        /// The split ratio (0.0-1.0) for the existing content when this
        /// pane is created. Only meaningful when direction is non-null.
        ratio: f64 = 0.5,
    };

    pub const SplitDirection = enum {
        right,
        down,
    };

    /// A split operation needed to restore a tmux layout using
    /// Ghostty's leaf-based split API.
    pub const RestoreStep = struct {
        /// The existing pane surface to split.
        split_pane_id: usize,
        /// The new pane surface created by the split.
        new_pane_id: usize,
        direction: SplitDirection,
        ratio: f64 = 0.5,
    };

    /// Build a split plan that recreates this tmux layout with repeated
    /// leaf splits. Returns the root pane ID that should be created as
    /// the initial tab before applying the returned steps.
    pub fn buildRestorePlan(
        self: Layout,
        list: *std.ArrayListUnmanaged(RestoreStep),
        alloc: Allocator,
    ) Allocator.Error!?usize {
        const root_pane_id = self.firstPaneId() orelse return null;
        try self.appendRestoreSteps(list, alloc);
        return root_pane_id;
    }

    /// Flatten the layout tree into an ordered list of pane entries
    /// with split directions. The first entry has direction=null
    /// (it should be created as a tab). Subsequent entries specify
    /// how to split from the previous pane.
    pub fn flattenPanes(
        self: Layout,
        list: *std.ArrayListUnmanaged(PaneEntry),
        alloc: Allocator,
        parent_direction: ?SplitDirection,
        parent_ratio: f64,
    ) Allocator.Error!void {
        switch (self.content) {
            .pane => |id| {
                try list.append(alloc, .{
                    .pane_id = id,
                    .direction = if (list.items.len == 0) null else parent_direction orelse .right,
                    .ratio = parent_ratio,
                });
            },
            .horizontal => |children| {
                var remaining_width = self.width;
                for (children, 0..) |child, i| {
                    if (i == 0) {
                        try child.flattenPanes(
                            list,
                            alloc,
                            parent_direction,
                            parent_ratio,
                        );
                    } else {
                        const ratio: f64 = if (remaining_width > 0)
                            @as(f64, @floatFromInt(children[i - 1].width)) / @as(f64, @floatFromInt(remaining_width))
                        else
                            0.5;
                        try child.flattenPanes(
                            list,
                            alloc,
                            .right,
                            ratio,
                        );
                    }
                    if (i > 0) {
                        // Subtract previous child + 1 border from remaining
                        const used = children[i - 1].width + 1;
                        remaining_width = if (remaining_width > used) remaining_width - used else 0;
                    }
                }
            },
            .vertical => |children| {
                var remaining_height = self.height;
                for (children, 0..) |child, i| {
                    if (i == 0) {
                        try child.flattenPanes(
                            list,
                            alloc,
                            parent_direction,
                            parent_ratio,
                        );
                    } else {
                        const ratio: f64 = if (remaining_height > 0)
                            @as(f64, @floatFromInt(children[i - 1].height)) / @as(f64, @floatFromInt(remaining_height))
                        else
                            0.5;
                        try child.flattenPanes(
                            list,
                            alloc,
                            .down,
                            ratio,
                        );
                    }
                    if (i > 0) {
                        const used = children[i - 1].height + 1;
                        remaining_height = if (remaining_height > used) remaining_height - used else 0;
                    }
                }
            },
        }
    }

    fn appendRestoreSteps(
        self: Layout,
        list: *std.ArrayListUnmanaged(RestoreStep),
        alloc: Allocator,
    ) Allocator.Error!void {
        switch (self.content) {
            .pane => {},
            .horizontal => |children| {
                if (children.len == 0) return;

                var split_anchor = children[0].firstPaneId() orelse return;
                var remaining: usize = 0;
                for (children) |child| remaining += child.width;

                for (children[1..], 1..) |child, i| {
                    const previous = children[i - 1];
                    const new_pane_id = child.firstPaneId() orelse return;
                    const previous_size = previous.width;

                    try list.append(alloc, .{
                        .split_pane_id = split_anchor,
                        .new_pane_id = new_pane_id,
                        .direction = .right,
                        .ratio = if (remaining > 0)
                            @as(f64, @floatFromInt(previous_size)) /
                                @as(f64, @floatFromInt(remaining))
                        else
                            0.5,
                    });

                    split_anchor = new_pane_id;
                    const used = previous_size;
                    remaining = if (remaining > used) remaining - used else 0;
                }

                for (children) |child| try child.appendRestoreSteps(list, alloc);
            },
            .vertical => |children| {
                if (children.len == 0) return;

                var split_anchor = children[0].firstPaneId() orelse return;
                var remaining: usize = 0;
                for (children) |child| remaining += child.height;

                for (children[1..], 1..) |child, i| {
                    const previous = children[i - 1];
                    const new_pane_id = child.firstPaneId() orelse return;
                    const previous_size = previous.height;

                    try list.append(alloc, .{
                        .split_pane_id = split_anchor,
                        .new_pane_id = new_pane_id,
                        .direction = .down,
                        .ratio = if (remaining > 0)
                            @as(f64, @floatFromInt(previous_size)) /
                                @as(f64, @floatFromInt(remaining))
                        else
                            0.5,
                    });

                    split_anchor = new_pane_id;
                    const used = previous_size;
                    remaining = if (remaining > used) remaining - used else 0;
                }

                for (children) |child| try child.appendRestoreSteps(list, alloc);
            },
        }
    }

    pub const ParseError = Allocator.Error || error{SyntaxError};

    /// Parse a layout string that includes a 4-character checksum prefix.
    ///
    /// The expected format is: `XXXX,layout_string` where XXXX is the
    /// 4-character hexadecimal checksum and the layout string follows
    /// after the comma. For example: `f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}`.
    ///
    /// Returns `ChecksumMismatch` if the checksum doesn't match the layout.
    /// Returns `SyntaxError` if the format is invalid.
    pub fn parseWithChecksum(
        alloc: Allocator,
        str: []const u8,
    ) (ParseError || error{ChecksumMismatch})!Layout {
        // If the string is less than 5 characters, it can't possibly
        // be correct. 4-char checksum + comma. In practice it should
        // be even longer, but that'll fail parse later.
        if (str.len < 5) return error.SyntaxError;
        if (str[4] != ',') return error.SyntaxError;

        // The layout string should start with a 4-character checksum.
        const checksum: Checksum = .calculate(str[5..]);
        if (!std.mem.startsWith(
            u8,
            str,
            &checksum.asString(),
        )) return error.ChecksumMismatch;

        // Checksum matches, parse the rest.
        return try parse(alloc, str[5..]);
    }

    /// Parse a layout string into a Layout structure. The given allocator
    /// will be used for all allocations within the layout. Note that
    /// individual nodes can't be freed so this allocator must be some
    /// kind of arena allocator.
    ///
    /// The layout string must be fully provided as a single string.
    /// Layouts are generally small so this should not be a problem.
    ///
    /// Tmux layout strings have the following format:
    ///
    /// - WxH,X,Y,ID Leaf pane: width×height, x-offset, y-offset, pane ID
    /// - WxH,X,Y{...} Horizontal split (left-right), children comma-separated
    /// - WxH,X,Y[...] Vertical split (top-bottom), children comma-separated
    pub fn parse(alloc: Allocator, str: []const u8) ParseError!Layout {
        var offset: usize = 0;
        const root = try parseNext(
            alloc,
            str,
            &offset,
        );
        if (offset != str.len) return error.SyntaxError;
        return root;
    }

    const max_depth = 32;

    fn parseNext(
        alloc: Allocator,
        str: []const u8,
        offset: *usize,
    ) ParseError!Layout {
        return parseNextDepth(alloc, str, offset, 0);
    }

    fn parseNextDepth(
        alloc: Allocator,
        str: []const u8,
        offset: *usize,
        depth: usize,
    ) ParseError!Layout {
        if (depth >= max_depth) return error.SyntaxError;
        // Find the first `x` to grab the width.
        const width: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            'x',
        )) |idx| width: {
            defer offset.* += idx + 1; // Consume `x`
            break :width std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find the height, up to a comma.
        const height: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| height: {
            defer offset.* += idx + 1; // Consume `,`
            break :height std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find X
        const x: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| x: {
            defer offset.* += idx + 1; // Consume `,`
            break :x std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find Y, which can end in any of `,{,[`
        const y: usize = if (std.mem.indexOfAny(
            u8,
            str[offset.*..],
            ",{[",
        )) |idx| y: {
            defer offset.* += idx; // Don't consume the delimiter!
            break :y std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Determine our child node.
        const content: Layout.Content = switch (str[offset.*]) {
            ',' => content: {
                // Consume the delimiter
                offset.* += 1;

                // Leaf pane. Read up to `,}]` because we may be in
                // a set of nodes. If none exist, end of string is fine.
                const idx = std.mem.indexOfAny(
                    u8,
                    str[offset.*..],
                    ",}]",
                ) orelse str.len - offset.*;

                defer offset.* += idx; // Consume the pane ID, not the delimiter
                const pane_id = std.fmt.parseInt(
                    usize,
                    str[offset.* .. offset.* + idx],
                    10,
                ) catch return error.SyntaxError;

                break :content .{ .pane = pane_id };
            },

            '{', '[' => |opening| content: {
                var nodes: std.ArrayList(Layout) = .empty;
                defer nodes.deinit(alloc);

                // Move beyond our opening
                offset.* += 1;

                while (true) {
                    try nodes.append(alloc, try parseNextDepth(
                        alloc,
                        str,
                        offset,
                        depth + 1,
                    ));

                    // We should not reach the end of string here because
                    // we expect a closing bracket.
                    if (offset.* >= str.len) return error.SyntaxError;

                    // If it is a comma, we expect another node.
                    if (str[offset.*] == ',') {
                        offset.* += 1; // Consume
                        continue;
                    }

                    // We expect a closing bracket now.
                    switch (opening) {
                        '{' => if (str[offset.*] != '}') return error.SyntaxError,
                        '[' => if (str[offset.*] != ']') return error.SyntaxError,
                        else => return error.SyntaxError,
                    }

                    // Successfully parsed all children.
                    offset.* += 1; // Consume closing bracket
                    break :content switch (opening) {
                        '{' => .{ .horizontal = try nodes.toOwnedSlice(alloc) },
                        '[' => .{ .vertical = try nodes.toOwnedSlice(alloc) },
                        else => unreachable,
                    };
                }
            },

            // indexOfAny above guarantees we have only the above
            else => unreachable,
        };

        return .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .content = content,
        };
    }
};

pub const Checksum = enum(u16) {
    _,

    /// Calculate the checksum of a tmux layout string.
    /// The algorithm rotates the checksum right by 1 bit (with wraparound)
    /// and adds the ASCII value of each character.
    pub fn calculate(str: []const u8) Checksum {
        var result: u16 = 0;
        for (str) |c| {
            // Rotate right by 1: (result >> 1) + ((result & 1) << 15)
            result = (result >> 1) | ((result & 1) << 15);
            result +%= c;
        }

        return @enumFromInt(result);
    }

    /// Convert the checksum to a 4-character hexadecimal string. This
    /// is always zero-padded to match the tmux implementation
    /// (in layout-custom.c).
    pub fn asString(self: Checksum) [4]u8 {
        const value = @intFromEnum(self);
        const charset = "0123456789abcdef";
        return .{
            charset[(value >> 12) & 0xf],
            charset[(value >> 8) & 0xf],
            charset[(value >> 4) & 0xf],
            charset[value & 0xf],
        };
    }
};

test "simple single pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,42");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);
    try testing.expectEqual(42, layout.content.pane);
}

test "single pane with offset" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "40x12,10,5,7");
    try testing.expectEqual(40, layout.width);
    try testing.expectEqual(12, layout.height);
    try testing.expectEqual(10, layout.x);
    try testing.expectEqual(5, layout.y);
    try testing.expectEqual(7, layout.content.pane);
}

test "single pane large values" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "1920x1080,100,200,999");
    try testing.expectEqual(1920, layout.width);
    try testing.expectEqual(1080, layout.height);
    try testing.expectEqual(100, layout.x);
    try testing.expectEqual(200, layout.y);
    try testing.expectEqual(999, layout.content.pane);
}

test "horizontal split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);

    const children = layout.content.horizontal;
    try testing.expectEqual(2, children.len);

    try testing.expectEqual(40, children[0].width);
    try testing.expectEqual(24, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);

    try testing.expectEqual(40, children[1].width);
    try testing.expectEqual(24, children[1].height);
    try testing.expectEqual(40, children[1].x);
    try testing.expectEqual(0, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}

test "vertical split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12,2]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);

    const children = layout.content.vertical;
    try testing.expectEqual(2, children.len);

    try testing.expectEqual(80, children[0].width);
    try testing.expectEqual(12, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);

    try testing.expectEqual(80, children[1].width);
    try testing.expectEqual(12, children[1].height);
    try testing.expectEqual(0, children[1].x);
    try testing.expectEqual(12, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}

test "horizontal split three panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "120x24,0,0{40x24,0,0,1,40x24,40,0,2,40x24,80,0,3}");
    try testing.expectEqual(120, layout.width);
    try testing.expectEqual(24, layout.height);

    const children = layout.content.horizontal;
    try testing.expectEqual(3, children.len);
    try testing.expectEqual(1, children[0].content.pane);
    try testing.expectEqual(2, children[1].content.pane);
    try testing.expectEqual(3, children[2].content.pane);
}

test "nested horizontal in vertical" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Vertical split with top pane and bottom horizontal split
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12{40x12,0,12,2,40x12,40,12,3}]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);

    const vert_children = layout.content.vertical;
    try testing.expectEqual(2, vert_children.len);

    // First child is a simple pane
    try testing.expectEqual(1, vert_children[0].content.pane);

    // Second child is a horizontal split
    const horiz_children = vert_children[1].content.horizontal;
    try testing.expectEqual(2, horiz_children.len);
    try testing.expectEqual(2, horiz_children[0].content.pane);
    try testing.expectEqual(3, horiz_children[1].content.pane);
}

test "nested vertical in horizontal" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Horizontal split with left pane and right vertical split
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);

    const horiz_children = layout.content.horizontal;
    try testing.expectEqual(2, horiz_children.len);

    // First child is a simple pane
    try testing.expectEqual(1, horiz_children[0].content.pane);

    // Second child is a vertical split
    const vert_children = horiz_children[1].content.vertical;
    try testing.expectEqual(2, vert_children.len);
    try testing.expectEqual(2, vert_children[0].content.pane);
    try testing.expectEqual(3, vert_children[1].content.pane);
}

test "deeply nested layout" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Three levels deep
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0[40x12,0,0,1,40x12,0,12,2],40x24,40,0,3}");

    const horiz = layout.content.horizontal;
    try testing.expectEqual(2, horiz.len);

    const vert = horiz[0].content.vertical;
    try testing.expectEqual(2, vert.len);
    try testing.expectEqual(1, vert[0].content.pane);
    try testing.expectEqual(2, vert[1].content.pane);

    try testing.expectEqual(3, horiz[1].content.pane);
}

test "syntax error empty string" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), ""));
}

test "syntax error missing width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "x24,0,0,1"));
}

test "syntax error missing height" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x,0,0,1"));
}

test "syntax error missing x" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,,0,1"));
}

test "syntax error missing y" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,,1"));
}

test "syntax error missing pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,"));
}

test "syntax error non-numeric width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "abcx24,0,0,1"));
}

test "syntax error non-numeric pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,abc"));
}

test "syntax error unclosed horizontal bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1"));
}

test "syntax error unclosed vertical bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1"));
}

test "syntax error mismatched brackets" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1]"));
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1}"));
}

test "syntax error trailing data" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,1extra"));
}

test "syntax error no x separator" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "8024,0,0,1"));
}

test "syntax error no content delimiter" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0"));
}

// parseWithChecksum tests

test "parseWithChecksum valid" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parseWithChecksum(arena.allocator(), "f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
}

test "parseWithChecksum mismatch" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.ChecksumMismatch, Layout.parseWithChecksum(arena.allocator(), "0000,80x24,0,0{40x24,0,0,1,40x24,40,0,2}"));
}

test "parseWithChecksum too short" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), "bb62"));
    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), ""));
}

test "parseWithChecksum missing comma" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), "bb62x159x48,0,0"));
}

// Checksum tests

test "checksum empty string" {
    const checksum = Checksum.calculate("");
    try testing.expectEqual(@as(u16, 0), @intFromEnum(checksum));
    try testing.expectEqualStrings("0000", &checksum.asString());
}

test "checksum single character" {
    // 'A' = 65, first iteration: csum = 0 >> 1 | 0 = 0, then 0 + 65 = 65
    const checksum = Checksum.calculate("A");
    try testing.expectEqual(@as(u16, 65), @intFromEnum(checksum));
    try testing.expectEqualStrings("0041", &checksum.asString());
}

test "checksum two characters" {
    // 'A' (65): csum = 0, rotate = 0, add 65 => 65
    // 'B' (66): csum = 65, rotate => (65 >> 1) | ((65 & 1) << 15) = 32 | 32768 = 32800
    //           add 66 => 32800 + 66 = 32866
    const checksum = Checksum.calculate("AB");
    try testing.expectEqual(@as(u16, 32866), @intFromEnum(checksum));
    try testing.expectEqualStrings("8062", &checksum.asString());
}

test "checksum simple layout" {
    const checksum = Checksum.calculate("80x24,0,0,42");
    try testing.expectEqualStrings("d962", &checksum.asString());
}

test "checksum horizontal split layout" {
    const checksum = Checksum.calculate("80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqualStrings("f8f9", &checksum.asString());
}

test "checksum asString zero padding" {
    // Value 0x000f should produce "000f"
    const checksum: Checksum = @enumFromInt(0x000f);
    try testing.expectEqualStrings("000f", &checksum.asString());
}

test "checksum asString all digits" {
    // Value 0x1234 should produce "1234"
    const checksum: Checksum = @enumFromInt(0x1234);
    try testing.expectEqualStrings("1234", &checksum.asString());
}

test "checksum asString with letters" {
    // Value 0xabcd should produce "abcd"
    const checksum: Checksum = @enumFromInt(0xabcd);
    try testing.expectEqualStrings("abcd", &checksum.asString());
}

test "checksum asString max value" {
    // Value 0xffff should produce "ffff"
    const checksum: Checksum = @enumFromInt(0xffff);
    try testing.expectEqualStrings("ffff", &checksum.asString());
}

test "checksum wraparound" {
    const checksum = Checksum.calculate("\xff\xff\xff\xff\xff\xff\xff\xff");
    try testing.expectEqualStrings("03fc", &checksum.asString());
}

test "checksum deterministic" {
    // Same input should always produce same output
    const str = "159x48,0,0{79x48,0,0,79x48,80,0}";
    const checksum1 = Checksum.calculate(str);
    const checksum2 = Checksum.calculate(str);
    try testing.expectEqual(checksum1, checksum2);
}

test "checksum different inputs different outputs" {
    const checksum1 = Checksum.calculate("80x24,0,0,1");
    const checksum2 = Checksum.calculate("80x24,0,0,2");
    try testing.expect(@intFromEnum(checksum1) != @intFromEnum(checksum2));
}

test "checksum known tmux layout bb62" {
    // From tmux documentation: "bb62,159x48,0,0{79x48,0,0,79x48,80,0}"
    // The checksum "bb62" corresponds to the layout "159x48,0,0{79x48,0,0,79x48,80,0}"
    const checksum = Checksum.calculate("159x48,0,0{79x48,0,0,79x48,80,0}");
    try testing.expectEqualStrings("bb62", &checksum.asString());
}

test "firstPaneId single pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,5");
    try testing.expectEqual(@as(?usize, 5), layout.firstPaneId());
}

test "firstPaneId horizontal split returns leftmost" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "160x24,0,0{80x24,0,0,3,79x24,81,0,7}");
    try testing.expectEqual(@as(?usize, 3), layout.firstPaneId());
}

test "firstPaneId vertical split returns topmost" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x48,0,0[80x24,0,0,10,80x23,0,25,20]");
    try testing.expectEqual(@as(?usize, 10), layout.firstPaneId());
}

test "collectPaneIds single pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,5");
    var ids: std.ArrayListUnmanaged(usize) = .empty;
    defer ids.deinit(testing.allocator);
    try layout.collectPaneIds(&ids, testing.allocator);
    try testing.expectEqual(1, ids.items.len);
    try testing.expectEqual(5, ids.items[0]);
}

test "collectPaneIds nested layout" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "160x48,0,0{80x48,0,0[80x24,0,0,1,80x23,0,25,2],79x48,81,0,3}");
    var ids: std.ArrayListUnmanaged(usize) = .empty;
    defer ids.deinit(testing.allocator);
    try layout.collectPaneIds(&ids, testing.allocator);
    try testing.expectEqual(3, ids.items.len);
    try testing.expectEqual(1, ids.items[0]);
    try testing.expectEqual(2, ids.items[1]);
    try testing.expectEqual(3, ids.items[2]);
}

test "flattenPanes single pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,5");
    var entries: std.ArrayListUnmanaged(Layout.PaneEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try layout.flattenPanes(&entries, testing.allocator, null, 0.5);
    try testing.expectEqual(1, entries.items.len);
    try testing.expectEqual(5, entries.items[0].pane_id);
    try testing.expectEqual(@as(?Layout.SplitDirection, null), entries.items[0].direction);
}

test "flattenPanes horizontal split" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "160x24,0,0{80x24,0,0,1,79x24,81,0,2}");
    var entries: std.ArrayListUnmanaged(Layout.PaneEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try layout.flattenPanes(&entries, testing.allocator, null, 0.5);
    try testing.expectEqual(2, entries.items.len);
    try testing.expectEqual(1, entries.items[0].pane_id);
    try testing.expectEqual(@as(?Layout.SplitDirection, null), entries.items[0].direction);
    try testing.expectEqual(2, entries.items[1].pane_id);
    try testing.expectEqual(@as(?Layout.SplitDirection, .right), entries.items[1].direction);
}

test "flattenPanes vertical split" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x48,0,0[80x24,0,0,3,80x23,0,25,4]");
    var entries: std.ArrayListUnmanaged(Layout.PaneEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try layout.flattenPanes(&entries, testing.allocator, null, 0.5);
    try testing.expectEqual(2, entries.items.len);
    try testing.expectEqual(3, entries.items[0].pane_id);
    try testing.expectEqual(@as(?Layout.SplitDirection, null), entries.items[0].direction);
    try testing.expectEqual(4, entries.items[1].pane_id);
    try testing.expectEqual(@as(?Layout.SplitDirection, .down), entries.items[1].direction);
}

test "findPane existing pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "160x24,0,0{80x24,0,0,1,79x24,81,0,2}");
    const found = layout.findPane(2).?;
    try testing.expectEqual(79, found.width);
    try testing.expectEqual(24, found.height);
}

test "findPane missing pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,1");
    try testing.expectEqual(@as(?Layout, null), layout.findPane(99));
}

test "flattenPanes ratio for equal vertical split" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // 80x49: top=80x24 + 1 border + bottom=80x24
    const layout: Layout = try .parse(arena.allocator(), "80x49,0,0[80x24,0,0,1,80x24,0,25,2]");
    var entries: std.ArrayListUnmanaged(Layout.PaneEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try layout.flattenPanes(&entries, testing.allocator, null, 0.5);
    try testing.expectEqual(2, entries.items.len);
    // ratio = top.height / parent.height = 24/49 ≈ 0.4898
    try testing.expectApproxEqAbs(24.0 / 49.0, entries.items[1].ratio, 0.001);
}

test "flattenPanes ratio for unequal horizontal split" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // 160x24: left=100x24 + 1 border + right=59x24
    const layout: Layout = try .parse(arena.allocator(), "160x24,0,0{100x24,0,0,1,59x24,101,0,2}");
    var entries: std.ArrayListUnmanaged(Layout.PaneEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try layout.flattenPanes(&entries, testing.allocator, null, 0.5);
    try testing.expectEqual(2, entries.items.len);
    // ratio = left.width / parent.width = 100/160 = 0.625
    try testing.expectApproxEqAbs(100.0 / 160.0, entries.items[1].ratio, 0.001);
}

test "flattenPanes ratio for three-way vertical split" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // 80x74: top=80x24 + border + mid=80x24 + border + bot=80x24
    const layout: Layout = try .parse(arena.allocator(), "80x74,0,0[80x24,0,0,1,80x24,0,25,2,80x24,0,50,3]");
    var entries: std.ArrayListUnmanaged(Layout.PaneEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try layout.flattenPanes(&entries, testing.allocator, null, 0.5);
    try testing.expectEqual(3, entries.items.len);
    // Second pane: ratio = top.height / parent.height = 24/74
    try testing.expectApproxEqAbs(24.0 / 74.0, entries.items[1].ratio, 0.001);
    // Third pane: ratio = mid.height / remaining = 24/(74-24-1) = 24/49
    try testing.expectApproxEqAbs(24.0 / 49.0, entries.items[2].ratio, 0.001);
}

test "buildRestorePlan nested top split then bottom pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(
        arena.allocator(),
        "160x49,0,0[160x24,0,0{80x24,0,0,1,79x24,81,0,2},160x24,0,25,3]",
    );

    var steps: std.ArrayListUnmanaged(Layout.RestoreStep) = .empty;
    defer steps.deinit(testing.allocator);

    const root_pane_id = try layout.buildRestorePlan(&steps, testing.allocator);
    try testing.expectEqual(@as(?usize, 1), root_pane_id);
    try testing.expectEqual(@as(usize, 2), steps.items.len);

    try testing.expectEqual(@as(usize, 1), steps.items[0].split_pane_id);
    try testing.expectEqual(@as(usize, 3), steps.items[0].new_pane_id);
    try testing.expectEqual(Layout.SplitDirection.down, steps.items[0].direction);
    try testing.expectApproxEqAbs(24.0 / 48.0, steps.items[0].ratio, 0.001);

    try testing.expectEqual(@as(usize, 1), steps.items[1].split_pane_id);
    try testing.expectEqual(@as(usize, 2), steps.items[1].new_pane_id);
    try testing.expectEqual(Layout.SplitDirection.right, steps.items[1].direction);
    try testing.expectApproxEqAbs(80.0 / 159.0, steps.items[1].ratio, 0.001);
}

test "buildRestorePlan right subtree restores from its own anchor" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(
        arena.allocator(),
        "160x49,0,0{80x49,0,0,1,79x49,81,0[79x24,81,0,2,79x24,81,25,3]}",
    );

    var steps: std.ArrayListUnmanaged(Layout.RestoreStep) = .empty;
    defer steps.deinit(testing.allocator);

    const root_pane_id = try layout.buildRestorePlan(&steps, testing.allocator);
    try testing.expectEqual(@as(?usize, 1), root_pane_id);
    try testing.expectEqual(@as(usize, 2), steps.items.len);

    try testing.expectEqual(@as(usize, 1), steps.items[0].split_pane_id);
    try testing.expectEqual(@as(usize, 2), steps.items[0].new_pane_id);
    try testing.expectEqual(Layout.SplitDirection.right, steps.items[0].direction);
    try testing.expectApproxEqAbs(80.0 / 159.0, steps.items[0].ratio, 0.001);

    try testing.expectEqual(@as(usize, 2), steps.items[1].split_pane_id);
    try testing.expectEqual(@as(usize, 3), steps.items[1].new_pane_id);
    try testing.expectEqual(Layout.SplitDirection.down, steps.items[1].direction);
    try testing.expectApproxEqAbs(24.0 / 48.0, steps.items[1].ratio, 0.001);
}
