-- Usage: osascript terminal-tab.applescript <action> <tty> [arg]
--   paste  bring the Terminal tab on <tty> to the front and paste the clipboard;
--          arg "1" also presses Return
--   key    bring it to the front and press key code <arg>
-- Returns the app that was in front before, so the caller can go back to it.
-- Never types unless Terminal is really in front.
on run argv
	set action to item 1 of argv
	set ttyPath to item 2 of argv
	tell application "System Events" to set prevApp to name of first application process whose frontmost is true
	set found to false
	tell application "Terminal"
		repeat with w in windows
			repeat with t in tabs of w
				if tty of t is ttyPath then
					set selected of t to true
					set index of w to 1
					set found to true
					exit repeat
				end if
			end repeat
			if found then exit repeat
		end repeat
		if not found then error "No Terminal tab on " & ttyPath
		activate
	end tell
	tell application "System Events"
		repeat 40 times
			if name of first application process whose frontmost is true is "Terminal" then exit repeat
			delay 0.05
		end repeat
		if name of first application process whose frontmost is true is not "Terminal" then error "Terminal didn't come to the front"
		delay 0.15
		if action is "paste" then
			keystroke "v" using command down
			if item 3 of argv is "1" then
				delay 0.4
				key code 36
			end if
		else if action is "key" then
			key code ((item 3 of argv) as integer)
		end if
	end tell
	return prevApp
end run
