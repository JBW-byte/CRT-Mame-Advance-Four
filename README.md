<div align="center">

# 🕹️ Reshade CRT-Mame-Advance-Four

### *State-of-the-Art experimental CRT Simulation Engineered Specifically for MAME64 & Arcade Preservation, compatible with many more emulators*

[![ReShade Version](https://img.shields.io/badge/ReShade-5.0%2B%20%7C%206.6%2B-blue?style=for-the-badge&logo=reshade)](https://reshade.me)
[![Architecture](https://img.shields.io/badge/Pipeline-12--Pass%20(10--Pass%20Fast%20Mode)-purple?style=for-the-badge)]()
[![Display Support](https://img.shields.io/badge/Display-HDR10%20%7C%20scRGB%20%7C%20SDR-yellow?style=for-the-badge)]()
[![API Support](https://img.shields.io/badge/APIs-DX10%20%7C%20DX11%20%7C%20DX12%20%7C%20Vulkan%20%7C%20OpenGL-brightgreen?style=for-the-badge)]()
[![Ko-fi](https://img.shields.io/badge/Ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/led_jbw)

<p align="center">
  <b>Author:</b> L.E.D. &nbsp;|&nbsp; <b>Version:</b> 4.10 Deluxe Edition
</p>

---

</div>

## 📖 Overview

**`CRT-Mame-Advance-Four`** is a high-performance, physically grounded CRT simulation shader engineered specifically for arcade emulation in **MAME64**. [RetroArch Slang conversion](https://github.com/JBW-byte/RetroArch-CRT-Mame-Advance-Four/tree/main)

Built from the ground up to eliminate common emulation artifacts (such as moiré pattern fringing, white-clipping, shadow crush, and uneven scanline dilation), this shader integrates physical electron beam dynamics, multi-subpixel OLED phosphor layouts, true linear-space analog signal modeling, and cabinet bezel optical reflections.

---

<p float="left">
  <img src="https://raw.githubusercontent.com/JBW-byte/Screenshots/refs/heads/main/CRT-Mame-Advance-Four.png" width="48%" />
  <img src="https://raw.githubusercontent.com/JBW-byte/Screenshots/refs/heads/main/CRT-Mame-Advance-Four-2.png" width="48%" />
</p>

Captured using BGFX with the default chain selected for a free smoothing pass. For blur/smoothing adjustments in ReShade, tweak `Blur_Width` between `1.0` and `2.0`, and match the **Arcade Raster Line Preset** to the game hardware.
<br><br>
Auto-TATE detection attempts to switch automatically between Horizontal (`4:3`) and Vertical (`3:4`) layouts; you may need to set it manually on games with very dark outer screens, or when using MAME side bezel artwork (which triggers the flank sensor as Horizontal).

## ✨ Key Features

### ⚡ 1. Electron Beam Dynamics & Dynamic Scanlines
* **Non-Linear Beam Blooming:** Scanline thickness dynamically expands on bright highlights and narrows in shadow troughs, mimicking true CRT cathode voltage response.
* **Scanline Line Presets:** Native line-rate presets covering all major arcade systems:
  * **224 Lines:** Capcom CPS-1/2/3, SNK Neo-Geo
  * **240 Lines:** Standard Arcade, NES, Sega Master System
  * **256 Lines:** PC Engine, Midway Y/T-Unit (*Mortal Kombat*, *NBA Jam*)
  * **288 Lines:** Namco Classics (*Pac-Man*, *Galaga*), PAL Arcade systems
  * **384 Lines:** Sega Model 2 / Model 3 Medium-Resolution
  * **480 Lines:** Sega NAOMI, Dreamcast, Standard VGA

### 🎯 2. Optical Engineering, Signal & Mask Fidelity
* **Dynamic Beam Dilation & Edge Focus:** Non-collapsing Gaussian profile interpolates beam width between dark troughs and highlight blooms with clamped corner yoke defocus.
* **7-Tap Gaussian & Analog RC Signal Filtering:** Corner-safe 7-tap symmetric Gaussian, asymmetric JAMMA RC cable bleed, and dual-axis flyback defocus.
* **Hardware-Interleaved NTSC/PAL Engine:** 3-tap composite filter with luma/chroma phase crosstalk and animated dot crawl.
* **Host Subpixel Matrix Matching:** Clean phosphor mask reproduction tailored for Standard RGB, Inverted BGR, LG WRGB WOLED, and Samsung QD-OLED triangular matrices.
* **Mathematical Auto Mask Compensation:** Mean-transmission normalization prevents mask patterns from dimming the display without clipping highlights or washing out phosphor contrast.
* **4-Tap Bilinear Diffuse Glow:** Wide, energy-conserving diffuse bloom protected against bezel artwork bleed, paired with soft-knee highlight extraction.
* **Zero-Fringe Stationary Tube Framing:** Exact rounded-box Signed Distance Field (SDF) glass bezel with single-pass blending against MAME cabinet artwork.
* **Optical Auto-TATE Detection:** Automatic horizontal (`4:3`) and vertical (`3:4`) raster switching via optical flank luminance probes and temporal hysteresis.
* **True HDR10, scRGB & Auto Swapchain Support:** Native Rec.2020 color transforms with SMPTE ST 2084 (PQ) encoding, overflow-safe highlight roll-off, physically matched SDR/HDR black levels, and optional `Auto` detection (`BUFFER_COLOR_SPACE`).

### 🔬 3. Vintage Hardware & Tube Quirks
* **High-Voltage Anode Sag (Screen Breathing):** Linearized beam-current probing balloons the raster behind a stationary glass bezel during full-screen explosions and flashes.
* **Phosphor Persistence & Tube Aging:** Independent R/G/B phosphor decay trails (`P_Decay`), phosphor burn-in/aging (`Tube_Age`), and `480i`/`240p` interlacing/line jitter.
* **Deflection Yoke Deconvergence:** Static and radial RGB convergence misalignment with full-luminance bleed scaling.
* **Framerate-Independent AC Hum Bar & Sync Sweep:** Timer-driven rolling ground-loop hum and single-wave refresh sweep that stay consistent across 60Hz, 120Hz+, and VRR displays.
* **P22 Phosphor Gamut Mixing:** Reconstructs authentic EBU/P22 arcade phosphor chromaticity.

---

## 🚀 Performance Architecture

* **Bandwidth & Precision Optimization:** Intermediate linear targets use **`32-bit R11G11B10F`** on ReShade 6.6+ (`D3D10+ / OpenGL / Vulkan`)—cutting VRAM bandwidth in half vs. `RGBA16F` while eliminating 10-bit dark-shadow banding—with automatic `RGBA16F` fallback on older ReShade builds or D3D9. Faceplate halation runs at half resolution (75% bandwidth reduction), and diffuse glow runs at 1/4 resolution using a 4-tap bilinear box downsampler (covering full 4×4 blocks).
* **VRAM Pooling & Early-Outs:** Transient scratch targets use `< pooled = true; >` to alias VRAM across effects without disturbing temporal history buffers. Outer bezel regions and rounded corners (`maskClip <= 0.0`) early-exit before scanline/mask sampling, and disabled optical passes return a constant zero-fill.
* **Adaptive Deconvergence Branching:** Uniform GPU branch skips red/blue coordinate offset lookups when convergence is centered, eliminating 66% of raster texture fetches.
* **Optional Fast 10-Pass Mode:** Set `CRT_ENABLE_PERSISTENCE=0` in ReShade's **Preprocessor Definitions** to skip both persistence passes and free two full-resolution render targets when phosphor ghosting isn't needed.
* **Quality Profiles:** Selectable performance tiers (`Performance` 2-line, `Balanced` 3-line, and `Ultra` 5-line dynamic beam taps).

---

BGFX on its own looks great for the best performance — my custom preset: https://github.com/JBW-byte/Mame-BGFX-Reshade

```text
📁 MAME/
└── 📁 reshade-shaders/
    └── 📁 Shaders/
        └── CRT-Mame-Advance-Four.fx
```

---

## ⚙️ Recommended `mame.ini` Settings

Generate a config with `mame -createconfig` if needed, and set the following options so the shader receives a cleanly framed image:

| Setting | Value | Notes |
| :--- | :--- | :--- |
| **video** | `bgfx` | Recommended (`bgfx`, `d3d`, or `opengl`) |
| **filter** | `1` | `1` = bilinear pre-smoothing, `0` = raw sharp pixels |
| **keepaspect** | `1` | Maintain original `4:3` / `3:4` game aspect ratio |
| **unevenstretch** | `1` | Fractional scaling to fill the tube frame (`0` = integer-only borders) |
| **bgfx_backend** | `d3d11` | `d3d11`, `d3d12`, `vulkan`, `opengl`, or `auto` (match your ReShade API) |
| **bgfx_screen_chains** | `default` | `default` (free bilinear smoothing) or `unfiltered` (raw pixels) |

> **Tip:** Make sure the **API selected in ReShade** during installation matches `bgfx_backend` (e.g., DirectX 10/11/12 for `d3d11`/`d3d12`, Vulkan for `vulkan`, or OpenGL for `opengl`). If using `video d3d` or `video opengl` instead of `bgfx`, install ReShade for DirectX 9 or OpenGL respectively.
