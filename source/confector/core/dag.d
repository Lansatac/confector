module confector.core.dag;

import confector.core.model;
import std.algorithm : canFind, sort, filter;
import std.array : array;
import std.format : format;
import std.string : join;

/**
 * Directed Acyclic Graph (DAG) manager for task dependency resolution,
 * cycle detection, topological sorting, and subgraph slicing.
 */
class TaskGraph
{
    private TaskNode[string] m_tasks;
    private string[][string] m_dependencies; // taskId -> array of upstream tasks it depends on
    private string[][string] m_dependents;   // taskId -> array of downstream tasks depending on it
    private string[string] m_fingerprints;   // taskId -> deterministic upfront fingerprint

    /**
     * Constructs a TaskGraph from a ProjectRecord.
     */
    this(in ProjectRecord project)
    {
        this(project.tasks);
    }

    /**
     * Constructs a TaskGraph from a list of TaskNode elements.
     */
    this(in TaskNode[] tasks)
    {
        foreach (task; tasks)
        {
            if (task.id in m_tasks)
            {
                throw new DAGValidationException(format("Duplicate task id defined in graph: '%s'", task.id));
            }
            m_tasks[task.id] = cast(TaskNode) task;
            m_dependencies[task.id] = [];
            m_dependents[task.id] = [];
        }

        // Build dependency edges
        foreach (task; tasks)
        {
            string[] allDeps = task.dependsOn.dup;

            // Also include upstream artifacts as dependencies
            foreach (art; task.inputs.upstreamArtifacts)
            {
                if (art.taskId.length > 0 && !allDeps.canFind(art.taskId))
                {
                    allDeps ~= art.taskId;
                }
            }

            foreach (depId; allDeps)
            {
                if (depId !in m_tasks)
                {
                    throw new DAGValidationException(
                        format("Task '%s' depends on non-existent task '%s'", task.id, depId),
                        null,
                        [depId]
                    );
                }

                if (!m_dependencies[task.id].canFind(depId))
                {
                    m_dependencies[task.id] ~= depId;
                }
                if (!m_dependents[depId].canFind(task.id))
                {
                    m_dependents[depId] ~= task.id;
                }
            }
        }

        validate();
        computeFingerprints();
    }

    /**
     * Precomputes deterministic node fingerprints in topological execution order.
     */
    void computeFingerprints(string workspaceDir = "")
    {
        import confector.core.fingerprinter : Fingerprinter;

        m_fingerprints.clear();
        auto order = topologicalSort();
        foreach (taskId; order)
        {
            TaskNode node = m_tasks[taskId];
            string[string] upstreamFps;
            auto deps = m_dependencies.get(taskId, []);
            foreach (depId; deps)
            {
                if (depId in m_fingerprints)
                {
                    upstreamFps[depId] = m_fingerprints[depId];
                }
            }
            foreach (art; node.inputs.upstreamArtifacts)
            {
                if (art.taskId in m_fingerprints)
                {
                    upstreamFps[art.taskId] = m_fingerprints[art.taskId];
                }
            }

            string fp = Fingerprinter.computeNodeFingerprint(node, workspaceDir, upstreamFps);
            m_fingerprints[taskId] = fp;
        }
    }

    /**
     * Returns the precalculated deterministic fingerprint for a given task ID.
     */
    string getFingerprint(string taskId) const
    {
        auto p = taskId in m_fingerprints;
        if (p is null)
        {
            throw new DAGValidationException(format("Task '%s' not found or fingerprint not computed in graph", taskId));
        }
        return *p;
    }

    /**
     * Returns a copy of all precalculated task fingerprints keyed by task ID.
     */
    string[string] allFingerprints() const
    {
        return m_fingerprints.dup;
    }

    /**
     * Returns the task node for a given task ID.
     */
    TaskNode getTask(string taskId) const
    {
        auto p = taskId in m_tasks;
        if (p is null)
        {
            throw new DAGValidationException(format("Task '%s' not found in graph", taskId));
        }
        return cast(TaskNode) *p;
    }

    /**
     * Returns all task IDs registered in the graph.
     */
    string[] allTaskIds() const
    {
        string[] keys;
        foreach (k; m_tasks.byKey)
        {
            keys ~= k;
        }
        keys.sort();
        return keys;
    }

    /**
     * Returns direct upstream dependencies for a given task ID.
     */
    string[] getDependencies(string taskId) const
    {
        auto p = taskId in m_dependencies;
        return p ? (*p).dup : [];
    }

    /**
     * Returns direct downstream dependents for a given task ID.
     */
    string[] getDependents(string taskId) const
    {
        auto p = taskId in m_dependents;
        return p ? (*p).dup : [];
    }

    /**
     * Validates graph structure and detects cyclic dependencies.
     */
    void validate() const
    {
        // Cycle detection using DFS with coloring:
        // 0 = unvisited, 1 = visiting (in current DFS stack), 2 = visited
        int[string] state;
        string[] currentPath;

        foreach (taskId; allTaskIds())
        {
            state[taskId] = 0;
        }

        bool dfs(string current)
        {
            state[current] = 1;
            currentPath ~= current;

            // Explore upstream dependencies
            auto deps = m_dependencies.get(current, []);
            foreach (dep; deps)
            {
                if (state[dep] == 1)
                {
                    // Cycle detected! Extract cycle path
                    size_t cycleStart = 0;
                    foreach (idx, node; currentPath)
                    {
                        if (node == dep)
                        {
                            cycleStart = idx;
                            break;
                        }
                    }
                    string[] cycle = currentPath[cycleStart .. $] ~ dep;
                    throw new DAGValidationException(
                        format("Cyclic dependency detected in task graph: %s", cycle.join(" -> ")),
                        cycle
                    );
                }
                else if (state[dep] == 0)
                {
                    if (dfs(dep)) return true;
                }
            }

            currentPath.length--;
            state[current] = 2;
            return false;
        }

        foreach (taskId; allTaskIds())
        {
            if (state[taskId] == 0)
            {
                dfs(taskId);
            }
        }
    }

    /**
     * Returns task IDs in topological execution order.
     */
    string[] topologicalSort() const
    {
        int[string] inDegree;
        foreach (taskId; allTaskIds())
        {
            inDegree[taskId] = cast(int) m_dependencies.get(taskId, []).length;
        }

        string[] queue;
        foreach (taskId; allTaskIds())
        {
            if (inDegree[taskId] == 0)
            {
                queue ~= taskId;
            }
        }
        queue.sort();

        string[] sorted;
        while (queue.length > 0)
        {
            string current = queue[0];
            queue = queue[1 .. $];
            sorted ~= current;

            string[] nextQueueAdditions;
            foreach (dep; m_dependents.get(current, []))
            {
                inDegree[dep]--;
                if (inDegree[dep] == 0)
                {
                    nextQueueAdditions ~= dep;
                }
            }
            nextQueueAdditions.sort();
            queue ~= nextQueueAdditions;
        }

        if (sorted.length != m_tasks.length)
        {
            throw new DAGValidationException("Topological sort failed: graph contains unresolved cycles");
        }

        return sorted;
    }

    /**
     * Resolves all upstream ancestors needed to execute `targetTaskId` (including `targetTaskId`)
     * in topological order.
     */
    string[] resolveSubgraph(string targetTaskId) const
    {
        if (targetTaskId !in m_tasks)
        {
            throw new DAGValidationException(format("Target task '%s' does not exist in graph", targetTaskId));
        }

        bool[string] required;

        void collectAncestors(string current)
        {
            required[current] = true;
            foreach (dep; m_dependencies.get(current, []))
            {
                if (dep !in required)
                {
                    collectAncestors(dep);
                }
            }
        }

        collectAncestors(targetTaskId);

        // Filter the full topological sort to only include required tasks
        auto fullOrder = topologicalSort();
        string[] result;
        foreach (taskId; fullOrder)
        {
            if (taskId in required)
            {
                result ~= taskId;
            }
        }
        return result;
    }

    /**
     * Resolves all downstream tasks that depend on `startTaskId` (including `startTaskId`)
     * in topological order.
     */
    string[] resolveDownstream(string startTaskId) const
    {
        if (startTaskId !in m_tasks)
        {
            throw new DAGValidationException(format("Task '%s' does not exist in graph", startTaskId));
        }

        bool[string] affected;

        void collectDescendants(string current)
        {
            affected[current] = true;
            foreach (child; m_dependents.get(current, []))
            {
                if (child !in affected)
                {
                    collectDescendants(child);
                }
            }
        }

        collectDescendants(startTaskId);

        auto fullOrder = topologicalSort();
        string[] result;
        foreach (taskId; fullOrder)
        {
            if (taskId in affected)
            {
                result ~= taskId;
            }
        }
        return result;
    }

    /**
     * Slices the DAG for execution when an arbitrary `targetTaskId` is triggered.
     * Evaluates ancestors (filtering those already cached with valid outputs) and includes
     * all downstream tasks that will be affected by running `targetTaskId`.
     */
    string[] resolveTriggerExecution(string targetTaskId, in string[] cachedTaskIds = null) const
    {
        auto ancestors = resolveSubgraph(targetTaskId);
        auto downstream = resolveDownstream(targetTaskId);

        bool[string] tasksToRun;

        // Ancestors: only include if not cached
        foreach (anc; ancestors)
        {
            if (anc == targetTaskId)
            {
                tasksToRun[anc] = true;
            }
            else if (!cachedTaskIds.canFind(anc))
            {
                tasksToRun[anc] = true;
            }
        }

        // Downstream tasks must run because targetTaskId is re-running
        foreach (desc; downstream)
        {
            tasksToRun[desc] = true;
        }

        // Return in topological order
        auto fullOrder = topologicalSort();
        string[] result;
        foreach (taskId; fullOrder)
        {
            if (taskId in tasksToRun)
            {
                result ~= taskId;
            }
        }
        return result;
    }
}

unittest
{
    // 1. Test linear pipeline A -> B -> C
    TaskNode a; a.id = "A";
    TaskNode b; b.id = "B"; b.dependsOn = ["A"];
    TaskNode c; c.id = "C"; c.dependsOn = ["B"];

    auto graph = new TaskGraph([a, b, c]);
    auto sorted = graph.topologicalSort();
    assert(sorted == ["A", "B", "C"]);

    // Test subgraph resolution for C
    assert(graph.resolveSubgraph("C") == ["A", "B", "C"]);
    assert(graph.resolveSubgraph("B") == ["A", "B"]);
    assert(graph.resolveSubgraph("A") == ["A"]);

    // Test downstream resolution from A
    assert(graph.resolveDownstream("A") == ["A", "B", "C"]);
    assert(graph.resolveDownstream("B") == ["B", "C"]);
    assert(graph.resolveDownstream("C") == ["C"]);

    // Test trigger resolution with cached ancestor
    // If A is cached and we trigger B, only B and C run
    assert(graph.resolveTriggerExecution("B", ["A"]) == ["B", "C"]);
    // If nothing cached and we trigger B, A, B, C run
    assert(graph.resolveTriggerExecution("B", []) == ["A", "B", "C"]);
}

unittest
{
    // 2. Test diamond pipeline A -> B -> D and A -> C -> D
    TaskNode a; a.id = "A";
    TaskNode b; b.id = "B"; b.dependsOn = ["A"];
    TaskNode c; c.id = "C"; c.dependsOn = ["A"];
    TaskNode d; d.id = "D"; d.dependsOn = ["B", "C"];

    auto graph = new TaskGraph([a, b, c, d]);
    auto sorted = graph.topologicalSort();
    assert(sorted[0] == "A");
    assert(sorted[$ - 1] == "D");
    assert(sorted.canFind("B") && sorted.canFind("C"));

    // Subgraph for D must include all 4
    assert(graph.resolveSubgraph("D").length == 4);

    // Downstream from B should be B and D
    assert(graph.resolveDownstream("B") == ["B", "D"]);
}

unittest
{
    // 3. Test cycle detection
    TaskNode a; a.id = "A"; a.dependsOn = ["C"];
    TaskNode b; b.id = "B"; b.dependsOn = ["A"];
    TaskNode c; c.id = "C"; c.dependsOn = ["B"];

    bool caught = false;
    try
    {
        new TaskGraph([a, b, c]);
    }
    catch (DAGValidationException ex)
    {
        caught = true;
        assert(ex.cycle.length > 0);
    }
    assert(caught, "Expected cycle detection to throw DAGValidationException");
}

unittest
{
    // 4. Test self-cycle detection
    TaskNode a; a.id = "A"; a.dependsOn = ["A"];
    bool caught = false;
    try
    {
        new TaskGraph([a]);
    }
    catch (DAGValidationException ex)
    {
        caught = true;
        assert(ex.cycle == ["A", "A"]);
    }
    assert(caught, "Expected self-cycle detection to throw DAGValidationException");
}

unittest
{
    // 5. Test duplicate task ID detection
    TaskNode a1; a1.id = "A";
    TaskNode a2; a2.id = "A";
    bool caught = false;
    try
    {
        new TaskGraph([a1, a2]);
    }
    catch (DAGValidationException ex)
    {
        caught = true;
    }
    assert(caught, "Expected duplicate task ID to throw DAGValidationException");
}

unittest
{
    // 6. Test missing dependency detection
    TaskNode a; a.id = "A"; a.dependsOn = ["non_existent"];
    bool caught = false;
    try
    {
        new TaskGraph([a]);
    }
    catch (DAGValidationException ex)
    {
        caught = true;
        assert(ex.missingDependencies == ["non_existent"]);
    }
    assert(caught, "Expected missing dependency to throw DAGValidationException");
}

unittest
{
    // 7. Test upstream artifact dependency linkage
    TaskNode a; a.id = "A";
    TaskNode b; b.id = "B";
    b.inputs.upstreamArtifacts = [UpstreamArtifactRef("A", "out/app")];

    auto graph = new TaskGraph([a, b]);
    assert(graph.getDependencies("B") == ["A"]);
    assert(graph.getDependents("A") == ["B"]);
    assert(graph.topologicalSort() == ["A", "B"]);
}

unittest
{
    // 8. Test disconnected independent subgraphs: (A -> B) and (C -> D)
    TaskNode a; a.id = "A";
    TaskNode b; b.id = "B"; b.dependsOn = ["A"];
    TaskNode c; c.id = "C";
    TaskNode d; d.id = "D"; d.dependsOn = ["C"];

    auto graph = new TaskGraph([a, b, c, d]);
    auto sorted = graph.topologicalSort();
    assert(sorted.length == 4);
    assert(sorted.canFind("A") && sorted.canFind("B") && sorted.canFind("C") && sorted.canFind("D"));

    // Subgraph for B only includes A and B
    assert(graph.resolveSubgraph("B") == ["A", "B"]);
    // Subgraph for D only includes C and D
    assert(graph.resolveSubgraph("D") == ["C", "D"]);
}

unittest
{
    // 9. Test deterministic upfront fingerprint calculation and propagation
    TaskNode a; a.id = "compile";
    a.steps = [BuildStep("Build", "bash", null, "dub build")];
    a.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];

    TaskNode b; b.id = "test"; b.dependsOn = ["compile"];
    b.inputs.upstreamArtifacts = [UpstreamArtifactRef("compile", "binaries", "dist")];
    b.steps = [BuildStep("Test", "bash", null, "dub test")];

    TaskNode c; c.id = "docs";
    c.steps = [BuildStep("Docs", "bash", null, "dub build --build=docs")];

    auto graph1 = new TaskGraph([a, b, c]);
    auto graph2 = new TaskGraph([a, b, c]);

    // All fingerprints must be computed upfront and match identically across evaluations
    assert(graph1.getFingerprint("compile") == graph2.getFingerprint("compile"));
    assert(graph1.getFingerprint("test") == graph2.getFingerprint("test"));
    assert(graph1.getFingerprint("docs") == graph2.getFingerprint("docs"));
    assert(graph1.getFingerprint("compile").length == 64);
    assert(graph1.getFingerprint("test").length == 64);

    // 10. Modifying upstream task changes downstream fingerprint
    TaskNode aMod = a;
    aMod.steps = [BuildStep("Build", "bash", null, "dub build --build=release")];
    auto graphMod = new TaskGraph([aMod, b, c]);

    // compile and test fingerprints must change
    assert(graphMod.getFingerprint("compile") != graph1.getFingerprint("compile"));
    assert(graphMod.getFingerprint("test") != graph1.getFingerprint("test"));
    // Unrelated task C (docs) fingerprint must remain unchanged
    assert(graphMod.getFingerprint("docs") == graph1.getFingerprint("docs"));
}
