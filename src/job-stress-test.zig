const job = @import("job.zig");

test "job shared shell runner captures stdout and merged stderr" {
    try job.StressTests.jobSharedShellRunnerCapturesStdoutAndMergedStderr();
}

test "job_free terminates a live shared job process" {
    try job.StressTests.jobFreeTerminatesALiveSharedJobProcess();
}

test "job_kill_all terminates all live shared job processes" {
    try job.StressTests.jobKillAllTerminatesAllLiveSharedJobProcesses();
}

test "job server reaper async shell captures output and completion" {
    try job.StressTests.jobServerReaperAsyncShellCapturesOutputAndCompletion();
}

test "job_run streams output via bufferevent" {
    try job.StressTests.jobRunStreamsOutputViaBufferevent();
}
