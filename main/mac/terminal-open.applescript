-- Usage: osascript terminal-open.applescript <shell command>
-- Runs the command in a new Terminal window and brings it to the front.
on run argv
	tell application "Terminal"
		do script (item 1 of argv)
		activate
	end tell
	return "ok"
end run
