Output demo.gif
Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 30
Set Width 2500
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
Type `snails() { if [ "$1" = "new" ]; then command snails "$@" 2>/dev/null; else command snails "$@"; fi; }`
Enter
Type `bin/test() { command ./bin/test "$@" 2>/dev/null | sed 's/ (cached)//'; }`
Enter
Type `bin/dev() { command ./bin/dev "$@" 2>/dev/null; }`
Enter
Type "clear"
Enter
Show

Sleep 1s

Type "snails new demo --scaffold"
Enter
Sleep 8s

Type "cd demo"
Enter
Sleep 1s

Type "snails migrate load"
Enter
Sleep 4s

Type "cat config/routes.rb"
Enter
Sleep 6s

# The first build and the test run are warmed outside the recording; the
# README footnote says so. Development logs are muted as well.
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
Sleep 3s

Type `curl -s -X POST localhost:3000/posts -H 'Content-Type: application/json' -d '{"title":"Hello","body":"World"}'; echo`
Enter
Sleep 5s

Type "curl -s localhost:3000/posts/1; echo"
Enter
Sleep 5s
