const cmd_run_shell = @import("cmd-run-shell.zig");

test "run-shell writes output to stdout for detached clients when no target pane is forced" {
    try cmd_run_shell.StressTests.runShellWritesOutputToStdoutForDetachedClientsWhenNoTargetPaneIsForced();
}

test "run-shell -E forwards stderr into detached stdout output" {
    try cmd_run_shell.StressTests.runShellEForwardsStderrIntoDetachedStdoutOutput();
}

test "run-shell without -t shows shell output in the attached current pane view mode" {
    try cmd_run_shell.StressTests.runShellWithoutTShowsShellOutputInTheAttachedCurrentPaneViewMode();
}

test "run-shell -t shows shell output in the target pane view mode" {
    try cmd_run_shell.StressTests.runShellTShowsShellOutputInTheTargetPaneViewMode();
}

test "run-shell target-pane output preserves shared utf8 grid payloads" {
    try cmd_run_shell.StressTests.runShellTargetPaneOutputPreservesSharedUtf8GridPayloads();
}

test "run-shell -bC preserves the original target context for delayed commands" {
    try cmd_run_shell.StressTests.runShellBCPreservesTheOriginalTargetContextForDelayedCommands();
}

test "run-shell -bC preserves quoted semicolons inside delayed commands" {
    try cmd_run_shell.StressTests.runShellBCPreservesQuotedSemicolonsInsideDelayedCommands();
}

test "run-shell registers the shared reduced job summary while work is active" {
    try cmd_run_shell.StressTests.runShellRegistersTheSharedReducedJobSummaryWhileWorkIsActive();
}

test "run-shell -b without a client falls back to the best session pane" {
    try cmd_run_shell.StressTests.runShellBWithoutAClientFallsBackToTheBestSessionPane();
}

test "run-shell does not truncate large target-pane output" {
    try cmd_run_shell.StressTests.runShellDoesNotTruncateLargeTargetPaneOutput();
}
