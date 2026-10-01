/**
 * Confector DAG Visualizer
 * Interactive HTML5 Canvas graph visualizer for DAG nodes and dependency edges.
 */
(function() {
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

  function renderGraph(canvasId, nodes, edges) {
    var canvas = document.getElementById(canvasId);
    if (!canvas) return;
    var ctx = canvas.getContext("2d");
    if (!ctx) return;

    var width = canvas.width;
    var height = canvas.height;
    ctx.clearRect(0, 0, width, height);

    // Node positioning by layer
    var nodePositions = {};
    var nodeWidth = 110;
    var nodeHeight = 44;

    nodes.forEach(function(n, index) {
      var x = n.x !== undefined ? n.x : 50 + index * 140;
      var y = n.y !== undefined ? n.y : (index % 2 === 0 ? 60 : 130);
      nodePositions[n.id] = { x: x, y: y, name: n.name || n.id, status: n.status || "ready" };
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
        drawArrow(ctx, startX, startY, endX, endY, "#6c757d");
      }
    });

    // Draw nodes
    Object.keys(nodePositions).forEach(function(id) {
      var pos = nodePositions[id];
      var x = pos.x;
      var y = pos.y;

      // Color based on status
      var bgColor = "#ffffff";
      var borderColor = "#2196f3";
      var textColor = "#222222";

      if (pos.status === "succeeded" || pos.status === "success") {
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
      ctx.lineWidth = 2;

      // Rounded rect
      var r = 6;
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
      ctx.fillStyle = textColor;
      ctx.font = "bold 13px Verdana, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(pos.name, x + nodeWidth / 2, y + nodeHeight / 2);
    });
  }

  window.renderPipelineDAG = function(canvasId, tasks, taskStatuses) {
    if (!tasks || !tasks.length) return;
    taskStatuses = taskStatuses || {};

    // 1. Calculate in-degrees and levels
    var graph = {};
    var inDegree = {};
    var taskMap = {};

    tasks.forEach(function(t) {
      taskMap[t.id] = t;
      graph[t.id] = [];
      inDegree[t.id] = 0;
    });

    tasks.forEach(function(t) {
      var deps = t.depends_on || t.dependsOn || [];
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
      var t = taskMap[nodeId];
      if (!t) return 0;
      var deps = t.depends_on || t.dependsOn || [];
      if (!deps.length) {
        levels[nodeId] = 0;
        return 0;
      }
      var maxL = 0;
      deps.forEach(function(d) {
        if (!visited[d]) {
          visited[d] = true;
          maxL = Math.max(maxL, computeLevel(d, visited) + 1);
        }
      });
      levels[nodeId] = maxL;
      return maxL;
    }

    tasks.forEach(function(t) {
      var visited = {};
      visited[t.id] = true;
      computeLevel(t.id, visited);
    });

    // Group nodes by level
    var levelGroups = {};
    var maxLevel = 0;
    tasks.forEach(function(t) {
      var lvl = levels[t.id] || 0;
      if (lvl > maxLevel) maxLevel = lvl;
      if (!levelGroups[lvl]) levelGroups[lvl] = [];
      levelGroups[lvl].push(t);
    });

    // Assign coordinates
    var nodes = [];
    var edges = [];
    var xSpacing = 160;
    var startX = 40;

    Object.keys(levelGroups).forEach(function(lvlKey) {
      var lvl = parseInt(lvlKey, 10);
      var group = levelGroups[lvl];
      var totalInLvl = group.length;
      group.forEach(function(t, idx) {
        var x = startX + lvl * xSpacing;
        var y = 40 + idx * 70;
        var status = taskStatuses[t.id] || "ready";
        nodes.push({ id: t.id, name: t.name || t.id, x: x, y: y, status: status });

        var deps = t.depends_on || t.dependsOn || [];
        deps.forEach(function(d) {
          edges.push({ from: d, to: t.id });
        });
      });
    });

    renderGraph(canvasId, nodes, edges);
  };

  window.renderSamplePipeline = function(canvasId) {
    var nodes = [
      { id: "lint", name: "lint", x: 40, y: 90, status: "ready" },
      { id: "build", name: "build", x: 190, y: 90, status: "ready" },
      { id: "test", name: "test", x: 350, y: 40, status: "ready" },
      { id: "package", name: "package", x: 350, y: 140, status: "ready" },
      { id: "deploy", name: "deploy", x: 520, y: 90, status: "ready" }
    ];

    var edges = [
      { from: "lint", to: "build" },
      { from: "build", to: "test" },
      { from: "build", to: "package" },
      { from: "test", to: "deploy" },
      { from: "package", to: "deploy" }
    ];

    renderGraph(canvasId, nodes, edges);
  };

  document.addEventListener("DOMContentLoaded", function() {
    var dagCanvas = document.getElementById("dag-canvas");
    if (dagCanvas) {
      window.renderSamplePipeline("dag-canvas");
    }
  });
})();
