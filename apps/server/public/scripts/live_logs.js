/**
 * Confector Live Log Streamer
 * Polls and refreshes live log output for executing builds and queue tasks.
 */
(function() {
  document.addEventListener("DOMContentLoaded", function() {
    var terminal = document.getElementById("live-terminal");
    if (!terminal) return;

    var buildId = terminal.getAttribute("data-build-id");
    if (!buildId) return;
    var taskId = terminal.getAttribute("data-task-id");

    var autoScroll = true;
    var autoscrollBtn = document.getElementById("btn-autoscroll");
    var refreshBtn = document.getElementById("btn-refresh-logs");

    if (autoscrollBtn) {
      autoscrollBtn.addEventListener("click", function() {
        autoScroll = !autoScroll;
        autoscrollBtn.innerText = "Auto-scroll: " + (autoScroll ? "ON" : "OFF");
        if (autoScroll) {
          terminal.scrollTop = terminal.scrollHeight;
        }
      });
    }

    function fetchLogs() {
      // Check for dynamically selected task (build page task selection)
      var selectedTask = terminal.getAttribute("data-selected-task");
      var effectiveTaskId = selectedTask || taskId;

      var logsUrl = effectiveTaskId
        ? "/api/v1/builds/" + encodeURIComponent(buildId) + "/tasks/" + encodeURIComponent(effectiveTaskId) + "/logs"
        : "/api/v1/builds/logs?id=" + encodeURIComponent(buildId);
      fetch(logsUrl)
        .then(function(res) {
          if (!res.ok) throw new Error("HTTP " + res.status);
          return res.json();
        })
        .then(function(data) {
          if (data && data.logs && data.logs.length > 0) {
            terminal.innerHTML = "";
            data.logs.forEach(function(line) {
              var lineDiv = document.createElement("div");
              lineDiv.className = "log-line";
              lineDiv.textContent = line;
              terminal.appendChild(lineDiv);
            });
            if (autoScroll) {
              terminal.scrollTop = terminal.scrollHeight;
            }
          } else if (effectiveTaskId) {
            // Task selected but no logs yet
            terminal.innerHTML = '<div class="log-empty">No log output recorded for this task yet.</div>';
          }
        })
        .catch(function(err) {
          // Ignore network glitch during live streaming
        });
    }

    if (refreshBtn) {
      refreshBtn.addEventListener("click", fetchLogs);
    }

    // Live poll every 2.5 seconds
    var pollInterval = setInterval(fetchLogs, 2500);

    // Initial scroll
    terminal.scrollTop = terminal.scrollHeight;
  });
})();
