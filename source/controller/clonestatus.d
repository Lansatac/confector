module clonestatus;

import vibe.vibe;

@safe
final class CloneStatus {
	string[] logLines;
	LocalManualEvent logEvent;

	this()
	{
		logEvent = createManualEvent();
	}

	void addLogLine(string line)
	{
		logLines ~= line;
		logEvent.emit();
	}

	void waitForMessage(size_t next_message)
	{
		while (logLines.length <= next_message)
			logEvent.wait();
	}
}