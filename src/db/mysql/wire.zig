const std = @import("std");
const types = @import("types.zig");

const Io = std.Io;
const ExecResult = types.ExecResult;
const StoredServerError = types.StoredServerError;
const FieldType = types.FieldType;
const Column = types.Column;
const Row = types.Row;
const Date = types.Date;
const Time = types.Time;
const DateTime = types.DateTime;
const formatDateText = types.formatDateText;
const formatTimeText = types.formatTimeText;
const formatDateTimeText = types.formatDateTimeText;

pub const max_payload_len: usize = 0x00ff_ffff;
pub const Command = enum(u8) {
    quit = 0x01,
    init_db = 0x02,
    query = 0x03,
    ping = 0x0e,
    stmt_prepare = 0x16,
    stmt_execute = 0x17,
    stmt_close = 0x19,
    reset_connection = 0x1f,
};

pub fn parseOkPacket(packet: []const u8) !ExecResult {
    if (packet.len == 0 or packet[0] != 0x00) return error.ProtocolError;
    var reader = Io.Reader.fixed(packet[1..]);
    const affected_rows = try readLengthEncodedInteger(&reader);
    const last_insert_id = try readLengthEncodedInteger(&reader);
    const status_flags = if (reader.bufferedLen() >= 2) try reader.takeInt(u16, .little) else 0;
    const warnings = if (reader.bufferedLen() >= 2) try reader.takeInt(u16, .little) else 0;
    return .{
        .affected_rows = affected_rows,
        .last_insert_id = last_insert_id,
        .status_flags = status_flags,
        .warnings = warnings,
    };
}

pub fn parseServerErrorPacket(packet: []const u8) !StoredServerError {
    if (packet.len < 3 or packet[0] != 0xff) return error.ProtocolError;

    var out: StoredServerError = .{};
    out.code = std.mem.readInt(u16, packet[1..3], .little);

    var message_start: usize = 3;
    if (packet.len >= 9 and packet[3] == '#') {
        @memcpy(&out.sql_state, packet[4..9]);
        message_start = 9;
    }

    const message = packet[message_start..];
    out.message_len = @min(message.len, out.message_buf.len);
    if (out.message_len > 0) {
        @memcpy(out.message_buf[0..out.message_len], message[0..out.message_len]);
    }
    out.truncated = message.len > out.message_buf.len;
    return out;
}

pub fn parseColumnDefinition(allocator: std.mem.Allocator, packet: []const u8) !Column {
    var reader = Io.Reader.fixed(packet);
    _ = try readLengthEncodedString(&reader); // catalog
    const database = try allocator.dupe(u8, try readLengthEncodedString(&reader));
    errdefer allocator.free(database);
    const table = try allocator.dupe(u8, try readLengthEncodedString(&reader));
    errdefer allocator.free(table);
    _ = try readLengthEncodedString(&reader); // original table
    const name = try allocator.dupe(u8, try readLengthEncodedString(&reader));
    errdefer allocator.free(name);
    _ = try readLengthEncodedString(&reader); // original name

    _ = try reader.takeByte(); // fixed length marker
    _ = try reader.takeInt(u16, .little); // character set
    const column_length = try reader.takeInt(u32, .little);
    const field_type: FieldType = @enumFromInt(try reader.takeByte());
    const flags = try reader.takeInt(u16, .little);
    const decimals = try reader.takeByte();

    return .{
        .name = name,
        .table = table,
        .database = database,
        .field_type = field_type,
        .flags = flags,
        .decimals = decimals,
        .length = column_length,
    };
}

pub fn parseTextRow(allocator: std.mem.Allocator, packet: []const u8, column_count: usize) !Row {
    var reader = Io.Reader.fixed(packet);
    const values = try allocator.alloc(?[]const u8, column_count);
    errdefer allocator.free(values);

    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| {
            if (value) |bytes| allocator.free(bytes);
        }
    }

    for (values) |*value| {
        const first = try reader.takeByte();
        if (first == 0xfb) {
            value.* = null;
        } else {
            const len = std.math.cast(usize, try readLengthEncodedIntegerAfterFirst(first, &reader)) orelse return error.PacketTooLarge;
            const bytes = try allocator.dupe(u8, try reader.take(len));
            value.* = bytes;
        }
        initialized += 1;
    }

    return .{ .values = values };
}

pub fn parseTextRowInto(values: []?[]const u8, packet: []const u8) !void {
    var reader = Io.Reader.fixed(packet);
    for (values) |*value| {
        const first = try reader.takeByte();
        if (first == 0xfb) {
            value.* = null;
        } else {
            const len = std.math.cast(usize, try readLengthEncodedIntegerAfterFirst(first, &reader)) orelse return error.PacketTooLarge;
            value.* = try reader.take(len);
        }
    }
}

pub fn parseBinaryTextRow(allocator: std.mem.Allocator, packet: []const u8, columns: []const Column) !Row {
    if (packet.len == 0 or packet[0] != 0x00) return error.ProtocolError;

    var reader = Io.Reader.fixed(packet[1..]);
    const null_bitmap_len = (columns.len + 7 + 2) / 8;
    const null_bitmap = try reader.take(null_bitmap_len);

    const values = try allocator.alloc(?[]const u8, columns.len);
    errdefer allocator.free(values);

    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| {
            if (value) |bytes| allocator.free(bytes);
        }
    }

    for (columns, 0..) |column, index| {
        if (nullBitmapSet(null_bitmap, index + 2)) {
            values[index] = null;
        } else {
            values[index] = try readBinaryValueAsText(allocator, &reader, column);
        }
        initialized += 1;
    }

    return .{ .values = values };
}

pub const BinaryValue = union(enum) {
    signed: i64,
    unsigned: u64,
    float: f32,
    double: f64,
    bytes: []const u8,
    date: Date,
    datetime: DateTime,
    time: Time,
};

pub fn parseBinaryValuesInto(values: []?BinaryValue, packet: []const u8, columns: []const Column) !void {
    if (packet.len == 0 or packet[0] != 0x00) return error.ProtocolError;
    if (values.len < columns.len) return error.ProtocolError;

    var reader = Io.Reader.fixed(packet[1..]);
    const null_bitmap_len = (columns.len + 7 + 2) / 8;
    const null_bitmap = try reader.take(null_bitmap_len);

    for (columns, 0..) |column, index| {
        if (nullBitmapSet(null_bitmap, index + 2)) {
            values[index] = null;
        } else {
            values[index] = try readBinaryValue(&reader, column);
        }
    }
}

fn nullBitmapSet(bitmap: []const u8, bit_index: usize) bool {
    return (bitmap[bit_index / 8] & (@as(u8, 1) << @as(u3, @intCast(bit_index % 8)))) != 0;
}

pub fn setNullBitmap(bitmap: []u8, index: usize) void {
    bitmap[index / 8] |= @as(u8, 1) << @as(u3, @intCast(index % 8));
}

fn readBinaryValueAsText(allocator: std.mem.Allocator, reader: *Io.Reader, column: Column) ![]const u8 {
    return switch (column.field_type) {
        .tiny => if (column.unsigned())
            try std.fmt.allocPrint(allocator, "{d}", .{try reader.takeByte()})
        else
            try std.fmt.allocPrint(allocator, "{d}", .{@as(i8, @bitCast(try reader.takeByte()))}),
        .short => if (column.unsigned())
            try std.fmt.allocPrint(allocator, "{d}", .{try reader.takeInt(u16, .little)})
        else
            try std.fmt.allocPrint(allocator, "{d}", .{@as(i16, @bitCast(try reader.takeInt(u16, .little)))}),
        .year => try std.fmt.allocPrint(allocator, "{d}", .{try reader.takeInt(u16, .little)}),
        .long, .int24 => if (column.unsigned())
            try std.fmt.allocPrint(allocator, "{d}", .{try reader.takeInt(u32, .little)})
        else
            try std.fmt.allocPrint(allocator, "{d}", .{@as(i32, @bitCast(try reader.takeInt(u32, .little)))}),
        .longlong => if (column.unsigned())
            try std.fmt.allocPrint(allocator, "{d}", .{try reader.takeInt(u64, .little)})
        else
            try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @bitCast(try reader.takeInt(u64, .little)))}),
        .float => {
            const bits = try reader.takeInt(u32, .little);
            const value: f32 = @bitCast(bits);
            return try std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        .double => {
            const bits = try reader.takeInt(u64, .little);
            const value: f64 = @bitCast(bits);
            return try std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        .date, .newdate => try readBinaryDateAsText(allocator, reader),
        .datetime, .datetime2, .timestamp, .timestamp2 => try readBinaryDateTimeAsText(allocator, reader),
        .time, .time2 => try readBinaryTimeAsText(allocator, reader),
        .null => try allocator.dupe(u8, ""),
        else => try allocator.dupe(u8, try readLengthEncodedString(reader)),
    };
}

fn readBinaryValue(reader: *Io.Reader, column: Column) !BinaryValue {
    return switch (column.field_type) {
        .tiny => if (column.unsigned())
            .{ .unsigned = try reader.takeByte() }
        else
            .{ .signed = @as(i8, @bitCast(try reader.takeByte())) },
        .short => if (column.unsigned())
            .{ .unsigned = try reader.takeInt(u16, .little) }
        else
            .{ .signed = @as(i16, @bitCast(try reader.takeInt(u16, .little))) },
        .year => .{ .unsigned = try reader.takeInt(u16, .little) },
        .long, .int24 => if (column.unsigned())
            .{ .unsigned = try reader.takeInt(u32, .little) }
        else
            .{ .signed = @as(i32, @bitCast(try reader.takeInt(u32, .little))) },
        .longlong => if (column.unsigned())
            .{ .unsigned = try reader.takeInt(u64, .little) }
        else
            .{ .signed = @as(i64, @bitCast(try reader.takeInt(u64, .little))) },
        .float => .{ .float = @as(f32, @bitCast(try reader.takeInt(u32, .little))) },
        .double => .{ .double = @as(f64, @bitCast(try reader.takeInt(u64, .little))) },
        .date, .newdate => .{ .date = try readBinaryDate(reader) },
        .datetime, .datetime2, .timestamp, .timestamp2 => .{ .datetime = try readBinaryDateTime(reader) },
        .time, .time2 => .{ .time = try readBinaryTime(reader) },
        .null => .{ .bytes = "" },
        else => .{ .bytes = try readLengthEncodedString(reader) },
    };
}

fn readBinaryDateAsText(allocator: std.mem.Allocator, reader: *Io.Reader) ![]const u8 {
    return formatDateText(allocator, try readBinaryDate(reader));
}

fn readBinaryDateTimeAsText(allocator: std.mem.Allocator, reader: *Io.Reader) ![]const u8 {
    return formatDateTimeText(allocator, try readBinaryDateTime(reader));
}

fn readBinaryTimeAsText(allocator: std.mem.Allocator, reader: *Io.Reader) ![]const u8 {
    return formatTimeText(allocator, try readBinaryTime(reader));
}

fn readBinaryDate(reader: *Io.Reader) !Date {
    const len = try reader.takeByte();
    if (len == 0) return .{ .year = 0, .month = 0, .day = 0 };
    if (len != 4 and len != 7 and len != 11) return error.ProtocolError;
    const date = Date{
        .year = try reader.takeInt(u16, .little),
        .month = try reader.takeByte(),
        .day = try reader.takeByte(),
    };
    if (len >= 7) _ = try reader.take(3);
    if (len == 11) _ = try reader.takeInt(u32, .little);
    return date;
}

fn readBinaryDateTime(reader: *Io.Reader) !DateTime {
    const len = try reader.takeByte();
    if (len == 0) return .{ .year = 0, .month = 0, .day = 0 };
    if (len != 4 and len != 7 and len != 11) return error.ProtocolError;

    const year = try reader.takeInt(u16, .little);
    const month = try reader.takeByte();
    const day = try reader.takeByte();
    var hour: u8 = 0;
    var minute: u8 = 0;
    var second: u8 = 0;
    var microsecond: u32 = 0;
    if (len >= 7) {
        hour = try reader.takeByte();
        minute = try reader.takeByte();
        second = try reader.takeByte();
    }
    if (len == 11) {
        microsecond = try reader.takeInt(u32, .little);
    }
    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .microsecond = microsecond,
    };
}

fn readBinaryTime(reader: *Io.Reader) !Time {
    const len = try reader.takeByte();
    if (len == 0) return .{ .hour = 0, .minute = 0, .second = 0 };
    if (len != 8 and len != 12) return error.ProtocolError;

    const negative = (try reader.takeByte()) != 0;
    const days = try reader.takeInt(u32, .little);
    const hour = try reader.takeByte();
    const minute = try reader.takeByte();
    const second = try reader.takeByte();
    const microsecond = if (len == 12) try reader.takeInt(u32, .little) else 0;
    return .{
        .negative = negative,
        .days = days,
        .hour = hour,
        .minute = minute,
        .second = second,
        .microsecond = microsecond,
    };
}

pub fn isEofPacket(packet: []const u8) bool {
    return packet.len > 0 and packet[0] == 0xfe and packet.len < 9;
}

pub fn readLengthEncodedInteger(reader: *Io.Reader) !u64 {
    const first = try reader.takeByte();
    if (first == 0xfb) return error.UnexpectedNull;
    return readLengthEncodedIntegerAfterFirst(first, reader);
}

pub fn readLengthEncodedIntegerAfterFirst(first: u8, reader: *Io.Reader) !u64 {
    return switch (first) {
        0xfc => @as(u64, try reader.takeInt(u16, .little)),
        0xfd => @as(u64, try reader.takeInt(u24, .little)),
        0xfe => try reader.takeInt(u64, .little),
        else => @as(u64, first),
    };
}

pub fn readLengthEncodedString(reader: *Io.Reader) ![]const u8 {
    const len = std.math.cast(usize, try readLengthEncodedInteger(reader)) orelse return error.PacketTooLarge;
    return reader.take(len);
}

pub fn appendInt(comptime T: type, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: T) !void {
    var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

pub fn appendLengthEncodedInteger(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: u64) !void {
    if (value < 251) {
        try out.append(allocator, @as(u8, @intCast(value)));
    } else if (value <= std.math.maxInt(u16)) {
        try out.append(allocator, 0xfc);
        try appendInt(u16, allocator, out, @as(u16, @intCast(value)));
    } else if (value <= std.math.maxInt(u24)) {
        try out.append(allocator, 0xfd);
        try appendInt(u24, allocator, out, @as(u24, @intCast(value)));
    } else {
        try out.append(allocator, 0xfe);
        try appendInt(u64, allocator, out, value);
    }
}

pub fn appendLengthEncodedString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try appendLengthEncodedInteger(allocator, out, @as(u64, @intCast(value.len)));
    try out.appendSlice(allocator, value);
}
