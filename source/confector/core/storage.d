module confector.core.storage;

/// Re-export BuildStateRepository and ArtifactStorage from plugin_api for backward compatibility.
/// All interfaces are now owned by plugin_api.model; this module exists
/// solely to maintain backward compatibility for existing import paths.
public import confector.plugin_api.model : BuildStateRepository, ArtifactStorage;

unittest
{
    import confector.core.test_storage : InMemoryArtifactStorage, InMemoryBuildStateRepository;
    import confector.plugin_api.model : ArtifactMetadata, BuildRecord, TriggerRuleRecord, ProjectRecord, TaskNode, BuildStep, RepositoryRecord, TaskExecutionRecord, TaskStatus;
    auto storage = new InMemoryArtifactStorage();
    auto stateRepo = new InMemoryBuildStateRepository();

    // Test stream-based content-addressed artifact storage
    string fingerprint = "fp123";
    string artifactId = "output.txt";
    string contents = "test artifact contents";

    // Store artifact via stream
    storage.storeArtifactStream(fingerprint, artifactId, (void delegate(const(ubyte)[]) sink) {
        sink(cast(ubyte[])contents.dup);
    });

    // Verify artifact exists
    assert(storage.artifactExists(fingerprint, artifactId));
    assert(!storage.artifactExists(fingerprint, "nonexistent"));
    assert(!storage.artifactExists("", artifactId));

    // Retrieve artifact via stream
    import std.array : Appender;
    Appender!(ubyte[]) retrievedBuffer;
    storage.retrieveArtifactStream(fingerprint, artifactId, (const(ubyte)[] chunk) {
        retrievedBuffer.put(chunk);
    });
    assert(retrievedBuffer.data == contents.dup);

    // Delete artifact
    storage.deleteArtifact(fingerprint, artifactId);
    assert(!storage.artifactExists(fingerprint, artifactId));

    ArtifactMetadata testMeta;
    testMeta.sha256 = "abc123";
    stateRepo.saveCachedFingerprint("t1", "hash123", [testMeta]);
    ArtifactMetadata[] cachedMetas;
    assert(stateRepo.getCachedFingerprint("t1", "hash123", cachedMetas));
    assert(cachedMetas.length == 1);
    assert(cachedMetas[0].sha256 == "abc123");

    // Build recording and logging
    BuildRecord bRecord;
    bRecord.buildId = "b1";
    bRecord.projectName = "test_project";
    bRecord.status = "succeeded";
    stateRepo.recordBuild(bRecord);

    BuildRecord fetchedBuild;
    assert(stateRepo.getBuild("b1", fetchedBuild));
    assert(fetchedBuild.projectName == "test_project");
    assert(stateRepo.listBuilds().length == 1);

    stateRepo.appendBuildLog("b1", "[step1] Building application");
    assert(stateRepo.getBuildLogs("b1").length == 1);
    assert(stateRepo.getBuildLogs("b1")[0] == "[step1] Building application");

    // Trigger rule recording
    TriggerRuleRecord rule;
    rule.id = "trig_1";
    rule.name = "Main Branch Push";
    rule.triggerType = "git_push";
    rule.criteria = "main";
    stateRepo.saveTriggerRule(rule);
    assert(stateRepo.listTriggerRules().length == 1);
    assert(stateRepo.deleteTriggerRule("trig_1"));
    assert(stateRepo.listTriggerRules().length == 0);

    // Project persistence in InMemoryBuildStateRepository
    ProjectRecord proj;
    proj.id = "proj-confector";
    proj.name = "Confector";
    TaskNode node;
    node.id = "build";
    node.steps = [BuildStep("Build", "bash", null, "dub build")];
    proj.tasks = [node];
    proj.createdAt = "2026-09-30T12:00:00Z";
    proj.updatedAt = "2026-09-30T12:00:00Z";

    stateRepo.saveProject(proj);
    assert(stateRepo.listProjects().length == 1);
    ProjectRecord fetchedProj;
    assert(stateRepo.getProject("proj-confector", fetchedProj));
    assert(fetchedProj.name == "Confector");
    assert(fetchedProj.tasks.length == 1);
    assert(fetchedProj.tasks[0].id == "build");

    assert(stateRepo.deleteProject("proj-confector"));
    assert(stateRepo.listProjects().length == 0);

    // Repository persistence in InMemoryBuildStateRepository
    RepositoryRecord repo;
    repo.name = "confector-core";
    repo.address = "https://github.com/confector/confector.git";
    stateRepo.saveRepository(repo);
    assert(stateRepo.listRepositories().length == 1);
    RepositoryRecord fetchedRepo;
    assert(stateRepo.getRepository("confector-core", fetchedRepo));
    assert(fetchedRepo.address == "https://github.com/confector/confector.git");
    assert(stateRepo.deleteRepository("confector-core"));
    assert(stateRepo.listRepositories().length == 0);

    // Executor persistence in InMemoryBuildStateRepository
    import std.json : JSONValue;
    import confector.plugin_api.model : WorkerRecord;
    WorkerRecord exec;
    exec.id = "exec-local-1";
    exec.name = "Local Executor 1";
    exec.providerType = "local";
    exec.description = "Primary local runner";
    exec.enabled = false;
    exec.configuration = JSONValue(["maxConcurrency": JSONValue(8)]);
    exec.createdAt = "2026-09-30T12:00:00Z";
    exec.updatedAt = "2026-09-30T12:00:00Z";

    stateRepo.saveExecutor(exec);
    assert(stateRepo.listExecutors().length == 1);
    WorkerRecord fetchedExec;
    assert(stateRepo.getExecutor("exec-local-1", fetchedExec));
    assert(fetchedExec.name == "Local Executor 1");
    assert(!fetchedExec.enabled);
    assert(fetchedExec.configuration["maxConcurrency"].integer == 8);

    // Toggle enabled
    fetchedExec.enabled = true;
    stateRepo.saveExecutor(fetchedExec);
    WorkerRecord updatedExec;
    assert(stateRepo.getExecutor("exec-local-1", updatedExec));
    assert(updatedExec.enabled);

    assert(stateRepo.deleteExecutor("exec-local-1"));
    assert(stateRepo.listExecutors().length == 0);
    assert(!stateRepo.getExecutor("exec-local-1", fetchedExec));

    // Granular task execution and status tracking
    TaskExecutionRecord taskRec;
    taskRec.buildId = "b1";
    taskRec.taskId = "t1";
    taskRec.status = "succeeded";
    taskRec.fingerprint = "fp_t1";
    taskRec.durationMs = 150;
    taskRec.producedArtifacts = [testMeta];
    taskRec.upstreamArtifactHashes = ["t0": "hash0"];
    stateRepo.recordTaskExecution(taskRec);

    TaskExecutionRecord fetchedTaskRec;
    assert(stateRepo.getTaskExecution("b1", "t1", fetchedTaskRec));
    assert(fetchedTaskRec.taskId == "t1");
    assert(fetchedTaskRec.status == "succeeded");
    assert(fetchedTaskRec.fingerprint == "fp_t1");
    assert(fetchedTaskRec.durationMs == 150);
    assert(fetchedTaskRec.producedArtifacts.length == 1);
    assert(fetchedTaskRec.upstreamArtifactHashes["t0"] == "hash0");

    auto buildTaskRecs = stateRepo.getTaskExecutionsForBuild("b1");
    assert(buildTaskRecs.length == 1);
    assert(buildTaskRecs[0].taskId == "t1");

    auto buildStatuses = stateRepo.getTaskStatusesForBuild("b1");
    assert("t1" in buildStatuses);
    assert(buildStatuses["t1"] == TaskStatus.succeeded);

    stateRepo.setTaskStatus("b1", "t2", TaskStatus.running);
    auto buildStatuses2 = stateRepo.getTaskStatusesForBuild("b1");
    assert(buildStatuses2.length == 2);
    assert(buildStatuses2["t2"] == TaskStatus.running);

    // Test listTaskExecutionsForTask
    TaskExecutionRecord taskRec2;
    taskRec2.buildId = "b2";
    taskRec2.taskId = "t1";
    taskRec2.projectId = "proj_test";
    taskRec2.status = "cached";
    taskRec2.startedAt = "2026-10-01T10:00:00Z";
    stateRepo.recordTaskExecution(taskRec2);

    TaskExecutionRecord taskRec3;
    taskRec3.buildId = "b3";
    taskRec3.taskId = "t1";
    taskRec3.projectId = "proj_test";
    taskRec3.status = "failed";
    taskRec3.startedAt = "2026-10-02T10:00:00Z";
    stateRepo.recordTaskExecution(taskRec3);

    auto t1Execs = stateRepo.listTaskExecutionsForTask("proj_test", "t1");
    assert(t1Execs.length == 2);
    assert(t1Execs[0].buildId == "b3"); // sorted descending by startedAt
    assert(t1Execs[1].buildId == "b2");

    auto t1Limited = stateRepo.listTaskExecutionsForTask("proj_test", "t1", 1);
    assert(t1Limited.length == 1);
    assert(t1Limited[0].buildId == "b3");

    auto t1OtherProj = stateRepo.listTaskExecutionsForTask("proj_other", "t1");
    assert(t1OtherProj.length == 0);

    // ==========================================
    // Stream-based Content-Addressed Storage Tests
    // ==========================================
    import confector.core.zip_packager : ZipPackager;
    import std.array : Appender;

    string fp1 = "fingerprint_node_100";
    string art1 = "bin_app";

    assert(!storage.artifactExists(fp1, art1));

    // Test stream storage write
    storage.storeArtifactStream(fp1, art1, (sink) {
        sink(cast(const(ubyte)[]) "zip payload chunk 1; ");
        sink(cast(const(ubyte)[]) "zip payload chunk 2;");
    });

    assert(storage.artifactExists(fp1, art1));

    // Test stream storage read
    Appender!(ubyte[]) retrievedBytes;
    storage.retrieveArtifactStream(fp1, art1, (const(ubyte)[] chunk) {
        retrievedBytes.put(chunk);
    });
    assert(cast(string) retrievedBytes.data == "zip payload chunk 1; zip payload chunk 2;");

    // Test ZipPackager round-trip with InMemoryArtifactStorage
    import std.file : exists, mkdirRecurse, read, rmdirRecurse, write, tempDir;
    import std.path : buildPath;
    string testDir2 = buildPath(tempDir, "test_artifacts_storage_zip");
    if (exists(testDir2)) rmdirRecurse(testDir2);
    scope(exit) if (exists(testDir2)) rmdirRecurse(testDir2);

    string wsDir = buildPath(testDir2, "ws_source");
    string unpackDir = buildPath(testDir2, "ws_unpacked");
    mkdirRecurse(buildPath(wsDir, "dist"));
    write(buildPath(wsDir, "dist", "bundle.js"), "console.log('hello');");
    write(buildPath(wsDir, "dist", "style.css"), "body { margin: 0; }");

    string fp2 = "fingerprint_node_200";
    string art2 = "dist_assets";

    storage.storeArtifactStream(fp2, art2, (sink) {
        ZipPackager.pack(wsDir, ["dist/*"], sink);
    });

    assert(storage.artifactExists(fp2, art2));

    ZipPackager.unpackStream((sink) {
        storage.retrieveArtifactStream(fp2, art2, sink);
    }, unpackDir);

    assert(exists(buildPath(unpackDir, "dist", "bundle.js")));
    assert(exists(buildPath(unpackDir, "dist", "style.css")));
    assert(cast(string) read(buildPath(unpackDir, "dist", "bundle.js")) == "console.log('hello');");
    assert(cast(string) read(buildPath(unpackDir, "dist", "style.css")) == "body { margin: 0; }");

    // Test deletion
    storage.deleteArtifact(fp1, art1);
    assert(!storage.artifactExists(fp1, art1));

    // Test retrieval of nonexistent artifact
    bool caughtNotFound = false;
    try
    {
        storage.retrieveArtifactStream("no_such_fp", "no_such_art", (chunk) {});
    }
    catch (Exception)
    {
        caughtNotFound = true;
    }
    assert(caughtNotFound);

    // ==========================================
    // VCS Repository State & Change Record Tests
    // ==========================================
    import confector.plugin_api.model : VcsRepositoryState, VcsChangeRecord;

    // Test save and get repository state
    VcsRepositoryState vcsState;
    vcsState.repositoryUrl = "https://github.com/confector/confector.git";
    vcsState.providerType = "git";
    vcsState.targetRef = "main";
    vcsState.revision = "abc123def456";
    vcsState.author = "dev@example.com";
    vcsState.message = "Initial commit";
    vcsState.updatedAt = "2026-10-09T10:00:00Z";

    stateRepo.saveRepositoryState(vcsState);

    VcsRepositoryState fetchedState;
    assert(stateRepo.getRepositoryState("https://github.com/confector/confector.git", "main", fetchedState));
    assert(fetchedState.revision == "abc123def456");
    assert(fetchedState.providerType == "git");
    assert(fetchedState.author == "dev@example.com");

    // Test that non-existent state returns false
    VcsRepositoryState missingState;
    assert(!stateRepo.getRepositoryState("https://github.com/other/repo.git", "main", missingState));

    // Test change record recording and listing
    VcsChangeRecord change1;
    change1.id = "change-001";
    change1.repositoryUrl = "https://github.com/confector/confector.git";
    change1.providerType = "git";
    change1.targetRef = "main";
    change1.fromRevision = "abc123def456";
    change1.toRevision = "789xyz000";
    change1.detectedAt = "2026-10-09T11:00:00Z";
    change1.triggerSource = "webhook";

    VcsChangeRecord change2;
    change2.id = "change-002";
    change2.repositoryUrl = "https://github.com/confector/confector.git";
    change2.providerType = "git";
    change2.targetRef = "main";
    change2.fromRevision = "789xyz000";
    change2.toRevision = "newrevision123";
    change2.detectedAt = "2026-10-09T12:00:00Z";
    change2.triggerSource = "polling";

    VcsChangeRecord change3;
    change3.id = "change-003";
    change3.repositoryUrl = "https://github.com/other/repo.git";
    change3.providerType = "git";
    change3.targetRef = "develop";
    change3.fromRevision = "old1";
    change3.toRevision = "new1";
    change3.detectedAt = "2026-10-09T13:00:00Z";
    change3.triggerSource = "manual";

    stateRepo.recordRepositoryChange(change1);
    stateRepo.recordRepositoryChange(change2);
    stateRepo.recordRepositoryChange(change3);

    auto changes = stateRepo.listRepositoryChanges("https://github.com/confector/confector.git");
    assert(changes.length == 2);
    assert(changes[0].id == "change-001");
    assert(changes[1].id == "change-002");

    // Test limit parameter
    auto limitedChanges = stateRepo.listRepositoryChanges("https://github.com/confector/confector.git", 1);
    assert(limitedChanges.length == 1);
    assert(limitedChanges[0].id == "change-002"); // last one due to slicing

    // Test filtering by repository URL
    auto otherChanges = stateRepo.listRepositoryChanges("https://github.com/other/repo.git");
    assert(otherChanges.length == 1);
    assert(otherChanges[0].id == "change-003");

    // Test empty result for unknown repository
    auto noChanges = stateRepo.listRepositoryChanges("https://github.com/unknown/repo.git");
    assert(noChanges.length == 0);
}
