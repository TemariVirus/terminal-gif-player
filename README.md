# Terminal GIF Player

An optimised joke GIF player for the terminal.
Works on Windows and Linux, haven't tested on Mac.
A GIF may loop infinitely, so use `Ctrl+C` to exit.

## Usage

```bash
term-gif-player[.exe] <file>
```

## Build

```bash
git clone https://github.com/Zemogus/terminal-gif-player
cd terminal-gif-player
zig build -Doptimize=ReleaseFast
```

## Notes

Given that writing to stdout is extremely slow, this program only writes once per frame.
Using VT100 escape codes, it moves the cursor to only the pixels that have changed, rendering the least amount possible.
On my Windows 10 machine, however, this is only enough to play Nyan Cat and the smaller Bad Apple GIF smoothly.
My Windows 11 machine uses the GPU to render the terminal, which speeds up the program dramatically, and there it can play the busier OkaKoro GIF smoothly, but is still sluggish for the larger GIFs.
Terminals just aren't optimised for rendering moving images, who would've thought?

## Sources for GIFs

All GIFs provided are not owned by me, and are used for demostrational purposes only. Everything outside of the `test-gifs/` folder is provided under the license included in the root folder of this repository.

- [bad-apple.gif, bad-apple-original.gif](https://www.youtube.com/watch?v=FtutLA63Cp8)
- [c-donut.gif](https://github.com/limiteci/limiteci/blob/main/esc/images/donut1.gif)
- [nyan-cat.gif](https://www.youtube.com/watch?v=QH2-TGUlwu4)
- [okakoro.gif](https://www.youtube.com/watch?v=MiuFIzr8bR0)
