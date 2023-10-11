socket = null

function connect(name)
{
  let origin = new URL(window.location.origin)
  origin.protocol = "ws"
  let wsAddress = origin + "repositories/ws?repo_name="+encodeURIComponent(name)
  //console.log("connecting to " + wsAddress);
  if(!socket)
  {
    console.log("creating new socket");
	  socket = new WebSocket(wsAddress);
  }


	socket.onopen = function() {
    console.log("socket connected.");
    clearInterval(this.timerId);
	}

	socket.onmessage = function(message) {
		var history = document.getElementById("history");
		var previous = history.innerHTML.trim();
		if (previous.length) previous = previous + "\n";
		history.innerHTML = previous + message.data;
		history.scrollTop = history.scrollHeight;
	}

  
  socket.onclose = function() {
    console.log("socket disconnected");
      //connect(name);
    }
    
  socket.onerror = function() {
    console.log("socket error - reconnecting...");
    connect(name);
  }

}