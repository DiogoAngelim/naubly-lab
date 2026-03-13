-- Best-effort helper for enabling Internet Sharing on macOS.
-- This is fragile because System Settings UI structure can change after macOS updates.
-- Requires Accessibility permission for the app running osascript/Terminal.
-- Failure here should not block the core devlab service.

try
  tell application "System Settings"
    activate
  end tell

  delay 1.5

  tell application "System Events"
    tell process "System Settings"
      set frontmost to true

      -- Attempt to navigate quickly via search box for "Internet Sharing".
      keystroke "f" using {command down}
      delay 0.3
      keystroke "Internet Sharing"
      delay 1.0
      key code 36

      -- Toggle attempt is intentionally conservative; UI may differ across versions.
      delay 2.0
      key code 36
    end tell
  end tell

  return "Internet Sharing toggle attempt executed. Verify manually in System Settings."
on error errMsg number errNum
  return "Hotspot automation failed (expected occasionally): " & errMsg & " (" & errNum & ")"
end try
