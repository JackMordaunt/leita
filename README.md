<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/hero-dark.svg">
    <img src="branding/hero-light.svg" alt="estoile" width="660">
  </picture>
</p>

<p align="center"><b>See what is using the disk, as the scan finds it.</b><br>It reads an NTFS volume's own table directly and walks every other filesystem.</p>

## Use

```sh
estoile                  # the largest files and directories under your home directory
estoile /dev/nvme0n1p3   # a drive, device, image or directory
estoile --live D:        # draw the answer as it is found
Estoile [path]           # the same, in a window
```

Reading a live volume needs an elevated prompt. `estoile -h` lists the flags.

## Build

estoile is written in [Odin](https://odin-lang.org) and builds with
[just](https://just.systems). It targets Linux and Windows.

```sh
just release       # build/release/estoile
just gui-release   # build/release/app/Estoile
just test
```

`just` alone lists every recipe.
