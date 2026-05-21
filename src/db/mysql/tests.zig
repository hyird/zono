const std = @import("std");

const auth = @import("auth.zig");
const mapper = @import("mapper.zig");
const prepared = @import("prepared.zig");
const sql_mod = @import("sql.zig");
const types_mod = @import("types.zig");
const wire = @import("wire.zig");

const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Config = types_mod.Config;
const Decimal = types_mod.Decimal;
const Json = types_mod.Json;
const Blob = types_mod.Blob;
const Date = types_mod.Date;
const Time = types_mod.Time;
const DateTime = types_mod.DateTime;
const FieldType = types_mod.FieldType;
const Column = types_mod.Column;
const Row = types_mod.Row;
const ResultSet = types_mod.ResultSet;
const Command = wire.Command;
const cloneConfig = types_mod.cloneConfig;
const deinitConfig = types_mod.deinitConfig;
const deinitRows = types_mod.deinitRows;
const formatQuery = sql_mod.formatQuery;
const parseServerErrorPacket = wire.parseServerErrorPacket;
const parseBinaryTextRow = wire.parseBinaryTextRow;
const parseBinaryValuesInto = wire.parseBinaryValuesInto;
const parseTextRowInto = wire.parseTextRowInto;
const BinaryValue = wire.BinaryValue;
const appendInt = wire.appendInt;
const appendLengthEncodedString = wire.appendLengthEncodedString;
const buildPreparedExecutePayloadInto = prepared.buildPreparedExecutePayloadInto;
const RowMapper = mapper.RowMapper;
const deinitMappedValue = mapper.deinitMappedValue;
const mysqlNativePassword = auth.mysqlNativePassword;
const cachingSha2Password = auth.cachingSha2Password;

fn buildTestPreparedPayload(allocator: std.mem.Allocator, stmt_id: u32, param_count: usize, params: anytype) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try buildPreparedExecutePayloadInto(allocator, &payload, stmt_id, param_count, params);
    return payload.toOwnedSlice(allocator);
}

test "mysql formats escaped query parameters" {
    const testing = std.testing;
    const rendered = try formatQuery(
        testing.allocator,
        "SELECT ?, '?', `?`, ? -- ?\n",
        .{ "O'Reilly\n", @as(?u32, null) },
    );
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("SELECT 'O\\'Reilly\\n', '?', `?`, NULL -- ?\n", rendered);
}

test "mysql rejects mismatched query parameter counts" {
    try std.testing.expectError(
        error.ParameterCountMismatch,
        formatQuery(std.testing.allocator, "SELECT ? + ?", .{1}),
    );
}

test "mysql parses server error packets" {
    const packet = [_]u8{
        0xff,
        0x48,
        0x04,
        '#',
        '4',
        '2',
        'S',
        '0',
        '2',
        'b',
        'a',
        'd',
        ' ',
        's',
        'q',
        'l',
    };

    const stored = try parseServerErrorPacket(&packet);
    const err = stored.view();
    try std.testing.expectEqual(@as(u16, 1096), err.code);
    try std.testing.expectEqualSlices(u8, "42S02", &err.sql_state);
    try std.testing.expectEqualStrings("bad sql", err.message);
    try std.testing.expect(!err.truncated);
}

test "mysql maps decimal json and blob values" {
    const testing = std.testing;

    const rendered = try formatQuery(
        testing.allocator,
        "SELECT ?, ?, ?",
        .{
            Decimal{ .text = "123.4500" },
            Json{ .bytes = "{\"ok\":true}" },
            Blob{ .bytes = "bin\x00data" },
        },
    );
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("SELECT 123.4500, '{\\\"ok\\\":true}', 'bin\\0data'", rendered);
    try testing.expectError(error.InvalidDecimal, formatQuery(testing.allocator, "SELECT ?", .{Decimal{ .text = "1;DROP" }}));

    const scalar_result: ResultSet = .{
        .allocator = testing.allocator,
        .columns = &.{},
        .rows = &.{},
    };
    var scalar_values = [_]?[]const u8{"123.4500"};
    const scalar_row: Row = .{ .values = scalar_values[0..] };

    const decimal_mapper = RowMapper(Decimal).init(&scalar_result);
    var decimal = try decimal_mapper.map(scalar_row, testing.allocator);
    defer deinitMappedValue(Decimal, testing.allocator, &decimal);
    try testing.expectEqualStrings("123.4500", decimal.text);

    scalar_values[0] = "{\"ok\":true}";
    const json_mapper = RowMapper(Json).init(&scalar_result);
    var json = try json_mapper.map(scalar_row, testing.allocator);
    defer deinitMappedValue(Json, testing.allocator, &json);
    try testing.expectEqualStrings("{\"ok\":true}", json.bytes);

    scalar_values[0] = "raw";
    const blob_mapper = RowMapper(Blob).init(&scalar_result);
    var blob = try blob_mapper.map(scalar_row, testing.allocator);
    defer deinitMappedValue(Blob, testing.allocator, &blob);
    try testing.expectEqualStrings("raw", blob.bytes);
}

test "mysql keeps an owned config copy for reconnects" {
    const testing = std.testing;
    const host = "db.local";
    const database = "app";
    const user = "app_user";
    const password = "secret";

    var owned = try cloneConfig(testing.allocator, .{
        .host = host,
        .database = database,
        .user = user,
        .password = password,
        .pool_size = 3,
    });
    defer deinitConfig(testing.allocator, &owned);

    try testing.expectEqualStrings(host, owned.host);
    try testing.expectEqualStrings(database, owned.database);
    try testing.expectEqualStrings(user, owned.user);
    try testing.expectEqualStrings(password, owned.password);
    try testing.expectEqual(@as(usize, 3), owned.pool_size);
    try testing.expect(@intFromPtr(owned.host.ptr) != @intFromPtr(host.ptr));
}

test "mysql maps text rows into structs and scalars" {
    const testing = std.testing;
    var columns = [_]Column{
        .{ .name = "id", .field_type = .long },
        .{ .name = "name", .field_type = .var_string },
        .{ .name = "active", .field_type = .tiny },
        .{ .name = "missing_ok", .field_type = .var_string },
    };
    var values = [_]?[]const u8{ "42", "Ada", "1", null };
    const row: Row = .{ .values = values[0..] };
    const result: ResultSet = .{
        .allocator = testing.allocator,
        .columns = columns[0..],
        .rows = &.{},
    };

    const User = struct {
        id: u32,
        name: []const u8,
        active: bool,
        missing_ok: ?[]const u8,
    };

    const row_mapper = RowMapper(User).init(&result);
    const user = try row_mapper.map(row, testing.allocator);
    defer testing.allocator.free(user.name);
    try testing.expectEqual(@as(u32, 42), user.id);
    try testing.expectEqualStrings("Ada", user.name);
    try testing.expect(user.active);
    try testing.expect(user.missing_ok == null);

    const borrowed_user = try row_mapper.mapTextBorrowed(row);
    try testing.expectEqualStrings("Ada", borrowed_user.name);
    try testing.expectEqual(@intFromPtr(values[1].?.ptr), @intFromPtr(borrowed_user.name.ptr));

    const scalar_mapper = RowMapper(u32).init(&result);
    const id = try scalar_mapper.map(row, testing.allocator);
    try testing.expectEqual(@as(u32, 42), id);
}

test "mysql parses borrowed text row views" {
    const testing = std.testing;

    const packet = [_]u8{ 3, 'A', 'd', 'a', 0xfb };
    var values: [2]?[]const u8 = undefined;
    try parseTextRowInto(values[0..], &packet);

    try testing.expectEqualStrings("Ada", values[0].?);
    try testing.expectEqual(@intFromPtr(packet[1..4].ptr), @intFromPtr(values[0].?.ptr));
    try testing.expect(values[1] == null);
}

test "mysql owning text mapper duplicates packet-backed slices" {
    const testing = std.testing;

    var columns = [_]Column{
        .{ .name = "name", .field_type = .var_string },
        .{ .name = "city", .field_type = .var_string },
    };
    var packet = [_]u8{ 3, 'A', 'd', 'a', 5, 'P', 'a', 'r', 'i', 's' };
    var values: [2]?[]const u8 = undefined;
    try parseTextRowInto(values[0..], packet[0..]);

    const result: ResultSet = .{
        .allocator = testing.allocator,
        .columns = columns[0..],
        .rows = &.{},
    };
    const User = struct {
        name: []const u8,
        city: []const u8,
    };

    const row_mapper = RowMapper(User).init(&result);
    var user = try row_mapper.map(.{ .values = values[0..] }, testing.allocator);
    defer deinitMappedValue(User, testing.allocator, &user);

    try testing.expect(@intFromPtr(user.name.ptr) != @intFromPtr(values[0].?.ptr));
    try testing.expect(@intFromPtr(user.city.ptr) != @intFromPtr(values[1].?.ptr));

    @memset(packet[0..], 0xaa);
    try testing.expectEqualStrings("Ada", user.name);
    try testing.expectEqualStrings("Paris", user.city);
}

test "mysql maps date and time values" {
    const testing = std.testing;

    const rendered = try formatQuery(
        testing.allocator,
        "SELECT ?, ?, ?",
        .{
            Date{ .year = 2026, .month = 5, .day = 20 },
            Time{ .hour = 1, .minute = 2, .second = 3, .microsecond = 4000 },
            DateTime{ .year = 2026, .month = 5, .day = 20, .hour = 9, .minute = 8, .second = 7, .microsecond = 123 },
        },
    );
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("SELECT '2026-05-20', '01:02:03.004000', '2026-05-20 09:08:07.000123'", rendered);

    const date = try Date.parse("2026-05-20");
    try testing.expectEqual(@as(u16, 2026), date.year);
    try testing.expectEqual(@as(u8, 5), date.month);
    try testing.expectEqual(@as(u8, 20), date.day);

    const time = try Time.parse("-2 03:04:05.6");
    try testing.expect(time.negative);
    try testing.expectEqual(@as(u32, 2), time.days);
    try testing.expectEqual(@as(u8, 3), time.hour);
    try testing.expectEqual(@as(u32, 600000), time.microsecond);

    const datetime = try DateTime.parse("2026-05-20 09:08:07.123");
    try testing.expectEqual(@as(u8, 9), datetime.hour);
    try testing.expectEqual(@as(u32, 123000), datetime.microsecond);
}

test "mysql parses binary prepared rows" {
    const testing = std.testing;

    var packet: std.ArrayListUnmanaged(u8) = .empty;
    defer packet.deinit(testing.allocator);

    try packet.append(testing.allocator, 0x00);
    try packet.append(testing.allocator, 0x00);
    try appendInt(u64, testing.allocator, &packet, 42);
    try appendLengthEncodedString(testing.allocator, &packet, "Ada");
    try packet.append(testing.allocator, 11);
    try appendInt(u16, testing.allocator, &packet, 2026);
    try packet.appendSlice(testing.allocator, &.{ 5, 20, 9, 8, 7 });
    try appendInt(u32, testing.allocator, &packet, 123);
    try packet.append(testing.allocator, 12);
    try packet.append(testing.allocator, 1);
    try appendInt(u32, testing.allocator, &packet, 2);
    try packet.appendSlice(testing.allocator, &.{ 3, 4, 5 });
    try appendInt(u32, testing.allocator, &packet, 600);

    const unsigned_flag: u16 = 1 << 5;
    var columns = [_]Column{
        .{ .name = "id", .field_type = .longlong, .flags = unsigned_flag },
        .{ .name = "name", .field_type = .var_string },
        .{ .name = "created_at", .field_type = .datetime },
        .{ .name = "elapsed", .field_type = .time },
    };

    const row = try parseBinaryTextRow(testing.allocator, packet.items, columns[0..]);
    var rows = [_]Row{row};
    defer deinitRows(testing.allocator, rows[0..]);

    try testing.expectEqualStrings("42", row.values[0].?);
    try testing.expectEqualStrings("Ada", row.values[1].?);
    try testing.expectEqualStrings("2026-05-20 09:08:07.000123", row.values[2].?);
    try testing.expectEqualStrings("-2 03:04:05.000600", row.values[3].?);

    var values: [columns.len]?BinaryValue = undefined;
    try parseBinaryValuesInto(values[0..], packet.items, columns[0..]);

    const result: ResultSet = .{
        .allocator = testing.allocator,
        .columns = columns[0..],
        .rows = &.{},
    };
    const User = struct {
        id: u64,
        name: []const u8,
        created_at: DateTime,
        elapsed: Time,
    };
    const row_mapper = RowMapper(User).init(&result);
    var user = try row_mapper.mapBinary(values[0..], columns[0..], testing.allocator);
    defer deinitMappedValue(User, testing.allocator, &user);

    try testing.expectEqual(@as(u64, 42), user.id);
    try testing.expectEqualStrings("Ada", user.name);
    try testing.expectEqual(@as(u32, 123), user.created_at.microsecond);
    try testing.expect(user.elapsed.negative);
    try testing.expectEqual(@as(u32, 600), user.elapsed.microsecond);
}

test "mysql encodes prepared statement parameters" {
    const testing = std.testing;

    const payload = try buildTestPreparedPayload(
        testing.allocator,
        7,
        7,
        .{
            @as(u64, 42),
            "Ada",
            @as(?u8, null),
            Date{ .year = 2026, .month = 5, .day = 20 },
            Decimal{ .text = "12.34" },
            Json{ .bytes = "{\"x\":1}" },
            Blob{ .bytes = "bytes" },
        },
    );
    defer testing.allocator.free(payload);

    try testing.expectEqual(@as(u8, 0b0000_0100), payload[10]);
    try testing.expectEqual(@as(u8, 1), payload[11]);
    try testing.expectEqualSlices(u8, &.{
        @intFromEnum(FieldType.longlong),
        0x80,
        @intFromEnum(FieldType.var_string),
        0x00,
        @intFromEnum(FieldType.null),
        0x00,
        @intFromEnum(FieldType.date),
        0x00,
        @intFromEnum(FieldType.var_string),
        0x00,
        @intFromEnum(FieldType.var_string),
        0x00,
        @intFromEnum(FieldType.blob),
        0x00,
    }, payload[12..26]);
    try testing.expectEqual(@as(usize, 37), payload[26..].len);
}

test "mysql builds prepared execute packets" {
    const testing = std.testing;

    const payload = try buildTestPreparedPayload(
        testing.allocator,
        0x11223344,
        3,
        .{ @as(u64, 42), "Ada", @as(?u8, null) },
    );
    defer testing.allocator.free(payload);

    try testing.expectEqual(@intFromEnum(Command.stmt_execute), payload[0]);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11 }, payload[1..5]);
    try testing.expectEqual(@as(u8, 0), payload[5]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, payload[6..10]);
    try testing.expectEqual(@as(u8, 0b0000_0100), payload[10]);
    try testing.expectEqual(@as(u8, 1), payload[11]);
}

test "mysql auth token lengths" {
    var native_out: [Sha1.digest_length]u8 = undefined;
    mysqlNativePassword("secret", "12345678901234567890", &native_out);

    var sha2_out: [Sha256.digest_length]u8 = undefined;
    cachingSha2Password("secret", "12345678901234567890", &sha2_out);

    try std.testing.expect(!std.mem.allEqual(u8, &native_out, 0));
    try std.testing.expect(!std.mem.allEqual(u8, &sha2_out, 0));
}
