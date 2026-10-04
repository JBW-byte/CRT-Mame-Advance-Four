<div align="center">

# 🕹️ Reshade CRT-Mame-Advance-Four

### *State-of-the-Art CRT Simulation Engineered Specifically for MAME64 & Arcade Preservation, compatible with many more emulators*

[![ReShade Version](https://img.shields.io/badge/ReShade-5.0%2B%20%7C%206.0%2B-blue?style=for-the-badge&logo=reshade)](https://reshade.me)
[![Architecture](https://img.shields.io/badge/Pipeline-12--Pass%20(10--bit%20Optimized)-purple?style=for-the-badge)]()
[![Display Support](https://img.shields.io/badge/Display-HDR10%20%7C%20scRGB%20%7C%20SDR-yellow?style=for-the-badge)]()
[![API Support](https://img.shields.io/badge/APIs-DX10%20%7C%20DX11%20%7C%20DX12%20%7C%20Vulkan%20%7C%20OpenGL-brightgreen?style=for-the-badge)]()
[![License](https://img.shields.io/badge/License-MIT-orange?style=for-the-badge)]()

<p align="center">
  <b>Author:</b> L.E.D. &nbsp;|&nbsp; <b>Version:</b> 4.7 Deluxe Edition
</p>

---

</div>

## 📖 Overview

**`CRT-Mame-Advance-Four`** is a high-performance, physically grounded CRT simulation shader engineered specifically for arcade emulation in **MAME64**. 

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
* **TATE Orientation:** First-class support for vertical arcade rasters (*DoDonPachi*, *Ikaruga*, *1942*).

### 🔍 2. Phosphor Mask & Advanced Display Matrix Support
* **Authentic Mask Profiles:**
  * **Aperture Grille:** Fine-pitch vertical stripe mask (Sony Trinitron / BVM / PVM).
  * **Slot Mask:** Staggered rectangular arcade slot mask (Nanao MS9, Wells-Gardner).
  * **Shadow Mask:** Classic dot-triad delta mask.
* **Modern Display Subpixel Mapping:**
  * **Standard RGB:** LCD Panels.
  * **Inverted BGR:** Laptops and inverted desktop displays.
  * **LG WOLED (WRGB):** Dedicated 4-subpixel cadence with white-subpixel attenuation, preventing color wash-out on OLED panels.
  * **Samsung QD-OLED:** Triangular subpixel array smoothing to eliminate fringing.
* **Auto Mask Brightness Compensation (`M_AutoComp`):** Dynamically calculates mask transmission loss and restores target luminance without clipping highlights.
* - HDR10 / scRGB Profiles: Industry-standard Rec.2020 / SMPTE ST 2084 PQ & scRGB mapping.

### 📡 3. Linear-Space Analog Signal & NTSC Composite Emulation
* **Pure Linear-Space YIQ Processing:** Chroma/Luma decoding operating completely free of gamma-space clipping distortions.
* **Asymmetric Analog RC Delay Lines:** Authentic low-pass cable decay profile mimicking JAMMA harness color bleed.
* **Composite Dot Crawl:** Frequency-locked subcarrier crosstalk and animated dot crawl with adjustable clock resolutions.

### 📺 4. Glass Curvature, Bezel Reflections & Framing
* **Barrel Curvature Distortion:** Glass tube curvature with exact piece-wise signed distance field (SDF) corner clipping.
* **MAME Artwork Pass-Through (`UI_PassThroughBorder`):** Option to pass through original MAME bezels, marquees, and side artwork untouched while constraining CRT processing strictly to the active 4:3 / 3:4 tube raster.

### 🔬 5. Vintage Hardware & Tube Quirks
* **High-Voltage Anode Sag (Screen Breathing):** The tube raster physically balloons outward during full-screen explosions and flashes.
* **Phosphor Persistence (Ghosting):** Independent R/G/B phosphor decay curves simulating classic arcade tube persistence.
* **Deflection Yoke Deconvergence:** Radial and static multi-axis RGB convergence misalignment.
* **AC Ground Hum Bar:** Rolling 50Hz / 60Hz power supply ground loop hum.
* **P22 Phosphor Gamut Mixing:** Reconstructs authentic EBU/P22 arcade phosphor chromaticity.

---

## 🚀 Performance Architecture

* **Bandwidth Optimization:** Halation runs at half resolution (75% VRAM bandwidth reduction) and diffuse glow runs at 1/8th resolution with a 16-tap hardware-bilinear downsampler.
* **Zero-Branch Inner Loops:** Flattened branchless math for deconvergence and scanlines to maximize GPU warp occupancy.
* **Hardware Discard:** Disabled features execute `discard;` instantly, bypassing unneeded render target operations.
*  Quality Profiles: Selectable tiers (Performance 2-line, Balanced, Ultra).

---

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

