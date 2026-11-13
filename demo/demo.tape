Output demo.gif
Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 15
Set Width 1100
Set Height 420
Set Padding 16
Set Theme "Dracula"
Set CursorBlink false
Set TypingSpeed 40ms

# Keep the prompt free of host and path.
Hide
Type "PS1='$ '"
Enter
Type "clear"
Enter
Show

Sleep 1s

Type "snails new demo 2>/dev/null"
Enter
Sleep 6s

Type "cd demo"
Enter
Sleep 1s

# The first build compiles the app. Build it once outside the recording so
# the visible demo stays short; the README footnote says so. Development logs
# are muted so the terminal shows the loop, not the request records.
Hide
Type "echo 'Snails.logger.level = :warn' >> config/environment.rb"
Enter
Type "bin/test"
Enter
Sleep 180s
Type "clear"
Enter
Show

Type "bin/test 2>/dev/null"
Enter
Sleep 6s

Type "bin/dev 2>/dev/null &"
Enter
Sleep 6s

Type "curl -s http://127.0.0.1:3000/up; echo"
Enter
Sleep 4s

Type "kill %1"
Enter
Sleep 3s
