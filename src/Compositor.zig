const std = @import("std");
const Cell = @import("Cell.zig");
const Buffer = @import("Buffer.zig");
const Plane = @import("Plane.zig").Plane;
const Event = @import("Event.zig");
const Size = Event.Size;
const Rect = Event.Rect;
const unicode = @import("unicode/width.zig");

/// Compositor for merging planes into a target buffer.
///
/// The compositor walks planes in z-order (back to front), applying clipping,
/// and composing cells into the target buffer. Continuation cells (char == 0,
/// the second half of wide characters) are normally copied to preserve wide
/// character integrity, except when clipping would create an orphan.
///
/// Dirty region tracking optimizes rendering by only compositing regions that
/// have changed since the last frame.
///
/// ## Invalidation API
///
/// - `invalidatePlane`: Call when plane content changes. Must be called BEFORE
///   hiding a plane to ensure the region is properly marked dirty.
/// - `invalidatePlaneMove`: Call AFTER moving a plane, passing the old position.
///   This marks both the old and new positions as dirty.
/// - `invalidateRect`: Call to mark an arbitrary screen region as dirty.
pub const Compositor = @This();

/// Target buffer for composition output
target: *Buffer,

/// Allocator for internal state
allocator: std.mem.Allocator,

/// Dirty regions accumulated this frame (in screen coordinates)
dirty_regions: std.ArrayList(Rect),

/// Whether a full redraw is needed (e.g., after resize)
needs_full_redraw: bool,

/// Initialize the compositor with a target buffer.
pub fn init(allocator: std.mem.Allocator, target: *Buffer) Compositor {
    return .{
        .target = target,
        .allocator = allocator,
        .dirty_regions = .empty,
        .needs_full_redraw = true,
    };
}

/// Clean up compositor resources.
pub fn deinit(self: *Compositor) void {
    self.dirty_regions.deinit(self.allocator);
    self.* = undefined;
}

/// Mark the entire screen as dirty (forces full redraw).
pub fn invalidateAll(self: *Compositor) void {
    self.needs_full_redraw = true;
}

/// Mark a specific screen region as dirty.
pub fn invalidateRect(self: *Compositor, rect: Rect) !void {
    // Clip to target buffer bounds
    const clipped = clipToBuffer(rect, self.target) orelse return;
    try self.dirty_regions.append(self.allocator, clipped);
}

/// Mark a plane as dirty (its entire visible area).
/// Call this when plane content changes.
///
/// IMPORTANT: Must be called BEFORE hiding a plane. If called after hiding,
/// `getClippedBounds()` returns null and no region will be invalidated,
/// potentially leaving stale content on screen.
pub fn invalidatePlane(self: *Compositor, plane: *const Plane) !void {
    const bounds = plane.getClippedBounds() orelse return;
    try self.dirty_regions.append(self.allocator, bounds);
}

/// Mark a plane's previous and new position as dirty (for move operations).
/// Call this AFTER moving a plane, passing the plane's old position.
///
/// Example:
/// ```
/// const old_x = plane.x;
/// const old_y = plane.y;
/// plane.move(new_x, new_y);
/// try compositor.invalidatePlaneMove(plane, old_x, old_y);
/// ```
pub fn invalidatePlaneMove(self: *Compositor, plane: *const Plane, old_x: i32, old_y: i32) !void {
    // Invalidate new position (plane has already moved)
    if (plane.getClippedBounds()) |new_bounds| {
        try self.dirty_regions.append(self.allocator, new_bounds);
    }

    // Compute and invalidate old position using the provided old coordinates
    const old_bounds = computePlaneBounds(plane, old_x, old_y);
    if (old_bounds) |bounds| {
        const clipped = clipToBuffer(bounds, self.target) orelse return;
        try self.dirty_regions.append(self.allocator, clipped);
    }
}

/// Compose all visible planes from the root into the target buffer.
/// Returns the list of dirty regions that were composited (for diff renderer).
/// Caller owns the returned slice and must free it with the compositor's allocator.
///
/// Auto dirty-tracking: This function automatically collects dirty regions from
/// all visible planes. Plane drawing operations (setCell, print, fill, clear)
/// automatically mark planes dirty, so explicit invalidatePlane() calls are
/// typically not needed for content changes. However, structural changes (move,
/// visibility changes) still require explicit invalidation.
pub fn compose(self: *Compositor, root: *Plane) ![]const Rect {
    // Collect all dirty regions for this frame
    var frame_dirty: std.ArrayList(Rect) = .empty;
    defer frame_dirty.deinit(self.allocator);

    if (self.needs_full_redraw) {
        // Full screen is dirty
        try frame_dirty.append(self.allocator, .{
            .x = 0,
            .y = 0,
            .width = self.target.width,
            .height = self.target.height,
        });
        self.needs_full_redraw = false;

        // Clear plane dirty flags since we're doing a full redraw
        try self.clearPlaneDirtyFlags(root);
    } else {
        // Collect dirty regions from planes (auto dirty-tracking)
        try self.collectPlaneDirtyRegions(root);

        // Coalesce all dirty regions (manual + auto-collected)
        const coalesced = try coalesceRegions(self.allocator, self.dirty_regions.items);
        defer self.allocator.free(coalesced);
        for (coalesced) |region| {
            try frame_dirty.append(self.allocator, region);
        }
    }

    // Clear dirty tracking for next frame
    self.dirty_regions.clearRetainingCapacity();

    // If no dirty regions, nothing to do - return empty allocated slice
    if (frame_dirty.items.len == 0) {
        return try self.allocator.alloc(Rect, 0);
    }

    // Collect visible planes in z-order
    var visible_planes = try root.collectVisible(self.allocator);
    defer visible_planes.deinit(self.allocator);

    // For each dirty region, composite all planes that intersect
    for (frame_dirty.items) |dirty_rect| {
        try self.compositeRegion(dirty_rect, visible_planes.items);
    }

    // Return dirty regions - caller owns and must free this slice
    const result = try self.allocator.alloc(Rect, frame_dirty.items.len);
    @memcpy(result, frame_dirty.items);
    return result;
}

/// Collect dirty regions from all visible planes and add them to dirty_regions.
/// Also clears the dirty flags on planes after collecting.
fn collectPlaneDirtyRegions(self: *Compositor, root: *Plane) !void {
    try self.collectPlaneDirtyRegionsInner(root);
}

fn collectPlaneDirtyRegionsInner(self: *Compositor, plane: *Plane) !void {
    if (!plane.visible) {
        // Hidden planes don't contribute dirty regions, but we still clear their flags
        _ = plane.takeDirtyRect();
        // Still recurse into children to clear their flags too
        for (plane.children.items) |child| {
            try self.collectPlaneDirtyRegionsInner(child);
        }
        return;
    }

    // Collect dirty region from this plane (converts to screen coords, clips)
    // Note: getDirtyScreenRect reads dirty_rect, so call before takeDirtyRect
    if (plane.getDirtyScreenRect()) |screen_dirty| {
        const clipped = clipToBuffer(screen_dirty, self.target);
        if (clipped) |rect| {
            try self.dirty_regions.append(self.allocator, rect);
        }
    }

    // Clear the plane's dirty flag
    _ = plane.takeDirtyRect();

    // Recurse into children
    for (plane.children.items) |child| {
        try self.collectPlaneDirtyRegionsInner(child);
    }
}

/// Clear dirty flags on all planes without collecting regions (for full redraw).
fn clearPlaneDirtyFlags(self: *Compositor, plane: *Plane) !void {
    _ = plane.takeDirtyRect();
    for (plane.children.items) |child| {
        try self.clearPlaneDirtyFlags(child);
    }
}

/// Composite a single dirty region.
fn compositeRegion(self: *Compositor, dirty_rect: Rect, planes: []*const Plane) !void {
    // First, clear the region to the background (from root plane or default)
    const default_cell = Cell.default;

    var y = dirty_rect.y;
    while (y < dirty_rect.y +| dirty_rect.height) : (y += 1) {
        var x = dirty_rect.x;
        while (x < dirty_rect.x +| dirty_rect.width) : (x += 1) {
            self.target.setCell(x, y, default_cell);
        }
    }

    // Then, composite each plane from back to front
    for (planes) |plane| {
        // Get plane's clipped screen bounds
        const plane_bounds = plane.getClippedBounds() orelse continue;

        // Check if plane intersects dirty region
        const intersection = rectIntersect(dirty_rect, plane_bounds) orelse continue;

        // Composite the intersection
        try self.compositePlaneRegion(plane, intersection, plane_bounds);
    }
}

/// Composite a single plane's cells within the given screen region.
fn compositePlaneRegion(self: *Compositor, plane: *const Plane, region: Rect, plane_bounds: Rect) !void {
    // Convert region to plane-local coordinates
    const local_start = plane.screenToLocal(@intCast(region.x), @intCast(region.y));

    // Handle negative local coordinates (plane extends beyond parent)
    const local_x_start: u16 = if (local_start.x < 0) 0 else @intCast(@min(local_start.x, std.math.maxInt(u16)));
    const local_y_start: u16 = if (local_start.y < 0) 0 else @intCast(@min(local_start.y, std.math.maxInt(u16)));

    // Adjust screen start if we clamped local coords
    var screen_x_start = region.x;
    var screen_y_start = region.y;
    if (local_start.x < 0) {
        screen_x_start +|= @intCast(-local_start.x);
    }
    if (local_start.y < 0) {
        screen_y_start +|= @intCast(-local_start.y);
    }

    // Calculate how many cells to copy
    const width = @min(region.width, plane.width -| local_x_start);
    const height = @min(region.height, plane.height -| local_y_start);

    const bounds_local = plane.screenToLocal(@intCast(plane_bounds.x), @intCast(plane_bounds.y));
    const visible_left: i32 = @max(bounds_local.x, 0);
    const visible_top: i32 = @max(bounds_local.y, 0);
    const visible_right: i32 = visible_left + @as(i32, plane_bounds.width);
    const visible_bottom: i32 = visible_top + @as(i32, plane_bounds.height);

    var dy: u16 = 0;
    while (dy < height) : (dy += 1) {
        var dx: u16 = 0;
        while (dx < width) : (dx += 1) {
            const local_x = local_x_start +| dx;
            const local_y = local_y_start +| dy;
            const screen_x = screen_x_start +| dx;
            const screen_y = screen_y_start +| dy;

            var cell = plane.getCell(local_x, local_y);

            if (cell.isContinuation() and isOrphanContinuation(
                plane,
                local_x,
                local_y,
                visible_left,
                visible_right,
                visible_top,
                visible_bottom,
            )) {
                cell = .{
                    .char = ' ',
                    .combining = .{ 0, 0 },
                    .fg = cell.fg,
                    .bg = cell.bg,
                    .attrs = cell.attrs,
                };
            }

            // Skip transparent cells (default space with default colors)
            if (isTransparent(cell)) continue;

            self.target.setCell(screen_x, screen_y, cell);
        }
    }
}

fn isOrphanContinuation(
    plane: *const Plane,
    local_x: u16,
    local_y: u16,
    visible_left: i32,
    visible_right: i32,
    visible_top: i32,
    visible_bottom: i32,
) bool {
    if (local_x == 0) return true;

    const base_cell = plane.getCell(local_x - 1, local_y);
    if (base_cell.isContinuation() or unicode.codePointWidth(base_cell.char) != 2) {
        return true;
    }

    const base_x = @as(i32, local_x) - 1;
    const base_y = @as(i32, local_y);

    return base_x < visible_left or base_x >= visible_right or
        base_y < visible_top or base_y >= visible_bottom;
}

/// Check if a cell is transparent (should not overwrite underlying content).
///
/// A cell is transparent only if:
/// - It is a space character (not a continuation cell char==0)
/// - It has default foreground AND background colors
/// - It has no text attributes set
/// - It has no combining marks
///
/// Note: This means continuation cells (char == 0, second half of wide chars)
/// are NEVER transparent - they are always copied to preserve wide character
/// integrity. If you want an opaque "blank" region (like a dialog background),
/// set a non-default background color.
fn isTransparent(cell: Cell) bool {
    // Continuation cells (char == 0) are never transparent
    if (cell.char == 0) return false;

    return cell.char == ' ' and
        cell.fg.eql(.default) and
        cell.bg.eql(.default) and
        cell.attrs.eql(.{}) and
        !cell.hasCombining();
}

/// Compute plane bounds at a given position (for move tracking).
fn computePlaneBounds(plane: *const Plane, plane_x: i32, plane_y: i32) ?Rect {
    if (!plane.isVisible()) return null;

    // Compute screen position
    var screen_x: i32 = plane_x;
    var screen_y: i32 = plane_y;
    var current = plane.parent;
    while (current) |p| {
        screen_x += p.x;
        screen_y += p.y;
        current = p.parent;
    }

    // Compute bounds
    var left: i32 = screen_x;
    var top: i32 = screen_y;
    var right: i32 = screen_x + @as(i32, plane.width);
    var bottom: i32 = screen_y + @as(i32, plane.height);

    // Clip to ancestors
    current = plane.parent;
    while (current) |p| {
        var parent_screen_x: i32 = p.x;
        var parent_screen_y: i32 = p.y;
        var pp = p.parent;
        while (pp) |gp| {
            parent_screen_x += gp.x;
            parent_screen_y += gp.y;
            pp = gp.parent;
        }

        left = @max(left, parent_screen_x);
        top = @max(top, parent_screen_y);
        right = @min(right, parent_screen_x + @as(i32, p.width));
        bottom = @min(bottom, parent_screen_y + @as(i32, p.height));

        if (left >= right or top >= bottom) return null;
        current = p.parent;
    }

    // Clip to screen (non-negative)
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

/// Clip a rectangle to buffer bounds.
fn clipToBuffer(rect: Rect, buf: *const Buffer) ?Rect {
    if (rect.x >= buf.width or rect.y >= buf.height) return null;

    const x = rect.x;
    const y = rect.y;
    const width = @min(rect.width, buf.width -| rect.x);
    const height = @min(rect.height, buf.height -| rect.y);

    if (width == 0 or height == 0) return null;

    return .{ .x = x, .y = y, .width = width, .height = height };
}

/// Compute intersection of two rectangles.
fn rectIntersect(a: Rect, b: Rect) ?Rect {
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

/// Coalesce overlapping/adjacent dirty regions to reduce overdraw.
/// Returns a newly allocated slice (caller must free).
fn coalesceRegions(allocator: std.mem.Allocator, regions: []const Rect) ![]Rect {
    if (regions.len == 0) {
        return allocator.alloc(Rect, 0);
    }

    if (regions.len == 1) {
        const result = try allocator.alloc(Rect, 1);
        result[0] = regions[0];
        return result;
    }

    // Simple coalescing: merge overlapping rectangles
    // For MVP, we use a simple approach - merge into bounding box if overlap
    var result: std.ArrayList(Rect) = .empty;
    defer result.deinit(allocator);

    for (regions) |region| {
        var merged = false;
        for (result.items) |*existing| {
            if (rectsOverlapOrAdjacent(existing.*, region)) {
                // Merge into bounding box
                existing.* = boundingBox(existing.*, region);
                merged = true;
                break;
            }
        }
        if (!merged) {
            try result.append(allocator, region);
        }
    }

    // Second pass: merge any newly adjacent regions
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < result.items.len) {
            var j = i + 1;
            while (j < result.items.len) {
                if (rectsOverlapOrAdjacent(result.items[i], result.items[j])) {
                    result.items[i] = boundingBox(result.items[i], result.items[j]);
                    _ = result.orderedRemove(j);
                    changed = true;
                } else {
                    j += 1;
                }
            }
            i += 1;
        }
    }

    const final = try allocator.alloc(Rect, result.items.len);
    @memcpy(final, result.items);
    return final;
}

/// Check if two rectangles overlap or are adjacent.
fn rectsOverlapOrAdjacent(a: Rect, b: Rect) bool {
    // Extend each rect by 1 in all directions to detect adjacency
    const a_left = if (a.x > 0) a.x - 1 else a.x;
    const a_top = if (a.y > 0) a.y - 1 else a.y;
    const a_right = a.x +| a.width +| 1;
    const a_bottom = a.y +| a.height +| 1;

    const b_left = if (b.x > 0) b.x - 1 else b.x;
    const b_top = if (b.y > 0) b.y - 1 else b.y;
    const b_right = b.x +| b.width +| 1;
    const b_bottom = b.y +| b.height +| 1;

    return !(a_right < b_left or b_right < a_left or a_bottom < b_top or b_bottom < a_top);
}

/// Compute bounding box of two rectangles.
fn boundingBox(a: Rect, b: Rect) Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(a.x +| a.width, b.x +| b.width);
    const bottom = @max(a.y +| a.height, b.y +| b.height);

    return .{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Compositor init and deinit" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 80, .height = 24 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    try std.testing.expect(compositor.needs_full_redraw);
}

test "Compositor compose single plane" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    // Create root plane and draw something
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    root.print(0, 0, "Hello", Cell.Color.white, Cell.Color.black, .{});

    // Compose
    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Check that target buffer has the content
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'e'), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'l'), buf.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'l'), buf.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), buf.getCell(4, 0).char);
}

test "Compositor compose with child planes z-order" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    // Create root with two overlapping children
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    const child1 = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 5 });
    const child2 = try Plane.initChild(root, 2, 0, .{ .width = 10, .height = 5 });

    // child1 draws 'A', child2 draws 'B' at overlapping position
    child1.print(2, 0, "AAAA", Cell.Color.red, Cell.Color.black, .{});
    child2.print(0, 0, "BBBB", Cell.Color.blue, Cell.Color.black, .{});

    // Compose - child2 is on top (added last)
    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Position 2 should have 'B' (from child2 which is on top)
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(3, 0).char);
}

test "Compositor transparency" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    // Create root with child
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // Draw on root
    root.print(0, 0, "ROOT", Cell.Color.white, Cell.Color.black, .{});

    // Create child that overlaps but only draws at position 1
    const child = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 5 });
    child.print(1, 0, "X", Cell.Color.green, Cell.Color.black, .{});

    // Compose
    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Position 0 should have 'R' from root (child has transparent there)
    try std.testing.expectEqual(@as(u21, 'R'), buf.getCell(0, 0).char);
    // Position 1 should have 'X' from child
    try std.testing.expectEqual(@as(u21, 'X'), buf.getCell(1, 0).char);
}

test "Compositor hidden planes are skipped" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    root.print(0, 0, "ROOT", Cell.Color.white, Cell.Color.black, .{});

    const child = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 5 });
    child.print(0, 0, "CHILD", Cell.Color.green, Cell.Color.black, .{});
    child.setVisible(false);

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Should see ROOT, not CHILD
    try std.testing.expectEqual(@as(u21, 'R'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'O'), buf.getCell(1, 0).char);
}

test "Compositor clipping" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    // Child extends beyond root bounds
    const child = try Plane.initChild(root, 8, 3, .{ .width = 10, .height = 10 });
    child.print(0, 0, "ABCDEFGHIJ", Cell.Color.white, Cell.Color.black, .{});

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Only 'A' and 'B' should be visible (positions 8,3 and 9,3)
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(8, 3).char);
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(9, 3).char);
}

test "Compositor skips orphan continuation when base clipped" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 3, .height = 1 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 3, .height = 1 });
    defer root.deinit();
    root.print(0, 0, "RRR", .default, .default, .{});

    const child = try Plane.initChild(root, -1, 0, .{ .width = 2, .height = 1 });
    child.print(0, 0, "中", .default, .default, .{});

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    try std.testing.expectEqual(@as(u21, 'R'), buf.getCell(0, 0).char);
}

test "Compositor preserves continuation when base is visible" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 3, .height = 1 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 3, .height = 1 });
    defer root.deinit();

    const child = try Plane.initChild(root, 0, 0, .{ .width = 2, .height = 1 });
    child.print(0, 0, "中", .default, .default, .{});

    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    try compositor.invalidateRect(.{ .x = 1, .y = 0, .width = 1, .height = 1 });
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    try std.testing.expect(buf.getCell(1, 0).isContinuation());
}

test "Compositor dirty region tracking" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // First compose - full redraw
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);
    try std.testing.expectEqual(@as(usize, 1), dirty1.len);
    try std.testing.expectEqual(@as(u16, 0), dirty1[0].x);
    try std.testing.expectEqual(@as(u16, 20), dirty1[0].width);

    // No changes - should have no dirty regions
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);
    try std.testing.expectEqual(@as(usize, 0), dirty2.len);

    // Invalidate a region
    try compositor.invalidateRect(.{ .x = 5, .y = 3, .width = 4, .height = 2 });
    const dirty3 = try compositor.compose(root);
    defer allocator.free(dirty3);
    try std.testing.expectEqual(@as(usize, 1), dirty3.len);
    try std.testing.expectEqual(@as(u16, 5), dirty3[0].x);
    try std.testing.expectEqual(@as(u16, 3), dirty3[0].y);
}

test "rectIntersect" {
    // Overlapping
    const a = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = Rect{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const intersection = rectIntersect(a, b);
    try std.testing.expect(intersection != null);
    try std.testing.expectEqual(@as(u16, 5), intersection.?.x);
    try std.testing.expectEqual(@as(u16, 5), intersection.?.y);
    try std.testing.expectEqual(@as(u16, 5), intersection.?.width);
    try std.testing.expectEqual(@as(u16, 5), intersection.?.height);

    // Non-overlapping
    const c = Rect{ .x = 0, .y = 0, .width = 5, .height = 5 };
    const d = Rect{ .x = 10, .y = 10, .width = 5, .height = 5 };
    try std.testing.expect(rectIntersect(c, d) == null);
}

test "coalesceRegions merges overlapping" {
    const allocator = std.testing.allocator;

    const regions = [_]Rect{
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .{ .x = 5, .y = 5, .width = 10, .height = 10 },
    };

    const coalesced = try coalesceRegions(allocator, &regions);
    defer allocator.free(coalesced);

    // Should merge into one bounding box
    try std.testing.expectEqual(@as(usize, 1), coalesced.len);
    try std.testing.expectEqual(@as(u16, 0), coalesced[0].x);
    try std.testing.expectEqual(@as(u16, 0), coalesced[0].y);
    try std.testing.expectEqual(@as(u16, 15), coalesced[0].width);
    try std.testing.expectEqual(@as(u16, 15), coalesced[0].height);
}

test "coalesceRegions keeps separate" {
    const allocator = std.testing.allocator;

    const regions = [_]Rect{
        .{ .x = 0, .y = 0, .width = 5, .height = 5 },
        .{ .x = 20, .y = 20, .width = 5, .height = 5 },
    };

    const coalesced = try coalesceRegions(allocator, &regions);
    defer allocator.free(coalesced);

    // Should remain separate (not adjacent or overlapping)
    try std.testing.expectEqual(@as(usize, 2), coalesced.len);
}

test "Compositor plane move invalidates both regions" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    const child = try Plane.initChild(root, 5, 5, .{ .width = 10, .height = 5 });
    child.print(0, 0, "TEST", Cell.Color.white, Cell.Color.black, .{});

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Record old position before move
    const old_x = child.x;
    const old_y = child.y;

    // Move the child
    child.move(20, 10);

    // Invalidate move (both old and new positions)
    try compositor.invalidatePlaneMove(child, old_x, old_y);

    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Should have dirty regions (at least covering old and new positions)
    try std.testing.expect(dirty2.len > 0);

    // Check that content moved in the buffer
    try std.testing.expectEqual(@as(u21, 'T'), buf.getCell(20, 10).char);
    try std.testing.expectEqual(@as(u21, 'E'), buf.getCell(21, 10).char);
}

test "Compositor plane resize invalidates region" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    const child = try Plane.initChild(root, 5, 5, .{ .width = 10, .height = 5 });
    child.print(0, 0, "RESIZE", Cell.Color.white, Cell.Color.black, .{});

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Invalidate the plane before resize
    try compositor.invalidatePlane(child);

    // Resize (this clears buffer)
    try child.resize(.{ .width = 20, .height = 10 });

    // Invalidate again after resize
    try compositor.invalidatePlane(child);

    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Should have dirty regions
    try std.testing.expect(dirty2.len > 0);
}

test "Compositor visibility change invalidates region" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    const child = try Plane.initChild(root, 5, 5, .{ .width = 10, .height = 5 });
    child.print(0, 0, "HIDDEN", Cell.Color.white, Cell.Color.black, .{});

    // First compose with child visible
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(5, 5).char);

    // Invalidate and hide
    try compositor.invalidatePlane(child);
    child.setVisible(false);

    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Child should no longer be visible - expect default cell (space)
    try std.testing.expectEqual(@as(u21, ' '), buf.getCell(5, 5).char);
}

test "isTransparent" {
    // Default cell is transparent
    try std.testing.expect(isTransparent(Cell.default));

    // Cell with character is not transparent
    const char_cell = Cell{
        .char = 'A',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    try std.testing.expect(!isTransparent(char_cell));

    // Cell with background color is not transparent
    const bg_cell = Cell{
        .char = ' ',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = Cell.Color.blue,
        .attrs = .{},
    };
    try std.testing.expect(!isTransparent(bg_cell));

    // Cell with attributes is not transparent
    const attr_cell = Cell{
        .char = ' ',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{ .reverse = true },
    };
    try std.testing.expect(!isTransparent(attr_cell));

    // Continuation cells (char == 0) are NEVER transparent (wide char integrity)
    const continuation_cell = Cell{
        .char = 0,
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    try std.testing.expect(!isTransparent(continuation_cell));
}

// ============================================================================
// Auto dirty-tracking tests
// ============================================================================

test "Compositor auto collects dirty regions from planes" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    // First compose - full redraw
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Plane dirty should be cleared after compose
    try std.testing.expect(!root.isDirty());

    // Now draw something (no explicit invalidatePlane needed!)
    root.print(5, 3, "Hello", Cell.Color.white, Cell.Color.black, .{});

    // Compose should automatically pick up the dirty region
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Should have dirty region
    try std.testing.expect(dirty2.len > 0);

    // Check that content is in buffer
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(5, 3).char);
    try std.testing.expectEqual(@as(u21, 'e'), buf.getCell(6, 3).char);
}

test "Compositor auto collects dirty from child planes" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Create child and draw on it
    const child = try Plane.initChild(root, 10, 5, .{ .width = 15, .height = 8 });
    child.print(0, 0, "Child", Cell.Color.green, Cell.Color.black, .{});

    // Compose should auto-collect child's dirty region
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    try std.testing.expect(dirty2.len > 0);

    // Child content should be in buffer at screen position (10, 5)
    try std.testing.expectEqual(@as(u21, 'C'), buf.getCell(10, 5).char);
    try std.testing.expectEqual(@as(u21, 'h'), buf.getCell(11, 5).char);
}

test "Compositor clears plane dirty flags after compose" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    const child = try Plane.initChild(root, 5, 5, .{ .width = 10, .height = 5 });

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Draw on both planes
    root.setCell(0, 0, Cell{ .char = 'R', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    child.setCell(0, 0, Cell{ .char = 'C', .combining = .{ 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    try std.testing.expect(root.isDirty());
    try std.testing.expect(child.isDirty());

    // Compose
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Both should be clean now
    try std.testing.expect(!root.isDirty());
    try std.testing.expect(!child.isDirty());
}

test "Compositor full redraw clears plane dirty flags" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    // Draw something to make plane dirty
    root.print(0, 0, "Test", Cell.Color.white, Cell.Color.black, .{});
    try std.testing.expect(root.isDirty());

    // Force full redraw
    compositor.invalidateAll();

    // Compose
    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Full redraw should have cleared the plane's dirty flag
    try std.testing.expect(!root.isDirty());
}

test "Compositor hidden plane dirty ignored" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer buf.deinit();

    var compositor = Compositor.init(allocator, &buf);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Create hidden child and draw on it
    const child = try Plane.initChild(root, 10, 5, .{ .width = 15, .height = 8 });
    child.setVisible(false);
    child.print(0, 0, "Hidden", Cell.Color.red, Cell.Color.black, .{});

    // Compose - hidden plane's dirty region should not be collected
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // No dirty regions since hidden plane doesn't contribute
    try std.testing.expectEqual(@as(usize, 0), dirty2.len);

    // Child's dirty flag should still be cleared
    try std.testing.expect(!child.isDirty());
}
