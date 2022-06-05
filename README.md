# 2D Vector Editor for Hexops Mach Engine written in Zig.

In deps folder link to cloned mach project: 
`ln -l ../../mach/ mach`

This is an executable for testing wgsl shaders on the fly.
Build it and run it with:
`zig build run-ved2d`

Then modify shaderexp/frag.wgsl and save. The window will update and use the new fragment shader.
If errors occur, the window will show a black_screen and an error message will be written to stdout.
