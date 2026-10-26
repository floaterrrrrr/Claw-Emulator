# App Review test files

The repository contains original homebrew test programs in `Tests/RetroFixtures` and the generator `Tests/make-retro-fixtures.py`. The ROM programs and their original graphics/data are dedicated to the public domain under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/legalcode). The generated files contain no commercial game, console BIOS, firmware dump, or Nintendo logo image. The generator's source remains GPL-3.0-or-later; see its SPDX header.

On a Mac with Xcode command-line tools, generate the test files with:

```sh
python3 Tests/make-retro-fixtures.py /tmp/claw-review-games
```

On a machine without an ARM assembler, `--no-arm` generates only GB, GBC, and NES fixtures. For the reviewer package, include `fixture.gba` and `fixture.nes` if both have been verified in the **signed release candidate on an iPhone**. Do not include the temporary `.bin` or `.o` build files. Attach the license statement above, the matching source commit, and these instructions to the App Review notes or reviewer attachments.

Suggested verification steps for App Review:

1. Save the attached test ROMs in Files on the iPhone. Open Claw → Library → Import and select `fixture.gba`.
2. Start it. Its screen should be red. Hold **A** to change it to blue; release **A** to return to red. Open the in-game menu and make/load a save state.
3. Return to Library and import `fixture.nes`. Start it; it displays a solid red backdrop. Pause and resume, then return to Library.

These fixtures demonstrate import, rendering, input, save states, and library navigation. They do not establish compatibility or performance for other games or 3DS software. If a fixture fails on the release candidate, fix it or replace it with another lawfully redistributable game that has been tested on that exact build. Do not submit a commercial ROM, copyrighted cover art, or console keys as reviewer content.
