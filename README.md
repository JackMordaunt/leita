<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/hero-dark.svg">
    <img src="branding/hero-light.svg" alt="leita" width="538">
  </picture>
</p>

<p align="center"><b>See what is using the disk, as the scan finds it.</b><br>It reads an NTFS volume's own table directly and walks every other filesystem.</p>

## Use

```sh
leita                  # the largest files and directories under your home directory
leita /dev/nvme0n1p3   # a drive, device, image or directory
leita --live D:        # draw the answer as it is found
Leita [path]           # the same, in a window
```

Reading a live volume needs an elevated prompt. `leita -h` lists the flags.

## Build

leita is written in [Odin](https://odin-lang.org) and builds with
[just](https://just.systems). It targets Linux and Windows.

```sh
just release       # build/release/leita
just gui-release   # build/release/app/Leita
just test
```

`just` alone lists every recipe.
