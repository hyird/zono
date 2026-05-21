const std = @import("std");

const server_error_message_max: usize = 1024;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3306,
    database: []const u8 = "",
    user: []const u8 = "root",
    password: []const u8 = "",
    pool_size: usize = 1,
    read_buffer_size: usize = 64 * 1024,
    write_buffer_size: usize = 16 * 1024,
    max_packet_size: usize = 16 * 1024 * 1024,
};

pub fn cloneConfig(allocator: std.mem.Allocator, config: Config) !Config {
    var out = config;
    out.host = try allocator.dupe(u8, config.host);
    errdefer allocator.free(out.host);
    out.database = try allocator.dupe(u8, config.database);
    errdefer allocator.free(out.database);
    out.user = try allocator.dupe(u8, config.user);
    errdefer allocator.free(out.user);
    out.password = try allocator.dupe(u8, config.password);
    return out;
}

pub fn deinitConfig(allocator: std.mem.Allocator, config: *Config) void {
    allocator.free(config.host);
    allocator.free(config.database);
    allocator.free(config.user);
    allocator.free(config.password);
    config.* = undefined;
}

pub const ExecResult = struct {
    affected_rows: u64 = 0,
    last_insert_id: u64 = 0,
    status_flags: u16 = 0,
    warnings: u16 = 0,
    info: []const u8 = "",
};

pub const ServerError = struct {
    code: u16 = 0,
    sql_state: [5]u8 = .{ 'H', 'Y', '0', '0', '0' },
    message: []const u8 = "",
    truncated: bool = false,

    pub fn format(self: ServerError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("mysql {} {s}: {s}", .{
            self.code,
            self.sql_state[0..],
            self.message,
        });
        if (self.truncated) try writer.writeAll("...");
    }
};

pub const ErrorDetail = struct {
    err: anyerror,
    server: ?ServerError = null,

    pub fn hasDetail(self: ErrorDetail) bool {
        return self.server != null;
    }

    pub fn format(self: ErrorDetail, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.server) |server| {
            try writer.print("{s} ({f})", .{ @errorName(self.err), server });
            return;
        }
        try writer.writeAll(@errorName(self.err));
    }
};

pub const StoredServerError = struct {
    code: u16 = 0,
    sql_state: [5]u8 = .{ 'H', 'Y', '0', '0', '0' },
    message_buf: [server_error_message_max]u8 = undefined,
    message_len: usize = 0,
    truncated: bool = false,

    pub fn view(self: *const StoredServerError) ServerError {
        return .{
            .code = self.code,
            .sql_state = self.sql_state,
            .message = self.message_buf[0..self.message_len],
            .truncated = self.truncated,
        };
    }
};

pub const Decimal = struct {
    text: []const u8,
};

pub const Json = struct {
    bytes: []const u8,
};

pub const Blob = struct {
    bytes: []const u8,
};

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn parse(text: []const u8) !Date {
        if (text.len < 10) return error.InvalidDate;
        return .{
            .year = try std.fmt.parseInt(u16, text[0..4], 10),
            .month = try std.fmt.parseInt(u8, text[5..7], 10),
            .day = try std.fmt.parseInt(u8, text[8..10], 10),
        };
    }
};

pub const Time = struct {
    negative: bool = false,
    days: u32 = 0,
    hour: u8,
    minute: u8,
    second: u8,
    microsecond: u32 = 0,

    pub fn parse(text: []const u8) !Time {
        var rest = text;
        var negative = false;
        if (std.mem.startsWith(u8, rest, "-")) {
            negative = true;
            rest = rest[1..];
        }

        var days: u32 = 0;
        if (std.mem.indexOfScalar(u8, rest, ' ')) |space| {
            days = try std.fmt.parseInt(u32, rest[0..space], 10);
            rest = rest[space + 1 ..];
        }

        const micros_start = std.mem.indexOfScalar(u8, rest, '.');
        const hms = if (micros_start) |dot| rest[0..dot] else rest;
        if (hms.len < 8) return error.InvalidTime;

        return .{
            .negative = negative,
            .days = days,
            .hour = try std.fmt.parseInt(u8, hms[0..2], 10),
            .minute = try std.fmt.parseInt(u8, hms[3..5], 10),
            .second = try std.fmt.parseInt(u8, hms[6..8], 10),
            .microsecond = if (micros_start) |dot| try parseMicros(rest[dot + 1 ..]) else 0,
        };
    }
};

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    microsecond: u32 = 0,

    pub fn parse(text: []const u8) !DateTime {
        if (text.len < 10) return error.InvalidDateTime;
        const date = try Date.parse(text[0..10]);
        if (text.len == 10) return .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
        };

        const time_start: usize = if (text[10] == 'T' or text[10] == ' ') 11 else return error.InvalidDateTime;
        const time_part = text[time_start..];
        if (time_part.len < 8) return error.InvalidDateTime;
        const micros_start = std.mem.indexOfScalar(u8, time_part, '.');
        const hms = if (micros_start) |dot| time_part[0..dot] else time_part;

        return .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .hour = try std.fmt.parseInt(u8, hms[0..2], 10),
            .minute = try std.fmt.parseInt(u8, hms[3..5], 10),
            .second = try std.fmt.parseInt(u8, hms[6..8], 10),
            .microsecond = if (micros_start) |dot| try parseMicros(time_part[dot + 1 ..]) else 0,
        };
    }
};

pub const Timestamp = DateTime;

pub const FieldType = enum(u8) {
    decimal = 0x00,
    tiny = 0x01,
    short = 0x02,
    long = 0x03,
    float = 0x04,
    double = 0x05,
    null = 0x06,
    timestamp = 0x07,
    longlong = 0x08,
    int24 = 0x09,
    date = 0x0a,
    time = 0x0b,
    datetime = 0x0c,
    year = 0x0d,
    newdate = 0x0e,
    varchar = 0x0f,
    bit = 0x10,
    timestamp2 = 0x11,
    datetime2 = 0x12,
    time2 = 0x13,
    json = 0xf5,
    newdecimal = 0xf6,
    enum_value = 0xf7,
    set = 0xf8,
    tiny_blob = 0xf9,
    medium_blob = 0xfa,
    long_blob = 0xfb,
    blob = 0xfc,
    var_string = 0xfd,
    string = 0xfe,
    geometry = 0xff,
    _,
};

pub const Column = struct {
    name: []const u8,
    table: []const u8 = "",
    database: []const u8 = "",
    field_type: FieldType = .var_string,
    flags: u16 = 0,
    decimals: u8 = 0,
    length: u32 = 0,

    pub fn unsigned(self: Column) bool {
        return (self.flags & (1 << 5)) != 0;
    }
};

pub const Row = struct {
    values: []?[]const u8,

    pub fn get(self: Row, result: *const ResultSet, name: []const u8) ?[]const u8 {
        const index = result.columnIndex(name) orelse return null;
        if (index >= self.values.len) return null;
        return self.values[index];
    }
};

pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    columns: []Column = &.{},
    rows: []Row = &.{},

    pub fn deinit(self: *ResultSet) void {
        deinitColumns(self.allocator, self.columns);
        self.allocator.free(self.columns);

        deinitRows(self.allocator, self.rows);
        self.allocator.free(self.rows);
        self.* = undefined;
    }

    pub fn columnIndex(self: *const ResultSet, name: []const u8) ?usize {
        for (self.columns, 0..) |column, index| {
            if (std.mem.eql(u8, column.name, name) or std.ascii.eqlIgnoreCase(column.name, name)) {
                return index;
            }
        }
        return null;
    }
};

pub fn deinitColumns(allocator: std.mem.Allocator, columns: []const Column) void {
    for (columns) |column| {
        allocator.free(column.name);
        if (column.table.len > 0) allocator.free(column.table);
        if (column.database.len > 0) allocator.free(column.database);
    }
}

pub fn deinitRows(allocator: std.mem.Allocator, rows: []const Row) void {
    for (rows) |row| {
        deinitRow(allocator, row);
    }
}

pub fn deinitRow(allocator: std.mem.Allocator, row: Row) void {
    for (row.values) |value| {
        if (value) |bytes| allocator.free(bytes);
    }
    allocator.free(row.values);
}

pub fn formatDateText(allocator: std.mem.Allocator, value: Date) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ value.year, value.month, value.day });
}

pub fn formatTimeText(allocator: std.mem.Allocator, value: Time) ![]u8 {
    const sign: []const u8 = if (value.negative) "-" else "";
    if (value.microsecond != 0) {
        if (value.days != 0) {
            return std.fmt.allocPrint(allocator, "{s}{d} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
                sign,
                value.days,
                value.hour,
                value.minute,
                value.second,
                value.microsecond,
            });
        }
        return std.fmt.allocPrint(allocator, "{s}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
            sign,
            value.hour,
            value.minute,
            value.second,
            value.microsecond,
        });
    }

    if (value.days != 0) {
        return std.fmt.allocPrint(allocator, "{s}{d} {d:0>2}:{d:0>2}:{d:0>2}", .{
            sign,
            value.days,
            value.hour,
            value.minute,
            value.second,
        });
    }
    return std.fmt.allocPrint(allocator, "{s}{d:0>2}:{d:0>2}:{d:0>2}", .{
        sign,
        value.hour,
        value.minute,
        value.second,
    });
}

pub fn formatDateTimeText(allocator: std.mem.Allocator, value: DateTime) ![]u8 {
    if (value.microsecond != 0) {
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
            value.year,
            value.month,
            value.day,
            value.hour,
            value.minute,
            value.second,
            value.microsecond,
        });
    }
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        value.year,
        value.month,
        value.day,
        value.hour,
        value.minute,
        value.second,
    });
}

fn parseMicros(text: []const u8) !u32 {
    if (text.len == 0) return 0;

    var micros: u32 = 0;
    var digits: usize = 0;
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return error.InvalidTime;
        if (digits < 6) {
            micros = micros * 10 + @as(u32, ch - '0');
        }
        digits += 1;
    }
    while (digits < 6) : (digits += 1) {
        micros *= 10;
    }
    return micros;
}

test "mysql server errors format with errno sqlstate and message" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.print("{f}", .{ServerError{
        .code = 1146,
        .sql_state = .{ '4', '2', 'S', '0', '2' },
        .message = "Table does not exist",
    }});

    try std.testing.expectEqualStrings("mysql 1146 42S02: Table does not exist", writer.buffered());
}

test "mysql error detail includes server packet details when present" {
    var buffer: [160]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.print("{f}", .{ErrorDetail{
        .err = error.ServerError,
        .server = .{
            .code = 1062,
            .sql_state = .{ '2', '3', '0', '0', '0' },
            .message = "Duplicate entry",
        },
    }});

    try std.testing.expectEqualStrings("ServerError (mysql 1062 23000: Duplicate entry)", writer.buffered());
}
