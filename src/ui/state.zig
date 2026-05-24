//! UI data model: windows hold tabs, tabs hold a pane tree, pane leaves own a
//! Terminal (PTY + parser + screen). Mirrors Kaku's window/tab/pane shape.
//!
//! There is exactly one window in this scaffold, so the model is `State` (not
//! `Window`). Multi-window support is straightforward — promote `State` to a
//! `Window` and add a top-level `App`.

const std = @import("std");
const term = @import("../term.zig");

pub const PaneId = u32;

pub const SplitKind = enum {
    /// Two panes side-by-side, vertical divider between them.
    side_by_side,
    /// Two panes stacked, horizontal divider between them.
    top_bottom,
};

pub const Leaf = struct {
    id: PaneId,
    terminal: ?*term.Terminal = null,
};

pub const Pane = union(enum) {
    leaf: Leaf,
    split: SplitNode,
};

pub const SplitNode = struct {
    kind: SplitKind,
    /// Fraction of the parent rect occupied by `a`.
    ratio: f32,
    /// Left (side_by_side) or top (top_bottom).
    a: *Pane,
    /// Right (side_by_side) or bottom (top_bottom).
    b: *Pane,
};

pub const Tab = struct {
    name: []u8,
    root: *Pane,
    active: PaneId,
};

pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

pub const TabHit = struct { idx: usize, rect: Rect };
pub const PaneHit = struct { id: PaneId, rect: Rect };

pub const Selection = struct {
    pane_id: PaneId,
    anchor_col: u16,
    anchor_row: u16,
    end_col: u16,
    end_row: u16,
    dragging: bool,
};

pub const Spawner = *const fn (allocator: std.mem.Allocator) anyerror!*term.Terminal;

pub const State = struct {
    allocator: std.mem.Allocator,
    spawner: ?Spawner,
    tabs: std.ArrayList(*Tab),
    active_tab: usize,
    next_id: PaneId,
    selection: ?Selection = null,

    // Hit-box caches populated by the draw pass and consumed by mouseDown.
    tab_hits: std.ArrayList(TabHit),
    pane_hits: std.ArrayList(PaneHit),

    pub fn init(allocator: std.mem.Allocator, spawner: ?Spawner) !State {
        var self: State = .{
            .allocator = allocator,
            .spawner = spawner,
            .tabs = .empty,
            .active_tab = 0,
            .next_id = 0,
            .tab_hits = .empty,
            .pane_hits = .empty,
        };
        _ = try self.appendTab("session 1");
        return self;
    }

    pub fn deinit(self: *State) void {
        for (self.tabs.items) |tab| self.freeTab(tab);
        self.tabs.deinit(self.allocator);
        self.tab_hits.deinit(self.allocator);
        self.pane_hits.deinit(self.allocator);
    }

    pub fn currentTab(self: *State) *Tab {
        return self.tabs.items[self.active_tab];
    }

    fn newLeaf(self: *State) !*Pane {
        const id = self.next_id;
        self.next_id += 1;
        const p = try self.allocator.create(Pane);
        var leaf: Leaf = .{ .id = id };
        if (self.spawner) |sp| {
            leaf.terminal = sp(self.allocator) catch null;
        }
        p.* = .{ .leaf = leaf };
        return p;
    }

    fn appendTab(self: *State, name: []const u8) !*Tab {
        const root = try self.newLeaf();
        const tab = try self.allocator.create(Tab);
        tab.* = .{
            .name = try self.allocator.dupe(u8, name),
            .root = root,
            .active = root.leaf.id,
        };
        try self.tabs.append(self.allocator, tab);
        return tab;
    }

    fn freePane(self: *State, p: *Pane) void {
        switch (p.*) {
            .leaf => |l| {
                if (l.terminal) |t| t.destroy();
            },
            .split => |s| {
                self.freePane(s.a);
                self.freePane(s.b);
            },
        }
        self.allocator.destroy(p);
    }

    fn freeTab(self: *State, tab: *Tab) void {
        self.freePane(tab.root);
        self.allocator.free(tab.name);
        self.allocator.destroy(tab);
    }

    pub fn newTab(self: *State) !void {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "session {d}", .{self.tabs.items.len + 1});
        _ = try self.appendTab(name);
        self.active_tab = self.tabs.items.len - 1;
    }

    pub fn closeTab(self: *State) void {
        if (self.tabs.items.len <= 1) return;
        const tab = self.tabs.items[self.active_tab];
        self.freeTab(tab);
        _ = self.tabs.orderedRemove(self.active_tab);
        if (self.active_tab >= self.tabs.items.len) {
            self.active_tab = self.tabs.items.len - 1;
        }
    }

    pub fn selectTab(self: *State, idx: usize) void {
        if (idx < self.tabs.items.len) self.active_tab = idx;
    }

    pub fn cycleTab(self: *State, delta: isize) void {
        const n = self.tabs.items.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.active_tab);
        const next = @mod(cur + delta, @as(isize, @intCast(n)));
        self.active_tab = @intCast(next);
    }

    fn findLeafSlot(slot: **Pane, id: PaneId) ?**Pane {
        const pane = slot.*;
        switch (pane.*) {
            .leaf => |l| return if (l.id == id) slot else null,
            .split => {
                const s = &pane.split;
                if (findLeafSlot(&s.a, id)) |hit| return hit;
                if (findLeafSlot(&s.b, id)) |hit| return hit;
                return null;
            },
        }
    }

    /// Returns the parent slot pointer for the split node holding `id` and
    /// the sibling slot. Used when closing a pane.
    fn findParentSlotAndSibling(slot: **Pane, id: PaneId) ?struct { parent: **Pane, sibling: *Pane } {
        const pane = slot.*;
        switch (pane.*) {
            .leaf => return null,
            .split => {
                const s = &pane.split;
                switch (s.a.*) {
                    .leaf => |l| if (l.id == id) return .{ .parent = slot, .sibling = s.b },
                    else => {},
                }
                switch (s.b.*) {
                    .leaf => |l| if (l.id == id) return .{ .parent = slot, .sibling = s.a },
                    else => {},
                }
                if (findParentSlotAndSibling(&s.a, id)) |hit| return hit;
                if (findParentSlotAndSibling(&s.b, id)) |hit| return hit;
                return null;
            },
        }
    }

    pub fn splitActive(self: *State, kind: SplitKind) !void {
        const tab = self.currentTab();
        const slot = findLeafSlot(&tab.root, tab.active) orelse return;
        const old = slot.*;
        const new_leaf_pane = try self.newLeaf();
        const split = try self.allocator.create(Pane);
        split.* = .{ .split = .{
            .kind = kind,
            .ratio = 0.5,
            .a = old,
            .b = new_leaf_pane,
        } };
        slot.* = split;
        tab.active = new_leaf_pane.leaf.id;
    }

    /// Close the focused pane. If it's the only pane in the tab, this is a
    /// no-op (caller decides whether to closeTab instead).
    pub fn closeActivePane(self: *State) bool {
        const tab = self.currentTab();
        const id = tab.active;
        const hit = findParentSlotAndSibling(&tab.root, id) orelse return false;
        // Free the leaf being removed.
        switch (hit.parent.*.*) {
            .split => |s| {
                const removed: *Pane = if (matchesLeaf(s.a, id)) s.a else s.b;
                switch (removed.*) {
                    .leaf => |l| if (l.terminal) |t| t.destroy(),
                    else => {},
                }
                self.allocator.destroy(removed);
                const old_split: *Pane = hit.parent.*;
                hit.parent.* = hit.sibling;
                self.allocator.destroy(old_split);
                tab.active = firstLeafId(hit.sibling);
            },
            else => unreachable,
        }
        return true;
    }

    fn matchesLeaf(p: *Pane, id: PaneId) bool {
        return switch (p.*) {
            .leaf => |l| l.id == id,
            else => false,
        };
    }

    fn firstLeafId(p: *Pane) PaneId {
        return switch (p.*) {
            .leaf => |l| l.id,
            .split => |s| firstLeafId(s.a),
        };
    }

    fn collectLeaves(p: *Pane, out: *std.ArrayList(PaneId), alloc: std.mem.Allocator) !void {
        switch (p.*) {
            .leaf => |l| try out.append(alloc, l.id),
            .split => |s| {
                try collectLeaves(s.a, out, alloc);
                try collectLeaves(s.b, out, alloc);
            },
        }
    }

    pub fn cyclePane(self: *State, delta: isize) void {
        const tab = self.currentTab();
        var leaves: std.ArrayList(PaneId) = .empty;
        defer leaves.deinit(self.allocator);
        collectLeaves(tab.root, &leaves, self.allocator) catch return;
        if (leaves.items.len == 0) return;
        var idx: usize = 0;
        for (leaves.items, 0..) |lid, i| if (lid == tab.active) {
            idx = i;
            break;
        };
        const n: isize = @intCast(leaves.items.len);
        const next = @mod(@as(isize, @intCast(idx)) + delta, n);
        tab.active = leaves.items[@intCast(next)];
    }

    /// Walk to the leaf carrying the active id and return its Terminal pointer.
    pub fn focusedTerminal(self: *State) ?*term.Terminal {
        const tab = self.currentTab();
        return findTerminal(tab.root, tab.active);
    }

    pub fn terminalOf(self: *State, id: PaneId) ?*term.Terminal {
        const tab = self.currentTab();
        return findTerminal(tab.root, id);
    }

    fn findTerminal(p: *Pane, id: PaneId) ?*term.Terminal {
        return switch (p.*) {
            .leaf => |l| if (l.id == id) l.terminal else null,
            .split => |s| findTerminal(s.a, id) orelse findTerminal(s.b, id),
        };
    }
};

/// Normalised selection rectangle in (col, row) cell coordinates with row 0 at
/// the top of the screen. start <= end in row-major order.
pub fn normalizedSelection(sel: Selection) struct { sc: u16, sr: u16, ec: u16, er: u16 } {
    const before = (sel.anchor_row < sel.end_row) or
        (sel.anchor_row == sel.end_row and sel.anchor_col <= sel.end_col);
    return if (before)
        .{ .sc = sel.anchor_col, .sr = sel.anchor_row, .ec = sel.end_col, .er = sel.end_row }
    else
        .{ .sc = sel.end_col, .sr = sel.end_row, .ec = sel.anchor_col, .er = sel.anchor_row };
}

test "newTab and selectTab" {
    var s = try State.init(std.testing.allocator, null);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.tabs.items.len);
    try s.newTab();
    try std.testing.expectEqual(@as(usize, 2), s.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.active_tab);
    s.selectTab(0);
    try std.testing.expectEqual(@as(usize, 0), s.active_tab);
}

test "split replaces active leaf" {
    var s = try State.init(std.testing.allocator, null);
    defer s.deinit();
    const original_active = s.currentTab().active;
    try s.splitActive(.side_by_side);
    const tab = s.currentTab();
    try std.testing.expect(tab.root.* == .split);
    try std.testing.expect(tab.active != original_active);
}

test "closeActivePane removes leaf and collapses split" {
    var s = try State.init(std.testing.allocator, null);
    defer s.deinit();
    try s.splitActive(.side_by_side);
    try std.testing.expect(s.currentTab().root.* == .split);
    try std.testing.expect(s.closeActivePane());
    try std.testing.expect(s.currentTab().root.* == .leaf);
}

test "closeTab keeps last tab" {
    var s = try State.init(std.testing.allocator, null);
    defer s.deinit();
    s.closeTab();
    try std.testing.expectEqual(@as(usize, 1), s.tabs.items.len);
    try s.newTab();
    s.closeTab();
    try std.testing.expectEqual(@as(usize, 1), s.tabs.items.len);
}
