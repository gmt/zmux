const cmd_source_file = @import("cmd-source-file.zig");

test "source-file waits for detached client reads and loads remote content" {
    try cmd_source_file.StressTests.sourceFileWaitsForDetachedClientReadsAndLoadsRemoteContent();
}
