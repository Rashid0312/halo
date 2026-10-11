-- Usage: osascript messages-send.applescript <phone or email> <text>
-- Tries iMessage first, then SMS (needs iPhone Text Message Forwarding).
-- "Sent" means Messages accepted it; delivery failures show up in Messages later.
on run argv
	set targetHandle to item 1 of argv
	set msg to item 2 of argv
	tell application "Messages"
		try
			set svc to 1st account whose service type = iMessage
			send msg to participant targetHandle of svc
			return "imessage"
		on error errIM
			try
				set svc to 1st account whose service type = SMS
				send msg to participant targetHandle of svc
				return "sms"
			on error errSMS
				error "iMessage: " & errIM & " | SMS: " & errSMS
			end try
		end try
	end tell
end run
