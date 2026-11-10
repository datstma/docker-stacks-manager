# Records docs/images/import*.png. Run through ./demo/screenshots/screenshots.sh,
# which starts the standalone containers this converts.

# Only the screenshots are kept (this GIF stays in the VHS container)
Output import.gif

Set Shell "bash"
Set FontSize 16
Set Width 1100
Set Height 780
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set BorderRadius 10
Set TypingSpeed 60ms

Type "export PS1='\[\e[1;34m\]~/docker-stacks\[\e[0m\] $ ' DSM_REFRESH=2; cd /home/you/docker-stacks; clear"
Enter
Sleep 500ms
Type "dsm -I"
Enter
Sleep 6s

# The import menu: paste a command, or pick a container
Type "i"
Sleep 3s
Down
Sleep 500ms
Down
Sleep 800ms
Screenshot out/import.png

# The generated file, and the stack folder prompt
Enter
Sleep 2500ms
Screenshot out/import-file.png

# Write it and switch the container over
Type "notes"
Enter
Sleep 600ms
Type "y"
Sleep 800ms
Type "y"
# busybox httpd as PID 1 ignores SIGTERM, so docker stop waits its 10s
Sleep 18s
Screenshot out/import-done.png
Sleep 500ms
