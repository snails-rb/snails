Output demo.gif
Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 30
Set Width 2200
Set Height 840
Set Padding 32
Set Theme "Dracula"
Set CursorBlink false
Set TypingSpeed 80ms

# Keep the prompt free of host and path. The wrappers mute the tools' progress
# lines off-camera; the visible commands stay plain and their results stay.
Hide
Type "PS1='$ '"
Enter
Type `snails() { command snails "$@" 2>/dev/null; }`
Enter
Type `bin/test() { command ./bin/test "$@" 2>/dev/null; }`
Enter
Type `bin/dev() { command ./bin/dev "$@" 2>/dev/null; }`
Enter
Type "clear"
Enter
Show

Sleep 1s

Type "snails new demo"
Enter
Sleep 8s

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

Type "bin/test"
Enter
Sleep 8s

Type "bin/dev &"
Enter
Sleep 8s

Type "curl -s localhost:3000/up; echo"
Enter
Sleep 4s
