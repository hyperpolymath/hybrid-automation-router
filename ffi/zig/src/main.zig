// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// main.zig — C-compatible FFI for the Hybrid Automation Router.
//
// Implements proven-fsm and proven-queueconn interfaces adapted for HAR's
// routing context.  Provides slot-based lifecycle management with
// mutex-protected global state.
//
// Exports:
//   Router lifecycle:  har_router_create, har_router_destroy,
//                      har_router_state, har_router_start,
//                      har_router_shutdown
//   Event dispatch:    har_dispatch_event
//   Target management: har_target_connect, har_target_disconnect,
//                      har_target_state
//   Introspection:     har_abi_version, har_last_error, har_version
//
// Tag values MUST match:
//   - Idris2 ABI (src/abi/ProvenFSM.idr, src/abi/ProvenQueue.idr)
//   - proven-servers (core/proven-fsm, connectors/proven-queueconn)

const std = @import("std");

// ── proven-fsm types (tag values match proven-servers exactly) ────────────

/// MachineState — maps to RouterState in ProvenFSM.idr.
///   Initial=0 (Configuring), Running=1 (Routing),
///   Terminal=2 (Shutdown), Faulted=3 (Failed)
pub const MachineState = enum(u8) {
    initial = 0,
    running = 1,
    terminal = 2,
    faulted = 3,
};

/// TransitionResult — outcome of a lifecycle transition.
///   Accepted=0, Rejected=1, Deferred=2
pub const TransitionResult = enum(u8) {
    accepted = 0,
    rejected = 1,
    deferred = 2,
};

/// ValidationError — reason a transition was rejected.
///   InvalidTransition=0, PreconditionFailed=1,
///   PostconditionFailed=2, GuardFailed=3
pub const ValidationError = enum(u8) {
    invalid_transition = 0,
    precondition_failed = 1,
    postcondition_failed = 2,
    guard_failed = 3,
};

/// EventDisposition — what happened to an event submitted to the router.
///   Consumed=0 (routed), Ignored=1 (no match), Queued=2 (deferred),
///   Dropped=3 (overflow)
pub const EventDisposition = enum(u8) {
    consumed = 0,
    ignored = 1,
    queued = 2,
    dropped = 3,
};

// ── proven-queueconn types (tag values match proven-servers exactly) ─────

/// QueueState — connection lifecycle to a downstream target.
///   Disconnected=0, Connected=1, Consuming=2, Producing=3, Failed=4
pub const QueueState = enum(u8) {
    disconnected = 0,
    connected = 1,
    consuming = 2,
    producing = 3,
    failed = 4,
};

/// DeliveryGuarantee — per-target delivery semantics.
///   AtMostOnce=0, AtLeastOnce=1, ExactlyOnce=2
pub const DeliveryGuarantee = enum(u8) {
    at_most_once = 0,
    at_least_once = 1,
    exactly_once = 2,
};

// ── Instance types ───────────────────────────────────────────────────────

const Router = struct {
    state: MachineState,
    event_count: u32,
    last_error: u8, // 255 = no error
    active: bool,
};

const Target = struct {
    state: QueueState,
    dispatched_count: u32,
    guarantee: DeliveryGuarantee,
    last_error: u8, // 255 = no error
    active: bool,
};

// ── Global state (slot-based, mutex-protected) ───────────────────────────

const MAX_ROUTERS: usize = 16;
const MAX_TARGETS: usize = 64;

var routers: [MAX_ROUTERS]Router = [_]Router{.{
    .state = .initial,
    .event_count = 0,
    .last_error = 255,
    .active = false,
}} ** MAX_ROUTERS;

var targets: [MAX_TARGETS]Target = [_]Target{.{
    .state = .disconnected,
    .dispatched_count = 0,
    .guarantee = .at_least_once,
    .last_error = 255,
    .active = false,
}} ** MAX_TARGETS;

var router_mutex: std.Thread.Mutex = .{};
var target_mutex: std.Thread.Mutex = .{};

// ── ABI version ──────────────────────────────────────────────────────────

/// ABI version.  Must match harFsmAbiVersion and harQueueAbiVersion in
/// ProvenFSM.idr and ProvenQueue.idr (currently 1).
export fn har_abi_version() callconv(.c) u32 {
    return 1;
}

// ── Router lifecycle ─────────────────────────────────────────────────────

/// Create a new router in Initial (Configuring) state.
/// Returns slot index (0..MAX_ROUTERS-1) or -1 if full.
export fn har_router_create() callconv(.c) c_int {
    router_mutex.lock();
    defer router_mutex.unlock();

    for (&routers, 0..) |*r, i| {
        if (!r.active) {
            r.* = .{
                .state = .initial,
                .event_count = 0,
                .last_error = 255,
                .active = true,
            };
            return @intCast(i);
        }
    }
    return -1;
}

/// Destroy a router, freeing its slot.  Safe with any slot value.
export fn har_router_destroy(slot: c_int) callconv(.c) void {
    router_mutex.lock();
    defer router_mutex.unlock();

    if (slot < 0 or slot >= MAX_ROUTERS) return;
    const idx: usize = @intCast(slot);
    routers[idx].active = false;
}

/// Get current MachineState tag.  Returns Initial (0) for invalid slots.
export fn har_router_state(slot: c_int) callconv(.c) u8 {
    router_mutex.lock();
    defer router_mutex.unlock();

    if (slot < 0 or slot >= MAX_ROUTERS) return 0;
    const idx: usize = @intCast(slot);
    if (!routers[idx].active) return 0;
    return @intFromEnum(routers[idx].state);
}

/// Start routing: Initial -> Running.  Returns TransitionResult tag.
export fn har_router_start(slot: c_int) callconv(.c) u8 {
    router_mutex.lock();
    defer router_mutex.unlock();

    if (slot < 0 or slot >= MAX_ROUTERS) return @intFromEnum(TransitionResult.rejected);
    const idx: usize = @intCast(slot);
    if (!routers[idx].active) return @intFromEnum(TransitionResult.rejected);

    if (routers[idx].state == .initial) {
        routers[idx].state = .running;
        routers[idx].last_error = 255;
        return @intFromEnum(TransitionResult.accepted);
    }
    routers[idx].last_error = @intFromEnum(ValidationError.invalid_transition);
    return @intFromEnum(TransitionResult.rejected);
}

/// Graceful shutdown: Running -> Terminal.  Returns TransitionResult tag.
export fn har_router_shutdown(slot: c_int) callconv(.c) u8 {
    router_mutex.lock();
    defer router_mutex.unlock();

    if (slot < 0 or slot >= MAX_ROUTERS) return @intFromEnum(TransitionResult.rejected);
    const idx: usize = @intCast(slot);
    if (!routers[idx].active) return @intFromEnum(TransitionResult.rejected);

    if (routers[idx].state == .running) {
        routers[idx].state = .terminal;
        routers[idx].last_error = 255;
        return @intFromEnum(TransitionResult.accepted);
    }
    routers[idx].last_error = @intFromEnum(ValidationError.invalid_transition);
    return @intFromEnum(TransitionResult.rejected);
}

/// Get last ValidationError tag, or 255 if no error.
export fn har_last_error(slot: c_int) callconv(.c) u8 {
    router_mutex.lock();
    defer router_mutex.unlock();

    if (slot < 0 or slot >= MAX_ROUTERS) return 255;
    const idx: usize = @intCast(slot);
    return routers[idx].last_error;
}

// ── Event dispatch ───────────────────────────────────────────────────────

/// Route and dispatch an event.  Returns EventDisposition tag.
/// Only Running routers accept events; others return Ignored.
/// Invalid/inactive slots return Dropped.
export fn har_dispatch_event(slot: c_int, event_id: u32) callconv(.c) u8 {
    router_mutex.lock();
    defer router_mutex.unlock();

    _ = event_id; // routing rules will use this

    if (slot < 0 or slot >= MAX_ROUTERS) return @intFromEnum(EventDisposition.dropped);
    const idx: usize = @intCast(slot);
    if (!routers[idx].active) return @intFromEnum(EventDisposition.dropped);

    if (routers[idx].state == .running) {
        routers[idx].event_count += 1;
        return @intFromEnum(EventDisposition.consumed);
    }
    return @intFromEnum(EventDisposition.ignored);
}

// ── Target connection management ─────────────────────────────────────────

/// Connect to a downstream automation target.
/// Returns slot index (0..MAX_TARGETS-1) or -1 if full.
/// The guarantee parameter is a DeliveryGuarantee tag (default: AtLeastOnce=1).
export fn har_target_connect(guarantee: u8) callconv(.c) c_int {
    target_mutex.lock();
    defer target_mutex.unlock();

    const g: DeliveryGuarantee = std.meta.intToEnum(DeliveryGuarantee, guarantee) catch .at_least_once;

    for (&targets, 0..) |*t, i| {
        if (!t.active) {
            t.* = .{
                .state = .connected,
                .dispatched_count = 0,
                .guarantee = g,
                .last_error = 255,
                .active = true,
            };
            return @intCast(i);
        }
    }
    return -1;
}

/// Disconnect from a downstream target.  Safe with any slot value.
export fn har_target_disconnect(slot: c_int) callconv(.c) void {
    target_mutex.lock();
    defer target_mutex.unlock();

    if (slot < 0 or slot >= MAX_TARGETS) return;
    const idx: usize = @intCast(slot);
    if (!targets[idx].active) return;
    targets[idx].state = .disconnected;
    targets[idx].active = false;
}

/// Get current QueueState tag for a target.
/// Returns Disconnected (0) for invalid/inactive slots.
export fn har_target_state(slot: c_int) callconv(.c) u8 {
    target_mutex.lock();
    defer target_mutex.unlock();

    if (slot < 0 or slot >= MAX_TARGETS) return 0;
    const idx: usize = @intCast(slot);
    if (!targets[idx].active) return 0;
    return @intFromEnum(targets[idx].state);
}

// ── Version ──────────────────────────────────────────────────────────────

const VERSION: [:0]const u8 = "0.1.0";

/// Library version as a null-terminated C string.
export fn har_version() callconv(.c) [*:0]const u8 {
    return VERSION;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "router lifecycle: create -> start -> shutdown -> destroy" {
    const slot = har_router_create();
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(u8, 0), har_router_state(slot));

    const start_result = har_router_start(slot);
    try std.testing.expectEqual(@as(u8, @intFromEnum(TransitionResult.accepted)), start_result);
    try std.testing.expectEqual(@as(u8, 1), har_router_state(slot));

    const dispatch_result = har_dispatch_event(slot, 42);
    try std.testing.expectEqual(@as(u8, @intFromEnum(EventDisposition.consumed)), dispatch_result);

    const shutdown_result = har_router_shutdown(slot);
    try std.testing.expectEqual(@as(u8, @intFromEnum(TransitionResult.accepted)), shutdown_result);
    try std.testing.expectEqual(@as(u8, 2), har_router_state(slot));

    har_router_destroy(slot);
}

test "router rejects invalid transitions" {
    const slot = har_router_create();
    try std.testing.expect(slot >= 0);

    const result = har_router_shutdown(slot);
    try std.testing.expectEqual(@as(u8, @intFromEnum(TransitionResult.rejected)), result);

    _ = har_router_start(slot);
    const double_start = har_router_start(slot);
    try std.testing.expectEqual(@as(u8, @intFromEnum(TransitionResult.rejected)), double_start);

    har_router_destroy(slot);
}

test "event dispatch only works in Running state" {
    const slot = har_router_create();
    try std.testing.expect(slot >= 0);

    const result = har_dispatch_event(slot, 1);
    try std.testing.expectEqual(@as(u8, @intFromEnum(EventDisposition.ignored)), result);

    har_router_destroy(slot);
}

test "target connection lifecycle" {
    const slot = har_target_connect(1); // AtLeastOnce
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(u8, 1), har_target_state(slot));

    har_target_disconnect(slot);
    try std.testing.expectEqual(@as(u8, 0), har_target_state(slot));
}

test "invalid slots return safe defaults" {
    try std.testing.expectEqual(@as(u8, 0), har_router_state(-1));
    try std.testing.expectEqual(@as(u8, 0), har_router_state(999));
    try std.testing.expectEqual(@as(u8, @intFromEnum(EventDisposition.dropped)), har_dispatch_event(-1, 0));
    try std.testing.expectEqual(@as(u8, 0), har_target_state(-1));
}

test "abi version is 1" {
    try std.testing.expectEqual(@as(u32, 1), har_abi_version());
}

test "version string" {
    const v = har_version();
    const slice = std.mem.span(v);
    try std.testing.expectEqualStrings("0.1.0", slice);
}
