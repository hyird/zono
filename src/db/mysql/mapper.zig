const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");

const ResultSet = types.ResultSet;
const Row = types.Row;
const Column = types.Column;
const Date = types.Date;
const Time = types.Time;
const DateTime = types.DateTime;
const Decimal = types.Decimal;
const Json = types.Json;
const Blob = types.Blob;
const BinaryValue = wire.BinaryValue;
const formatDateText = types.formatDateText;
const formatTimeText = types.formatTimeText;
const formatDateTimeText = types.formatDateTimeText;

pub fn RowMapper(comptime T: type) type {
    return struct {
        const Self = @This();
        const maps_as_struct = mapsAsStruct(T);
        const field_count = if (maps_as_struct) @typeInfo(T).@"struct".fields.len else 0;

        field_indices: [field_count]?usize = undefined,

        pub fn init(result: *const ResultSet) Self {
            var self: Self = undefined;
            if (comptime maps_as_struct) {
                const info = @typeInfo(T).@"struct";
                inline for (info.fields, 0..) |field, index| {
                    self.field_indices[index] = result.columnIndex(field.name);
                }
            }
            return self;
        }

        pub fn map(self: *const Self, row: Row, allocator: std.mem.Allocator) !T {
            if (comptime isScalarResultType(T)) {
                if (row.values.len == 0) return error.MissingColumn;
                return try decodeTextValue(T, row.values[0], allocator);
            }

            return switch (@typeInfo(T)) {
                .@"struct" => try self.mapStruct(row, allocator),
                else => {
                    if (row.values.len == 0) return error.MissingColumn;
                    return try decodeTextValue(T, row.values[0], allocator);
                },
            };
        }

        pub fn mapTextBorrowed(self: *const Self, row: Row) !T {
            if (comptime isScalarResultType(T)) {
                if (row.values.len == 0) return error.MissingColumn;
                return try decodeBorrowedTextValue(T, row.values[0]);
            }

            return switch (@typeInfo(T)) {
                .@"struct" => try self.mapBorrowedTextStruct(row),
                else => {
                    if (row.values.len == 0) return error.MissingColumn;
                    return try decodeBorrowedTextValue(T, row.values[0]);
                },
            };
        }

        pub fn mapBinary(self: *const Self, values: []const ?BinaryValue, columns: []const Column, allocator: std.mem.Allocator) !T {
            if (comptime isScalarResultType(T)) {
                if (values.len == 0) return error.MissingColumn;
                return try decodeBinaryValue(T, values[0], if (columns.len > 0) columns[0] else null, allocator);
            }

            return switch (@typeInfo(T)) {
                .@"struct" => try self.mapBinaryStruct(values, columns, allocator),
                else => {
                    if (values.len == 0) return error.MissingColumn;
                    return try decodeBinaryValue(T, values[0], if (columns.len > 0) columns[0] else null, allocator);
                },
            };
        }

        fn mapStruct(self: *const Self, row: Row, allocator: std.mem.Allocator) !T {
            var out: T = undefined;
            const info = @typeInfo(T).@"struct";

            inline for (info.fields, 0..) |field, field_index| {
                if (self.field_indices[field_index]) |column_index| {
                    const raw_value = if (column_index < row.values.len) row.values[column_index] else null;
                    @field(out, field.name) = try decodeTextValue(field.type, raw_value, allocator);
                } else {
                    if (field.defaultValue()) |default_value| {
                        @field(out, field.name) = default_value;
                    } else switch (@typeInfo(field.type)) {
                        .optional => @field(out, field.name) = null,
                        else => return error.MissingColumn,
                    }
                }
            }

            return out;
        }

        fn mapBorrowedTextStruct(self: *const Self, row: Row) !T {
            var out: T = undefined;
            const info = @typeInfo(T).@"struct";

            inline for (info.fields, 0..) |field, field_index| {
                if (self.field_indices[field_index]) |column_index| {
                    const raw_value = if (column_index < row.values.len) row.values[column_index] else null;
                    @field(out, field.name) = try decodeBorrowedTextValue(field.type, raw_value);
                } else {
                    if (field.defaultValue()) |default_value| {
                        @field(out, field.name) = default_value;
                    } else switch (@typeInfo(field.type)) {
                        .optional => @field(out, field.name) = null,
                        else => return error.MissingColumn,
                    }
                }
            }

            return out;
        }

        fn mapBinaryStruct(self: *const Self, values: []const ?BinaryValue, columns: []const Column, allocator: std.mem.Allocator) !T {
            var out: T = undefined;
            const info = @typeInfo(T).@"struct";

            inline for (info.fields, 0..) |field, field_index| {
                if (self.field_indices[field_index]) |column_index| {
                    const raw_value = if (column_index < values.len) values[column_index] else null;
                    const column = if (column_index < columns.len) columns[column_index] else null;
                    @field(out, field.name) = try decodeBinaryValue(field.type, raw_value, column, allocator);
                } else {
                    if (field.defaultValue()) |default_value| {
                        @field(out, field.name) = default_value;
                    } else switch (@typeInfo(field.type)) {
                        .optional => @field(out, field.name) = null,
                        else => return error.MissingColumn,
                    }
                }
            }

            return out;
        }
    };
}

fn decodeBorrowedTextValue(comptime T: type, value: ?[]const u8) !T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const data = value orelse return null;
            return try decodeBorrowedTextValue(optional.child, data);
        },
        else => {},
    }

    const data = value orelse return error.NullValue;
    if (T == Date) return try Date.parse(data);
    if (T == Time) return try Time.parse(data);
    if (T == DateTime) return try DateTime.parse(data);
    if (T == Decimal) return .{ .text = data };
    if (T == Json or T == Blob) return .{ .bytes = data };

    return switch (@typeInfo(T)) {
        .bool => decodeBool(data),
        .int => try std.fmt.parseInt(T, data, 10),
        .float => try std.fmt.parseFloat(T, data),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8 and ptr.is_const)
                data
            else
                @compileError("borrowed MySQL text results require []const u8 slices: " ++ @typeName(T)),
            else => @compileError("unsupported MySQL result type: " ++ @typeName(T)),
        },
        .@"enum" => std.meta.stringToEnum(T, data) orelse error.InvalidEnumValue,
        else => @compileError("unsupported MySQL result type: " ++ @typeName(T)),
    };
}

fn isScalarResultType(comptime T: type) bool {
    return T == Date or T == Time or T == DateTime or T == Decimal or T == Json or T == Blob;
}

fn mapsAsStruct(comptime T: type) bool {
    if (isScalarResultType(T)) return false;
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        else => false,
    };
}

fn decodeTextValue(comptime T: type, value: ?[]const u8, allocator: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const data = value orelse return null;
            return try decodeTextValue(optional.child, data, allocator);
        },
        else => {},
    }

    const data = value orelse return error.NullValue;
    if (T == Date) return try Date.parse(data);
    if (T == Time) return try Time.parse(data);
    if (T == DateTime) return try DateTime.parse(data);
    if (T == Decimal) return .{ .text = try allocator.dupe(u8, data) };
    if (T == Json) return .{ .bytes = try allocator.dupe(u8, data) };
    if (T == Blob) return .{ .bytes = try allocator.dupe(u8, data) };

    return switch (@typeInfo(T)) {
        .bool => decodeBool(data),
        .int => try std.fmt.parseInt(T, data, 10),
        .float => try std.fmt.parseFloat(T, data),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8)
                try allocator.dupe(u8, data)
            else
                @compileError("unsupported MySQL result type: " ++ @typeName(T)),
            else => @compileError("unsupported MySQL result type: " ++ @typeName(T)),
        },
        .@"enum" => std.meta.stringToEnum(T, data) orelse error.InvalidEnumValue,
        else => @compileError("unsupported MySQL result type: " ++ @typeName(T)),
    };
}

fn decodeBinaryValue(comptime T: type, value: ?BinaryValue, column: ?Column, allocator: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const data = value orelse return null;
            return try decodeBinaryValue(optional.child, data, column, allocator);
        },
        else => {},
    }

    const data = value orelse return error.NullValue;
    if (T == Date) return binaryDate(data);
    if (T == Time) return binaryTime(data);
    if (T == DateTime) return binaryDateTime(data);
    if (T == Decimal) return .{ .text = try binaryOwnedText(allocator, data) };
    if (T == Json or T == Blob) return .{ .bytes = try binaryOwnedText(allocator, data) };

    return switch (@typeInfo(T)) {
        .bool => binaryBool(data),
        .int => try binaryInt(T, data),
        .float => try binaryFloat(T, data),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8)
                try binaryOwnedText(allocator, data)
            else
                @compileError("unsupported MySQL result type: " ++ @typeName(T)),
            else => @compileError("unsupported MySQL result type: " ++ @typeName(T)),
        },
        .@"enum" => switch (data) {
            .bytes => |bytes| std.meta.stringToEnum(T, bytes) orelse error.InvalidEnumValue,
            else => error.InvalidEnumValue,
        },
        else => @compileError("unsupported MySQL result type: " ++ @typeName(T)),
    };
}

fn decodeBool(data: []const u8) bool {
    return std.mem.eql(u8, data, "1") or
        std.ascii.eqlIgnoreCase(data, "true") or
        std.ascii.eqlIgnoreCase(data, "yes") or
        std.ascii.eqlIgnoreCase(data, "on");
}

fn binaryBool(value: BinaryValue) bool {
    return switch (value) {
        .signed => |number| number != 0,
        .unsigned => |number| number != 0,
        .float => |number| number != 0,
        .double => |number| number != 0,
        .bytes => |bytes| decodeBool(bytes),
        else => true,
    };
}

fn binaryInt(comptime T: type, value: BinaryValue) !T {
    return switch (value) {
        .signed => |number| std.math.cast(T, number) orelse error.IntegerOverflow,
        .unsigned => |number| std.math.cast(T, number) orelse error.IntegerOverflow,
        .float => |number| std.math.cast(T, @as(i64, @intFromFloat(number))) orelse error.IntegerOverflow,
        .double => |number| std.math.cast(T, @as(i64, @intFromFloat(number))) orelse error.IntegerOverflow,
        .bytes => |bytes| try std.fmt.parseInt(T, bytes, 10),
        else => error.InvalidInteger,
    };
}

fn binaryFloat(comptime T: type, value: BinaryValue) !T {
    return switch (value) {
        .signed => |number| @as(T, @floatFromInt(number)),
        .unsigned => |number| @as(T, @floatFromInt(number)),
        .float => |number| @as(T, @floatCast(number)),
        .double => |number| @as(T, @floatCast(number)),
        .bytes => |bytes| try std.fmt.parseFloat(T, bytes),
        else => error.InvalidFloat,
    };
}

fn binaryDate(value: BinaryValue) !Date {
    return switch (value) {
        .date => |date| date,
        .datetime => |datetime| .{ .year = datetime.year, .month = datetime.month, .day = datetime.day },
        .bytes => |bytes| try Date.parse(bytes),
        else => error.InvalidDate,
    };
}

fn binaryTime(value: BinaryValue) !Time {
    return switch (value) {
        .time => |time| time,
        .bytes => |bytes| try Time.parse(bytes),
        else => error.InvalidTime,
    };
}

fn binaryDateTime(value: BinaryValue) !DateTime {
    return switch (value) {
        .datetime => |datetime| datetime,
        .date => |date| .{ .year = date.year, .month = date.month, .day = date.day },
        .bytes => |bytes| try DateTime.parse(bytes),
        else => error.InvalidDateTime,
    };
}

fn binaryOwnedText(allocator: std.mem.Allocator, value: BinaryValue) ![]u8 {
    return switch (value) {
        .signed => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .unsigned => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .float => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .double => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .bytes => |bytes| allocator.dupe(u8, bytes),
        .date => |date| formatDateText(allocator, date),
        .datetime => |datetime| formatDateTimeText(allocator, datetime),
        .time => |time| formatTimeText(allocator, time),
    };
}

pub fn deinitMappedRows(comptime T: type, allocator: std.mem.Allocator, rows: []T) void {
    for (rows) |*row| {
        deinitMappedValue(T, allocator, row);
    }
    allocator.free(rows);
}

pub fn deinitMappedValue(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    if (T == Decimal) {
        allocator.free(value.text);
        value.text = "";
        return;
    }
    if (T == Json or T == Blob) {
        allocator.free(value.bytes);
        value.bytes = "";
        return;
    }

    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (value.*) |*child| {
                deinitMappedValue(optional.child, allocator, child);
            }
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) {
                allocator.free(value.*);
                value.* = &.{};
            },
            else => {},
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                deinitMappedValue(field.type, allocator, &@field(value.*, field.name));
            }
        },
        else => {},
    }
}
