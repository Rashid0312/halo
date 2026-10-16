-- Usage: osascript iterm-session.applescript <action> <tty> <arg> [submit]
--   write  type <arg> into the iTerm2 session on <tty>; submit "1" presses Return
--   char   send the character with code <arg> (27 = Esc)
-- iTerm2 takes the text directly: nothing is focused, nothing is pasted.
on run argv
	set action to item 1 of argv
	set ttyPath to item 2 of argv
	tell application "iTerm2"
		repeat with w in windows
			repeat with t in tabs of w
				repeat with s in sessions of t
					if tty of s is ttyPath then
						if action is "write" then
							tell s to write text (item 3 of argv) newline no
							if item 4 of argv is "1" then
								delay 0.3
								tell s to write text (ASCII character 13) newline no
							end if
						else if action is "char" then
							tell s to write text (ASCII character ((item 3 of argv) as integer)) newline no
						end if
						return "ok"
					end if
				end repeat
			end repeat
		end repeat
	end tell
	error "No iTerm2 session on " & ttyPath
end run
