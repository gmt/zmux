const file_write = @import("file-write.zig");

test "client write handlers open, write, and close files" {
    try file_write.StressTests.clientWriteHandlersOpenWriteAndCloseFiles();
}
