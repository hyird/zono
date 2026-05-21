const std = @import("std");

pub const mysql = @import("mysql.zig");

const sql_client_decls = .{
    "execute",
    "executeVoid",
    "queryRows",
    "queryRowsAlloc",
    "queryAll",
    "queryAllAlloc",
    "queryOne",
    "queryOneAlloc",
    "deinitValue",
    "deinitAll",
    "forEach",
    "forEachAlloc",
    "forEachRow",
    "forEachRowAlloc",
    "prepare",
    "transaction",
    "transact",
    "lastError",
    "errorDetail",
};

const transaction_decls = .{
    "execute",
    "executeVoid",
    "queryRows",
    "queryRowsAlloc",
    "queryAll",
    "queryAllAlloc",
    "queryOne",
    "queryOneAlloc",
    "deinitValue",
    "deinitAll",
    "forEach",
    "forEachAlloc",
    "forEachRow",
    "forEachRowAlloc",
    "prepare",
    "commit",
    "rollback",
    "lastError",
    "errorDetail",
};

const prepared_decls = .{
    "execute",
    "executeVoid",
    "queryRows",
    "queryRowsAlloc",
    "queryAll",
    "queryAllAlloc",
    "queryOne",
    "queryOneAlloc",
    "deinitValue",
    "deinitAll",
    "forEach",
    "forEachAlloc",
    "forEachRow",
    "forEachRowAlloc",
    "lastError",
    "errorDetail",
};

pub fn assertSqlClient(comptime T: type) void {
    requireDecls(T, sql_client_decls);
}

pub fn assertTransaction(comptime T: type) void {
    requireDecls(T, transaction_decls);
}

pub fn assertPrepared(comptime T: type) void {
    requireDecls(T, prepared_decls);
}

fn requireDecls(comptime T: type, comptime decls: anytype) void {
    inline for (decls) |decl| {
        if (!@hasDecl(T, decl)) {
            @compileError(@typeName(T) ++ " is missing db API declaration: " ++ decl);
        }
    }
}

test "mysql types satisfy unified db api" {
    assertSqlClient(mysql.Connection);
    assertSqlClient(mysql.Pool);
    assertTransaction(mysql.Transaction);
    assertPrepared(mysql.Statement);

    try std.testing.expect(@hasDecl(@This(), "mysql"));
}
