const cmd_save_buffer = @import("cmd-save-buffer.zig");

test "show-buffer uses the remote write-open handshake for detached clients" {
    try cmd_save_buffer.StressTests.showBufferUsesTheRemoteWriteOpenHandshakeForDetachedClients();
}

test "save-buffer writes detached file paths through write-ready then write-close" {
    try cmd_save_buffer.StressTests.saveBufferWritesDetachedFilePathsThroughWriteReadyThenWriteClose();
}

test "save-buffer reports client-side open errors from write-ready" {
    try cmd_save_buffer.StressTests.saveBufferReportsClientSideOpenErrorsFromWriteReady();
}

test "show-buffer writes raw bytes over the peer transport for control clients" {
    try cmd_save_buffer.StressTests.showBufferWritesRawBytesOverThePeerTransportForControlClients();
}
