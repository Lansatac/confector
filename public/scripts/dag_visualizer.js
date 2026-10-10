/**
 * Confector DAG Visualizer
 * Interactive HTML5 Canvas graph visualizer for DAG nodes, repository inputs, and dependency edges.
 */
(function() {
  // Polyfill for CanvasRenderingContext2D.roundRect (not available in older browsers)
  if (!CanvasRenderingContext2D.prototype.roundRect) {
    CanvasRenderingContext2D.prototype.roundRect = function(x, y, w, h, r) {
      if (typeof r === "number") r = [r, r, r, r];
      var radii = r.map(function(v) { return Math.min(v, w / 2, h / 2); });
      this.moveTo(x + radii[0], y);
      this.lineTo(x + w - radii[1], y);
      this.quadraticCurveTo(x + w, y, x + w, y + radii[1]);
      this.lineTo(x + w, y + h - radii[2]);
      this.quadraticCurveTo(x + w, y + h, x + w - radii[2], y + h);
      this.lineTo(x + radii[3], y + h);
      this.quadraticCurveTo(x, y + h, x, y + h - radii[3]);
      this.lineTo(x, y + radii[0]);
      this.quadraticCurveTo(x, y, x + radii[0], y);
      this.closePath();
      return this;
    };
  }
  // Stored node bounding boxes for click hit-detection
  var nodeBounds = [];
  var selectedNodeId = null;
  var onNodeSelectedCallback = null;
  var currentCanvasId = null;
  var cachedNodes = [];
  var cachedEdges = [];
  var cachedPendingCommits = {};

  function drawArrow(ctx, fromX, fromY, toX, toY, color) {
    var headLen = 8;
    var angle = Math.atan2(toY - fromY, toX - fromX);
    
    ctx.strokeStyle = color || "#999";
    ctx.fillStyle = color || "#999";
    ctx.lineWidth = 2;
    
    ctx.beginPath();
    ctx.moveTo(fromX, fromY);
    ctx.lineTo(toX, toY);
    ctx.stroke();
    
    ctx.beginPath();
    ctx.moveTo(toX, toY);
    ctx.lineTo(toX - headLen * Math.cos(angle - Math.PI / 6), toY - headLen * Math.sin(angle - Math.PI / 6));
    ctx.lineTo(toX - headLen * Math.cos(angle + Math.PI / 6), toY - headLen * Math.sin(angle + Math.PI / 6));
    ctx.closePath();
    ctx.fill();
  }

  function extractRepos(t) {
    var raw = (t.inputs && (t.inputs.repositories || t.inputs.repos)) || t.repositories;
    if (!raw) return [];
    if (Array.isArray(raw)) return raw;
    if (typeof raw === "string") {
      return raw.split(",").map(function(s) { return s.trim(); }).filter(Boolean);
    }
    return [];
  }

  function extractDeps(t) {
    var raw = t.depends_on || t.dependsOn;
    if (!raw) return [];
    if (Array.isArray(raw)) return raw;
    if (typeof raw === "string") {
      return raw.split(",").map(function(s) { return s.trim(); }).filter(Boolean);
    }
    return [];
  }

  function renderGraph(canvasId, nodes, edges, selectedId, pendingCommits) {
    var canvas = document.getElementById(canvasId);
    if (!canvas) return;
    var ctx = canvas.getContext("2d");
    if (!ctx) return;

    pendingCommits = pendingCommits || {};

    var width = canvas.width;
    var height = canvas.height;
    ctx.clearRect(0, 0, width, height);

    // Node positioning by layer
    var nodePositions = {};
    var nodeWidth = 115;
    var nodeHeight = 44;

    // Clear and rebuild node bounds for hit-detection
    nodeBounds = [];

    nodes.forEach(function(n, index) {
      var x = n.x !== undefined ? n.x : 50 + index * 140;
      var y = n.y !== undefined ? n.y : (index % 2 === 0 ? 60 : 130);
      var isRepo = !!n.isRepo || n.type === "repository" || n.status === "repository";
      var pendingCount = 0;
      if (isRepo) {
        // Extract repo name from node id (format: "repo:repoName")
        var repoName = n.id.replace(/^repo:/, "");
        var pc = pendingCommits[repoName];
        if (pc !== undefined) {
          pendingCount = parseInt(pc, 10) || 0;
        }
      }
      nodePositions[n.id] = {
        x: x,
        y: y,
        name: n.name || n.id,
        status: n.status || "ready",
        isRepo: isRepo,
        pendingCount: pendingCount
      };
      // Store bounding box for hit-detection (only task nodes)
      if (!isRepo) {
        nodeBounds.push({ id: n.id, x: x, y: y, w: nodeWidth, h: nodeHeight });
      }
    });

    // Draw edges
    edges.forEach(function(e) {
      var src = nodePositions[e.from];
      var dest = nodePositions[e.to];
      if (src && dest) {
        var startX = src.x + nodeWidth;
        var startY = src.y + nodeHeight / 2;
        var endX = dest.x;
        var endY = dest.y + nodeHeight / 2;
        var edgeColor = e.color || (src.isRepo ? "#7c3aed" : "#6c757d");
        drawArrow(ctx, startX, startY, endX, endY, edgeColor);
      }
    });

    // Draw nodes
    Object.keys(nodePositions).forEach(function(id) {
      var pos = nodePositions[id];
      var x = pos.x;
      var y = pos.y;

      var bgColor = "#ffffff";
      var borderColor = "#2196f3";
      var textColor = "#222222";
      var isSelected = (id === selectedId);

      if (pos.isRepo || pos.status === "repository") {
        bgColor = "#f5f3ff";
        borderColor = "#7c3aed";
        textColor = "#4c1d95";
      } else if (pos.status === "succeeded" || pos.status === "success") {
        bgColor = "#e8f5e9";
        borderColor = "#4caf50";
      } else if (pos.status === "cached") {
        bgColor = "#e0f7fa";
        borderColor = "#00bcd4";
      } else if (pos.status === "running") {
        bgColor = "#fff3e0";
        borderColor = "#ff9800";
      } else if (pos.status === "failed") {
        bgColor = "#ffebee";
        borderColor = "#f44336";
      }

      // Draw box with shadow
      ctx.shadowColor = "rgba(0,0,0,0.08)";
      ctx.shadowBlur = 6;
      ctx.shadowOffsetX = 0;
      ctx.shadowOffsetY = 2;

      ctx.fillStyle = bgColor;
      ctx.strokeStyle = borderColor;
      ctx.lineWidth = isSelected ? 4 : 2;

      // Rounded rect
      var r = pos.isRepo ? 10 : 6;
      ctx.beginPath();
      ctx.moveTo(x + r, y);
      ctx.lineTo(x + nodeWidth - r, y);
      ctx.quadraticCurveTo(x + nodeWidth, y, x + nodeWidth, y + r);
      ctx.lineTo(x + nodeWidth, y + nodeHeight - r);
      ctx.quadraticCurveTo(x + nodeWidth, y + nodeHeight, x + nodeWidth - r, y + nodeHeight);
      ctx.lineTo(x + r, y + nodeHeight);
      ctx.quadraticCurveTo(x, y + nodeHeight, x, y + nodeHeight - r);
      ctx.lineTo(x, y + r);
      ctx.quadraticCurveTo(x, y, x + r, y);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();

      ctx.shadowColor = "transparent";

      // Draw label
      if (pos.isRepo) {
        ctx.fillStyle = "#7c3aed";
        ctx.font = "bold 9px Verdana, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "top";
        ctx.fillText("REPOSITORY", x + nodeWidth / 2, y + 6);

        ctx.fillStyle = textColor;
        ctx.font = "bold 11px Verdana, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        var repoName = pos.name;
        if (repoName.length > 13) {
          repoName = repoName.substring(0, 11) + "..";
        }
        ctx.fillText(repoName, x + nodeWidth / 2, y + nodeHeight / 2 + 6);

        // Draw pending commit badge if there are pending commits
        if (pos.pendingCount > 0) {
          var badgeX = x + nodeWidth - 8;
          var badgeY = y + 4;
          var badgeText = String(pos.pendingCount);
          // Measure badge text for size
          ctx.font = "bold 10px Verdana, sans-serif";
          var textMetrics = ctx.measureText(badgeText);
          var badgeW = textMetrics.width + 10;
          var badgeH = 16;

          // Draw badge background
          ctx.shadowColor = "rgba(0,0,0,0.15)";
          ctx.shadowBlur = 3;
          ctx.shadowOffsetX = 0;
          ctx.shadowOffsetY = 1;
          ctx.fillStyle = "#e53e3e";
          ctx.beginPath();
          ctx.roundRect(badgeX - badgeW / 2, badgeY - badgeH / 2, badgeW, badgeH, 8);
          ctx.fill();
          ctx.shadowColor = "transparent";

          // Draw badge text
          ctx.fillStyle = "#ffffff";
          ctx.font = "bold 10px Verdana, sans-serif";
          ctx.textAlign = "center";
          ctx.textBaseline = "middle";
          ctx.fillText(badgeText, badgeX, badgeY);
        }
      } else {
        ctx.fillStyle = textColor;
        ctx.font = "bold 12px Verdana, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        var taskName = pos.name;
        if (taskName.length > 13) {
          taskName = taskName.substring(0, 11) + "..";
        }
        ctx.fillText(taskName, x + nodeWidth / 2, y + nodeHeight / 2);
      }
    });
  }

  window.renderTaskGraph = function(canvasId, tasks, taskStatuses, onNodeSelected, pendingCommits) {
    if (!tasks || !tasks.length) return;
    taskStatuses = taskStatuses || {};
    pendingCommits = pendingCommits || {};
    if (typeof onNodeSelected === "function") {
      onNodeSelectedCallback = onNodeSelected;
    }
    currentCanvasId = canvasId;
    selectedNodeId = null;

    // Remove old click listener and add new one
    var canvas = document.getElementById(canvasId);
    if (canvas) {
      canvas.removeEventListener("click", handleCanvasClick);
      canvas.addEventListener("click", handleCanvasClick);
      canvas.style.cursor = "pointer";
    }

    // 1. Collect all repository dependencies across tasks
    var repoSet = {};
    var repoList = [];
    tasks.forEach(function(t) {
      var repos = extractRepos(t);
      repos.forEach(function(r) {
        if (typeof r === "string" && r.trim().length > 0) {
          var trimmed = r.trim();
          if (!repoSet[trimmed]) {
            repoSet[trimmed] = true;
            repoList.push(trimmed);
          }
        }
      });
    });

    var graph = {};
    var inDegree = {};
    var taskMap = {};

    // Register repo nodes
    repoList.forEach(function(repoName) {
      var repoId = "repo:" + repoName;
      graph[repoId] = [];
      inDegree[repoId] = 0;
    });

    // Register task nodes
    tasks.forEach(function(t) {
      taskMap[t.id] = t;
      graph[t.id] = [];
      inDegree[t.id] = 0;
    });

    // Build edges for repo dependencies
    tasks.forEach(function(t) {
      var repos = extractRepos(t);
      repos.forEach(function(r) {
        var trimmed = typeof r === "string" ? r.trim() : "";
        if (trimmed.length > 0) {
          var repoId = "repo:" + trimmed;
          if (graph[repoId]) {
            graph[repoId].push(t.id);
            inDegree[t.id] = (inDegree[t.id] || 0) + 1;
          }
        }
      });
    });

    // Build edges for task dependencies
    tasks.forEach(function(t) {
      var deps = extractDeps(t);
      deps.forEach(function(dep) {
        if (graph[dep]) {
          graph[dep].push(t.id);
          inDegree[t.id] = (inDegree[t.id] || 0) + 1;
        }
      });
    });

    // Compute levels (longest path from roots)
    var levels = {};
    function computeLevel(nodeId, visited) {
      if (levels[nodeId] !== undefined) return levels[nodeId];
      if (nodeId.indexOf("repo:") === 0) {
        levels[nodeId] = 0;
        return 0;
      }
      var t = taskMap[nodeId];
      if (!t) return 0;

      var allDeps = [];
      var deps = extractDeps(t);
      deps.forEach(function(d) { allDeps.push(d); });
      var repos = extractRepos(t);
      repos.forEach(function(r) {
        var trimmed = typeof r === "string" ? r.trim() : "";
        if (trimmed.length > 0) allDeps.push("repo:" + trimmed);
      });

      if (!allDeps.length) {
        levels[nodeId] = 0;
        return 0;
      }

      var maxL = 0;
      allDeps.forEach(function(d) {
        if (!visited[d]) {
          visited[d] = true;
          maxL = Math.max(maxL, computeLevel(d, visited) + 1);
        }
      });
      levels[nodeId] = maxL;
      return maxL;
    }

    // Set level 0 for repo nodes
    repoList.forEach(function(repoName) {
      levels["repo:" + repoName] = 0;
    });

    tasks.forEach(function(t) {
      var visited = {};
      visited[t.id] = true;
      computeLevel(t.id, visited);
    });

    // Group nodes by level
    var levelGroups = {};
    var maxLevel = 0;

    repoList.forEach(function(repoName) {
      var repoId = "repo:" + repoName;
      var lvl = levels[repoId] || 0;
      if (!levelGroups[lvl]) levelGroups[lvl] = [];
      levelGroups[lvl].push({
        id: repoId,
        name: repoName,
        isRepo: true,
        type: "repository",
        status: "repository"
      });
    });

    tasks.forEach(function(t) {
      var lvl = levels[t.id] || 0;
      if (lvl > maxLevel) maxLevel = lvl;
      if (!levelGroups[lvl]) levelGroups[lvl] = [];
      levelGroups[lvl].push({
        id: t.id,
        name: t.name || t.id,
        isRepo: false,
        type: "task",
        status: taskStatuses[t.id] || "ready",
        task: t
      });
    });

    // Assign coordinates and construct nodes & edges
    var nodes = [];
    var edges = [];
    var xSpacing = 160;
    var startX = 40;

    var maxNodesInLevel = 0;
    Object.keys(levelGroups).forEach(function(k) {
      if (levelGroups[k].length > maxNodesInLevel) maxNodesInLevel = levelGroups[k].length;
    });

    var canvas = document.getElementById(canvasId);
    if (canvas) {
      var minWidth = startX + (maxLevel + 1) * xSpacing + 40;
      var minHeight = 40 + maxNodesInLevel * 70 + 30;
      if (canvas.width < minWidth) canvas.width = minWidth;
      if (canvas.height < minHeight) canvas.height = minHeight;
    }

    Object.keys(levelGroups).forEach(function(lvlKey) {
      var lvl = parseInt(lvlKey, 10);
      var group = levelGroups[lvl];
      group.forEach(function(item, idx) {
        var x = startX + lvl * xSpacing;
        var y = 40 + idx * 70;
        nodes.push({
          id: item.id,
          name: item.name,
          x: x,
          y: y,
          status: item.status,
          isRepo: item.isRepo,
          type: item.type
        });

        if (!item.isRepo && item.task) {
          var t = item.task;
          var repos = extractRepos(t);
          repos.forEach(function(r) {
            var trimmed = typeof r === "string" ? r.trim() : "";
            if (trimmed.length > 0) {
              edges.push({ from: "repo:" + trimmed, to: t.id, color: "#7c3aed" });
            }
          });

          var deps = extractDeps(t);
          deps.forEach(function(d) {
            edges.push({ from: d, to: t.id, color: "#6c757d" });
          });
        }
      });
    });

    // Cache nodes and edges for click re-rendering
    cachedNodes = nodes;
    cachedEdges = edges;
    cachedPendingCommits = pendingCommits;
    renderGraph(canvasId, nodes, edges, selectedNodeId, pendingCommits);
  };

  // Click handler for canvas — hit-detect task nodes
  function handleCanvasClick(event) {
    var canvas = event.target;
    var rect = canvas.getBoundingClientRect();
    var mx = event.clientX - rect.left;
    var my = event.clientY - rect.top;

    // Find which node was clicked (reverse order so top-drawn nodes are hit first)
    for (var i = nodeBounds.length - 1; i >= 0; i--) {
      var b = nodeBounds[i];
      if (mx >= b.x && mx <= b.x + b.w && my >= b.y && my <= b.y + b.h) {
        // Toggle selection: clicking the same node deselects it
        if (selectedNodeId === b.id) {
          selectedNodeId = null;
        } else {
          selectedNodeId = b.id;
        }
        // Re-render with selection highlight
        renderGraph(currentCanvasId, cachedNodes, cachedEdges, selectedNodeId, cachedPendingCommits);
        // Fire callback
        if (onNodeSelectedCallback) {
          onNodeSelectedCallback(selectedNodeId);
        }
        return;
      }
    }
    // Clicked empty space — clear selection
    if (selectedNodeId) {
      selectedNodeId = null;
      renderGraph(currentCanvasId, cachedNodes, cachedEdges, null, cachedPendingCommits);
      if (onNodeSelectedCallback) {
        onNodeSelectedCallback(null);
      }
    }
  }

  window.renderDAG = window.renderTaskGraph;

  window.renderSampleDAG = function(canvasId) {
    var nodes = [
      { id: "repo:confector", name: "confector", isRepo: true, status: "repository", x: 40, y: 90 },
      { id: "lint", name: "lint", x: 190, y: 90, status: "ready" },
      { id: "build", name: "build", x: 340, y: 90, status: "ready" },
      { id: "test", name: "test", x: 490, y: 40, status: "ready" },
      { id: "package", name: "package", x: 490, y: 140, status: "ready" },
      { id: "deploy", name: "deploy", x: 640, y: 90, status: "ready" }
    ];

    var edges = [
      { from: "repo:confector", to: "lint", color: "#7c3aed" },
      { from: "lint", to: "build" },
      { from: "build", to: "test" },
      { from: "build", to: "package" },
      { from: "test", to: "deploy" },
      { from: "package", to: "deploy" }
    ];

    renderGraph(canvasId, nodes, edges);
  };
})();
