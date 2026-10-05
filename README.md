<div align="center">

# 🕹️ Reshade CRT-Mame-Advance-Four

### *State-of-the-Art CRT Simulation Engineered Specifically for MAME64 & Arcade Preservation, compatible with many more emulators*

[![ReShade Version](https://img.shields.io/badge/ReShade-5.0%2B%20%7C%206.0%2B-blue?style=for-the-badge&logo=reshade)](https://reshade.me)
[![Architecture](https://img.shields.io/badge/Pipeline-12--Pass%20(10--bit%20Optimized)-purple?style=for-the-badge)]()
[![Display Support](https://img.shields.io/badge/Display-HDR10%20%7C%20scRGB%20%7C%20SDR-yellow?style=for-the-badge)]()
[![API Support](https://img.shields.io/badge/APIs-DX10%20%7C%20DX11%20%7C%20DX12%20%7C%20Vulkan%20%7C%20OpenGL-brightgreen?style=for-the-badge)]()

<p align="center">
  <b>Author:</b> L.E.D. &nbsp;|&nbsp; <b>Version:</b> 4.7 Deluxe Edition
</p>

---

</div>

## 📖 Overview

**`CRT-Mame-Advance-Four`** is a high-performance, physically grounded CRT simulation shader engineered specifically for arcade emulation in **MAME64**.  [RetroArch Slang conversion](https://github.com/JBW-byte/RetroArch-CRT-Mame-Advance-Four/tree/main)

Built from the ground up to eliminate common emulation artifacts (such as moiré pattern fringing, white-clipping, shadow crush, and uneven scanline dilation), this shader integrates physical electron beam dynamics, multi-subpixel OLED phosphor layouts, true linear-space analog signal modeling, and cabinet bezel optical reflections.

---

<p float="left">
  <img src="https://raw.githubusercontent.com/JBW-byte/Screenshots/refs/heads/main/CRT-Mame-Advance-Four.png" width="48%" />
  <img src="https://raw.githubusercontent.com/JBW-byte/Screenshots/refs/heads/main/CRT-Mame-Advance-Four-2.png" width="48%" />
</p>
Captured using bgfx and default chain selected for a free smoothing pass. for blur/smoothing, change blur width in Reshade 1.0 to 2.0. Match the Arcade Raster line Preset to the game hardware.
<br><br>
There is an attempt to auto detect Horizontal or Vertical layout, you may need to set it manually, fails if the horizontal screen has dark areas, mostly ok.

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
<br>

### ⚡ 2. Electron Beam Dynamics & Dynamic Scanlines
* **Dynamic Beam Dilation:** Non-collapsing Gaussian profile interpolates beam width between dark troughs and highlight blooms with variable edge focus decay.
* **Hardware-Interleaved NTSC/PAL Engine:** 3-tap composite filter with luma/chroma phase crosstalk and animated dot crawl.
* **Host Subpixel Matrix Matching:** Clean phosphor mask reproduction tailored for Standard RGB, Inverted BGR, LG WRGB WOLED, and Samsung QD-OLED triangular matrices.
* **Mathematical Auto Mask Compensation:** Mean-transmission normalization prevents mask patterns from dimming the display without clipping highlights or washing out phosphor contrast.
* **Rebuilt 4-Tap Bilinear Diffuse Glow:** Wide, energy-conserving diffuse bloom covering up to 100+ pixels with soft-knee highlight extraction.
* **Zero-Fringe Tube Framing:** Exact rounded-box Signed Distance Field (SDF) geometry with single-pass alpha blending to eliminate dark edge halos against MAME cabinet artwork.
* **Optical Auto-TATE Detection:** Automatic horizontal (4:3) and vertical (3:4) raster switching via optical flank luminance probes and temporal Schmitt-trigger hysteresis.
* **True HDR10 & scRGB Support:** Native Rec.2020 color transforms with SMPTE ST 2084 (PQ) encoding and configurable paper white/peak luminance.
<br>

### 🔬 3. Vintage Hardware & Tube Quirks
* **High-Voltage Anode Sag (Screen Breathing):** The tube raster physically balloons outward during full-screen explosions and flashes.
* **Phosphor Persistence (Ghosting):** Independent R/G/B phosphor decay curves simulating classic arcade tube persistence.
* **Deflection Yoke Deconvergence:** Radial and static multi-axis RGB convergence misalignment.
* **AC Ground Hum Bar:** Rolling 50Hz / 60Hz power supply ground loop hum.
* **P22 Phosphor Gamut Mixing:** Reconstructs authentic EBU/P22 arcade phosphor chromaticity.

---

## 🚀 Performance Architecture

* **Bandwidth Optimization:** Intermediate render targets use 32-bit RGB10A2 format (cutting VRAM bandwidth in half vs RGBA16F). Faceplate halation runs at half resolution (75% bandwidth reduction), and diffuse glow runs at 1/4 resolution using a 4-tap bilinear box downsampler (covering full 4×4 4×4 blocks).
* **Adaptive Deconvergence Branching:** Uniform GPU branch skips red/blue coordinate offset lookups when convergence is centered, eliminating 66% of raster texture fetches.
* **Zero-Fill Pass Early-Exit:**  Disabled optical features immediately early-return a constant zero-fill vector, skipping blur loops while preserving clean render-target state without the hazards of pixel discard.
* **Quality Profiles:** Selectable performance tiers (Performance 2-line, Balanced 3-line, and Ultra 5-line dynamic beam taps).
---
BGFX on its own looks great for the best performance, my custom preset https://github.com/JBW-byte/Mame-BGFX-Reshade

## 📥 Installation

1. Install **[ReShade](https://reshade.me/)** (with full Add-on support) for your MAME executable (`mame.exe` / `mame64.exe`).
2. Copy `CRT-Mame-Advance-Four.fx` into your MAME shaders directory:
   ```text
   📁 MAME/
   └── 📁 reshade-shaders/
       └── 📁 Shaders/
           └── CRT-Mame-Advance-Four.fx

⚙️ Recommended MAME Configuration
To ensure the shader receives clean, unscaled raw pixels directly from the arcade core, configure your mame.ini:
code
   ```text
# --- Video Options ---
video                     d3d11       # Or 'bgfx' / 'opengl'
filter                    1           # 1 - smoothing on , 0 - Disable bilinear filtering
keepaspect                1           # Maintain original game aspect ratio
unevenstretch             1           # Prevent MAME software scaling distortion



