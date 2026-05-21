const std = @import("std");
const types_mod = @import("types.zig");
const wire = @import("wire.zig");
const sql_mod = @import("sql.zig");

const FieldType = types_mod.FieldType;
const Date = types_mod.Date;
const Time = types_mod.Time;
const DateTime = types_mod.DateTime;
const Decimal = types_mod.Decimal;
const Json = types_mod.Json;
const Blob = types_mod.Blob;
const Command = wire.Command;
const appendInt = wire.appendInt;
const appendLengthEncodedString = wire.appendLengthEncodedString;
const setNullBitmap = wire.setNullBitmap;
const validateDecimal = sql_mod.validateDecimal;

fn writeParamType(payload: *std.ArrayListUnmanaged(u8), type_start: usize, index: usize, field_type: FieldType, unsigned: bool) void {
    const offset = type_start + index * 2;
    payload.items[offset] = @intFromEnum(field_type);
    payload.items[offset + 1] = if (unsigned) 0x80 else 0x00;
}

fn setPayloadNull(payload: *std.ArrayListUnmanaged(u8), null_bitmap_start: usize, null_bitmap_len: usize, index: usize) void {
    setNullBitmap(payload.items[null_bitmap_start .. null_bitmap_start + null_bitmap_len], index);
}

fn appendPreparedParam(
    allocator: std.mem.Allocator,
    payload: *std.ArrayListUnmanaged(u8),
    null_bitmap_start: usize,
    null_bitmap_len: usize,
    type_start: usize,
    index: usize,
    value: anytype,
) !void {
    const T = @TypeOf(value);

    if (T == Date) {
        writeParamType(payload, type_start, index, .date, false);
        try appendBinaryDate(allocator, payload, value);
        return;
    }
    if (T == Time) {
        writeParamType(payload, type_start, index, .time, false);
        try appendBinaryTime(allocator, payload, value);
        return;
    }
    if (T == DateTime) {
        writeParamType(payload, type_start, index, .datetime, false);
        try appendBinaryDateTime(allocator, payload, value);
        return;
    }
    if (T == Decimal) {
        try validateDecimal(value.text);
        writeParamType(payload, type_start, index, .var_string, false);
        try appendLengthEncodedString(allocator, payload, value.text);
        return;
    }
    if (T == Json) {
        writeParamType(payload, type_start, index, .var_string, false);
        try appendLengthEncodedString(allocator, payload, value.bytes);
        return;
    }
    if (T == Blob) {
        writeParamType(payload, type_start, index, .blob, false);
        try appendLengthEncodedString(allocator, payload, value.bytes);
        return;
    }

    switch (@typeInfo(T)) {
        .null => {
            setPayloadNull(payload, null_bitmap_start, null_bitmap_len, index);
            writeParamType(payload, type_start, index, .null, false);
        },
        .optional => if (value) |child| {
            try appendPreparedParam(allocator, payload, null_bitmap_start, null_bitmap_len, type_start, index, child);
        } else {
            setPayloadNull(payload, null_bitmap_start, null_bitmap_len, index);
            writeParamType(payload, type_start, index, .null, false);
        },
        .bool => {
            writeParamType(payload, type_start, index, .tiny, true);
            try payload.append(allocator, if (value) 1 else 0);
        },
        .int => |info| {
            const unsigned = info.signedness == .unsigned;
            writeParamType(payload, type_start, index, .longlong, unsigned);
            if (unsigned) {
                try appendInt(u64, allocator, payload, @as(u64, @intCast(value)));
            } else {
                try appendInt(i64, allocator, payload, @as(i64, @intCast(value)));
            }
        },
        .comptime_int => {
            writeParamType(payload, type_start, index, .longlong, false);
            try appendInt(i64, allocator, payload, @as(i64, value));
        },
        .float, .comptime_float => {
            writeParamType(payload, type_start, index, .double, false);
            const number: f64 = @floatCast(value);
            const bits: u64 = @bitCast(number);
            try appendInt(u64, allocator, payload, bits);
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) {
                writeParamType(payload, type_start, index, .var_string, false);
                try appendLengthEncodedString(allocator, payload, value);
            } else {
                @compileError("unsupported MySQL prepared parameter type: " ++ @typeName(T));
            },
            .one => switch (@typeInfo(ptr.child)) {
                .array => |array| if (array.child == u8) {
                    writeParamType(payload, type_start, index, .var_string, false);
                    try appendLengthEncodedString(allocator, payload, value[0..]);
                } else {
                    @compileError("unsupported MySQL prepared parameter type: " ++ @typeName(T));
                },
                else => @compileError("unsupported MySQL prepared parameter type: " ++ @typeName(T)),
            },
            else => @compileError("unsupported MySQL prepared parameter type: " ++ @typeName(T)),
        },
        .array => |array| if (array.child == u8) {
            writeParamType(payload, type_start, index, .var_string, false);
            try appendLengthEncodedString(allocator, payload, value[0..]);
        } else {
            @compileError("unsupported MySQL prepared parameter type: " ++ @typeName(T));
        },
        .@"enum" => {
            writeParamType(payload, type_start, index, .var_string, false);
            try appendLengthEncodedString(allocator, payload, @tagName(value));
        },
        .enum_literal => {
            writeParamType(payload, type_start, index, .var_string, false);
            try appendLengthEncodedString(allocator, payload, @tagName(value));
        },
        else => @compileError("unsupported MySQL prepared parameter type: " ++ @typeName(T)),
    }
}

fn appendBinaryDate(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: Date) !void {
    try out.append(allocator, 4);
    try appendInt(u16, allocator, out, value.year);
    try out.append(allocator, value.month);
    try out.append(allocator, value.day);
}

fn appendBinaryDateTime(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: DateTime) !void {
    try out.append(allocator, if (value.microsecond != 0) 11 else 7);
    try appendInt(u16, allocator, out, value.year);
    try out.append(allocator, value.month);
    try out.append(allocator, value.day);
    try out.append(allocator, value.hour);
    try out.append(allocator, value.minute);
    try out.append(allocator, value.second);
    if (value.microsecond != 0) try appendInt(u32, allocator, out, value.microsecond);
}

fn appendBinaryTime(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: Time) !void {
    if (!value.negative and value.days == 0 and value.hour == 0 and value.minute == 0 and value.second == 0 and value.microsecond == 0) {
        try out.append(allocator, 0);
        return;
    }

    try out.append(allocator, if (value.microsecond != 0) 12 else 8);
    try out.append(allocator, if (value.negative) 1 else 0);
    try appendInt(u32, allocator, out, value.days);
    try out.append(allocator, value.hour);
    try out.append(allocator, value.minute);
    try out.append(allocator, value.second);
    if (value.microsecond != 0) try appendInt(u32, allocator, out, value.microsecond);
}

pub fn buildPreparedExecutePayloadInto(
    allocator: std.mem.Allocator,
    payload: *std.ArrayListUnmanaged(u8),
    stmt_id: u32,
    param_count: usize,
    params: anytype,
) !void {
    const Params = @TypeOf(params);
    const params_info = @typeInfo(Params);
    if (params_info != .@"struct" or !params_info.@"struct".is_tuple) {
        @compileError("mysql prepared params must be a tuple literal, for example .{id, name}");
    }
    const fields = params_info.@"struct".fields;
    if (fields.len != param_count) return error.ParameterCountMismatch;

    try payload.ensureUnusedCapacity(allocator, 10 + if (param_count > 0) (param_count + 7) / 8 + 1 + param_count * 2 else 0);

    try payload.append(allocator, @intFromEnum(Command.stmt_execute));
    try appendInt(u32, allocator, payload, stmt_id);
    try payload.append(allocator, 0); // CURSOR_TYPE_NO_CURSOR
    try appendInt(u32, allocator, payload, 1);

    if (param_count > 0) {
        const null_bitmap_start = payload.items.len;
        const null_bitmap_len = (param_count + 7) / 8;
        try payload.appendNTimes(allocator, 0, null_bitmap_len);
        try payload.append(allocator, 1); // new params bound
        const type_start = payload.items.len;
        try payload.appendNTimes(allocator, 0, param_count * 2);

        inline for (fields, 0..) |field, index| {
            try appendPreparedParam(
                allocator,
                payload,
                null_bitmap_start,
                null_bitmap_len,
                type_start,
                index,
                @field(params, field.name),
            );
        }
    }
}
