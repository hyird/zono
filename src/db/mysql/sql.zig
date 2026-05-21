const std = @import("std");
const types = @import("types.zig");

const Date = types.Date;
const Time = types.Time;
const DateTime = types.DateTime;
const Decimal = types.Decimal;
const Json = types.Json;
const Blob = types.Blob;
pub const RenderedQuery = struct {
    sql: []const u8,
    owned: bool = false,

    pub fn deinit(self: RenderedQuery, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.sql);
    }
};

pub fn formatQueryMaybe(allocator: std.mem.Allocator, sql: []const u8, params: anytype) !RenderedQuery {
    const Params = @TypeOf(params);
    const params_info = @typeInfo(Params);
    if (params_info != .@"struct" or !params_info.@"struct".is_tuple) {
        @compileError("mysql query params must be a tuple literal, for example .{id, name}");
    }
    if (params_info.@"struct".fields.len == 0) {
        return .{ .sql = sql };
    }
    return .{ .sql = try formatQuery(allocator, sql, params), .owned = true };
}

pub fn formatQuery(allocator: std.mem.Allocator, sql: []const u8, params: anytype) ![]u8 {
    const Params = @TypeOf(params);
    const params_info = @typeInfo(Params);
    if (params_info != .@"struct" or !params_info.@"struct".is_tuple) {
        @compileError("mysql query params must be a tuple literal, for example .{id, name}");
    }

    return substitutePlaceholders(allocator, sql, params);
}

const SqlState = enum {
    normal,
    single_quote,
    double_quote,
    backtick,
    line_comment,
    block_comment,
};

fn substitutePlaceholders(allocator: std.mem.Allocator, sql: []const u8, params: anytype) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, sql.len);

    var state: SqlState = .normal;
    var literal_index: usize = 0;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        const ch = sql[i];
        switch (state) {
            .normal => {
                if (ch == '?') {
                    try appendParamLiteral(allocator, &out, params, literal_index);
                    literal_index += 1;
                    continue;
                }
                if (ch == '\'') state = .single_quote;
                if (ch == '"') state = .double_quote;
                if (ch == '`') state = .backtick;
                if (ch == '#') state = .line_comment;
                if (ch == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
                    try out.appendSlice(allocator, sql[i .. i + 2]);
                    i += 1;
                    state = .line_comment;
                    continue;
                }
                if (ch == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
                    try out.appendSlice(allocator, sql[i .. i + 2]);
                    i += 1;
                    state = .block_comment;
                    continue;
                }
                try out.append(allocator, ch);
            },
            .single_quote => {
                try out.append(allocator, ch);
                if (ch == '\\' and i + 1 < sql.len) {
                    i += 1;
                    try out.append(allocator, sql[i]);
                } else if (ch == '\'') {
                    state = .normal;
                }
            },
            .double_quote => {
                try out.append(allocator, ch);
                if (ch == '\\' and i + 1 < sql.len) {
                    i += 1;
                    try out.append(allocator, sql[i]);
                } else if (ch == '"') {
                    state = .normal;
                }
            },
            .backtick => {
                try out.append(allocator, ch);
                if (ch == '`') state = .normal;
            },
            .line_comment => {
                try out.append(allocator, ch);
                if (ch == '\n') state = .normal;
            },
            .block_comment => {
                if (ch == '*' and i + 1 < sql.len and sql[i + 1] == '/') {
                    try out.appendSlice(allocator, sql[i .. i + 2]);
                    i += 1;
                    state = .normal;
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }

    const Params = @TypeOf(params);
    const param_count = @typeInfo(Params).@"struct".fields.len;
    if (literal_index != param_count) return error.ParameterCountMismatch;
    return out.toOwnedSlice(allocator);
}

fn appendParamLiteral(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), params: anytype, literal_index: usize) !void {
    const Params = @TypeOf(params);
    const fields = @typeInfo(Params).@"struct".fields;
    var matched = false;

    inline for (fields, 0..) |field, index| {
        if (literal_index == index) {
            try appendSqlLiteral(allocator, out, @field(params, field.name));
            matched = true;
        }
    }

    if (!matched) return error.ParameterCountMismatch;
}

fn appendSqlLiteral(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: anytype) !void {
    const T = @TypeOf(value);
    if (T == Date) {
        try out.print(allocator, "'{d:0>4}-{d:0>2}-{d:0>2}'", .{ value.year, value.month, value.day });
        return;
    }
    if (T == Time) {
        try appendTimeLiteral(allocator, out, value);
        return;
    }
    if (T == DateTime) {
        try appendDateTimeLiteral(allocator, out, value);
        return;
    }
    if (T == Decimal) {
        try validateDecimal(value.text);
        try out.appendSlice(allocator, value.text);
        return;
    }
    if (T == Json or T == Blob) {
        try appendQuotedStringLiteral(allocator, out, value.bytes);
        return;
    }

    switch (@typeInfo(T)) {
        .null => try out.appendSlice(allocator, "NULL"),
        .optional => if (value) |child| try appendSqlLiteral(allocator, out, child) else try out.appendSlice(allocator, "NULL"),
        .bool => try out.appendSlice(allocator, if (value) "TRUE" else "FALSE"),
        .int, .comptime_int => try out.print(allocator, "{d}", .{value}),
        .float, .comptime_float => try out.print(allocator, "{d}", .{value}),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8)
                try appendQuotedStringLiteral(allocator, out, value)
            else
                @compileError("unsupported MySQL parameter type: " ++ @typeName(T)),
            .one => switch (@typeInfo(ptr.child)) {
                .array => |array| if (array.child == u8)
                    try appendQuotedStringLiteral(allocator, out, value)
                else
                    @compileError("unsupported MySQL parameter type: " ++ @typeName(T)),
                else => @compileError("unsupported MySQL parameter type: " ++ @typeName(T)),
            },
            else => @compileError("unsupported MySQL parameter type: " ++ @typeName(T)),
        },
        .array => |array| if (array.child == u8)
            try appendQuotedStringLiteral(allocator, out, value[0..])
        else
            @compileError("unsupported MySQL parameter type: " ++ @typeName(T)),
        .@"enum" => try appendQuotedStringLiteral(allocator, out, @tagName(value)),
        .enum_literal => try appendQuotedStringLiteral(allocator, out, @tagName(value)),
        else => @compileError("unsupported MySQL parameter type: " ++ @typeName(T)),
    }
}

fn appendTimeLiteral(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: Time) !void {
    const sign: []const u8 = if (value.negative) "-" else "";
    if (value.microsecond != 0) {
        if (value.days != 0) {
            try out.print(allocator, "'{s}{d} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}'", .{
                sign,
                value.days,
                value.hour,
                value.minute,
                value.second,
                value.microsecond,
            });
            return;
        }
        try out.print(allocator, "'{s}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}'", .{
            sign,
            value.hour,
            value.minute,
            value.second,
            value.microsecond,
        });
        return;
    }

    if (value.days != 0) {
        try out.print(allocator, "'{s}{d} {d:0>2}:{d:0>2}:{d:0>2}'", .{
            sign,
            value.days,
            value.hour,
            value.minute,
            value.second,
        });
        return;
    }
    try out.print(allocator, "'{s}{d:0>2}:{d:0>2}:{d:0>2}'", .{
        sign,
        value.hour,
        value.minute,
        value.second,
    });
}

fn appendDateTimeLiteral(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: DateTime) !void {
    if (value.microsecond != 0) {
        try out.print(allocator, "'{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}'", .{
            value.year,
            value.month,
            value.day,
            value.hour,
            value.minute,
            value.second,
            value.microsecond,
        });
        return;
    }
    try out.print(allocator, "'{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}'", .{
        value.year,
        value.month,
        value.day,
        value.hour,
        value.minute,
        value.second,
    });
}

fn appendQuotedStringLiteral(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |byte| {
        switch (byte) {
            0 => try out.appendSlice(allocator, "\\0"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\'' => try out.appendSlice(allocator, "\\'"),
            '"' => try out.appendSlice(allocator, "\\\""),
            0x1a => try out.appendSlice(allocator, "\\Z"),
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '\'');
}

pub fn validateDecimal(text: []const u8) !void {
    if (text.len == 0) return error.InvalidDecimal;

    var index: usize = 0;
    if (text[0] == '-' or text[0] == '+') {
        index = 1;
        if (index == text.len) return error.InvalidDecimal;
    }

    var seen_digit = false;
    var seen_dot = false;
    while (index < text.len) : (index += 1) {
        const ch = text[index];
        if (std.ascii.isDigit(ch)) {
            seen_digit = true;
            continue;
        }
        if (ch == '.' and !seen_dot) {
            seen_dot = true;
            continue;
        }
        return error.InvalidDecimal;
    }

    if (!seen_digit) return error.InvalidDecimal;
}
