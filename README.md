# dlss5-proton

Install DLSS 5 Neural Rendering and DLAA into Steam games running under Proton.

NVIDIA ships neural rendering as an NGX feature that only exists on Direct3D 12,
delivered over an OTA updater that does not run under Wine. Games without DLSS
have nothing to hook in the first place. This installer wires up the community
add-ons that work around both problems, applies the two settings that Proton
needs and that no upstream project documents yet, and verifies every download
against a known hash.

Everything here is a wrapper. The actual work is done by
[dlss5-bridge](https://github.com/NIGos/dlss5-bridge),
[addon-dlssnr-linux](https://github.com/NapXDD/addon-dlssnr-linux),
[DLSS5-Reshade-AIO](https://github.com/kibblerz/DLSS5-Reshade-AIO) and
[ReShade](https://reshade.me).

## Status

Verified on one machine: RTX 4080, driver 610.57.04, GE-Proton11-3, Ubuntu 24.04.

| Game | Renderer | Result |
| --- | --- | --- |
| The Lord of the Rings Online | D3D11, no native DLSS | `nr`: 303,000 evaluates over 77 minutes, zero failures. Bridge 0.66 ms/frame, 6% of frame time |
| Galactic Civilizations IV | D3D11, no native DLSS | `nr`: neural rendering running, 1,800 evaluates, zero failures |
| International Trading League | D3D11, no native DLSS | `dlaa`: 0.6 ms/frame at 1920x1080, frame rate unchanged |

Both modes work. They are alternatives, not layers: pick one.

What this cannot do is improve a game that has nothing to gain. The substitute
contract is fed approximated inputs and runs on the presented frame, UI
included; on a flat 2D or menu-heavy title the honest outcome is softer text,
not a better picture. It belongs on 3D scenes with motion.

## Requirements

- NVIDIA GPU, RTX 40 (Ada) or RTX 50 (Blackwell)
- Proprietary NVIDIA driver, **610 or newer**. Older branches refuse NGX
  feature 18 with `0xBAD00001`, whatever else is configured.
- Steam with a Proton runner. GE-Proton, proton-cachyos and Valve's Proton all work.
- A 64-bit game executable. There is no 32-bit path.
- `curl`, `7z`, `unzip`, `tar`, `sha256sum`

The game must already run under Proton. Check
[ProtonDB](https://www.protondb.com/) first; this cannot fix a game that does
not launch.

## 32-bit games

`dlss5-install.sh` refuses a 32-bit executable, because NGX has no 32-bit
runtime: NVIDIA ships none, the driver puts `_nvngx.dll` in `system32` and
leaves `syswow64` empty, and the DLSS SDK has no `Windows_x86` build.

`dlss5-install-x86.sh` covers those games through DLSS5-Reshade-AIO's two-process
design. A 32-bit add-on loads inside the game and starts a 64-bit wrapper that
does the NGX work, so the folder ends up with two ReShade installations:

```
game.exe
dxgi.dll                     32-bit ReShade, add-on build
d3dcompiler_47.dll           32-bit
standalone-dlssnr.addon32    the carrier
host64/
  dxgi.dll                   64-bit ReShade, add-on build
  d3dcompiler_47.dll         64-bit
  AIO DLSS5 32-bit Wrapper.exe
  standalone-dlssnr.addon64  where neural rendering runs
  nvngx_dlssnr.dll  nvngx_dlss.dll  nvngx_dlssg.dll
```

```
./dlss5-install-x86.sh /path/to/game32.exe
./dlss5-install-x86.sh --api d3d9 /path/to/oldgame.exe
```

Native D3D9 and D3D11 are supported. A D3D9 game needs `--api d3d9`, which names
the proxy `d3d9.dll` and moves any `dxgi.dll` aside — the bridge needs Windows'
real DXGI, and a second proxy there stops the add-on loading. `--uninstall` puts
it back.

The `nr` mode does not exist here. `dlss5-bridge` and `addon-dlssnr-linux` ship
64-bit add-ons only.

**Untested at runtime.** The installation itself is verified — every file lands
in the right place with the right bitness, install and uninstall are clean — but
no 32-bit game has been launched with it yet.

## Install

```
git clone https://github.com/24high/DLSS5-Reshade-Linux-Steam
cd DLSS5-Reshade-Linux-Steam
./dlss5-install.sh [options] /path/to/game.exe
```

Point it at the executable that actually renders, not at a launcher. Games that
ship a separate launcher usually keep the client in a subdirectory:

```
./dlss5-install.sh ~/SteamLibrary/steamapps/common/Some Game/x64/game64.exe
```

The installer resolves the Steam library from that path, reads the AppID out of
the matching `appmanifest_*.acf`, and finds the Proton prefix on its own. Then
set the launch options Steam passes to the game:

```
PROTON_FORCE_NVAPI=1 WINEDLLOVERRIDES=dxgi=n,b %command%
```

`PROTON_FORCE_NVAPI` is the GE-Proton and proton-cachyos spelling; Valve's
Proton calls it `PROTON_ENABLE_NVAPI`. Without `dxgi=n,b`, Wine loads its own
`dxgi` and ReShade is never called.

Start the game, press <kbd>Home</kbd> for the ReShade overlay, then run:

```
./check-dlss5.sh /path/to/game.exe
```

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `--mode nr\|dlaa` | `nr` | Which add-on path is active |
| `--model auto\|ref\|rtx40` | `auto` | Neural rendering model build |
| `--prefix PATH` | detected | Proton prefix, if detection fails |
| `--dlss PATH` | NVIDIA SDK | Use a local `nvngx_dlss.dll` instead |
| `--cache DIR` | `~/.cache/dlss5-installer` | Download cache |
| `--uninstall` | | Remove and restore the backup |
| `-y`, `--yes` | | Do not prompt |

Re-running with a different `--mode` switches over without downloading anything.

## Modes

### `nr` — neural rendering (default)

`dlss5-bridge` builds a synthetic DLAA contract from ReShade's depth buffer and
motion vectors, and runs it on a private D3D12 device. `addon-dlssnr-linux`
detours the NGX entry points, sees that contract, and runs the neural pass on it
through its own forwarder, bypassing driver dispatch entirely.

This is the only path that produces neural rendering on Ada. It is also the
lower-quality path by construction: the contract is approximated rather than
supplied by the engine, so text softens and dense foliage smears. The bridge's
own log says so on every launch.

### `dlaa` — super resolution only

Use this when `nr` will not work: `vort_Motion.fx` fails to compile on some
runtimes with `E5017: Unhandled attribute 'fastopt'`, and without it the bridge
has no motion vectors. `dlaa` needs no shader at all.

`DLSS5-Reshade-AIO` copies the back buffer into a texture shared with a private
D3D12 NGX device and runs DLSS super resolution at native resolution. Cheap,
stable, and the more mature pipeline of the two.

Since v2.2.0 it drives NVIDIA Optical Flow itself and makes that its default
motion source, which its author reports as substantially less boiling, smearing
and ghosting. That is worth noting next to the `nr` mode, where the bridge's own
optical flow request is refused by the driver (`API version 0x20`,
`INVALID_PTR`) and motion vectors come from a ReShade shader instead.

Its neural rendering goes through the driver's NGX dispatch, which refuses
feature 18 on Ada. The installer therefore writes `NeuralRendering=0` on RTX 40
and `NeuralRendering=1` on RTX 50.

## Model builds

Both builds report version `310.8.0.0` and are the same size. They accept
different hardware, and the wrong one answers `0xBAD00001 FeatureNotSupported`.

| Build | SHA-256 | Verified on |
| --- | --- | --- |
| `ref` | `e16bcf15…fc8e` | RTX 50 / Blackwell |
| `rtx40` | `4b8d19bc…ba05` | RTX 40 / Ada |

`--model auto` reads the compute capability from `nvidia-smi`: `8.9` selects
`rtx40`, `10.0` and above select `ref`. Turing and Ampere have no verified build;
the installer warns and falls back to `rtx40`.

`addon-dlssnr-linux` prints a warning that the `rtx40` build is not the one it
was tested against. On Ada that warning is expected and was contradicted by 77
minutes of clean operation.

## What gets installed

Into the directory holding the executable:

| File | Source |
| --- | --- |
| `dxgi.dll` | ReShade 6.8.0, add-on build, extracted from the official installer |
| `dlss5-bridge.addon64` | dlss5-bridge v1.4.8 |
| `dlssnr-linux.addon64`, `nvngx.dll_nrfwd.dll` | addon-dlssnr-linux v0.2.1 |
| `standalone-dlssnr.addon64`, `nvngx.dll` | DLSS5-Reshade-AIO v2.2.1, from the published ZIP, checksum verified |
| `nvngx_dlssnr.dll` | RankFTW/rhi-repo, hash-checked |
| `nvngx_dlss.dll` | NVIDIA DLSS SDK v310.7.0 |
| `nvngx_dlssg.dll` | your installed driver |
| `d3dcompiler_47.dll` | copied from another game on your system, see below |
| `reshade-shaders/Shaders/` | crosire/reshade-shaders, slim branch — mainly for `ReShade.fxh` |
| `reshade-shaders/Shaders/vort_Shaders/` | vortigern11/vort_Shaders, MIT — `nr` mode only |
| `ReShade.ini`, `ReShadePreset.ini`, `dlss5-bridge.cfg` | written by the installer |

Add-ons belonging to the inactive mode go to `_disabled/`. Two DLSS 5 add-ons in
one directory make the feature create fault inside `D3D12Core`
([dlss5-bridge #16](https://github.com/NIGos/dlss5-bridge/issues/16)), so the
installer clears both locations before placing either set.

Files that already existed are copied to `_dlss5-backup-<timestamp>/` on the
first run only, and restored by `--uninstall`. A marker file
`.dlss5-install.state` records the exe, mode, model and prefix.

## The three things that matter

None of them is documented upstream. All were found the hard way.

### A real d3dcompiler_47.dll

Wine's built-in HLSL compiler does not implement every attribute. `[fastopt]`
is one, and effects that use it fail:

```
Failed to compile '...\vort_Shaders\vort_Motion.fx':
<anonymous>:115:13: E5017: Aborting due to not yet implemented feature: Unhandled attribute 'fastopt'.
```

That wording is Wine's, not ReShade's. Without motion vectors the bridge
reports `verdict: not viable -- motion vectors no` and the panel shows
*no frames rendered*. The same ReShade binary and the same shader sources
compile without a single error next to a game that ships Microsoft's
redistributable compiler.

The installer searches every Steam library listed in `libraryfolders.vdf` for a
64-bit `d3dcompiler_47.dll` carrying Microsoft's *"for Redistribution"* string
and copies the newest one next to the executable. Many games ship it — on the
test machine six did, one of them inside the very game that was failing, in a
tools subdirectory. If none is found, install it into the prefix instead:

```
WINEPREFIX=<prefix> winetricks -q d3dcompiler_47
```

The D3D runtime DLLs are a different matter and must **not** be replaced.
`d3d11.dll`, `d3d12.dll`, `d3d10.dll` and `dxgi.dll` come from DXVK and
vkd3d-proton, which translate to Vulkan; Microsoft's builds need a Windows
kernel driver and cannot load under Wine. `dxgi.dll` in the game directory is
ReShade itself.

### `unwrap=0` in `dlss5-bridge.cfg`

With the default `unwrap=1` the bridge crashes on its first evaluate:

```
[bridge] evaluate raised exception 0xC0000005 -- disabling to protect the game
[bridge]   it faulted in .../x64/dxgi.dll +0x147F7F
```

The fault is in ReShade, not in the add-on. `convert_to_original_cpu_descriptor_handle`
assumes every handle it receives is one of ReShade's synthetic ones and indexes
`_descriptor_heaps` with bits taken from it. Given a real vkd3d VA-encoded
handle it reads out of bounds and returns garbage, which vkd3d then dereferences.
The `assert` that would have caught it is compiled out in release builds. The
analysis is [flshy1337's, in dlss5-bridge #22](https://github.com/NIGos/dlss5-bridge/issues/22).

`unwrap=0` keeps ReShade's proxy device on the D3D12 side and the fault does not
occur. That issue still lists the D3D11 path as blocked; on this machine it is not.

### The fake DriverStore

Both add-ons look for NVIDIA's NGX core where Windows keeps it:

```
NGX core: no NVIDIA DriverStore packages matched
          C:\windows\system32\DriverStore\FileRepository\nv*.inf_amd64_*  error=2
standalone pipeline FAILED at driver NGX core exports: 0x000000B7
```

Wine has no DriverStore; Proton drops `_nvngx.dll` straight into `system32`. The
installer creates a directory matching that glob inside the prefix and copies
`_nvngx.dll`, `nvngx.dll` and `nvngx_dlssg.dll` from the host driver into it.

**Repeat after every driver update.** The shim keeps the old NGX core while the
kernel module moves on. `check-dlss5.sh` compares the two and warns; re-running
the installer fixes it.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| No `ReShade.log` in the game directory | Wine used its own dxgi | Set `WINEDLLOVERRIDES=dxgi=n,b` |
| `ReShade.log` names a launcher exe | Installed next to the wrong binary | Re-run against the client exe |
| `CreateFeature(18) => 0xbad00001` | Wrong model build, or driver older than 610 | `--model auto`; check `nvidia-smi` |
| `FAILED at driver NGX core exports: 0x000000B7` | DriverStore shim missing or stale | Re-run the installer |
| `evaluate raised exception 0xC0000005` in `dxgi.dll` | `unwrap` is not 0 | Set `unwrap=0` in `dlss5-bridge.cfg` |
| `verdict: not viable -- motion vectors no` | `vort_MotionEffects` not enabled | Enable it in the ReShade Home tab |
| `E5017 ... Unhandled attribute 'fastopt'` | Wine's built-in HLSL compiler | Re-run the installer; it copies a Microsoft `d3dcompiler_47.dll` |
| `D3D11CreateDeviceAndSwapChain failed with E_FAIL` | No working Vulkan driver | `nvidia-smi`; a half-finished driver upgrade looks exactly like this |
| Game starts, nothing changes | Two DLSS 5 add-ons present | `check-dlss5.sh` reports this |

`Failed to install hook for D3D10...` in `ReShade.log` is normal under Wine and
can be ignored.

## Limitations

- Neural rendering on a game without native DLSS is fed an approximated
  contract. It is measurably worse than an engine-side integration and always
  will be: the ceiling is set by the inputs, not by the tuning.
- The pass runs on the presented frame, UI included.
- Nothing here improves frame rate. DLAA renders at native resolution; the
  neural pass only costs.
- Hardware optical flow does not initialise under Proton
  (`refused API version 0x20 with status 1`), so motion vectors come from a
  ReShade shader. That estimator is the source of the smearing.
- `nvngx_dlssnr.dll` is an unreleased NVIDIA binary. It is not redistributed
  here; the installer downloads it from a public mirror and checks its hash.
- Third-party add-ons in an online game carry a risk to your account.

## Files

| | |
| --- | --- |
| `dlss5-install.sh` | Installer for 64-bit games |
| `dlss5-install-x86.sh` | Installer for 32-bit games, AIO two-process path |
| `check-dlss5.sh` | Post-run report |
| `set-steam-launch-options.sh` | Writes the launch options into `localconfig.vdf`. Steam must be closed. |

## Credits

- [NIGos/dlss5-bridge](https://github.com/NIGos/dlss5-bridge)
- [NapXDD/addon-dlssnr-linux](https://github.com/NapXDD/addon-dlssnr-linux) — GPL-3.0
- [kibblerz/DLSS5-Reshade-AIO](https://github.com/kibblerz/DLSS5-Reshade-AIO)
- [Dagherbou/OptiScaler_DLSSNR](https://github.com/Dagherbou/OptiScaler_DLSSNR) and
  [optiscaler/OptiScaler](https://github.com/optiscaler/OptiScaler) — GPL-3.0,
  where the feature-18 recipe originates
- [vortigern11/vort_Shaders](https://github.com/vortigern11/vort_Shaders) — MIT
- [crosire/reshade](https://github.com/crosire/reshade)
- flshy1337, for the descriptor-converter analysis in dlss5-bridge #22

## License

Copyright (C) 2026 Dennis Michael Heine

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE).

GPL-3 rather than a permissive licence because the recipe these scripts
automate comes from GPL-3 work: `addon-dlssnr-linux` is GPL-3 and derives from
OptiScaler, which is GPL-3 as well. The scripts here contain none of that code,
they only install it.

Nothing in this repository redistributes NVIDIA binaries. `nvngx_dlssnr.dll`,
`nvngx_dlss.dll`, `nvngx_dlssg.dll` and `d3dcompiler_47.dll` are downloaded from
their upstream sources, taken from your installed driver, or copied from a game
already on your disk, and are checked against a known hash where one exists.
