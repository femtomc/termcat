const std = @import("std");
const Cell = @import("Cell.zig");
const Buffer = @import("Buffer.zig");
const Event = @import("Event.zig");
const Size = Event.Size;
const Position = Event.Position;
const Rect = Event.Rect;
const Color = Cell.Color;
const Attributes = Cell.Attributes;

/// A composable plane in the rendering hierarchy.
///
/// Planes are rectangular regions that can contain cells and child planes.
/// Each plane has:
/// - A position relative to its parent (or screen for root)
/// - Its own cell buffer for drawing
/// - A list of child planes with z-order (lower index = further back)
/// - Visibility flag to show/hide the entire plane subtree
///
/// Planes automatically clip content and children to their bounds.
/// Coordinate translation helpers convert between plane-local and screen coords.
pub const Plane = @This();

/// Position relative to parent (or screen for root planes)
x: i32,
y: i32,

/// Dimensions of this plane
width: u16,
height: u16,

/// Cell buffer for this plane's content
buffer: Buffer,

/// Parent plane (null for root planes)
parent: ?*Plane,

/// Child planes in z-order (index 0 = furthest back)
children: std.ArrayList(*Plane),

/// Whether this plane and its children are visible
visible: bool,

/// Allocator for managing children and buffer
allocator: std.mem.Allocator,

/// Dirty region tracking: bounding box of modifications since last clear.
/// Coordinates are in plane-local space. null means no modifications.
dirty_rect: ?Rect,

/// Create a new root plane (no parent).
/// Root planes typically represent the full screen.
pub fn initRoot(allocator: std.mem.Allocator, dimensions: Size) !*Plane {
    const plane = try allocator.create(Plane);
    errdefer allocator.destroy(plane);

    const buffer = try Buffer.init(allocator, dimensions);

    plane.* = .{
        .x = 0,
        .y = 0,
        .width = dimensions.width,
        .height = dimensions.height,
        .buffer = buffer,
        .parent = null,
        .children = .empty,
        .visible = true,
        .allocator = allocator,
        .dirty_rect = null,
    };

    return plane;
}

/// Create a child plane at the given position relative to parent.
/// The child is automatically added to the end of the parent's z-order (topmost).
pub fn initChild(
    parent: *Plane,
    x: i32,
    y: i32,
    dimensions: Size,
) !*Plane {
    const allocator = parent.allocator;
    const plane = try allocator.create(Plane);
    errdefer allocator.destroy(plane);

    var buffer = try Buffer.init(allocator, dimensions);
    errdefer buffer.deinit();

    plane.* = .{
        .x = x,
        .y = y,
        .width = dimensions.width,
        .height = dimensions.height,
        .buffer = buffer,
        .parent = parent,
        .children = .empty,
        .visible = true,
        .allocator = allocator,
        .dirty_rect = null,
    };

    try parent.children.append(allocator, plane);

    return plane;
}

/// Destroy this plane and all its children recursively.
/// If this plane has a parent, it removes itself from the parent's child list.
pub fn deinit(self: *Plane) void {
    const allocator = self.allocator;

    // Recursively destroy children first
    for (self.children.items) |child| {
        // Don't let child try to remove itself from our list during deinit
        child.parent = null;
        child.deinit();
    }
    self.children.deinit(allocator);

    // Remove from parent's child list if we have a parent
    if (self.parent) |parent| {
        for (parent.children.items, 0..) |child, i| {
            if (child == self) {
                _ = parent.children.orderedRemove(i);
                break;
            }
        }
    }

    // Clean up buffer
    self.buffer.deinit();

    // Destroy the plane struct itself
    allocator.destroy(self);
}

/// Move this plane to a new position relative to its parent.
pub fn move(self: *Plane, new_x: i32, new_y: i32) void {
    self.x = new_x;
    self.y = new_y;
}

/// Resize this plane. Clears the buffer content.
pub fn resize(self: *Plane, new_size: Size) !void {
    const old_width = self.width;
    const old_height = self.height;
    const old_x = self.x;
    const old_y = self.y;

    try self.buffer.resize(new_size);
    self.width = new_size.width;
    self.height = new_size.height;
    self.markAllDirty();

    if (self.parent) |parent| {
        // Invalidate the old bounds on the parent so shrink clears stale content.
        const old_right = old_x + @as(i32, old_width);
        const old_bottom = old_y + @as(i32, old_height);
        const parent_right = @as(i32, parent.width);
        const parent_bottom = @as(i32, parent.height);

        const clipped_left = @max(old_x, 0);
        const clipped_top = @max(old_y, 0);
        const clipped_right = @min(old_right, parent_right);
        const clipped_bottom = @min(old_bottom, parent_bottom);

        if (clipped_left < clipped_right and clipped_top < clipped_bottom) {
            parent.markDirtyRect(.{
                .x = @intCast(clipped_left),
                .y = @intCast(clipped_top),
                .width = @intCast(clipped_right - clipped_left),
                .height = @intCast(clipped_bottom - clipped_top),
            });
        }
    }
}

/// Set visibility of this plane and its children.
pub fn setVisible(self: *Plane, vis: bool) void {
    self.visible = vis;
}

/// Check if this plane is visible.
/// A plane is effectively visible only if it and all ancestors are visible.
pub fn isVisible(self: *const Plane) bool {
    if (!self.visible) return false;
    if (self.parent) |parent| {
        return parent.isVisible();
    }
    return true;
}

/// Raise this plane to the top of its parent's z-order.
/// No-op for root planes.
pub fn raise(self: *Plane) void {
    if (self.parent) |parent| {
        // Find and remove self
        for (parent.children.items, 0..) |child, i| {
            if (child == self) {
                _ = parent.children.orderedRemove(i);
                break;
            }
        }
        // Add to end (top)
        parent.children.append(parent.allocator, self) catch {}; // Can't fail - we just removed one
    }
}

/// Lower this plane to the bottom of its parent's z-order.
/// No-op for root planes.
pub fn lower(self: *Plane) void {
    if (self.parent) |parent| {
        // Find and remove self
        for (parent.children.items, 0..) |child, i| {
            if (child == self) {
                _ = parent.children.orderedRemove(i);
                break;
            }
        }
        // Insert at beginning (bottom)
        parent.children.insert(parent.allocator, 0, self) catch {}; // Can't fail - we just removed one
    }
}

/// Move this plane above another sibling in z-order.
/// No-op if planes don't share a parent or if self == other.
pub fn raiseAbove(self: *Plane, other: *Plane) void {
    if (self.parent == null or self.parent != other.parent or self == other) return;

    const parent = self.parent.?;

    // Find positions
    var self_idx: ?usize = null;
    var other_idx: ?usize = null;

    for (parent.children.items, 0..) |child, i| {
        if (child == self) self_idx = i;
        if (child == other) other_idx = i;
    }

    if (self_idx == null or other_idx == null) return;

    // Remove self
    _ = parent.children.orderedRemove(self_idx.?);

    // Adjust other_idx if necessary
    var insert_pos = other_idx.?;
    if (self_idx.? < other_idx.?) {
        insert_pos -= 1; // other shifted down after self was removed
    }

    // Insert after other (insert_pos + 1)
    parent.children.insert(parent.allocator, insert_pos + 1, self) catch {};
}

/// Move this plane below another sibling in z-order.
/// No-op if planes don't share a parent or if self == other.
pub fn lowerBelow(self: *Plane, other: *Plane) void {
    if (self.parent == null or self.parent != other.parent or self == other) return;

    const parent = self.parent.?;

    // Find positions
    var self_idx: ?usize = null;
    var other_idx: ?usize = null;

    for (parent.children.items, 0..) |child, i| {
        if (child == self) self_idx = i;
        if (child == other) other_idx = i;
    }

    if (self_idx == null or other_idx == null) return;

    // Remove self
    _ = parent.children.orderedRemove(self_idx.?);

    // Adjust other_idx if necessary
    var insert_pos = other_idx.?;
    if (self_idx.? < other_idx.?) {
        insert_pos -= 1; // other shifted down after self was removed
    }

    // Insert at other's position (before other)
    parent.children.insert(parent.allocator, insert_pos, self) catch {};
}

/// Get the z-index of this plane within its parent.
/// Returns null for root planes.
pub fn zIndex(self: *const Plane) ?usize {
    if (self.parent) |parent| {
        for (parent.children.items, 0..) |child, i| {
            if (child == self) return i;
        }
    }
    return null;
}

/// Convert plane-local coordinates to screen (root) coordinates.
/// Walks up the parent chain accumulating offsets.
///
/// Note: The returned Position uses u16 coordinates which cannot represent negative values.
/// For planes with negative positions, off-screen local coordinates will be clamped to 0.
/// If you need the true signed screen position, use `localToScreenSigned` instead.
pub fn localToScreen(self: *const Plane, local_x: i32, local_y: i32) Position {
    const signed = self.localToScreenSigned(local_x, local_y);
    // Clamp to u16 range (screen coords are non-negative for rendering)
    return .{
        .x = if (signed.x < 0) 0 else @intCast(@min(signed.x, std.math.maxInt(u16))),
        .y = if (signed.y < 0) 0 else @intCast(@min(signed.y, std.math.maxInt(u16))),
    };
}

/// Convert plane-local coordinates to signed screen coordinates.
/// Walks up the parent chain accumulating offsets.
/// Returns signed coordinates that may be negative for off-screen positions.
pub fn localToScreenSigned(self: *const Plane, local_x: i32, local_y: i32) struct { x: i32, y: i32 } {
    var screen_x = local_x + self.x;
    var screen_y = local_y + self.y;

    var current = self.parent;
    while (current) |p| {
        screen_x += p.x;
        screen_y += p.y;
        current = p.parent;
    }

    return .{ .x = screen_x, .y = screen_y };
}

/// Convert screen (root) coordinates to plane-local coordinates.
/// Returns the position relative to this plane's origin.
pub fn screenToLocal(self: *const Plane, screen_x: i32, screen_y: i32) struct { x: i32, y: i32 } {
    var offset_x: i32 = self.x;
    var offset_y: i32 = self.y;

    var current = self.parent;
    while (current) |p| {
        offset_x += p.x;
        offset_y += p.y;
        current = p.parent;
    }

    return .{
        .x = screen_x - offset_x,
        .y = screen_y - offset_y,
    };
}

/// Get the visible bounds of this plane clipped to all ancestors.
/// Returns null if the plane is completely clipped, not visible, or has an invisible ancestor.
/// Coordinates are in screen space.
pub fn getClippedBounds(self: *const Plane) ?Rect {
    // Check effective visibility (self and all ancestors)
    if (!self.isVisible()) return null;

    // Compute this plane's screen origin (signed to handle negative positions)
    var screen_x: i32 = self.x;
    var screen_y: i32 = self.y;
    var current_parent = self.parent;
    while (current_parent) |p| {
        screen_x += p.x;
        screen_y += p.y;
        current_parent = p.parent;
    }

    // Compute the plane's bounds as signed rect
    var left: i32 = screen_x;
    var top: i32 = screen_y;
    var right: i32 = screen_x + @as(i32, self.width);
    var bottom: i32 = screen_y + @as(i32, self.height);

    // Clip to each ancestor's bounds
    var current = self.parent;
    while (current) |p| {
        // Compute parent's screen origin
        var parent_screen_x: i32 = p.x;
        var parent_screen_y: i32 = p.y;
        var pp = p.parent;
        while (pp) |gp| {
            parent_screen_x += gp.x;
            parent_screen_y += gp.y;
            pp = gp.parent;
        }

        // Clip to parent bounds
        const parent_left = parent_screen_x;
        const parent_top = parent_screen_y;
        const parent_right = parent_screen_x + @as(i32, p.width);
        const parent_bottom = parent_screen_y + @as(i32, p.height);

        left = @max(left, parent_left);
        top = @max(top, parent_top);
        right = @min(right, parent_right);
        bottom = @min(bottom, parent_bottom);

        if (left >= right or top >= bottom) return null;

        current = p.parent;
    }

    // Final clip to screen (non-negative)
    left = @max(left, 0);
    top = @max(top, 0);
    if (left >= right or top >= bottom) return null;

    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

/// Get the visible bounds in local coordinates.
/// Returns null if completely clipped.
pub fn getClippedLocalBounds(self: *const Plane) ?Rect {
    const screen_bounds = self.getClippedBounds() orelse return null;
    const local = self.screenToLocal(@intCast(screen_bounds.x), @intCast(screen_bounds.y));

    // local coords could be negative if this plane extends past its parent
    // clamp to 0 and adjust width/height accordingly
    const local_x: u16 = if (local.x < 0) 0 else @intCast(@min(local.x, std.math.maxInt(u16)));
    const local_y: u16 = if (local.y < 0) 0 else @intCast(@min(local.y, std.math.maxInt(u16)));

    // Adjust width/height if we clamped
    const x_offset: u16 = if (local.x < 0) @intCast(-local.x) else 0;
    const y_offset: u16 = if (local.y < 0) @intCast(-local.y) else 0;

    const adj_width = screen_bounds.width -| x_offset;
    const adj_height = screen_bounds.height -| y_offset;

    if (adj_width == 0 or adj_height == 0) return null;

    return .{
        .x = local_x,
        .y = local_y,
        .width = adj_width,
        .height = adj_height,
    };
}

/// Check if a screen coordinate is within this plane's visible bounds.
pub fn containsScreen(self: *const Plane, screen_x: u16, screen_y: u16) bool {
    const bounds = self.getClippedBounds() orelse return false;

    return screen_x >= bounds.x and
        screen_x < bounds.x +| bounds.width and
        screen_y >= bounds.y and
        screen_y < bounds.y +| bounds.height;
}

/// Check if a local coordinate is within this plane's bounds (ignoring clipping).
pub fn containsLocal(self: *const Plane, local_x: i32, local_y: i32) bool {
    return local_x >= 0 and
        local_y >= 0 and
        local_x < self.width and
        local_y < self.height;
}

/// Get the cell buffer for direct drawing.
/// Note: Modifications through this buffer bypass dirty tracking.
/// Consider using setCell/print/fill/clear instead for automatic tracking.
pub fn getBuffer(self: *Plane) *Buffer {
    return &self.buffer;
}

/// Set a cell at plane-local coordinates.
/// Out-of-bounds coordinates are silently ignored.
/// Automatically marks the cell as dirty.
pub fn setCell(self: *Plane, x: u16, y: u16, cell: Cell) void {
    if (x < self.width and y < self.height) {
        self.buffer.setCell(x, y, cell);
        self.markDirtyRect(.{ .x = x, .y = y, .width = 1, .height = 1 });
    }
}

/// Get a cell at plane-local coordinates.
/// Out-of-bounds returns Cell.default.
pub fn getCell(self: *const Plane, x: u16, y: u16) Cell {
    return self.buffer.getCell(x, y);
}

/// Print text at plane-local coordinates.
/// Automatically marks the printed region as dirty.
pub fn print(self: *Plane, x: u16, y: u16, str: []const u8, fg: Color, bg: Color, attrs: Attributes) void {
    const unicode = @import("unicode/width.zig");
    self.buffer.print(x, y, str, fg, bg, attrs);
    // Calculate the width of the printed text
    const text_width = unicode.stringWidth(str);
    // Clip to plane bounds
    const actual_width: u16 = @intCast(@min(text_width, self.width -| x));
    if (actual_width > 0 and y < self.height) {
        self.markDirtyRect(.{ .x = x, .y = y, .width = actual_width, .height = 1 });
    }
}

/// Clear the plane's buffer.
/// Automatically marks the entire plane as dirty.
pub fn clear(self: *Plane) void {
    self.buffer.clear();
    self.markDirtyRect(.{ .x = 0, .y = 0, .width = self.width, .height = self.height });
}

/// Fill a rectangle within the plane.
/// Automatically marks the filled region as dirty.
pub fn fill(self: *Plane, rect: Rect, cell: Cell) void {
    self.buffer.fill(rect, cell);
    // Clip to plane bounds
    const x_end = @min(rect.x +| rect.width, self.width);
    const y_end = @min(rect.y +| rect.height, self.height);
    const actual_width = x_end -| rect.x;
    const actual_height = y_end -| rect.y;
    if (actual_width > 0 and actual_height > 0) {
        self.markDirtyRect(.{ .x = rect.x, .y = rect.y, .width = actual_width, .height = actual_height });
    }
}

// ============================================================================
// Dirty tracking
// ============================================================================

/// Mark a region as dirty (modified) in plane-local coordinates.
/// Expands the existing dirty region to include the new area.
pub fn markDirtyRect(self: *Plane, rect: Rect) void {
    if (self.dirty_rect) |*existing| {
        // Expand bounding box to include new region
        const existing_right = existing.x +| existing.width;
        const existing_bottom = existing.y +| existing.height;
        const new_right = rect.x +| rect.width;
        const new_bottom = rect.y +| rect.height;

        const left = @min(existing.x, rect.x);
        const top = @min(existing.y, rect.y);
        const right = @max(existing_right, new_right);
        const bottom = @max(existing_bottom, new_bottom);

        existing.* = .{
            .x = left,
            .y = top,
            .width = right - left,
            .height = bottom - top,
        };
    } else {
        self.dirty_rect = rect;
    }
}

/// Mark the entire plane as dirty.
pub fn markAllDirty(self: *Plane) void {
    self.dirty_rect = .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
}

/// Check if this plane has any dirty regions.
pub fn isDirty(self: *const Plane) bool {
    return self.dirty_rect != null;
}

/// Get and clear the dirty region.
/// Returns the dirty rect in plane-local coordinates, or null if clean.
/// After calling, the plane is marked as clean.
pub fn takeDirtyRect(self: *Plane) ?Rect {
    const rect = self.dirty_rect;
    self.dirty_rect = null;
    return rect;
}

/// Get the dirty region in screen coordinates, clipped to visible bounds.
/// Returns null if plane is clean, hidden, or completely clipped.
/// Does NOT clear the dirty flag (use takeDirtyRect for that).
pub fn getDirtyScreenRect(self: *const Plane) ?Rect {
    const local_dirty = self.dirty_rect orelse return null;

    // Get the plane's visible screen bounds
    const screen_bounds = self.getClippedBounds() orelse return null;

    // Convert dirty rect to screen coordinates
    const screen_pos = self.localToScreenSigned(@intCast(local_dirty.x), @intCast(local_dirty.y));

    // Handle negative screen coordinates
    var dirty_left: i32 = screen_pos.x;
    var dirty_top: i32 = screen_pos.y;
    var dirty_right: i32 = screen_pos.x + @as(i32, local_dirty.width);
    var dirty_bottom: i32 = screen_pos.y + @as(i32, local_dirty.height);

    // Clip to visible screen bounds
    dirty_left = @max(dirty_left, @as(i32, screen_bounds.x));
    dirty_top = @max(dirty_top, @as(i32, screen_bounds.y));
    dirty_right = @min(dirty_right, @as(i32, screen_bounds.x) + @as(i32, screen_bounds.width));
    dirty_bottom = @min(dirty_bottom, @as(i32, screen_bounds.y) + @as(i32, screen_bounds.height));

    // Also clip to non-negative (screen space)
    dirty_left = @max(dirty_left, 0);
    dirty_top = @max(dirty_top, 0);

    if (dirty_left >= dirty_right or dirty_top >= dirty_bottom) {
        return null;
    }

    return .{
        .x = @intCast(dirty_left),
        .y = @intCast(dirty_top),
        .width = @intCast(dirty_right - dirty_left),
        .height = @intCast(dirty_bottom - dirty_top),
    };
}

/// Get the dimensions of this plane.
pub fn size(self: *const Plane) Size {
    return .{ .width = self.width, .height = self.height };
}

/// Iterate over all visible planes in z-order (back to front).
/// Calls the callback for each visible plane, passing screen position.
/// If callback returns false, iteration stops.
/// Note: A plane is considered visible only if it and all its ancestors are visible.
pub fn iterateVisible(
    self: *const Plane,
    callback: *const fn (plane: *const Plane, screen_x: i32, screen_y: i32) bool,
) void {
    // Check effective visibility (handles case where this isn't the root)
    if (!self.isVisible()) return;

    // Compute the screen position of this plane's parent (or 0,0 for root)
    var parent_screen_x: i32 = 0;
    var parent_screen_y: i32 = 0;
    if (self.parent) |p| {
        const parent_pos = p.localToScreenSigned(0, 0);
        parent_screen_x = parent_pos.x;
        parent_screen_y = parent_pos.y;
    }

    iterateVisibleInner(self, parent_screen_x, parent_screen_y, callback);
}

fn iterateVisibleInner(
    self: *const Plane,
    parent_screen_x: i32,
    parent_screen_y: i32,
    callback: *const fn (plane: *const Plane, screen_x: i32, screen_y: i32) bool,
) void {
    // Use .visible here since ancestor visibility was checked at entry
    if (!self.visible) return;

    const screen_x = parent_screen_x + self.x;
    const screen_y = parent_screen_y + self.y;

    // Call callback for this plane
    if (!callback(self, screen_x, screen_y)) return;

    // Recurse into children (z-order: index 0 is furthest back, rendered first)
    for (self.children.items) |child| {
        iterateVisibleInner(child, screen_x, screen_y, callback);
    }
}

/// Get all visible planes as a flat list in z-order (back to front).
/// Caller owns the returned list.
/// Note: A plane is considered visible only if it and all its ancestors are visible.
pub fn collectVisible(self: *const Plane, allocator: std.mem.Allocator) !std.ArrayList(*const Plane) {
    var list: std.ArrayList(*const Plane) = .empty;
    errdefer list.deinit(allocator);

    // Check effective visibility (handles case where this isn't the root)
    if (!self.isVisible()) return list;

    try collectVisibleInner(self, allocator, &list);
    return list;
}

fn collectVisibleInner(self: *const Plane, allocator: std.mem.Allocator, list: *std.ArrayList(*const Plane)) !void {
    // Use .visible here since ancestor visibility was checked at entry
    if (!self.visible) return;

    try list.append(allocator, self);

    for (self.children.items) |child| {
        try collectVisibleInner(child, allocator, list);
    }
}

// Helper: intersect two rectangles, return null if no intersection
fn clipRect(a: Rect, b: Rect) ?Rect {
    const a_right = a.x +| a.width;
    const a_bottom = a.y +| a.height;
    const b_right = b.x +| b.width;
    const b_bottom = b.y +| b.height;

    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a_right, b_right);
    const bottom = @min(a_bottom, b_bottom);

    if (x >= right or y >= bottom) return null;

    return .{
        .x = x,
        .y = y,
        .width = right - x,
        .height = bottom - y,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "root plane creation and destruction" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    try std.testing.expectEqual(@as(i32, 0), root.x);
    try std.testing.expectEqual(@as(i32, 0), root.y);
    try std.testing.expectEqual(@as(u16, 80), root.width);
    try std.testing.expectEqual(@as(u16, 24), root.height);
    try std.testing.expect(root.visible);
    try std.testing.expect(root.parent == null);
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "child plane creation" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 40, .height = 10 });
    // child will be cleaned up by root.deinit()

    try std.testing.expectEqual(@as(i32, 10), child.x);
    try std.testing.expectEqual(@as(i32, 5), child.y);
    try std.testing.expectEqual(@as(u16, 40), child.width);
    try std.testing.expectEqual(@as(u16, 10), child.height);
    try std.testing.expect(child.parent == root);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expect(root.children.items[0] == child);
}

test "multiple children z-order" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child1 = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 10 });
    const child2 = try Plane.initChild(root, 5, 5, .{ .width = 10, .height = 10 });
    const child3 = try Plane.initChild(root, 10, 10, .{ .width = 10, .height = 10 });

    // Children added in order: child1 (bottom), child2, child3 (top)
    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
    try std.testing.expect(root.children.items[0] == child1);
    try std.testing.expect(root.children.items[1] == child2);
    try std.testing.expect(root.children.items[2] == child3);

    // Check z-index
    try std.testing.expectEqual(@as(?usize, 0), child1.zIndex());
    try std.testing.expectEqual(@as(?usize, 1), child2.zIndex());
    try std.testing.expectEqual(@as(?usize, 2), child3.zIndex());
}

test "raise and lower" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child1 = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 10 });
    const child2 = try Plane.initChild(root, 5, 5, .{ .width = 10, .height = 10 });
    const child3 = try Plane.initChild(root, 10, 10, .{ .width = 10, .height = 10 });

    // Raise child1 to top
    child1.raise();
    try std.testing.expect(root.children.items[2] == child1);
    try std.testing.expect(root.children.items[0] == child2);
    try std.testing.expect(root.children.items[1] == child3);

    // Lower child1 to bottom
    child1.lower();
    try std.testing.expect(root.children.items[0] == child1);
    try std.testing.expect(root.children.items[1] == child2);
    try std.testing.expect(root.children.items[2] == child3);
}

test "raiseAbove and lowerBelow" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child1 = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 10 });
    const child2 = try Plane.initChild(root, 5, 5, .{ .width = 10, .height = 10 });
    const child3 = try Plane.initChild(root, 10, 10, .{ .width = 10, .height = 10 });

    // Move child1 above child2 (order: child2, child1, child3)
    child1.raiseAbove(child2);
    try std.testing.expect(root.children.items[0] == child2);
    try std.testing.expect(root.children.items[1] == child1);
    try std.testing.expect(root.children.items[2] == child3);

    // Move child3 below child1 (order: child2, child3, child1)
    child3.lowerBelow(child1);
    try std.testing.expect(root.children.items[0] == child2);
    try std.testing.expect(root.children.items[1] == child3);
    try std.testing.expect(root.children.items[2] == child1);
}

test "visibility" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 40, .height = 10 });
    const grandchild = try Plane.initChild(child, 5, 5, .{ .width = 20, .height = 5 });

    // All visible by default
    try std.testing.expect(root.isVisible());
    try std.testing.expect(child.isVisible());
    try std.testing.expect(grandchild.isVisible());

    // Hide child - grandchild should also be effectively invisible
    child.setVisible(false);
    try std.testing.expect(root.isVisible());
    try std.testing.expect(!child.isVisible());
    try std.testing.expect(!grandchild.isVisible());

    // Show child again
    child.setVisible(true);
    try std.testing.expect(grandchild.isVisible());

    // Hide root - all should be invisible
    root.setVisible(false);
    try std.testing.expect(!root.isVisible());
    try std.testing.expect(!child.isVisible());
    try std.testing.expect(!grandchild.isVisible());
}

test "move and resize" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 40, .height = 10 });

    // Move
    child.move(20, 15);
    try std.testing.expectEqual(@as(i32, 20), child.x);
    try std.testing.expectEqual(@as(i32, 15), child.y);

    // Resize
    try child.resize(.{ .width = 30, .height = 8 });
    try std.testing.expectEqual(@as(u16, 30), child.width);
    try std.testing.expectEqual(@as(u16, 8), child.height);
}

test "coordinate translation" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 40, .height = 10 });
    const grandchild = try Plane.initChild(child, 5, 3, .{ .width = 20, .height = 5 });

    // Local to screen
    const screen = grandchild.localToScreen(2, 2);
    // grandchild at (5,3) relative to child, child at (10,5) relative to root
    // so grandchild origin is at screen (15, 8), and local (2,2) -> screen (17, 10)
    try std.testing.expectEqual(@as(u16, 17), screen.x);
    try std.testing.expectEqual(@as(u16, 10), screen.y);

    // Screen to local
    const local = grandchild.screenToLocal(17, 10);
    try std.testing.expectEqual(@as(i32, 2), local.x);
    try std.testing.expectEqual(@as(i32, 2), local.y);
}

test "clipping to parent bounds" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    // Child partially outside root bounds
    const child = try Plane.initChild(root, 30, 15, .{ .width = 20, .height = 10 });

    // Full bounds would be (30,15) to (50,25), but root is only 40x20
    const clipped = child.getClippedBounds();
    try std.testing.expect(clipped != null);
    try std.testing.expectEqual(@as(u16, 30), clipped.?.x);
    try std.testing.expectEqual(@as(u16, 15), clipped.?.y);
    try std.testing.expectEqual(@as(u16, 10), clipped.?.width); // 40 - 30 = 10
    try std.testing.expectEqual(@as(u16, 5), clipped.?.height); // 20 - 15 = 5
}

test "completely clipped plane" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    // Child completely outside root bounds
    const child = try Plane.initChild(root, 50, 30, .{ .width = 10, .height = 10 });

    const clipped = child.getClippedBounds();
    try std.testing.expect(clipped == null);
}

test "negative position clipping" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    // Child with negative position (partially outside top-left)
    const child = try Plane.initChild(root, -5, -3, .{ .width = 20, .height = 10 });

    const clipped = child.getClippedBounds();
    try std.testing.expect(clipped != null);
    try std.testing.expectEqual(@as(u16, 0), clipped.?.x);
    try std.testing.expectEqual(@as(u16, 0), clipped.?.y);
    try std.testing.expectEqual(@as(u16, 15), clipped.?.width); // 20 - 5 = 15
    try std.testing.expectEqual(@as(u16, 7), clipped.?.height); // 10 - 3 = 7
}

test "containsScreen and containsLocal" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 20, .height = 10 });

    // containsScreen: child spans (10,5) to (30,15)
    try std.testing.expect(child.containsScreen(10, 5)); // top-left corner
    try std.testing.expect(child.containsScreen(29, 14)); // bottom-right (exclusive)
    try std.testing.expect(!child.containsScreen(30, 15)); // just outside
    try std.testing.expect(!child.containsScreen(9, 5)); // just outside left
    try std.testing.expect(!child.containsScreen(10, 4)); // just outside top

    // containsLocal
    try std.testing.expect(child.containsLocal(0, 0));
    try std.testing.expect(child.containsLocal(19, 9));
    try std.testing.expect(!child.containsLocal(20, 10));
    try std.testing.expect(!child.containsLocal(-1, 0));
}

test "cell operations" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const cell = Cell{
        .char = 'X',
        .combining = .{ 0, 0 },
        .fg = Color.red,
        .bg = Color.blue,
        .attrs = .{ .bold = true },
    };

    root.setCell(5, 3, cell);
    const got = root.getCell(5, 3);
    try std.testing.expect(got.eql(cell));

    // Out of bounds
    root.setCell(100, 100, cell);
    const default_cell = root.getCell(100, 100);
    try std.testing.expect(default_cell.eql(Cell.default));
}

test "print text" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    root.print(2, 1, "Hello", Color.white, Color.black, .{});

    try std.testing.expectEqual(@as(u21, 'H'), root.getCell(2, 1).char);
    try std.testing.expectEqual(@as(u21, 'e'), root.getCell(3, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), root.getCell(4, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), root.getCell(5, 1).char);
    try std.testing.expectEqual(@as(u21, 'o'), root.getCell(6, 1).char);
}

test "clear and fill" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    const fill_cell = Cell{
        .char = '#',
        .combining = .{ 0, 0 },
        .fg = Color.green,
        .bg = .default,
        .attrs = .{},
    };

    root.fill(.{ .x = 2, .y = 1, .width = 3, .height = 2 }, fill_cell);
    try std.testing.expect(root.getCell(2, 1).eql(fill_cell));
    try std.testing.expect(root.getCell(4, 2).eql(fill_cell));
    try std.testing.expect(root.getCell(1, 1).eql(Cell.default));

    root.clear();
    try std.testing.expect(root.getCell(2, 1).eql(Cell.default));
}

test "collectVisible" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child1 = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 10 });
    const child2 = try Plane.initChild(root, 10, 0, .{ .width = 10, .height = 10 });
    child2.setVisible(false);
    const child3 = try Plane.initChild(root, 20, 0, .{ .width = 10, .height = 10 });

    var visible = try root.collectVisible(allocator);
    defer visible.deinit(allocator);

    // Should have root, child1, child3 (child2 is hidden)
    try std.testing.expectEqual(@as(usize, 3), visible.items.len);
    try std.testing.expect(visible.items[0] == root);
    try std.testing.expect(visible.items[1] == child1);
    try std.testing.expect(visible.items[2] == child3);
}

test "nested children z-order in collectVisible" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 0, 0, .{ .width = 40, .height = 20 });
    const grandchild1 = try Plane.initChild(child, 0, 0, .{ .width = 10, .height = 10 });
    const grandchild2 = try Plane.initChild(child, 10, 0, .{ .width = 10, .height = 10 });

    var visible = try root.collectVisible(allocator);
    defer visible.deinit(allocator);

    // Order should be: root, child, grandchild1, grandchild2 (back to front)
    try std.testing.expectEqual(@as(usize, 4), visible.items.len);
    try std.testing.expect(visible.items[0] == root);
    try std.testing.expect(visible.items[1] == child);
    try std.testing.expect(visible.items[2] == grandchild1);
    try std.testing.expect(visible.items[3] == grandchild2);
}

test "child removal on deinit" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child1 = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 10 });
    _ = try Plane.initChild(root, 10, 0, .{ .width = 10, .height = 10 });

    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);

    // Manually deinit child1 - it should remove itself from root
    child1.deinit();

    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "clipRect helper" {
    // Full overlap
    const r1 = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const r2 = Rect{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const clipped = clipRect(r1, r2);
    try std.testing.expect(clipped != null);
    try std.testing.expectEqual(@as(u16, 5), clipped.?.x);
    try std.testing.expectEqual(@as(u16, 5), clipped.?.y);
    try std.testing.expectEqual(@as(u16, 5), clipped.?.width);
    try std.testing.expectEqual(@as(u16, 5), clipped.?.height);

    // No overlap
    const r3 = Rect{ .x = 0, .y = 0, .width = 5, .height = 5 };
    const r4 = Rect{ .x = 10, .y = 10, .width = 5, .height = 5 };
    try std.testing.expect(clipRect(r3, r4) == null);
}

test "getClippedBounds returns null for hidden planes" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 20, .height = 10 });

    // Visible plane should return bounds
    try std.testing.expect(child.getClippedBounds() != null);

    // Hidden plane should return null
    child.setVisible(false);
    try std.testing.expect(child.getClippedBounds() == null);

    // Hidden parent makes child effectively invisible
    child.setVisible(true);
    root.setVisible(false);
    try std.testing.expect(child.getClippedBounds() == null);
}

test "containsScreen returns false for hidden planes" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 20, .height = 10 });

    // Visible plane should contain screen coords
    try std.testing.expect(child.containsScreen(15, 8));

    // Hidden plane should not contain any coords
    child.setVisible(false);
    try std.testing.expect(!child.containsScreen(15, 8));

    // Hidden parent makes child effectively not contain coords
    child.setVisible(true);
    root.setVisible(false);
    try std.testing.expect(!child.containsScreen(15, 8));
}

test "collectVisible from hidden subtree returns empty" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 0, 0, .{ .width = 40, .height = 20 });
    _ = try Plane.initChild(child, 0, 0, .{ .width = 10, .height = 10 });
    _ = try Plane.initChild(child, 10, 0, .{ .width = 10, .height = 10 });

    // Collecting from visible child should include it and its children
    var visible1 = try child.collectVisible(allocator);
    defer visible1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), visible1.items.len);

    // Collecting from child when root is hidden should return empty
    root.setVisible(false);
    var visible2 = try child.collectVisible(allocator);
    defer visible2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), visible2.items.len);
}

test "localToScreenSigned preserves negative coordinates" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, -10, -5, .{ .width = 20, .height = 10 });

    // Signed version preserves negative
    const signed = child.localToScreenSigned(0, 0);
    try std.testing.expectEqual(@as(i32, -10), signed.x);
    try std.testing.expectEqual(@as(i32, -5), signed.y);

    // Unsigned version clamps to 0
    const unsigned = child.localToScreen(0, 0);
    try std.testing.expectEqual(@as(u16, 0), unsigned.x);
    try std.testing.expectEqual(@as(u16, 0), unsigned.y);
}

// ============================================================================
// Dirty tracking tests
// ============================================================================

test "setCell marks plane dirty" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    // Initially not dirty
    try std.testing.expect(!root.isDirty());

    // Set a cell
    root.setCell(5, 3, Cell{ .char = 'X', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Now dirty
    try std.testing.expect(root.isDirty());

    // Dirty rect should be exactly the cell
    const dirty = root.dirty_rect.?;
    try std.testing.expectEqual(@as(u16, 5), dirty.x);
    try std.testing.expectEqual(@as(u16, 3), dirty.y);
    try std.testing.expectEqual(@as(u16, 1), dirty.width);
    try std.testing.expectEqual(@as(u16, 1), dirty.height);
}

test "print marks region dirty" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    root.print(10, 5, "Hello", Color.white, Color.black, .{});

    try std.testing.expect(root.isDirty());

    const dirty = root.dirty_rect.?;
    try std.testing.expectEqual(@as(u16, 10), dirty.x);
    try std.testing.expectEqual(@as(u16, 5), dirty.y);
    try std.testing.expectEqual(@as(u16, 5), dirty.width); // "Hello" is 5 chars
    try std.testing.expectEqual(@as(u16, 1), dirty.height);
}

test "fill marks region dirty" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const fill_cell = Cell{ .char = '#', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} };
    root.fill(.{ .x = 5, .y = 3, .width = 10, .height = 4 }, fill_cell);

    try std.testing.expect(root.isDirty());

    const dirty = root.dirty_rect.?;
    try std.testing.expectEqual(@as(u16, 5), dirty.x);
    try std.testing.expectEqual(@as(u16, 3), dirty.y);
    try std.testing.expectEqual(@as(u16, 10), dirty.width);
    try std.testing.expectEqual(@as(u16, 4), dirty.height);
}

test "clear marks entire plane dirty" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    root.clear();

    try std.testing.expect(root.isDirty());

    const dirty = root.dirty_rect.?;
    try std.testing.expectEqual(@as(u16, 0), dirty.x);
    try std.testing.expectEqual(@as(u16, 0), dirty.y);
    try std.testing.expectEqual(@as(u16, 40), dirty.width);
    try std.testing.expectEqual(@as(u16, 20), dirty.height);
}

test "resize marks plane dirty and invalidates parent" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    const child = try Plane.initChild(root, 3, 2, .{ .width = 6, .height = 4 });

    try std.testing.expect(!root.isDirty());
    try std.testing.expect(!child.isDirty());

    try child.resize(.{ .width = 4, .height = 3 });

    try std.testing.expect(child.isDirty());
    const child_dirty = child.dirty_rect.?;
    try std.testing.expectEqual(@as(u16, 0), child_dirty.x);
    try std.testing.expectEqual(@as(u16, 0), child_dirty.y);
    try std.testing.expectEqual(@as(u16, 4), child_dirty.width);
    try std.testing.expectEqual(@as(u16, 3), child_dirty.height);

    try std.testing.expect(root.isDirty());
    const root_dirty = root.dirty_rect.?;
    try std.testing.expectEqual(@as(u16, 3), root_dirty.x);
    try std.testing.expectEqual(@as(u16, 2), root_dirty.y);
    try std.testing.expectEqual(@as(u16, 6), root_dirty.width);
    try std.testing.expectEqual(@as(u16, 4), root_dirty.height);
}

test "multiple operations expand dirty region" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    // Set two cells at opposite corners
    root.setCell(5, 3, Cell{ .char = 'A', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    root.setCell(20, 10, Cell{ .char = 'B', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Dirty region should be the bounding box
    const dirty = root.dirty_rect.?;
    try std.testing.expectEqual(@as(u16, 5), dirty.x);
    try std.testing.expectEqual(@as(u16, 3), dirty.y);
    try std.testing.expectEqual(@as(u16, 16), dirty.width); // 20 - 5 + 1 = 16
    try std.testing.expectEqual(@as(u16, 8), dirty.height); // 10 - 3 + 1 = 8
}

test "takeDirtyRect clears dirty flag" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    root.setCell(5, 3, Cell{ .char = 'X', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    try std.testing.expect(root.isDirty());

    // Take the dirty rect
    const dirty = root.takeDirtyRect();
    try std.testing.expect(dirty != null);
    try std.testing.expectEqual(@as(u16, 5), dirty.?.x);

    // Now clean
    try std.testing.expect(!root.isDirty());
    try std.testing.expect(root.takeDirtyRect() == null);
}

test "getDirtyScreenRect converts to screen coordinates" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 30, .height = 15 });

    // Draw at local (3, 2)
    child.setCell(3, 2, Cell{ .char = 'X', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Screen position should be (13, 7) = (10+3, 5+2)
    const screen_dirty = child.getDirtyScreenRect();
    try std.testing.expect(screen_dirty != null);
    try std.testing.expectEqual(@as(u16, 13), screen_dirty.?.x);
    try std.testing.expectEqual(@as(u16, 7), screen_dirty.?.y);
    try std.testing.expectEqual(@as(u16, 1), screen_dirty.?.width);
    try std.testing.expectEqual(@as(u16, 1), screen_dirty.?.height);
}

test "getDirtyScreenRect clips to visible bounds" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // Child extends beyond root bounds
    const child = try Plane.initChild(root, 15, 5, .{ .width = 20, .height = 10 });

    // Fill entire child (will extend beyond root)
    child.clear();

    // Screen dirty should be clipped to visible area
    const screen_dirty = child.getDirtyScreenRect();
    try std.testing.expect(screen_dirty != null);
    try std.testing.expectEqual(@as(u16, 15), screen_dirty.?.x);
    try std.testing.expectEqual(@as(u16, 5), screen_dirty.?.y);
    try std.testing.expectEqual(@as(u16, 5), screen_dirty.?.width); // 20 - 15 = 5
    try std.testing.expectEqual(@as(u16, 5), screen_dirty.?.height); // 10 - 5 = 5
}

test "getDirtyScreenRect returns null for hidden plane" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const child = try Plane.initChild(root, 10, 5, .{ .width = 30, .height = 15 });
    child.setCell(3, 2, Cell{ .char = 'X', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Should return valid rect while visible
    try std.testing.expect(child.getDirtyScreenRect() != null);

    // Hide and check again
    child.setVisible(false);
    try std.testing.expect(child.getDirtyScreenRect() == null);
}

test "out of bounds setCell does not mark dirty" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    // Try to set cell outside bounds
    root.setCell(100, 100, Cell{ .char = 'X', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Should not be dirty
    try std.testing.expect(!root.isDirty());
}

test "markAllDirty marks entire plane" {
    const allocator = std.testing.allocator;

    const root = try Plane.initRoot(allocator, .{ .width = 50, .height = 30 });
    defer root.deinit();

    root.markAllDirty();

    try std.testing.expect(root.isDirty());
    const dirty = root.dirty_rect.?;
    try std.testing.expectEqual(@as(u16, 0), dirty.x);
    try std.testing.expectEqual(@as(u16, 0), dirty.y);
    try std.testing.expectEqual(@as(u16, 50), dirty.width);
    try std.testing.expectEqual(@as(u16, 30), dirty.height);
}
