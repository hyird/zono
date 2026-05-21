const std = @import("std");

const auth = @import("mysql/auth.zig");
const mapper = @import("mysql/mapper.zig");
const prepared = @import("mysql/prepared.zig");
const sql_mod = @import("mysql/sql.zig");
const types_mod = @import("mysql/types.zig");
const wire = @import("mysql/wire.zig");

const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const max_payload_len = wire.max_payload_len;
const Command = wire.Command;
const StoredServerError = types_mod.StoredServerError;

pub const Config = types_mod.Config;
pub const ExecResult = types_mod.ExecResult;
pub const ServerError = types_mod.ServerError;
pub const ErrorDetail = types_mod.ErrorDetail;
pub const Decimal = types_mod.Decimal;
pub const Json = types_mod.Json;
pub const Blob = types_mod.Blob;
pub const Date = types_mod.Date;
pub const Time = types_mod.Time;
pub const DateTime = types_mod.DateTime;
pub const Timestamp = types_mod.Timestamp;
pub const FieldType = types_mod.FieldType;
pub const Column = types_mod.Column;
pub const Row = types_mod.Row;
pub const ResultSet = types_mod.ResultSet;
pub const formatQuery = sql_mod.formatQuery;

const cloneConfig = types_mod.cloneConfig;
const deinitConfig = types_mod.deinitConfig;
const deinitColumns = types_mod.deinitColumns;
const deinitRows = types_mod.deinitRows;
const deinitRow = types_mod.deinitRow;
const parseAuthSwitch = auth.parseAuthSwitch;
const buildAuthResponse = auth.buildAuthResponse;
const mysqlNativePassword = auth.mysqlNativePassword;
const cachingSha2Password = auth.cachingSha2Password;
const parseOkPacket = wire.parseOkPacket;
const parseServerErrorPacket = wire.parseServerErrorPacket;
const parseColumnDefinition = wire.parseColumnDefinition;
const parseTextRow = wire.parseTextRow;
const parseTextRowInto = wire.parseTextRowInto;
const parseBinaryTextRow = wire.parseBinaryTextRow;
const parseBinaryValuesInto = wire.parseBinaryValuesInto;
const isEofPacket = wire.isEofPacket;
const readLengthEncodedInteger = wire.readLengthEncodedInteger;
const appendInt = wire.appendInt;
const BinaryValue = wire.BinaryValue;
const formatQueryMaybe = sql_mod.formatQueryMaybe;
const buildPreparedExecutePayloadInto = prepared.buildPreparedExecutePayloadInto;
const RowMapper = mapper.RowMapper;
const deinitMappedRows = mapper.deinitMappedRows;
const deinitMappedValue = mapper.deinitMappedValue;
const ClientFlags = struct {
    const long_password: u32 = 1 << 0;
    const long_flag: u32 = 1 << 2;
    const connect_with_db: u32 = 1 << 3;
    const protocol_41: u32 = 1 << 9;
    const transactions: u32 = 1 << 13;
    const secure_connection: u32 = 1 << 15;
    const multi_results: u32 = 1 << 17;
    const plugin_auth: u32 = 1 << 19;
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    write_scratch: std.ArrayListUnmanaged(u8) = .empty,
    sequence_id: u8 = 0,
    max_packet_size: usize,
    last_error: ?StoredServerError = null,
    /// Pool-owned connections are repaired before reuse after transport/protocol failures.
    broken: bool = false,

    pub fn connect(allocator: std.mem.Allocator, io: Io, config: Config) !Connection {
        const read_buf = try allocator.alloc(u8, config.read_buffer_size);
        errdefer allocator.free(read_buf);

        const write_buf = try allocator.alloc(u8, config.write_buffer_size);
        errdefer allocator.free(write_buf);

        const stream = try connectToHost(io, config.host, config.port);
        errdefer stream.close(io);

        var self: Connection = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader = undefined,
            .writer = undefined,
            .max_packet_size = config.max_packet_size,
        };
        self.reader = Io.net.Stream.Reader.init(stream, io, read_buf);
        self.writer = Io.net.Stream.Writer.init(stream, io, write_buf);
        try self.handshake(config);
        return self;
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        self.write_scratch.deinit(self.allocator);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.* = undefined;
    }

    pub fn execute(self: *Connection, sql: []const u8, params: anytype) !ExecResult {
        const rendered = try formatQueryMaybe(self.allocator, sql, params);
        defer rendered.deinit(self.allocator);
        return self.executeSql(rendered.sql);
    }

    pub fn executeVoid(self: *Connection, sql: []const u8, params: anytype) !void {
        const rendered = try formatQueryMaybe(self.allocator, sql, params);
        defer rendered.deinit(self.allocator);
        return self.execSql(rendered.sql);
    }

    pub fn queryRows(self: *Connection, sql: []const u8, params: anytype) !ResultSet {
        return self.queryRowsAlloc(self.allocator, sql, params);
    }

    pub fn queryRowsAlloc(self: *Connection, allocator: std.mem.Allocator, sql: []const u8, params: anytype) !ResultSet {
        const rendered = try formatQueryMaybe(allocator, sql, params);
        defer rendered.deinit(allocator);
        return self.queryRowsSql(allocator, rendered.sql);
    }

    pub fn queryAll(self: *Connection, comptime T: type, sql: []const u8, params: anytype) ![]T {
        return self.queryAllAlloc(T, self.allocator, sql, params);
    }

    pub fn queryAllAlloc(self: *Connection, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype) ![]T {
        const rendered = try formatQueryMaybe(allocator, sql, params);
        defer rendered.deinit(allocator);
        return self.queryAllSql(T, allocator, rendered.sql);
    }

    pub fn queryOne(self: *Connection, comptime T: type, sql: []const u8, params: anytype) !?T {
        return self.queryOneAlloc(T, self.allocator, sql, params);
    }

    pub fn queryOneAlloc(self: *Connection, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype) !?T {
        const rendered = try formatQueryMaybe(allocator, sql, params);
        defer rendered.deinit(allocator);
        return self.queryOneSql(T, allocator, rendered.sql);
    }

    pub fn deinitValue(self: *Connection, comptime T: type, value: *T) void {
        deinitMappedValue(T, self.allocator, value);
    }

    pub fn deinitAll(self: *Connection, comptime T: type, rows: []T) void {
        deinitMappedRows(T, self.allocator, rows);
    }

    pub fn forEach(self: *Connection, comptime T: type, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        return self.forEachAlloc(T, self.allocator, sql, params, context, callback);
    }

    pub fn forEachAlloc(self: *Connection, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        const rendered = try formatQueryMaybe(allocator, sql, params);
        defer rendered.deinit(allocator);
        return self.forEachSql(allocator, T, rendered.sql, context, callback);
    }

    pub fn forEachRow(self: *Connection, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        return self.forEachRowAlloc(self.allocator, sql, params, context, callback);
    }

    pub fn forEachRowAlloc(self: *Connection, allocator: std.mem.Allocator, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        const rendered = try formatQueryMaybe(allocator, sql, params);
        defer rendered.deinit(allocator);
        return self.forEachRowSql(allocator, rendered.sql, context, callback);
    }

    pub fn lastError(self: *const Connection) ?ServerError {
        if (self.last_error) |*stored| return stored.view();
        return null;
    }

    pub fn errorDetail(self: *const Connection, err: anyerror) ErrorDetail {
        return .{
            .err = err,
            .server = if (err == error.ServerError) self.lastError() else null,
        };
    }

    pub fn prepare(self: *Connection, sql: []const u8) !Statement {
        self.last_error = null;
        try self.writeCommand(.stmt_prepare, sql);
        const packet = try self.readPacket(self.allocator);
        defer self.allocator.free(packet);
        if (packet.len == 0) return error.ProtocolError;
        if (packet[0] == 0xff) return self.serverError(packet);
        if (packet[0] != 0x00) return error.UnexpectedPacket;

        var reader = Io.Reader.fixed(packet[1..]);
        const statement_id = try reader.takeInt(u32, .little);
        const column_count = @as(usize, try reader.takeInt(u16, .little));
        const param_count = @as(usize, try reader.takeInt(u16, .little));
        _ = try reader.takeByte();
        _ = if (reader.bufferedLen() >= 2) try reader.takeInt(u16, .little) else 0;

        try self.readDefinitionsAndDiscard(param_count);
        try self.readDefinitionsAndDiscard(column_count);

        return .{
            .conn = self,
            .id = statement_id,
            .param_count = param_count,
            .column_count = column_count,
        };
    }

    pub fn transaction(self: *Connection) !Transaction {
        try self.execSql("START TRANSACTION");
        return .{ .conn = self };
    }

    pub fn transact(self: *Connection, context: anytype, callback: anytype) !void {
        var tx = try self.transaction();
        errdefer tx.deinit();

        try callback(context, &tx);
        try tx.commit();
    }

    pub fn ping(self: *Connection) !void {
        self.last_error = null;
        try self.writeCommand(.ping, "");
        const packet = try self.readPacket(self.allocator);
        defer self.allocator.free(packet);
        try self.expectOk(packet);
    }

    pub fn reset(self: *Connection) !void {
        self.last_error = null;
        try self.writeCommand(.reset_connection, "");
        const packet = try self.readPacket(self.allocator);
        defer self.allocator.free(packet);
        try self.expectOk(packet);
    }

    fn handshake(self: *Connection, config: Config) !void {
        const payload = try self.readPacket(self.allocator);
        defer self.allocator.free(payload);
        if (payload.len == 0) return error.ProtocolError;

        var reader = Io.Reader.fixed(payload);
        const protocol_version = try reader.takeByte();
        if (protocol_version != 10) return error.UnsupportedProtocol;

        _ = try reader.takeSentinel(0); // server version
        _ = try reader.takeInt(u32, .little); // connection id

        const part1 = try reader.take(8);
        _ = try reader.takeByte(); // filler

        const cap_low = try reader.takeInt(u16, .little);
        _ = try reader.takeByte(); // character set
        _ = try reader.takeInt(u16, .little); // status flags
        const cap_high = try reader.takeInt(u16, .little);
        const capabilities = (@as(u32, cap_high) << 16) | cap_low;

        const auth_plugin_data_len = try reader.takeByte();
        _ = try reader.take(10); // reserved

        const part2_len = if ((capabilities & ClientFlags.plugin_auth) != 0)
            @max(@as(usize, 13), @as(usize, auth_plugin_data_len) -| 8)
        else
            @as(usize, 12);
        const part2 = try reader.take(@min(part2_len, reader.bufferedLen()));

        const plugin_name = if ((capabilities & ClientFlags.plugin_auth) != 0 and reader.bufferedLen() > 0)
            reader.takeSentinel(0) catch "mysql_native_password"
        else
            "mysql_native_password";

        var seed_buf: [64]u8 = undefined;
        var seed_len: usize = 0;
        @memcpy(seed_buf[0..part1.len], part1);
        seed_len += part1.len;
        const clean_part2_len = if (part2.len > 0 and part2[part2.len - 1] == 0) part2.len - 1 else part2.len;
        @memcpy(seed_buf[seed_len .. seed_len + clean_part2_len], part2[0..clean_part2_len]);
        seed_len += clean_part2_len;
        const seed = seed_buf[0..@min(seed_len, 20)];

        try self.writeHandshakeResponse(config, seed, plugin_name);
        try self.finishAuthentication(config.password);
    }

    fn writeHandshakeResponse(self: *Connection, config: Config, seed: []const u8, plugin_name: []const u8) !void {
        var auth_response: [Sha256.digest_length]u8 = undefined;
        const auth_response_len = try buildAuthResponse(plugin_name, config.password, seed, &auth_response);

        var flags: u32 = ClientFlags.long_password |
            ClientFlags.long_flag |
            ClientFlags.protocol_41 |
            ClientFlags.transactions |
            ClientFlags.secure_connection |
            ClientFlags.multi_results |
            ClientFlags.plugin_auth;
        if (config.database.len > 0) flags |= ClientFlags.connect_with_db;

        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.allocator);

        try appendInt(u32, self.allocator, &payload, flags);
        try appendInt(u32, self.allocator, &payload, @as(u32, @intCast(@min(self.max_packet_size, std.math.maxInt(u32)))));
        try payload.append(self.allocator, 45); // utf8mb4_general_ci
        try payload.appendNTimes(self.allocator, 0, 23);
        try payload.appendSlice(self.allocator, config.user);
        try payload.append(self.allocator, 0);
        try payload.append(self.allocator, @as(u8, @intCast(auth_response_len)));
        try payload.appendSlice(self.allocator, auth_response[0..auth_response_len]);
        if (config.database.len > 0) {
            try payload.appendSlice(self.allocator, config.database);
            try payload.append(self.allocator, 0);
        }
        try payload.appendSlice(self.allocator, plugin_name);
        try payload.append(self.allocator, 0);

        self.sequence_id = 1;
        try self.writePacket(payload.items);
    }

    fn finishAuthentication(self: *Connection, password: []const u8) !void {
        var packet = try self.readPacket(self.allocator);

        while (true) {
            if (packet.len == 0) {
                self.allocator.free(packet);
                return error.ProtocolError;
            }
            switch (packet[0]) {
                0x00 => {
                    self.allocator.free(packet);
                    return;
                },
                0xff => {
                    self.last_error = parseServerErrorPacket(packet) catch null;
                    self.allocator.free(packet);
                    return error.ServerError;
                },
                0xfe => {
                    const auth_switch = parseAuthSwitch(packet) catch |err| {
                        self.allocator.free(packet);
                        return err;
                    };
                    var auth_response: [Sha256.digest_length]u8 = undefined;
                    const auth_response_len = buildAuthResponse(auth_switch.plugin_name, password, auth_switch.seed, &auth_response) catch |err| {
                        self.allocator.free(packet);
                        return err;
                    };
                    self.writePacket(auth_response[0..auth_response_len]) catch |err| {
                        self.allocator.free(packet);
                        return err;
                    };
                    self.allocator.free(packet);
                    packet = try self.readPacket(self.allocator);
                },
                0x01 => {
                    if (packet.len < 2) {
                        self.allocator.free(packet);
                        return error.ProtocolError;
                    }
                    switch (packet[1]) {
                        0x03 => {
                            self.allocator.free(packet);
                            packet = try self.readPacket(self.allocator);
                        },
                        0x04 => {
                            self.allocator.free(packet);
                            return error.FullAuthenticationRequiresTls;
                        },
                        else => {
                            self.allocator.free(packet);
                            return error.UnsupportedAuthentication;
                        },
                    }
                },
                else => {
                    self.allocator.free(packet);
                    return error.UnexpectedPacket;
                },
            }
        }
    }

    fn execSql(self: *Connection, sql: []const u8) !void {
        self.last_error = null;
        try self.writeCommand(.query, sql);
        const packet = try self.readPacket(self.allocator);
        defer self.allocator.free(packet);
        if (packet.len == 0) return error.ProtocolError;
        return self.expectOkPacket(packet);
    }

    fn executeSql(self: *Connection, sql: []const u8) !ExecResult {
        self.last_error = null;
        try self.writeCommand(.query, sql);
        const packet = try self.readPacket(self.allocator);
        defer self.allocator.free(packet);
        if (packet.len == 0) return error.ProtocolError;
        return switch (packet[0]) {
            0x00 => try parseOkPacket(packet),
            0xff => self.serverError(packet),
            0xfb => error.LocalInfileUnsupported,
            else => {
                try self.drainResultSet(packet);
                return error.ExpectedOkPacket;
            },
        };
    }

    fn queryRowsSql(self: *Connection, allocator: std.mem.Allocator, sql: []const u8) !ResultSet {
        self.last_error = null;
        try self.writeCommand(.query, sql);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseResultSetAfterFirst(allocator, first_packet, .text);
    }

    fn queryAllSql(self: *Connection, comptime T: type, allocator: std.mem.Allocator, sql: []const u8) ![]T {
        self.last_error = null;
        try self.writeCommand(.query, sql);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseAllAfterFirst(allocator, first_packet, .text, T);
    }

    fn forEachSql(self: *Connection, allocator: std.mem.Allocator, comptime T: type, sql: []const u8, context: anytype, callback: anytype) !void {
        self.last_error = null;
        try self.writeCommand(.query, sql);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseEachAfterFirst(allocator, first_packet, .text, T, context, callback);
    }

    fn forEachRowSql(self: *Connection, allocator: std.mem.Allocator, sql: []const u8, context: anytype, callback: anytype) !void {
        self.last_error = null;
        try self.writeCommand(.query, sql);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseEachRowAfterFirst(allocator, first_packet, .text, context, callback);
    }

    fn queryOneSql(self: *Connection, comptime T: type, allocator: std.mem.Allocator, sql: []const u8) !?T {
        self.last_error = null;
        try self.writeCommand(.query, sql);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseOneAfterFirst(allocator, first_packet, .text, T);
    }

    fn execPrepared(self: *Connection, stmt_id: u32, param_count: usize, params: anytype) !void {
        self.last_error = null;
        try self.writePreparedExecute(stmt_id, param_count, params);
        const packet = try self.readPacket(self.allocator);
        defer self.allocator.free(packet);
        if (packet.len == 0) return error.ProtocolError;
        return self.expectOkPacket(packet);
    }

    fn execPreparedResult(self: *Connection, stmt_id: u32, param_count: usize, params: anytype) !ExecResult {
        self.last_error = null;
        try self.writePreparedExecute(stmt_id, param_count, params);
        const packet = try self.readPacket(self.allocator);
        defer self.allocator.free(packet);
        if (packet.len == 0) return error.ProtocolError;
        return switch (packet[0]) {
            0x00 => try parseOkPacket(packet),
            0xff => self.serverError(packet),
            0xfb => error.LocalInfileUnsupported,
            else => {
                try self.drainResultSet(packet);
                return error.ExpectedOkPacket;
            },
        };
    }

    fn expectOkPacket(self: *Connection, packet: []const u8) !void {
        if (packet.len == 0) return error.ProtocolError;
        return switch (packet[0]) {
            0x00 => {},
            0xff => self.serverError(packet),
            0xfb => error.LocalInfileUnsupported,
            else => {
                try self.drainResultSet(packet);
                return error.ExpectedOkPacket;
            },
        };
    }

    fn queryPreparedRows(self: *Connection, allocator: std.mem.Allocator, stmt_id: u32, param_count: usize, params: anytype) !ResultSet {
        self.last_error = null;
        try self.writePreparedExecute(stmt_id, param_count, params);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseResultSetAfterFirst(allocator, first_packet, .binary);
    }

    fn queryPreparedAll(self: *Connection, comptime T: type, allocator: std.mem.Allocator, stmt_id: u32, param_count: usize, params: anytype) ![]T {
        self.last_error = null;
        try self.writePreparedExecute(stmt_id, param_count, params);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseAllAfterFirst(allocator, first_packet, .binary, T);
    }

    fn queryPreparedEach(self: *Connection, allocator: std.mem.Allocator, comptime T: type, stmt_id: u32, param_count: usize, params: anytype, context: anytype, callback: anytype) !void {
        self.last_error = null;
        try self.writePreparedExecute(stmt_id, param_count, params);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseEachAfterFirst(allocator, first_packet, .binary, T, context, callback);
    }

    fn forEachPreparedRow(self: *Connection, allocator: std.mem.Allocator, stmt_id: u32, param_count: usize, params: anytype, context: anytype, callback: anytype) !void {
        self.last_error = null;
        try self.writePreparedExecute(stmt_id, param_count, params);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseEachRowAfterFirst(allocator, first_packet, .binary, context, callback);
    }

    fn queryPreparedOne(self: *Connection, comptime T: type, allocator: std.mem.Allocator, stmt_id: u32, param_count: usize, params: anytype) !?T {
        self.last_error = null;
        try self.writePreparedExecute(stmt_id, param_count, params);
        const first_packet = try self.readPacket(allocator);
        defer allocator.free(first_packet);
        return self.parseOneAfterFirst(allocator, first_packet, .binary, T);
    }

    const RowProtocol = enum { text, binary };

    fn parseResultSetAfterFirst(self: *Connection, allocator: std.mem.Allocator, first_packet: []const u8, row_protocol: RowProtocol) !ResultSet {
        if (first_packet.len == 0) return error.ProtocolError;

        switch (first_packet[0]) {
            0x00 => return .{ .allocator = allocator },
            0xff => return self.serverError(first_packet),
            0xfb => return error.LocalInfileUnsupported,
            else => {},
        }

        var header_reader = Io.Reader.fixed(first_packet);
        const column_count = std.math.cast(usize, try readLengthEncodedInteger(&header_reader)) orelse return error.PacketTooLarge;

        var columns: std.ArrayListUnmanaged(Column) = .empty;
        var columns_owned = false;
        errdefer if (!columns_owned) {
            deinitColumns(allocator, columns.items);
            columns.deinit(allocator);
        };
        try columns.ensureTotalCapacity(allocator, column_count);

        for (0..column_count) |_| {
            const column_packet = try self.readPacket(allocator);
            defer allocator.free(column_packet);
            try columns.append(allocator, try parseColumnDefinition(allocator, column_packet));
        }

        try self.readEofOrOk(allocator);

        var rows: std.ArrayListUnmanaged(Row) = .empty;
        var rows_owned = false;
        errdefer if (!rows_owned) {
            deinitRows(allocator, rows.items);
            rows.deinit(allocator);
        };

        while (true) {
            const row_packet = try self.readPacket(allocator);
            defer allocator.free(row_packet);
            if (row_packet.len == 0) return error.ProtocolError;
            if (isEofPacket(row_packet)) break;
            if (row_packet[0] == 0xff) return self.serverError(row_packet);
            const row = switch (row_protocol) {
                .text => try parseTextRow(allocator, row_packet, column_count),
                .binary => try parseBinaryTextRow(allocator, row_packet, columns.items),
            };
            try rows.append(allocator, row);
        }

        const owned_columns = try columns.toOwnedSlice(allocator);
        columns_owned = true;
        errdefer {
            deinitColumns(allocator, owned_columns);
            allocator.free(owned_columns);
        }

        const owned_rows = try rows.toOwnedSlice(allocator);
        rows_owned = true;

        return .{
            .allocator = allocator,
            .columns = owned_columns,
            .rows = owned_rows,
        };
    }

    fn parseAllAfterFirst(self: *Connection, allocator: std.mem.Allocator, first_packet: []const u8, row_protocol: RowProtocol, comptime T: type) ![]T {
        if (first_packet.len == 0) return error.ProtocolError;

        switch (first_packet[0]) {
            0x00 => return allocator.alloc(T, 0),
            0xff => return self.serverError(first_packet),
            0xfb => return error.LocalInfileUnsupported,
            else => {},
        }

        var header_reader = Io.Reader.fixed(first_packet);
        const column_count = std.math.cast(usize, try readLengthEncodedInteger(&header_reader)) orelse return error.PacketTooLarge;

        var columns: std.ArrayListUnmanaged(Column) = .empty;
        defer {
            deinitColumns(allocator, columns.items);
            columns.deinit(allocator);
        }
        try columns.ensureTotalCapacity(allocator, column_count);

        for (0..column_count) |_| {
            const column_packet = try self.readPacket(allocator);
            defer allocator.free(column_packet);
            try columns.append(allocator, try parseColumnDefinition(allocator, column_packet));
        }

        try self.readEofOrOk(allocator);

        const result_view = ResultSet{
            .allocator = allocator,
            .columns = columns.items,
            .rows = &.{},
        };
        const row_mapper = RowMapper(T).init(&result_view);

        var text_values: []?[]const u8 = &.{};
        if (row_protocol == .text and column_count != 0) {
            text_values = try allocator.alloc(?[]const u8, column_count);
        }
        defer if (text_values.len != 0) allocator.free(text_values);

        var binary_values: []?BinaryValue = &.{};
        if (row_protocol == .binary and column_count != 0) {
            binary_values = try allocator.alloc(?BinaryValue, column_count);
        }
        defer if (binary_values.len != 0) allocator.free(binary_values);

        var out: std.ArrayListUnmanaged(T) = .empty;
        errdefer {
            for (out.items) |*value| {
                deinitMappedValue(T, allocator, value);
            }
            out.deinit(allocator);
        }

        while (true) {
            const row_packet = try self.readPacket(allocator);
            defer allocator.free(row_packet);
            if (row_packet.len == 0) return error.ProtocolError;
            if (isEofPacket(row_packet)) break;
            if (row_packet[0] == 0xff) return self.serverError(row_packet);

            var value = switch (row_protocol) {
                .text => text: {
                    try parseTextRowInto(text_values, row_packet);
                    const row = Row{ .values = text_values };
                    break :text row_mapper.map(row, allocator);
                },
                .binary => binary: {
                    try parseBinaryValuesInto(binary_values, row_packet, columns.items);
                    break :binary row_mapper.mapBinary(binary_values, columns.items, allocator);
                },
            } catch |err| {
                try self.drainResultRows(allocator);
                return err;
            };
            out.append(allocator, value) catch |err| {
                deinitMappedValue(T, allocator, &value);
                try self.drainResultRows(allocator);
                return err;
            };
        }

        return out.toOwnedSlice(allocator);
    }

    fn parseEachAfterFirst(self: *Connection, allocator: std.mem.Allocator, first_packet: []const u8, row_protocol: RowProtocol, comptime T: type, context: anytype, callback: anytype) !void {
        if (first_packet.len == 0) return error.ProtocolError;

        switch (first_packet[0]) {
            0x00 => return,
            0xff => return self.serverError(first_packet),
            0xfb => return error.LocalInfileUnsupported,
            else => {},
        }

        var header_reader = Io.Reader.fixed(first_packet);
        const column_count = std.math.cast(usize, try readLengthEncodedInteger(&header_reader)) orelse return error.PacketTooLarge;

        var columns: std.ArrayListUnmanaged(Column) = .empty;
        defer {
            deinitColumns(allocator, columns.items);
            columns.deinit(allocator);
        }
        try columns.ensureTotalCapacity(allocator, column_count);

        for (0..column_count) |_| {
            const column_packet = try self.readPacket(allocator);
            defer allocator.free(column_packet);
            try columns.append(allocator, try parseColumnDefinition(allocator, column_packet));
        }

        try self.readEofOrOk(allocator);

        const result_view = ResultSet{
            .allocator = allocator,
            .columns = columns.items,
            .rows = &.{},
        };
        const row_mapper = RowMapper(T).init(&result_view);

        var text_values: []?[]const u8 = &.{};
        if (row_protocol == .text and column_count != 0) {
            text_values = try allocator.alloc(?[]const u8, column_count);
        }
        defer if (text_values.len != 0) allocator.free(text_values);

        var binary_values: []?BinaryValue = &.{};
        if (row_protocol == .binary and column_count != 0) {
            binary_values = try allocator.alloc(?BinaryValue, column_count);
        }
        defer if (binary_values.len != 0) allocator.free(binary_values);

        while (true) {
            const row_packet = try self.readPacket(allocator);
            defer allocator.free(row_packet);
            if (row_packet.len == 0) return error.ProtocolError;
            if (isEofPacket(row_packet)) break;
            if (row_packet[0] == 0xff) return self.serverError(row_packet);

            var value = switch (row_protocol) {
                .text => text: {
                    try parseTextRowInto(text_values, row_packet);
                    const row = Row{ .values = text_values };
                    break :text row_mapper.mapTextBorrowed(row);
                },
                .binary => binary: {
                    try parseBinaryValuesInto(binary_values, row_packet, columns.items);
                    break :binary row_mapper.mapBinary(binary_values, columns.items, allocator);
                },
            } catch |err| {
                try self.drainResultRows(allocator);
                return err;
            };
            defer if (row_protocol == .binary) deinitMappedValue(T, allocator, &value);
            callback(context, value) catch |err| {
                try self.drainResultRows(allocator);
                return err;
            };
        }
    }

    fn parseEachRowAfterFirst(self: *Connection, allocator: std.mem.Allocator, first_packet: []const u8, row_protocol: RowProtocol, context: anytype, callback: anytype) !void {
        if (first_packet.len == 0) return error.ProtocolError;

        switch (first_packet[0]) {
            0x00 => return,
            0xff => return self.serverError(first_packet),
            0xfb => return error.LocalInfileUnsupported,
            else => {},
        }

        var header_reader = Io.Reader.fixed(first_packet);
        const column_count = std.math.cast(usize, try readLengthEncodedInteger(&header_reader)) orelse return error.PacketTooLarge;

        var columns: std.ArrayListUnmanaged(Column) = .empty;
        defer {
            deinitColumns(allocator, columns.items);
            columns.deinit(allocator);
        }
        try columns.ensureTotalCapacity(allocator, column_count);

        for (0..column_count) |_| {
            const column_packet = try self.readPacket(allocator);
            defer allocator.free(column_packet);
            try columns.append(allocator, try parseColumnDefinition(allocator, column_packet));
        }

        try self.readEofOrOk(allocator);

        const result_view = ResultSet{
            .allocator = allocator,
            .columns = columns.items,
            .rows = &.{},
        };

        var text_values: []?[]const u8 = &.{};
        if (row_protocol == .text and column_count != 0) {
            text_values = try allocator.alloc(?[]const u8, column_count);
        }
        defer if (text_values.len != 0) allocator.free(text_values);

        while (true) {
            const row_packet = try self.readPacket(allocator);
            defer allocator.free(row_packet);
            if (row_packet.len == 0) return error.ProtocolError;
            if (isEofPacket(row_packet)) break;
            if (row_packet[0] == 0xff) return self.serverError(row_packet);

            var row_owned = false;
            const row = switch (row_protocol) {
                .text => text: {
                    try parseTextRowInto(text_values, row_packet);
                    break :text Row{ .values = text_values };
                },
                .binary => binary: {
                    row_owned = true;
                    break :binary try parseBinaryTextRow(allocator, row_packet, columns.items);
                },
            };
            defer if (row_owned) deinitRow(allocator, row);

            callback(context, &result_view, row) catch |err| {
                try self.drainResultRows(allocator);
                return err;
            };
        }
    }

    fn parseOneAfterFirst(self: *Connection, allocator: std.mem.Allocator, first_packet: []const u8, row_protocol: RowProtocol, comptime T: type) !?T {
        if (first_packet.len == 0) return error.ProtocolError;

        switch (first_packet[0]) {
            0x00 => return null,
            0xff => return self.serverError(first_packet),
            0xfb => return error.LocalInfileUnsupported,
            else => {},
        }

        var header_reader = Io.Reader.fixed(first_packet);
        const column_count = std.math.cast(usize, try readLengthEncodedInteger(&header_reader)) orelse return error.PacketTooLarge;

        var columns: std.ArrayListUnmanaged(Column) = .empty;
        defer {
            deinitColumns(allocator, columns.items);
            columns.deinit(allocator);
        }
        try columns.ensureTotalCapacity(allocator, column_count);

        for (0..column_count) |_| {
            const column_packet = try self.readPacket(allocator);
            defer allocator.free(column_packet);
            try columns.append(allocator, try parseColumnDefinition(allocator, column_packet));
        }

        try self.readEofOrOk(allocator);

        const result_view = ResultSet{
            .allocator = allocator,
            .columns = columns.items,
            .rows = &.{},
        };
        const row_mapper = RowMapper(T).init(&result_view);

        var text_values: []?[]const u8 = &.{};
        if (row_protocol == .text and column_count != 0) {
            text_values = try allocator.alloc(?[]const u8, column_count);
        }
        defer if (text_values.len != 0) allocator.free(text_values);

        var binary_values: []?BinaryValue = &.{};
        if (row_protocol == .binary and column_count != 0) {
            binary_values = try allocator.alloc(?BinaryValue, column_count);
        }
        defer if (binary_values.len != 0) allocator.free(binary_values);

        while (true) {
            const row_packet = try self.readPacket(allocator);
            defer allocator.free(row_packet);
            if (row_packet.len == 0) return error.ProtocolError;
            if (isEofPacket(row_packet)) break;
            if (row_packet[0] == 0xff) return self.serverError(row_packet);

            var value = switch (row_protocol) {
                .text => text: {
                    try parseTextRowInto(text_values, row_packet);
                    const row = Row{ .values = text_values };
                    break :text row_mapper.map(row, allocator);
                },
                .binary => binary: {
                    try parseBinaryValuesInto(binary_values, row_packet, columns.items);
                    break :binary row_mapper.mapBinary(binary_values, columns.items, allocator);
                },
            } catch |err| {
                try self.drainResultRows(allocator);
                return err;
            };
            errdefer deinitMappedValue(T, allocator, &value);

            try self.drainResultRows(allocator);
            return value;
        }

        return null;
    }

    fn drainResultSet(self: *Connection, first_packet: []const u8) !void {
        var header_reader = Io.Reader.fixed(first_packet);
        const column_count = std.math.cast(usize, try readLengthEncodedInteger(&header_reader)) orelse return error.PacketTooLarge;
        for (0..column_count) |_| {
            const column_packet = try self.readPacket(self.allocator);
            self.allocator.free(column_packet);
        }
        try self.readEofOrOk(self.allocator);
        while (true) {
            const packet = try self.readPacket(self.allocator);
            defer self.allocator.free(packet);
            if (packet.len == 0) return error.ProtocolError;
            if (isEofPacket(packet)) break;
            if (packet[0] == 0xff) return self.serverError(packet);
        }
    }

    fn drainResultRows(self: *Connection, allocator: std.mem.Allocator) !void {
        while (true) {
            const packet = try self.readPacket(allocator);
            defer allocator.free(packet);
            if (packet.len == 0) return error.ProtocolError;
            if (isEofPacket(packet)) return;
            if (packet[0] == 0xff) return self.serverError(packet);
        }
    }

    fn readEofOrOk(self: *Connection, allocator: std.mem.Allocator) !void {
        const packet = try self.readPacket(allocator);
        defer allocator.free(packet);
        if (packet.len == 0) return error.ProtocolError;
        if (packet[0] == 0xff) return self.serverError(packet);
        if (packet[0] == 0x00 or isEofPacket(packet)) return;
        return error.UnexpectedPacket;
    }

    fn readDefinitionsAndDiscard(self: *Connection, count: usize) !void {
        if (count == 0) return;
        for (0..count) |_| {
            const packet = try self.readPacket(self.allocator);
            self.allocator.free(packet);
        }
        try self.readEofOrOk(self.allocator);
    }

    fn writePreparedExecute(self: *Connection, stmt_id: u32, param_count: usize, params: anytype) !void {
        self.last_error = null;
        self.write_scratch.clearRetainingCapacity();
        try buildPreparedExecutePayloadInto(
            self.allocator,
            &self.write_scratch,
            stmt_id,
            param_count,
            params,
        );
        self.sequence_id = 0;
        try self.writePacket(self.write_scratch.items);
    }

    fn writeCommand(self: *Connection, command: Command, payload: []const u8) !void {
        self.last_error = null;
        self.sequence_id = 0;
        if (payload.len + 1 <= max_payload_len) {
            var header: [4]u8 = undefined;
            std.mem.writeInt(u24, header[0..3], @as(u24, @intCast(payload.len + 1)), .little);
            header[3] = self.sequence_id;
            self.sequence_id +%= 1;

            const command_byte = [_]u8{@intFromEnum(command)};
            try self.writer.interface.writeAll(&header);
            try self.writer.interface.writeAll(&command_byte);
            try self.writer.interface.writeAll(payload);
            try self.writer.interface.flush();
            return;
        }

        var packet: std.ArrayListUnmanaged(u8) = .empty;
        defer packet.deinit(self.allocator);
        try packet.append(self.allocator, @intFromEnum(command));
        try packet.appendSlice(self.allocator, payload);
        try self.writePacket(packet.items);
    }

    fn expectOk(self: *Connection, packet: []const u8) !void {
        if (packet.len == 0) return error.ProtocolError;
        return switch (packet[0]) {
            0x00 => {},
            0xff => self.serverError(packet),
            else => error.UnexpectedPacket,
        };
    }

    fn serverError(self: *Connection, packet: []const u8) error{ ServerError, ProtocolError } {
        self.last_error = parseServerErrorPacket(packet) catch return error.ProtocolError;
        return error.ServerError;
    }

    fn readPacket(self: *Connection, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        while (true) {
            var header: [4]u8 = undefined;
            try self.reader.interface.readSliceAll(&header);
            const payload_len = @as(usize, std.mem.readInt(u24, header[0..3], .little));
            if (self.max_packet_size != 0 and out.items.len + payload_len > self.max_packet_size) {
                return error.PacketTooLarge;
            }

            const old_len = out.items.len;
            try out.resize(allocator, old_len + payload_len);
            try self.reader.interface.readSliceAll(out.items[old_len..]);
            if (payload_len < max_payload_len) break;
        }

        return out.toOwnedSlice(allocator);
    }

    fn writePacket(self: *Connection, payload: []const u8) !void {
        var offset: usize = 0;
        while (true) {
            const remaining = payload[offset..];
            const chunk_len = @min(remaining.len, max_payload_len);

            var header: [4]u8 = undefined;
            std.mem.writeInt(u24, header[0..3], @as(u24, @intCast(chunk_len)), .little);
            header[3] = self.sequence_id;
            self.sequence_id +%= 1;

            try self.writer.interface.writeAll(&header);
            try self.writer.interface.writeAll(remaining[0..chunk_len]);

            offset += chunk_len;
            if (chunk_len < max_payload_len) break;
        }
        try self.writer.interface.flush();
    }
};

pub const Statement = struct {
    conn: *Connection,
    pool: ?*Pool = null,
    error_pool: ?*Pool = null,
    id: u32,
    param_count: usize,
    column_count: usize = 0,
    closed: bool = false,

    pub fn execute(self: *Statement, params: anytype) !ExecResult {
        if (self.closed) return error.StatementClosed;
        self.clearPoolError();
        return self.conn.execPreparedResult(self.id, self.param_count, params) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn executeVoid(self: *Statement, params: anytype) !void {
        if (self.closed) return error.StatementClosed;
        self.clearPoolError();
        return self.conn.execPrepared(self.id, self.param_count, params) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn queryRows(self: *Statement, params: anytype) !ResultSet {
        return self.queryRowsAlloc(self.resultAllocator(), params);
    }

    pub fn queryRowsAlloc(self: *Statement, allocator: std.mem.Allocator, params: anytype) !ResultSet {
        if (self.closed) return error.StatementClosed;
        self.clearPoolError();
        return self.conn.queryPreparedRows(allocator, self.id, self.param_count, params) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn queryAll(self: *Statement, comptime T: type, params: anytype) ![]T {
        return self.queryAllAlloc(T, self.resultAllocator(), params);
    }

    pub fn queryAllAlloc(self: *Statement, comptime T: type, allocator: std.mem.Allocator, params: anytype) ![]T {
        if (self.closed) return error.StatementClosed;
        self.clearPoolError();
        return self.conn.queryPreparedAll(T, allocator, self.id, self.param_count, params) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn queryOne(self: *Statement, comptime T: type, params: anytype) !?T {
        return self.queryOneAlloc(T, self.resultAllocator(), params);
    }

    pub fn queryOneAlloc(self: *Statement, comptime T: type, allocator: std.mem.Allocator, params: anytype) !?T {
        if (self.closed) return error.StatementClosed;
        self.clearPoolError();
        return self.conn.queryPreparedOne(T, allocator, self.id, self.param_count, params) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn deinitValue(self: *Statement, comptime T: type, value: *T) void {
        deinitMappedValue(T, self.resultAllocator(), value);
    }

    pub fn deinitAll(self: *Statement, comptime T: type, rows: []T) void {
        deinitMappedRows(T, self.resultAllocator(), rows);
    }

    pub fn forEach(self: *Statement, comptime T: type, params: anytype, context: anytype, callback: anytype) !void {
        return self.forEachAlloc(T, self.resultAllocator(), params, context, callback);
    }

    pub fn forEachAlloc(self: *Statement, comptime T: type, allocator: std.mem.Allocator, params: anytype, context: anytype, callback: anytype) !void {
        if (self.closed) return error.StatementClosed;
        self.clearPoolError();
        return self.conn.queryPreparedEach(allocator, T, self.id, self.param_count, params, context, callback) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn forEachRow(self: *Statement, params: anytype, context: anytype, callback: anytype) !void {
        return self.forEachRowAlloc(self.resultAllocator(), params, context, callback);
    }

    pub fn forEachRowAlloc(self: *Statement, allocator: std.mem.Allocator, params: anytype, context: anytype, callback: anytype) !void {
        if (self.closed) return error.StatementClosed;
        self.clearPoolError();
        return self.conn.forEachPreparedRow(allocator, self.id, self.param_count, params, context, callback) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn lastError(self: *const Statement) ?ServerError {
        return self.conn.lastError();
    }

    pub fn errorDetail(self: *const Statement, err: anyerror) ErrorDetail {
        return self.conn.errorDetail(err);
    }

    pub fn close(self: *Statement) !void {
        if (self.closed) return;
        self.closed = true;
        const pool = self.pool;
        self.pool = null;
        defer if (pool) |p| p.release(self.conn);

        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.conn.allocator);
        try appendInt(u32, self.conn.allocator, &payload, self.id);
        self.conn.writeCommand(.stmt_close, payload.items) catch |err| {
            recordMysqlConnectionError(self.conn, self.error_pool, err);
            return err;
        };
    }

    pub fn deinit(self: *Statement) void {
        self.close() catch {};
    }

    fn resultAllocator(self: *Statement) std.mem.Allocator {
        if (self.pool) |pool| return pool.allocator;
        return self.conn.allocator;
    }

    fn clearPoolError(self: *Statement) void {
        if (self.error_pool) |pool| pool.last_error = null;
    }

    fn rememberServerError(self: *Statement, err: anyerror) void {
        recordMysqlConnectionError(self.conn, self.error_pool, err);
    }
};

pub const Transaction = struct {
    conn: *Connection,
    pool: ?*Pool = null,
    done: bool = false,

    pub fn execute(self: *Transaction, sql: []const u8, params: anytype) !ExecResult {
        if (self.done) return error.TransactionClosed;
        self.clearPoolError();
        return self.conn.execute(sql, params) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn executeVoid(self: *Transaction, sql: []const u8, params: anytype) !void {
        if (self.done) return error.TransactionClosed;
        self.clearPoolError();
        return self.conn.executeVoid(sql, params) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn queryRows(self: *Transaction, sql: []const u8, params: anytype) !ResultSet {
        return self.queryRowsAlloc(self.resultAllocator(), sql, params);
    }

    pub fn queryRowsAlloc(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, params: anytype) !ResultSet {
        if (self.done) return error.TransactionClosed;
        self.clearPoolError();
        return self.conn.queryRowsAlloc(allocator, sql, params) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn queryAll(self: *Transaction, comptime T: type, sql: []const u8, params: anytype) ![]T {
        return self.queryAllAlloc(T, self.resultAllocator(), sql, params);
    }

    pub fn queryAllAlloc(self: *Transaction, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype) ![]T {
        if (self.done) return error.TransactionClosed;
        self.clearPoolError();
        return self.conn.queryAllAlloc(T, allocator, sql, params) catch |err| {
            self.rememberConnectionError(err);
            return err;
        };
    }

    pub fn queryOne(self: *Transaction, comptime T: type, sql: []const u8, params: anytype) !?T {
        return self.queryOneAlloc(T, self.resultAllocator(), sql, params);
    }

    pub fn queryOneAlloc(self: *Transaction, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype) !?T {
        if (self.done) return error.TransactionClosed;
        self.clearPoolError();
        return self.conn.queryOneAlloc(T, allocator, sql, params) catch |err| {
            self.rememberConnectionError(err);
            return err;
        };
    }

    pub fn deinitValue(self: *Transaction, comptime T: type, value: *T) void {
        deinitMappedValue(T, self.resultAllocator(), value);
    }

    pub fn deinitAll(self: *Transaction, comptime T: type, rows: []T) void {
        deinitMappedRows(T, self.resultAllocator(), rows);
    }

    pub fn forEach(self: *Transaction, comptime T: type, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        return self.forEachAlloc(T, self.resultAllocator(), sql, params, context, callback);
    }

    pub fn forEachAlloc(self: *Transaction, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        if (self.done) return error.TransactionClosed;
        self.clearPoolError();
        return self.conn.forEachAlloc(T, allocator, sql, params, context, callback) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn forEachRow(self: *Transaction, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        return self.forEachRowAlloc(self.resultAllocator(), sql, params, context, callback);
    }

    pub fn forEachRowAlloc(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        if (self.done) return error.TransactionClosed;
        self.clearPoolError();
        return self.conn.forEachRowAlloc(allocator, sql, params, context, callback) catch |err| {
            self.rememberServerError(err);
            return err;
        };
    }

    pub fn lastError(self: *const Transaction) ?ServerError {
        return self.conn.lastError();
    }

    pub fn errorDetail(self: *const Transaction, err: anyerror) ErrorDetail {
        return .{
            .err = err,
            .server = if (err == error.ServerError) self.lastError() else null,
        };
    }

    pub fn prepare(self: *Transaction, sql: []const u8) !Statement {
        if (self.done) return error.TransactionClosed;
        self.clearPoolError();
        var stmt = self.conn.prepare(sql) catch |err| {
            self.rememberServerError(err);
            return err;
        };
        stmt.error_pool = self.pool;
        return stmt;
    }

    pub fn commit(self: *Transaction) !void {
        if (self.done) return;
        self.clearPoolError();
        self.conn.execSql("COMMIT") catch |err| {
            self.rememberServerError(err);
            return err;
        };
        self.done = true;
        self.releasePool();
    }

    pub fn rollback(self: *Transaction) !void {
        if (self.done) return;
        self.clearPoolError();
        self.conn.execSql("ROLLBACK") catch |err| {
            self.rememberConnectionError(err);
            return err;
        };
        self.done = true;
        self.releasePool();
    }

    pub fn deinit(self: *Transaction) void {
        if (!self.done) {
            self.conn.execSql("ROLLBACK") catch |err| {
                self.rememberConnectionError(err);
            };
            self.done = true;
        }
        self.releasePool();
    }

    fn releasePool(self: *Transaction) void {
        if (self.pool) |pool| {
            self.pool = null;
            pool.release(self.conn);
        }
    }

    fn clearPoolError(self: *Transaction) void {
        if (self.pool) |pool| pool.last_error = null;
    }

    fn rememberServerError(self: *Transaction, err: anyerror) void {
        self.rememberConnectionError(err);
    }

    fn rememberConnectionError(self: *Transaction, err: anyerror) void {
        recordMysqlConnectionError(self.conn, self.pool, err);
    }

    fn resultAllocator(self: *Transaction) std.mem.Allocator {
        if (self.pool) |pool| return pool.allocator;
        return self.conn.allocator;
    }
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    conns: []*Connection,
    available: std.ArrayListUnmanaged(*Connection) = .empty,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    last_error: ?StoredServerError = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) !Pool {
        var owned_config = try cloneConfig(allocator, config);
        errdefer deinitConfig(allocator, &owned_config);

        const pool_size = @max(config.pool_size, 1);
        const conns = try allocator.alloc(*Connection, pool_size);
        errdefer allocator.free(conns);

        var available: std.ArrayListUnmanaged(*Connection) = .empty;
        errdefer available.deinit(allocator);

        var initialized: usize = 0;
        errdefer {
            for (conns[0..initialized]) |conn| {
                conn.deinit();
                allocator.destroy(conn);
            }
        }

        for (0..pool_size) |i| {
            const conn = try allocator.create(Connection);
            errdefer allocator.destroy(conn);
            conn.* = try Connection.connect(allocator, io, owned_config);
            conns[i] = conn;
            initialized += 1;
            try available.append(allocator, conn);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .config = owned_config,
            .conns = conns,
            .available = available,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.conns) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.allocator.free(self.conns);
        self.available.deinit(self.allocator);
        deinitConfig(self.allocator, &self.config);
        self.* = undefined;
    }

    pub fn tryAcquire(self: *Pool) ?*Connection {
        if (!self.mutex.tryLock()) return null;
        const conn = self.available.pop() orelse {
            self.mutex.unlock(self.io);
            return null;
        };
        self.mutex.unlock(self.io);

        if (!conn.broken) return conn;
        self.reconnect(conn) catch {
            self.release(conn);
            return null;
        };
        return conn;
    }

    pub fn acquire(self: *Pool) !*Connection {
        while (true) {
            try self.mutex.lock(self.io);
            const conn = blk: {
                errdefer self.mutex.unlock(self.io);
                while (self.available.items.len == 0) {
                    try self.cond.wait(self.io, &self.mutex);
                }
                break :blk self.available.pop() orelse return error.NoConnectionsAvailable;
            };
            self.mutex.unlock(self.io);

            if (!conn.broken) return conn;
            self.reconnect(conn) catch |err| {
                self.release(conn);
                return err;
            };
            return conn;
        }
    }

    pub fn release(self: *Pool, conn: *Connection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.available.append(self.allocator, conn) catch {};
        self.cond.signal(self.io);
    }

    pub fn execute(self: *Pool, sql: []const u8, params: anytype) !ExecResult {
        self.last_error = null;
        const conn = try self.acquire();
        defer self.release(conn);
        return conn.execute(sql, params) catch |err| {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            return conn.execute(sql, params) catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
    }

    pub fn executeVoid(self: *Pool, sql: []const u8, params: anytype) !void {
        self.last_error = null;
        const conn = try self.acquire();
        defer self.release(conn);
        return conn.executeVoid(sql, params) catch |err| {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            return conn.executeVoid(sql, params) catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
    }

    pub fn queryRows(self: *Pool, sql: []const u8, params: anytype) !ResultSet {
        return self.queryRowsAlloc(self.allocator, sql, params);
    }

    pub fn queryRowsAlloc(self: *Pool, allocator: std.mem.Allocator, sql: []const u8, params: anytype) !ResultSet {
        self.last_error = null;
        const conn = try self.acquire();
        defer self.release(conn);
        return conn.queryRowsAlloc(allocator, sql, params) catch |err| {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            return conn.queryRowsAlloc(allocator, sql, params) catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
    }

    pub fn queryAll(self: *Pool, comptime T: type, sql: []const u8, params: anytype) ![]T {
        return self.queryAllAlloc(T, self.allocator, sql, params);
    }

    pub fn queryAllAlloc(self: *Pool, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype) ![]T {
        self.last_error = null;
        const conn = try self.acquire();
        defer self.release(conn);
        return conn.queryAllAlloc(T, allocator, sql, params) catch |err| {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            return conn.queryAllAlloc(T, allocator, sql, params) catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
    }

    pub fn queryOne(self: *Pool, comptime T: type, sql: []const u8, params: anytype) !?T {
        return self.queryOneAlloc(T, self.allocator, sql, params);
    }

    pub fn queryOneAlloc(self: *Pool, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype) !?T {
        self.last_error = null;
        const conn = try self.acquire();
        defer self.release(conn);
        return conn.queryOneAlloc(T, allocator, sql, params) catch |err| {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            return conn.queryOneAlloc(T, allocator, sql, params) catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
    }

    pub fn deinitValue(self: *Pool, comptime T: type, value: *T) void {
        deinitMappedValue(T, self.allocator, value);
    }

    pub fn deinitAll(self: *Pool, comptime T: type, rows: []T) void {
        deinitMappedRows(T, self.allocator, rows);
    }

    pub fn forEach(self: *Pool, comptime T: type, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        return self.forEachAlloc(T, self.allocator, sql, params, context, callback);
    }

    pub fn forEachAlloc(self: *Pool, comptime T: type, allocator: std.mem.Allocator, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        self.last_error = null;
        const conn = try self.acquire();
        defer self.release(conn);
        return conn.forEachAlloc(T, allocator, sql, params, context, callback) catch |err| {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            return conn.forEachAlloc(T, allocator, sql, params, context, callback) catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
    }

    pub fn forEachRow(self: *Pool, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        return self.forEachRowAlloc(self.allocator, sql, params, context, callback);
    }

    pub fn forEachRowAlloc(self: *Pool, allocator: std.mem.Allocator, sql: []const u8, params: anytype, context: anytype, callback: anytype) !void {
        self.last_error = null;
        const conn = try self.acquire();
        defer self.release(conn);
        return conn.forEachRowAlloc(allocator, sql, params, context, callback) catch |err| {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            return conn.forEachRowAlloc(allocator, sql, params, context, callback) catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
    }

    pub fn ping(self: *Pool) !void {
        self.last_error = null;
        const conn = try self.acquire();
        defer self.release(conn);
        conn.ping() catch |err| {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            conn.ping() catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
    }

    pub fn prepare(self: *Pool, sql: []const u8) !Statement {
        self.last_error = null;
        const conn = try self.acquire();
        errdefer self.release(conn);
        var stmt = conn.prepare(sql) catch |err| retry: {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            break :retry conn.prepare(sql) catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
        stmt.pool = self;
        stmt.error_pool = self;
        return stmt;
    }

    pub fn transaction(self: *Pool) !Transaction {
        self.last_error = null;
        const conn = try self.acquire();
        errdefer self.release(conn);
        var tx = conn.transaction() catch |err| retry: {
            recordMysqlConnectionError(conn, self, err);
            if (!isReconnectableError(err)) return err;
            try self.reconnect(conn);
            break :retry conn.transaction() catch |retry_err| {
                recordMysqlConnectionError(conn, self, retry_err);
                return retry_err;
            };
        };
        tx.pool = self;
        return tx;
    }

    pub fn transact(self: *Pool, context: anytype, callback: anytype) !void {
        var tx = try self.transaction();
        errdefer tx.deinit();

        try callback(context, &tx);
        try tx.commit();
    }

    pub fn lastError(self: *const Pool) ?ServerError {
        if (self.last_error) |*stored| return stored.view();
        return null;
    }

    pub fn errorDetail(self: *const Pool, err: anyerror) ErrorDetail {
        return .{
            .err = err,
            .server = if (err == error.ServerError) self.lastError() else null,
        };
    }

    fn reconnect(self: *Pool, conn: *Connection) !void {
        const fresh = try Connection.connect(self.allocator, self.io, self.config);
        conn.deinit();
        conn.* = fresh;
    }
};

fn recordMysqlConnectionError(conn: *Connection, pool: ?*Pool, err: anyerror) void {
    if (isReconnectableError(err)) conn.broken = true;
    if (err == error.ServerError) {
        if (pool) |p| p.last_error = conn.last_error;
    }
}

pub fn deinitValueAlloc(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    deinitMappedValue(T, allocator, value);
}

pub fn deinitAllAlloc(comptime T: type, allocator: std.mem.Allocator, rows: []T) void {
    deinitMappedRows(T, allocator, rows);
}

fn connectToHost(io: Io, host: []const u8, port: u16) !Io.net.Stream {
    if (Io.net.IpAddress.parse(host, port)) |address| {
        return address.connect(io, .{ .mode = .stream });
    } else |_| {
        const host_name = try Io.net.HostName.init(host);
        return Io.net.HostName.connect(host_name, io, port, .{ .mode = .stream });
    }
}

fn isReconnectableError(err: anyerror) bool {
    return switch (err) {
        error.EndOfStream,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.ConnectionTimedOut,
        error.ConnectionRefused,
        error.SocketNotConnected,
        error.NetworkUnreachable,
        error.NetworkSubsystemFailed,
        error.HostUnreachable,
        error.HostLacksNetworkAddresses,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.UnexpectedConnectFailure,
        error.OperationAborted,
        error.InputOutput,
        error.ReadFailed,
        error.WriteFailed,
        error.ProtocolError,
        error.UnexpectedPacket,
        => true,
        else => false,
    };
}

test {
    _ = @import("mysql/tests.zig");
}

test "mysql classifies reconnectable errors conservatively" {
    try std.testing.expect(isReconnectableError(error.EndOfStream));
    try std.testing.expect(isReconnectableError(error.ConnectionResetByPeer));
    try std.testing.expect(isReconnectableError(error.ProtocolError));
    try std.testing.expect(!isReconnectableError(error.ServerError));
    try std.testing.expect(!isReconnectableError(error.ParameterCountMismatch));
}

test "mysql records server details and marks broken pooled connections" {
    var stored: StoredServerError = .{
        .code = 1062,
        .sql_state = .{ '2', '3', '0', '0', '0' },
    };
    const message = "Duplicate entry";
    @memcpy(stored.message_buf[0..message.len], message);
    stored.message_len = message.len;

    var conn: Connection = undefined;
    conn.last_error = stored;
    conn.broken = false;

    var pool: Pool = undefined;
    pool.last_error = null;

    recordMysqlConnectionError(&conn, &pool, error.ServerError);
    try std.testing.expect(!conn.broken);
    try std.testing.expectEqual(@as(u16, 1062), pool.lastError().?.code);
    try std.testing.expectEqualStrings(message, pool.lastError().?.message);

    pool.last_error = null;
    recordMysqlConnectionError(&conn, &pool, error.ConnectionResetByPeer);
    try std.testing.expect(conn.broken);
    try std.testing.expectEqual(null, pool.lastError());

    conn.broken = false;
    recordMysqlConnectionError(&conn, &pool, error.ParameterCountMismatch);
    try std.testing.expect(!conn.broken);
}

test "mysql can deinit rendered parameterized queries across modules" {
    const rendered = try formatQueryMaybe(std.testing.allocator, "SELECT ? AS username", .{"alice"});
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("SELECT 'alice' AS username", rendered.sql);
}
