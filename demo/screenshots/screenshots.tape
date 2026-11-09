# Records docs/images/*. Run through ./demo/screenshots/screenshots.sh, which
# sets up the isolated Docker daemon and demo stacks this expects.

Output out/demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1100
Set Height 780
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set BorderRadius 10
Set TypingSpeed 60ms

Hide
Type "export PS1='\[\e[1;34m\]~/docker-stacks\[\e[0m\] $ ' DSM_REFRESH=2; cd /home/you/docker-stacks; clear"
Enter
Sleep 500ms
Show

# Plain status overview
Type "dsm"
Sleep 300ms
Enter
Sleep 3s
Screenshot out/status.png
Sleep 1s

Type "clear"
Enter
Sleep 300ms

# Interactive TUI
Type "dsm -I"
Sleep 300ms
Enter
Sleep 2s
Screenshot out/tui.png
Down
Sleep 700ms
Down
Sleep 700ms
Down
Sleep 700ms
Enter
Sleep 1500ms
Down
Sleep 800ms
Screenshot out/containers.png
Down
Sleep 800ms
Down
Sleep 800ms
Type "q"
Sleep 1s
Type "/"
Sleep 400ms
Type@150ms "mon"
Sleep 400ms
Enter
Sleep 1800ms
Escape
Sleep 800ms
Type "q"
Sleep 500ms

Type "clear"
Enter
Sleep 300ms

# Network view (still only)
Hide
Type "dsm -n"
Enter
Sleep 2s
Show
Screenshot out/network.png
Sleep 500ms
