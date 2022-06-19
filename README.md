# 2D Vector Editor written in Zig with Hexops Mach Engine in the future.

Right now this shows an colored Window.

Load submoludes:
`git submodule update --init --recursive`

Build it and run it with:
`zig build run`

Then modify frag.wgsl and save. The window will update and use the new fragment shader.
If errors occur, the window will show a black_screen and an error message will be written to stdout.