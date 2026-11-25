/*
    ===========================================================================
    CRT-Mame-Advance-Four.fx (v4.9 Deluxe Edition) Author L.E.D.
    State-of-the-art CRT simulation engineered specifically for MAME64 (other emulators supported).

    Summary of v4.9 Fixes & Improvements:
    - Fixed scRGB & HDR10 Black Level Crush: Converted COL_BlackLevel from gamma output space
      to linear physical luminance for HDR10 (pre-PQ) and scRGB, matching SDR shadow fidelity.
    - Fixed Composite Dot Crawl at Low Chroma Blur: CMP_Artifacts edge detector now falls back
      to a 1-texel luma probe when CMP_ChromaBlur < 1.0 so dot crawl stays active down to 0.0.
    - Fixed Corner Focus Blowout: Normalized and clamped B_EdgeDefocus so sharpness never turns negative.
    - Fixed Bezel Glow Bleed: Zeroed border pixels in Linearize/SignalBlur and masked/clamped Glow passes.
    - Fixed HDR10/scRGB Border Seam: Unified border/corner background mapping via GetBorderBG().
    - Fixed Shadow Banding & OpenGL/Vulkan NaNs: R11G11B10F linear targets (ReShade 6.6+ D3D10+/OGL/VK
      with RGBA16F fallback) and SafePow helpers preventing undefined pow(0.0, y).
    - Fixed Stationary Glass Bezel & Full-RGB Convergence: Fixed bezel SDF during HV sag and full-luma
      deconvergence scaling in SampleCRT() at zero extra texture bandwidth.
    - Fixed Minor Quirks: Removed CMP_ChromaBlur [0..1] dead zone, integer-aligned Shadow Mask rowShift.
    - Optimizations & Optional Controls: Added < pooled = true; > on scratch targets, corner early-out,
      timer-based hum/sync waves, 7-tap Gaussian blur, linearized HV sag probe, Auto HDR profile via
      BUFFER_COLOR_SPACE, and CRT_ENABLE_PERSISTENCE preprocessor toggle (set to 0 for max FPS).
    ===========================================================================
*/

#include "ReShade.fxh"

// Set to 0 in ReShade Preprocessor Definitions (CRT_ENABLE_PERSISTENCE=0) to omit persistence
// passes and free two full-resolution render targets when ghosting is not needed.
#ifndef CRT_ENABLE_PERSISTENCE
    #define CRT_ENABLE_PERSISTENCE 1
#endif

// Pixel-unit effects scale up above 1080p so they maintain identical physical size at 1440p/4K.
#define CRT_RES_SCALE (max(BUFFER_HEIGHT / 1080.0, 1.0))

#ifndef BUFFER_PIXEL_SIZE
#define BUFFER_PIXEL_SIZE float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)
#endif

#ifndef BUFFER_SCREEN_SIZE
#define BUFFER_SCREEN_SIZE float2(BUFFER_WIDTH, BUFFER_HEIGHT)
#endif

// Use 32-bit R11G11B10F on ReShade 6.6+ (D3D10+/OGL/VK) to preserve linear shadow precision & HDR headroom without extra VRAM.
#if (__RESHADE__ >= 60600) && (__RENDERER__ >= 0xa000)
    #define CRT_LINEAR_FMT R11G11B10F
#else
    #define CRT_LINEAR_FMT RGBA16F
#endif

uniform int framecount < source = "framecount"; >;
uniform float timer < source = "timer"; >;

// =========================================================================
// UI Uniforms
// =========================================================================

// ===================== 1. PRIMARY FEATURE TOGGLES =====================
uniform bool DPX_Enable <
    ui_label = "Enable DPX Filmic Tone";
    ui_tooltip = "Applies a normalized Cineon filmic S-curve: lifts midtones and enriches color without highlight clipping.";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = true;

uniform bool Blur_Enable <
    ui_label = "Enable Analog Signal Filtering";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = true;

uniform bool G_EnableCurvature <
    ui_label = "Enable Tube Glass Curvature";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = true;

uniform bool CMP_Enable <
    ui_label = "Enable NTSC/PAL Composite Video";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

uniform bool P_Enable <
    ui_label = "Enable Phosphor Persistence (Ghosting)";
    ui_tooltip = "Requires CRT_ENABLE_PERSISTENCE=1 (default). Set CRT_ENABLE_PERSISTENCE=0 in Preprocessor Definitions to skip persistence passes entirely.";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

uniform bool I_Enable <
    ui_label = "Enable Interlacing / Line Jitter";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

uniform bool HV_Enable <
    ui_label = "Enable High-Voltage Anode Sag";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

uniform bool HB_Enable <
    ui_label = "Enable AC Ground Loop Hum Bar";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

uniform bool AST_Enable <
    ui_label = "Enable Corner Deflection Defocus";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

uniform bool H_Enable <
    ui_label = "Enable Faceplate Glass Halation";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

uniform bool GL_Enable <
    ui_label = "Enable Diffuse Bloom / Wide Glow";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

uniform bool COL_P22Gamut <
    ui_label = "Simulate P22 Arcade Phosphor Gamut";
    ui_category = "=== 1. Primary Feature Toggles ===";
> = false;

// ===================== 2. SYSTEM & ARCHITECTURE =====================
uniform int CRT_QualityTier <
    ui_type = "combo";
    ui_items = "Performance (Fast 2-Line / Handhelds)\0Balanced (Calibrated Master Default)\0Ultra (Full Dynamic 5-Line Taps)\0";
    ui_min = 0; ui_max = 2;
    ui_label = "Shader Quality Profile";
    ui_category = "=== 2. System & Architecture ===";
> = 1;

uniform int C_OrientationMode <
    ui_type = "combo";
    ui_items = "Horizontal (Standard 4:3)\0Vertical (Forced TATE 3:4)\0Auto-Detect (Optical Flank Sensor)\0";
    ui_min = 0; ui_max = 2;
    ui_label = "Raster Orientation / TATE";
    ui_tooltip = "Note: Disable MAME side bezel artwork or force Vertical TATE if using Auto-Detect with illuminated bezels.";
    ui_category = "=== 2. System & Architecture ===";
> = 2;

uniform int C_LineMode <
    ui_type = "combo";
    ui_items = "CPS / Neo-Geo (224 Lines)\0Standard Arcade / NES (240 Lines)\0PC Engine / Midway (256 Lines)\0Namco Classic / PAL (288 Lines)\0Sega Model 2/3 Medium-Res (384 Lines)\0Naomi / VGA (480 Lines)\0Custom / Manual\0";
    ui_min = 0; ui_max = 6;
    ui_label = "Arcade Raster Line Preset";
    ui_category = "=== 2. System & Architecture ===";
> = 1;

uniform float C_CustomLines <
    ui_type = "drag"; ui_min = 100.0; ui_max = 1200.0; ui_step = 1.0;
    ui_label = "Custom Line Count";
    ui_category = "=== 2. System & Architecture ===";
> = 224.0;

uniform float C_ScanlineScale <
    ui_type = "drag"; ui_min = 0.25; ui_max = 3.0; ui_step = 0.025;
    ui_label = "Scanline Density Multiplier";
    ui_category = "=== 2. System & Architecture ===";
> = 1.0;

uniform int UI_AspectMode <
    ui_type = "combo";
    ui_items = "Auto Tube Framing (Matches Orientation)\0Fit 4:3 Tube (Standard 16:9 Display)\0Fit 3:4 Tube (Vertical TATE on 16:9)\0Manual Padding\0Fullscreen / Handled by MAME\0";
    ui_min = 0; ui_max = 4;
    ui_label = "Arcade Tube Framing";
    ui_category = "=== 2. System & Architecture ===";
> = 0;

uniform float2 UI_ManualPad <
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.40; ui_step = 0.005;
    ui_label = "Manual Tube Padding (X / Y)";
    ui_category = "=== 2. System & Architecture ===";
> = float2(0.110, 0.000);

uniform bool UI_PassThroughBorder <
    ui_label = "Pass-Through MAME Artwork / Bezels";
    ui_category = "=== 2. System & Architecture ===";
> = true;

// ===================== 3. ANALOG SIGNAL FILTERING =====================
uniform int Blur_Type <
    ui_type = "combo";
    ui_items = "Symmetric 7-Tap Gaussian\0Asymmetric Analog RC Bleed (JAMMA Cable)\0Flyback Defocus (Dual-Axis)\0";
    ui_min = 0; ui_max = 2;
    ui_label = "Signal Blur Profile";
    ui_category = "=== 3. Analog Signal Filtering ===";
> = 0;

uniform float Blur_Width <
    ui_type = "drag"; ui_min = 0.0; ui_max = 4.0; ui_step = 0.05;
    ui_label = "Beam Bandwidth / Blur Width";
    ui_category = "=== 3. Analog Signal Filtering ===";
> = 1.45;

uniform float RC_Bleed <
    ui_type = "drag"; ui_min = 0.5; ui_max = 3.0; ui_step = 0.05;
    ui_label = "RC Asymmetric Decay Tail";
    ui_category = "=== 3. Analog Signal Filtering ===";
> = 1.25;

uniform float AST_Amount <
    ui_type = "drag"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.05;
    ui_label = "Corner Defocus Intensity";
    ui_category = "=== 3. Analog Signal Filtering ===";
> = 0.65;

// ===================== 4. ELECTRON BEAM & SCANLINES =====================
uniform float B_MinBeam <
    ui_type = "drag"; ui_min = 0.5; ui_max = 3.0; ui_step = 0.02;
    ui_label = "Dark Beam Sharpness (Trough Size)";
    ui_category = "=== 4. Electron Beam & Scanlines ===";
> = 2.00;

uniform float B_MaxBeam <
    ui_type = "drag"; ui_min = 0.4; ui_max = 2.5; ui_step = 0.02;
    ui_label = "Bright Beam Dilation (Highlight Bloom)";
    ui_category = "=== 4. Electron Beam & Scanlines ===";
> = 1.50;

uniform float B_Sharpness <
    ui_type = "drag"; ui_min = 1.5; ui_max = 10.0; ui_step = 0.10;
    ui_label = "Beam Gaussian Profile Sharpness";
    ui_category = "=== 4. Electron Beam & Scanlines ===";
> = 6.00;

uniform float B_EdgeDefocus <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Edge Yoke Defocus Amount";
    ui_tooltip = "Softens the beam focus as it reaches the extreme edges of the glass tube.";
    ui_category = "=== 4. Electron Beam & Scanlines ===";
> = 0.25;

uniform float B_Gain <
    ui_type = "drag"; ui_min = 0.8; ui_max = 2.5; ui_step = 0.02;
    ui_label = "Scanline Brightness Gain";
    ui_category = "=== 4. Electron Beam & Scanlines ===";
> = 1.50;

// ===================== 5. CRT PHOSPHOR MASK & HOST DISPLAY MATRIX =====================
uniform int M_Type <
    ui_type = "combo";
    ui_items = "Off\0Aperture Grille (Sony Trinitron)\0Arcade Slot Mask (Nanao / Wells-Gardner)\0Shadow Mask (Dot Triad)\0";
    ui_min = 0; ui_max = 3;
    ui_label = "CRT Phosphor Mask Geometry";
    ui_category = "=== 5. CRT Phosphor Mask & Host Display Matrix ===";
> = 2;

uniform int M_SubpixelMode <
    ui_type = "combo";
    ui_items = "Standard RGB (LCD)\0BGR (Inverted LCD)\0WOLED (LG WRGB OLED 4-Subpixel)\0QD-OLED (Samsung Triangular OLED)\0";
    ui_min = 0; ui_max = 3;
    ui_label = "Host Panel Subpixel Matrix";
    ui_category = "=== 5. CRT Phosphor Mask & Host Display Matrix ===";
> = 0;

uniform bool M_ResolutionScale <
    ui_label = "Auto-Scale Mask with Resolution";
    ui_category = "=== 5. CRT Phosphor Mask & Host Display Matrix ===";
> = true;

uniform float M_Strength <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.025;
    ui_label = "Mask Dark Wire Attenuation";
    ui_category = "=== 5. CRT Phosphor Mask & Host Display Matrix ===";
> = 0.30;

uniform float M_Bloom <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Highlight Mask Bloom (Fade)";
    ui_category = "=== 5. CRT Phosphor Mask & Host Display Matrix ===";
> = 0.20;

uniform float M_Size <
    ui_type = "drag"; ui_min = 1.0; ui_max = 3.0; ui_step = 1.0;
    ui_label = "Manual Mask Scale Multiplier";
    ui_category = "=== 5. CRT Phosphor Mask & Host Display Matrix ===";
> = 1.0;

uniform float M_BrightBoost <
    ui_type = "drag"; ui_min = 1.0; ui_max = 2.0; ui_step = 0.02;
    ui_label = "Manual Mask Brightness Boost";
    ui_category = "=== 5. CRT Phosphor Mask & Host Display Matrix ===";
> = 1.24;

uniform float M_AutoComp <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Auto Mask Compensation Amount";
    ui_category = "=== 5. CRT Phosphor Mask & Host Display Matrix ===";
> = 0.00;

// ===================== 6. DPX FILMIC TONE & COLOR =====================
uniform float DPX_Gain <
    ui_type = "drag"; ui_min = 0.5; ui_max = 2.0; ui_step = 0.02;
    ui_label = "DPX Brightness Lift";
    ui_category = "=== 6. DPX Filmic Tone & Color ===";
> = 1.00;

uniform float DPX_Strength <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.02;
    ui_label = "DPX Effect Strength";
    ui_category = "=== 6. DPX Filmic Tone & Color ===";
> = 0.20;

uniform float DPX_Contrast <
    ui_type = "drag"; ui_min = -0.50; ui_max = 0.50; ui_step = 0.01;
    ui_label = "DPX Contrast";
    ui_category = "=== 6. DPX Filmic Tone & Color ===";
> = 0.12;

uniform float3 DPX_RGB_Curve <
    ui_type = "drag"; ui_min = 1.0; ui_max = 16.0; ui_step = 0.05;
    ui_label = "DPX S-Curve Slope (R / G / B)";
    ui_category = "=== 6. DPX Filmic Tone & Color ===";
> = float3(7.950, 8.000, 8.000);

uniform float3 DPX_RGB_C <
    ui_type = "drag"; ui_min = 0.10; ui_max = 0.60; ui_step = 0.005;
    ui_label = "DPX Midpoint Anchor (R / G / B)";
    ui_category = "=== 6. DPX Filmic Tone & Color ===";
> = float3(0.400, 0.355, 0.300);

uniform float DPX_Colorfulness <
    ui_type = "drag"; ui_min = 0.5; ui_max = 4.0; ui_step = 0.05;
    ui_label = "DPX Colorfulness";
    ui_category = "=== 6. DPX Filmic Tone & Color ===";
> = 1.20;

uniform float DPX_Saturation <
    ui_type = "drag"; ui_min = 0.5; ui_max = 2.0; ui_step = 0.05;
    ui_label = "DPX Saturation";
    ui_category = "=== 6. DPX Filmic Tone & Color ===";
> = 1.15;

// ===================== 7. TUBE GEOMETRY & CURVATURE =====================
uniform float2 G_Warp <
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.25; ui_step = 0.002;
    ui_label = "Glass Curvature Amount (X / Y)";
    ui_category = "=== 7. Tube Geometry & Curvature ===";
> = float2(0.010, 0.010);

uniform float G_CornerSize <
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.08; ui_step = 0.002;
    ui_label = "Corner Rounding Radius";
    ui_category = "=== 7. Tube Geometry & Curvature ===";
> = 0.020;

uniform float2 D_StaticShift <
    ui_type = "drag"; ui_min = -2.0; ui_max = 2.0; ui_step = 0.05;
    ui_label = "Static Convergence (In-Line / Cross-Line)";
    ui_category = "=== 7. Tube Geometry & Curvature ===";
> = float2(0.00, 0.00);

uniform float D_DynamicShift <
    ui_type = "drag"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.05;
    ui_label = "Luma-Dependent Convergence Bleed";
    ui_tooltip = "Scales the static / radial convergence shift up on bright pixels.";
    ui_category = "=== 7. Tube Geometry & Curvature ===";
> = 0.40;

uniform float D_RadialYoke <
    ui_type = "drag"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.05;
    ui_label = "Deflection Yoke Corner Fringe";
    ui_category = "=== 7. Tube Geometry & Curvature ===";
> = 0.00;

// ===================== 8. COLOR, GAMMA & HDR DISPLAY PROFILES =====================
uniform int HDR_Profile <
    ui_type = "combo";
    ui_items = "SDR (Standard sRGB / Rec.709)\0HDR10 (Rec.2020 / SMPTE ST 2084 PQ)\0scRGB (Linear FP16 Expanded Gamut)\0Auto (Match ReShade Swapchain)\0";
    ui_min = 0; ui_max = 3;
    ui_label = "Display Color & HDR Profile";
    ui_tooltip = "Auto detects swapchain color space (SDR/HDR10/scRGB) assuming standard sRGB-gamma emulator input.";
    ui_category = "=== 8. Color, Gamma & HDR Display Profiles ===";
> = 0;

uniform float HDR_PaperWhite <
    ui_type = "drag"; ui_min = 80.0; ui_max = 500.0; ui_step = 10.0;
    ui_label = "HDR Paper White (Nits)";
    ui_category = "=== 8. Color, Gamma & HDR Display Profiles ===";
> = 203.0;

uniform float HDR_PeakNits <
    ui_type = "drag"; ui_min = 400.0; ui_max = 2500.0; ui_step = 50.0;
    ui_label = "HDR Peak Luminance (Nits)";
    ui_category = "=== 8. Color, Gamma & HDR Display Profiles ===";
> = 1000.0;

uniform float COL_BlackLevel <
    ui_type = "drag"; ui_min = -0.05; ui_max = 0.05; ui_step = 0.001;
    ui_label = "Black Level Offset (Output Space)";
    ui_category = "=== 8. Color, Gamma & HDR Display Profiles ===";
> = -0.008;

uniform float COL_InputGamma <
    ui_type = "drag"; ui_min = 1.8; ui_max = 3.0; ui_step = 0.05;
    ui_label = "Arcade Core Input Gamma";
    ui_category = "=== 8. Color, Gamma & HDR Display Profiles ===";
> = 2.40;

uniform float COL_OutputGamma <
    ui_type = "drag"; ui_min = 1.8; ui_max = 2.6; ui_step = 0.05;
    ui_label = "Target SDR Monitor Output Gamma";
    ui_category = "=== 8. Color, Gamma & HDR Display Profiles ===";
> = 2.40;

uniform float COL_Saturation <
    ui_type = "drag"; ui_min = 0.5; ui_max = 1.5; ui_step = 0.02;
    ui_label = "Master Color Saturation";
    ui_category = "=== 8. Color, Gamma & HDR Display Profiles ===";
> = 1.00;

// ===================== 9. HARDWARE IMPERFECTIONS & OPTICS =====================
uniform float HV_SagAmount <
    ui_type = "drag"; ui_min = 0.0; ui_max = 2.5; ui_step = 0.05;
    ui_label = "Screen Expansion & Sag Response";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 1.00;

uniform float Tube_Age <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Phosphor Aging & Burn-in";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.10;

uniform float Sync_Phase <
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
    ui_label = "Beam Sync Refresh Phase";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.00;

uniform float HB_Strength <
    ui_type = "drag"; ui_min = 0.00; ui_max = 0.15; ui_step = 0.005;
    ui_label = "AC Hum Bar Intensity";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.025;

uniform float HB_Speed <
    ui_type = "drag"; ui_min = 0.1; ui_max = 5.0; ui_step = 0.1;
    ui_label = "AC Hum Bar Roll Speed";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 1.00;

uniform float HB_Frequency <
    ui_type = "drag"; ui_min = 1.0; ui_max = 8.0; ui_step = 0.5;
    ui_label = "AC Hum Bar Frequency (Wavelengths)";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 1.50;

uniform float H_Strength <
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.4; ui_step = 0.01;
    ui_label = "Halation Strength";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.08;

uniform float H_Radius <
    ui_type = "drag"; ui_min = 1.0; ui_max = 8.0; ui_step = 0.25;
    ui_label = "Halation Radius (Base 1080p)";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 2.00;

uniform float GL_Strength <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Wide Glow Strength";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.20;

uniform float GL_Radius <
    ui_type = "drag"; ui_min = 0.5; ui_max = 4.0; ui_step = 0.1;
    ui_label = "Wide Glow Radius";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.60;

uniform float GL_Threshold <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Wide Glow Threshold";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.70;

uniform float P_Strength <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Phosphor Decay Trail Strength";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.30;

uniform float3 P_Decay <
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.95; ui_step = 0.01;
    ui_label = "Phosphor Decay Rates (R / G / B)";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = float3(0.30, 0.35, 0.25);

uniform float CMP_ChromaBlur <
    ui_type = "drag"; ui_min = 0.0; ui_max = 8.0; ui_step = 0.1;
    ui_label = "Composite Chroma Bleed";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 1.90;

uniform float CMP_Artifacts <
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
    ui_label = "Composite Dot Crawl / Crosstalk";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.10;

uniform float CMP_Resolution <
    ui_type = "drag"; ui_min = 128.0; ui_max = 1024.0; ui_step = 1.0;
    ui_label = "Composite Source Horizontal Resolution";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 256.0;

uniform bool CMP_Crawl <
    ui_label = "Animate Composite Dot Crawl";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = true;

uniform int I_Mode <
    ui_type = "combo";
    ui_items = "Interlaced Fields (480i alternate lines each frame)\0Line Jitter (240p half-line shift each frame)\0";
    ui_min = 0; ui_max = 1;
    ui_label = "Interlace Mode";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0;

uniform float I_Strength <
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Inactive Field Attenuation";
    ui_category = "=== 9. Hardware Imperfections & Optics ===";
> = 0.50;

// =========================================================================
// Render Targets & Textures
// =========================================================================

texture TexTateStateCur { Width = 1; Height = 1; Format = RGBA16F; };
sampler SamplerTateStateCur { Texture = TexTateStateCur; };

// Temporal history textures MUST NOT be pooled
texture TexTateStatePrev { Width = 1; Height = 1; Format = RGBA16F; };
sampler SamplerTateStatePrev { Texture = TexTateStatePrev; };

texture TexLinear < pooled = true; > { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = CRT_LINEAR_FMT; };
sampler SamplerLinear { Texture = TexLinear; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

texture TexSignal < pooled = true; > { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = CRT_LINEAR_FMT; };
sampler SamplerSignal { Texture = TexSignal; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

#if CRT_ENABLE_PERSISTENCE
texture TexPersistPrev { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = CRT_LINEAR_FMT; };
sampler SamplerPersistPrev { Texture = TexPersistPrev; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

texture TexPersistCur { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = CRT_LINEAR_FMT; };
sampler SamplerPersistCur { Texture = TexPersistCur; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

#define CRT_SIGNAL_SAMPLER SamplerPersistCur
#else
#define CRT_SIGNAL_SAMPLER SamplerSignal
#endif

texture TexHalationH < pooled = true; > { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = CRT_LINEAR_FMT; };
sampler SamplerHalationH { Texture = TexHalationH; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

texture TexHalationV < pooled = true; > { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = CRT_LINEAR_FMT; };
sampler SamplerHalationV { Texture = TexHalationV; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

texture TexGlowA < pooled = true; > { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = CRT_LINEAR_FMT; };
sampler SamplerGlowA { Texture = TexGlowA; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

texture TexGlowB < pooled = true; > { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = CRT_LINEAR_FMT; };
sampler SamplerGlowB { Texture = TexGlowB; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

// =========================================================================
// Helper Functions & Color Science
// =========================================================================

// Safe pow helpers prevent undefined pow(0.0, y) NaN issues on Vulkan/OpenGL drivers
float3 SafePow(float3 x, float y)
{
    return pow(max(x, 1e-7), y) * step(1e-7, x);
}

float SafePow1(float x, float y)
{
    return pow(max(x, 1e-7), y) * step(1e-7, x);
}

bool GetTateState()
{
    if (C_OrientationMode == 0) return false;
    if (C_OrientationMode == 1) return true;
    if (BUFFER_WIDTH < BUFFER_HEIGHT) return true;
    return tex2Dlod(SamplerTateStateCur, float4(0.5, 0.5, 0.0, 0.0)).r > 0.5;
}

float GetTargetLines()
{
    float lines = 240.0;
    if (C_LineMode == 0) lines = 224.0;
    else if (C_LineMode == 1) lines = 240.0;
    else if (C_LineMode == 2) lines = 256.0;
    else if (C_LineMode == 3) lines = 288.0;
    else if (C_LineMode == 4) lines = 384.0;
    else if (C_LineMode == 5) lines = 480.0;
    else lines = C_CustomLines;

    return lines * max(C_ScanlineScale, 0.1);
}

float2 GetPillarboxPadding(bool isTate)
{
    if (UI_AspectMode == 4) return float2(0.0, 0.0);
    if (UI_AspectMode == 3) return min(UI_ManualPad, float2(0.45, 0.45));

    float screenAspect = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
    float targetAspect = isTate ? (3.0 / 4.0) : (4.0 / 3.0);

    if (UI_AspectMode == 1) targetAspect = 4.0 / 3.0;
    else if (UI_AspectMode == 2) targetAspect = 3.0 / 4.0;

    if (screenAspect > targetAspect) return float2((1.0 - targetAspect / screenAspect) * 0.5, 0.0);
    else return float2(0.0, (1.0 - screenAspect / targetAspect) * 0.5);
}

float2 WarpCoords(float2 uv, float2 warpAmount)
{
    if (!G_EnableCurvature) return uv;
    uv = uv * 2.0 - 1.0;
    float2 r2 = uv.yx * uv.yx;
    uv = uv + uv * r2 * warpAmount;
    return uv * 0.5 + 0.5;
}

float BeamWeight(float d, float3 c, float maxBeam, float activeSharpness)
{
    float l = max(max(c.r, c.g), c.b);
    float beamLow  = min(B_MinBeam, maxBeam);
    float beamHigh = max(B_MinBeam, maxBeam);
    float bw = lerp(beamHigh, beamLow, SafePow1(l, 0.70));
    float g = exp(-activeSharpness * d * d * bw * bw);

    return max(g, 0.18 * exp(-2.0 * d * d));
}

float MaskMeanTransmission()
{
    float s = M_Strength;
    float woled = (M_SubpixelMode == 2) ? (1.0 - 0.0875 * s) : 1.0;
    if (M_Type == 1) return (M_SubpixelMode == 2) ? (1.0 - 0.5875 * s) : (1.0 - 0.6666667 * s);
    if (M_Type == 2) return (1.0 - 0.6666667 * s) * (1.0 - 0.1875 * s) * woled;
    if (M_Type == 3) return (1.0 - 0.7777778 * s) * woled;
    return 1.0;
}

float3 HaloGate(float3 c)
{
    float l = max(max(c.r, c.g), c.b);
    return c * smoothstep(0.12, 0.65, l);
}

float3 GlowGate(float3 c, float threshold)
{
    float l = max(max(c.r, c.g), c.b);
    float knee = 0.15;
    float weight = smoothstep(threshold - knee, threshold + knee, l);
    return c * weight;
}

float3 RGBtoYIQ(float3 c)
{
    return float3(dot(c, float3(0.299,  0.587,  0.114)),
                  dot(c, float3(0.596, -0.274, -0.322)),
                  dot(c, float3(0.211, -0.523,  0.312)));
}

float3 YIQtoRGB(float3 q)
{
    return float3(q.x + 0.956 * q.y + 0.621 * q.z,
                  q.x - 0.272 * q.y - 0.647 * q.z,
                  q.x - 1.106 * q.y + 1.703 * q.z);
}

static const float3x3 Mat_Rec709_to_Rec2020 = float3x3(
    0.6274040, 0.3292820, 0.0433136,
    0.0690970, 0.9195400, 0.0113618,
    0.0163916, 0.0880132, 0.8955950
);

float3 EncodePQ(float3 linearNits)
{
    static const float m1 = 0.1593017578125;
    static const float m2 = 78.84375;
    static const float c1 = 0.8359375;
    static const float c2 = 18.8515625;
    static const float c3 = 18.6875;

    float3 y = saturate(max(linearNits, 0.0) / 10000.0);
    float3 ym1 = pow(max(y, 1e-7), m1);
    float3 pq = pow((c1 + c2 * ym1) / (1.0 + c3 * ym1), m2);
    return pq * step(0.0001, linearNits);
}

int GetEffectiveHDRProfile()
{
    if (HDR_Profile != 3) return HDR_Profile;
#if defined(BUFFER_COLOR_SPACE)
    #if (BUFFER_COLOR_SPACE == 3)
        return 1; // HDR10 ST2084 PQ
    #elif (BUFFER_COLOR_SPACE == 2)
        return 2; // scRGB Linear FP16
    #endif
#endif
    return 0; // SDR fallback
}

float3 GetBorderBG(float2 uv)
{
    if (!UI_PassThroughBorder) return float3(0.0, 0.0, 0.0);

    float3 raw = tex2Dlod(ReShade::BackBuffer, float4(uv, 0.0, 0.0)).rgb;
    int hdrMode = GetEffectiveHDRProfile();

    if (hdrMode == 1)
    {
        float3 lin = SafePow(raw, COL_InputGamma);
        return EncodePQ(mul(Mat_Rec709_to_Rec2020, lin * HDR_PaperWhite));
    }
    if (hdrMode == 2)
    {
        float3 lin = SafePow(raw, COL_InputGamma);
        return lin * (HDR_PaperWhite / 80.0);
    }
    return raw;
}

float3 SampleCRT(float2 sampleUV, float2 pad, bool hasDecon, float2 shift)
{
    float3 cCenter = tex2Dlod(CRT_SIGNAL_SAMPLER, float4(sampleUV, 0.0, 0.0)).rgb;
    if (!hasDecon) return cCenter;

    float cLuma = dot(cCenter, float3(0.2126, 0.7152, 0.0722));
    float2 finalShift = shift * (1.0 + cLuma * D_DynamicShift);
    float r = tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(sampleUV + finalShift, pad, 1.0 - pad), 0.0, 0.0)).r;
    float b = tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(sampleUV - finalShift, pad, 1.0 - pad), 0.0, 0.0)).b;
    return float3(r, cCenter.g, b);
}

// =========================================================================
// Pixel Shaders
// =========================================================================

// Pass 0: Temporal Optical Flank Sensor & Linearized Flash Luma Evaluator
float4 PS_TateDetect(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float prevState = tex2Dlod(SamplerTateStatePrev, float4(0.5, 0.5, 0.0, 0.0)).r;
    float3 lumaW = float3(0.2126, 0.7152, 0.0722);

    // Approximate linear beam current (gamma ~2.0) for accurate HV anode sag
    float3 s0 = tex2Dlod(ReShade::BackBuffer, float4(0.50, 0.50, 0.0, 0.0)).rgb;
    float3 s1 = tex2Dlod(ReShade::BackBuffer, float4(0.45, 0.38, 0.0, 0.0)).rgb;
    float3 s2 = tex2Dlod(ReShade::BackBuffer, float4(0.55, 0.38, 0.0, 0.0)).rgb;
    float3 s3 = tex2Dlod(ReShade::BackBuffer, float4(0.45, 0.62, 0.0, 0.0)).rgb;
    float3 s4 = tex2Dlod(ReShade::BackBuffer, float4(0.55, 0.62, 0.0, 0.0)).rgb;

    float flashRaw = dot(s0 * s0, lumaW) * 0.30
                   + dot(s1 * s1, lumaW) * 0.175
                   + dot(s2 * s2, lumaW) * 0.175
                   + dot(s3 * s3, lumaW) * 0.175
                   + dot(s4 * s4, lumaW) * 0.175;

    float prevFlash = tex2Dlod(SamplerTateStatePrev, float4(0.5, 0.5, 0.0, 0.0)).g;
    float flashLuma = lerp(prevFlash, flashRaw, (flashRaw > prevFlash) ? 0.35 : 0.08);

    if (C_OrientationMode == 0) return float4(0.0, flashLuma, 0.0, 1.0);
    if (C_OrientationMode == 1) return float4(1.0, flashLuma, 0.0, 1.0);
    if (BUFFER_WIDTH < BUFFER_HEIGHT) return float4(1.0, flashLuma, 0.0, 1.0);

    float screenAspect = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
    float pad43 = max(0.0, (1.0 - (4.0 / 3.0) / screenAspect) * 0.5);
    float pad34 = max(0.0, (1.0 - (3.0 / 4.0) / screenAspect) * 0.5);
    float probeLeft = (pad43 + pad34) * 0.5;
    float probeRight = 1.0 - probeLeft;

    float flankLuma = 0.0;
    flankLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(probeLeft,  0.20, 0.0, 0.0)).rgb, lumaW);
    flankLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(probeLeft,  0.40, 0.0, 0.0)).rgb, lumaW);
    flankLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(probeLeft,  0.60, 0.0, 0.0)).rgb, lumaW);
    flankLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(probeLeft,  0.80, 0.0, 0.0)).rgb, lumaW);
    flankLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(probeRight, 0.20, 0.0, 0.0)).rgb, lumaW);
    flankLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(probeRight, 0.40, 0.0, 0.0)).rgb, lumaW);
    flankLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(probeRight, 0.60, 0.0, 0.0)).rgb, lumaW);
    flankLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(probeRight, 0.80, 0.0, 0.0)).rgb, lumaW);
    flankLuma /= 8.0;

    float centerLuma = 0.0;
    centerLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(0.50, 0.30, 0.0, 0.0)).rgb, lumaW);
    centerLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(0.50, 0.50, 0.0, 0.0)).rgb, lumaW);
    centerLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(0.50, 0.70, 0.0, 0.0)).rgb, lumaW);
    centerLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(0.40, 0.50, 0.0, 0.0)).rgb, lumaW);
    centerLuma += dot(tex2Dlod(ReShade::BackBuffer, float4(0.60, 0.50, 0.0, 0.0)).rgb, lumaW);
    centerLuma /= 5.0;

    float targetState = prevState;
    if (flankLuma > 0.015) targetState = 0.0;
    else if (centerLuma > 0.02 && flankLuma < 0.004) targetState = 1.0;

    float smoothedState = lerp(prevState, targetState, 0.02);
    return float4(smoothedState, flashLuma, 0.0, 1.0);
}

// Pass 0B: Orientation State Copy
float4 PS_TateCopy(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dlod(SamplerTateStateCur, float4(0.5, 0.5, 0.0, 0.0));
}

// Pass 1: Linearization, DPX Filmic S-Curve & P22 Gamut
float4 PS_Linearize(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    bool isTate = GetTateState();
    float2 pad = GetPillarboxPadding(isTate);

    // Borders are handled directly in PS_Raster_Composite; keep signal textures dark outside active tube
    if (uv.x < pad.x || uv.x > (1.0 - pad.x) || uv.y < pad.y || uv.y > (1.0 - pad.y))
        return float4(0.0, 0.0, 0.0, 1.0);

    float3 color = tex2Dlod(ReShade::BackBuffer, float4(uv, 0.0, 0.0)).rgb;

    if (DPX_Enable)
    {
        float3 dpx = color * DPX_Gain;
        dpx = (dpx - DPX_RGB_C) * (1.0 + DPX_Contrast) + DPX_RGB_C;

        if (CRT_QualityTier == 0)
        {
            float3 satDpx = saturate(dpx);
            dpx = satDpx * satDpx * (3.0 - 2.0 * satDpx);
        }
        else
        {
            float3 sig  = 1.0 / (1.0 + exp(-DPX_RGB_Curve * (dpx - DPX_RGB_C)));
            float3 sig0 = 1.0 / (1.0 + exp(DPX_RGB_Curve * DPX_RGB_C));
            float3 sig1 = 1.0 / (1.0 + exp(-DPX_RGB_Curve * (1.0 - DPX_RGB_C)));
            dpx = saturate((sig - sig0) / max(sig1 - sig0, 0.0001));
        }

        float dpxLuma = dot(dpx, float3(0.299, 0.587, 0.114));
        dpx = max(lerp(dpxLuma.xxx, dpx, DPX_Colorfulness * DPX_Saturation), 0.0);
        color = lerp(color, dpx, DPX_Strength);
    }

    color = SafePow(color, COL_InputGamma);

    if (COL_P22Gamut)
    {
        static const float3x3 P22Matrix = float3x3(
            0.920, 0.055, 0.025,
            0.030, 0.940, 0.030,
            0.015, 0.065, 0.920
        );
        color = mul(P22Matrix, color);
    }

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = max(lerp(luma.xxx, color, COL_Saturation), 0.0);

    return float4(saturate(color), 1.0);
}

// Pass 2: Analog Blur Engine & NTSC Demodulator
float4 PS_SignalBlur(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    bool isTate = GetTateState();
    float2 pad = GetPillarboxPadding(isTate);
    float2 activeSize = 1.0 - 2.0 * pad;

    if (uv.x < pad.x || uv.x > (1.0 - pad.x) || uv.y < pad.y || uv.y > (1.0 - pad.y))
        return float4(0.0, 0.0, 0.0, 1.0);

    if (CMP_Enable)
    {
        float2 localUV = (uv - pad) / max(activeSize, 0.0001);
        float2 axis = isTate ? float2(0.0, 1.0) : float2(1.0, 0.0);
        float2 texel = axis * (isTate ? BUFFER_RCP_HEIGHT : BUFFER_RCP_WIDTH);
        float stepSize = max(CMP_ChromaBlur, 0.0) * 0.75 * CRT_RES_SCALE;

        static const float TapOffsets[3]       = { 0.0000, 1.3400, 3.3333 };
        static const float RC_LumaWeights[3]   = { 0.6500, 0.3500, 0.0000 };
        static const float RC_ChromaWeights[3] = { 0.4000, 0.4500, 0.1500 };

        float yLuma = 0.0; float2 iq = float2(0.0, 0.0);
        float ySample0 = 0.0; float ySample1 = 0.0;

        [unroll]
        for (int i = 0; i < 3; i++)
        {
            float2 uvTap = clamp(uv - texel * (TapOffsets[i] * stepSize), pad, 1.0 - pad);
            float3 cSample = tex2Dlod(SamplerLinear, float4(uvTap, 0.0, 0.0)).rgb;
            float3 yiqSample = RGBtoYIQ(cSample);

            if (i == 0) ySample0 = yiqSample.x;
            if (i == 1) ySample1 = yiqSample.x;

            yLuma += yiqSample.x  * RC_LumaWeights[i];
            iq    += yiqSample.yz * RC_ChromaWeights[i];
        }

        // Preserve dot crawl / crosstalk edge detection even when CMP_ChromaBlur < 1.0
        float yEdge = (CMP_ChromaBlur < 1.0)
            ? RGBtoYIQ(tex2Dlod(SamplerLinear, float4(clamp(uv - texel * CRT_RES_SCALE, pad, 1.0 - pad), 0.0, 0.0)).rgb).x
            : ySample1;
        float edge = abs(ySample0 - yEdge) * 2.0;

        float scanCoord = isTate ? localUV.y : localUV.x;
        float lineCoord = isTate ? localUV.x : localUV.y;
        float phase = (floor(scanCoord * CMP_Resolution) * 0.5 + floor(lineCoord * GetTargetLines()) + (CMP_Crawl ? (float)(framecount % 2) : 0.0)) * 3.14159265;
        iq += CMP_Artifacts * edge * float2(cos(phase), sin(phase));

        return float4(saturate(YIQtoRGB(float3(yLuma, iq.x, iq.y))), 1.0);
    }

    if (!Blur_Enable) return tex2Dlod(SamplerLinear, float4(clamp(uv, pad, 1.0 - pad), 0.0, 0.0));

    float2 tubeCenterDist = (uv - pad) / max(activeSize, 0.001) - 0.5;
    float effectiveWidth = Blur_Width * CRT_RES_SCALE * (1.0 + (AST_Enable ? dot(tubeCenterDist, tubeCenterDist) * 4.0 * AST_Amount : 0.0));
    float2 axis = (isTate ? float2(0.0, BUFFER_RCP_HEIGHT) : float2(BUFFER_RCP_WIDTH, 0.0)) * effectiveWidth;

    if (Blur_Type == 1)
    {
        float3 c = tex2Dlod(SamplerLinear, float4(clamp(uv - axis, pad, 1.0 - pad), 0.0, 0.0)).rgb * 0.15;
        c += tex2Dlod(SamplerLinear, float4(clamp(uv, pad, 1.0 - pad), 0.0, 0.0)).rgb * 0.38;
        c += tex2Dlod(SamplerLinear, float4(clamp(uv + axis * (1.0 * RC_Bleed), pad, 1.0 - pad), 0.0, 0.0)).rgb * 0.24;
        c += tex2Dlod(SamplerLinear, float4(clamp(uv + axis * (2.0 * RC_Bleed), pad, 1.0 - pad), 0.0, 0.0)).rgb * 0.15;
        c += tex2Dlod(SamplerLinear, float4(clamp(uv + axis * (3.0 * RC_Bleed), pad, 1.0 - pad), 0.0, 0.0)).rgb * 0.08;
        return float4(c, 1.0);
    }
    if (Blur_Type == 2)
    {
        float2 stepCross = (isTate ? float2(BUFFER_RCP_WIDTH, 0.0) : float2(0.0, BUFFER_RCP_HEIGHT)) * effectiveWidth * 0.40;
        float3 c = tex2Dlod(SamplerLinear, float4(clamp(uv, pad, 1.0 - pad), 0.0, 0.0)).rgb * 0.36;
        c += (tex2Dlod(SamplerLinear, float4(clamp(uv + axis, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerLinear, float4(clamp(uv - axis, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.22;
        c += (tex2Dlod(SamplerLinear, float4(clamp(uv + axis * 2.0, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerLinear, float4(clamp(uv - axis * 2.0, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.06;
        c += (tex2Dlod(SamplerLinear, float4(clamp(uv + stepCross, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerLinear, float4(clamp(uv - stepCross, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.04;
        return float4(c, 1.0);
    }

    // 7-Tap dense Gaussian eliminates discrete tap-skipping echoes at 4K or wide corner defocus
    float3 c = tex2Dlod(SamplerLinear, float4(clamp(uv, pad, 1.0 - pad), 0.0, 0.0)).rgb * 0.28278;
    c += (tex2Dlod(SamplerLinear, float4(clamp(uv + axis * 0.7, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerLinear, float4(clamp(uv - axis * 0.7, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.22133;
    c += (tex2Dlod(SamplerLinear, float4(clamp(uv + axis * 1.4, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerLinear, float4(clamp(uv - axis * 1.4, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.10612;
    c += (tex2Dlod(SamplerLinear, float4(clamp(uv + axis * 2.1, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerLinear, float4(clamp(uv - axis * 2.1, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.03116;
    return float4(c, 1.0);
}

#if CRT_ENABLE_PERSISTENCE
// Pass 3 & 4: Phosphor Persistence
float4 PS_PersistUpdate(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 cur = tex2Dlod(SamplerSignal, float4(uv, 0.0, 0.0)).rgb;
    if (!P_Enable) return float4(cur, 1.0);
    float3 prev = tex2Dlod(SamplerPersistPrev, float4(uv, 0.0, 0.0)).rgb;
    return float4(lerp(cur, max(cur, prev * P_Decay), P_Strength), 1.0);
}

float4 PS_PersistCopy(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dlod(SamplerPersistCur, float4(uv, 0.0, 0.0));
}
#endif

// Pass 5: Halation H
float4 PS_Halation_H(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (!H_Enable || H_Strength <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    bool isTate = GetTateState(); float2 pad = GetPillarboxPadding(isTate);
    if (uv.x < pad.x || uv.x > (1.0 - pad.x) || uv.y < pad.y || uv.y > (1.0 - pad.y)) return float4(0.0, 0.0, 0.0, 1.0);

    float2 stepVec = float2(BUFFER_RCP_WIDTH * 2.0 * H_Radius * (BUFFER_HEIGHT / 1080.0), 0.0);
    float3 r = HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(uv, 0.0, 0.0)).rgb) * 0.227027;
    r += (HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv + stepVec, pad, 1.0 - pad), 0.0, 0.0)).rgb) + HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv - stepVec, pad, 1.0 - pad), 0.0, 0.0)).rgb)) * 0.1945946;
    r += (HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv + stepVec * 2.0, pad, 1.0 - pad), 0.0, 0.0)).rgb) + HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv - stepVec * 2.0, pad, 1.0 - pad), 0.0, 0.0)).rgb)) * 0.1216216;
    r += (HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv + stepVec * 3.0, pad, 1.0 - pad), 0.0, 0.0)).rgb) + HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv - stepVec * 3.0, pad, 1.0 - pad), 0.0, 0.0)).rgb)) * 0.0540540;
    r += (HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv + stepVec * 4.0, pad, 1.0 - pad), 0.0, 0.0)).rgb) + HaloGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv - stepVec * 4.0, pad, 1.0 - pad), 0.0, 0.0)).rgb)) * 0.0162160;
    return float4(r, 1.0);
}

// Pass 6: Halation V
float4 PS_Halation_V(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (!H_Enable || H_Strength <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    bool isTate = GetTateState(); float2 pad = GetPillarboxPadding(isTate);
    if (uv.x < pad.x || uv.x > (1.0 - pad.x) || uv.y < pad.y || uv.y > (1.0 - pad.y)) return float4(0.0, 0.0, 0.0, 1.0);

    float2 stepVec = float2(0.0, BUFFER_RCP_HEIGHT * 2.0 * H_Radius * (BUFFER_HEIGHT / 1080.0));
    float3 r = tex2Dlod(SamplerHalationH, float4(uv, 0.0, 0.0)).rgb * 0.227027;
    r += (tex2Dlod(SamplerHalationH, float4(clamp(uv + stepVec, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerHalationH, float4(clamp(uv - stepVec, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.1945946;
    r += (tex2Dlod(SamplerHalationH, float4(clamp(uv + stepVec * 2.0, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerHalationH, float4(clamp(uv - stepVec * 2.0, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.1216216;
    r += (tex2Dlod(SamplerHalationH, float4(clamp(uv + stepVec * 3.0, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerHalationH, float4(clamp(uv - stepVec * 3.0, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.0540540;
    r += (tex2Dlod(SamplerHalationH, float4(clamp(uv + stepVec * 4.0, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerHalationH, float4(clamp(uv - stepVec * 4.0, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.0162160;
    return float4(r, 1.0);
}

// Pass 7: 4-Tap Bilinear Box Downsampler (Tube-Bounds Protected)
float4 PS_GlowDown(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (!GL_Enable || GL_Strength <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    bool isTate = GetTateState(); float2 pad = GetPillarboxPadding(isTate);
    if (uv.x < pad.x || uv.x > (1.0 - pad.x) || uv.y < pad.y || uv.y > (1.0 - pad.y)) return float4(0.0, 0.0, 0.0, 1.0);

    float2 d = BUFFER_PIXEL_SIZE * 1.0;
    float3 sum = GlowGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv + float2(-d.x, -d.y), pad, 1.0 - pad), 0.0, 0.0)).rgb, GL_Threshold);
    sum       += GlowGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv + float2( d.x, -d.y), pad, 1.0 - pad), 0.0, 0.0)).rgb, GL_Threshold);
    sum       += GlowGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv + float2(-d.x,  d.y), pad, 1.0 - pad), 0.0, 0.0)).rgb, GL_Threshold);
    sum       += GlowGate(tex2Dlod(CRT_SIGNAL_SAMPLER, float4(clamp(uv + float2( d.x,  d.y), pad, 1.0 - pad), 0.0, 0.0)).rgb, GL_Threshold);
    return float4(sum * 0.25, 1.0);
}

// Pass 8: Wide-Dispersion Glow Blur H (Tube-Bounds Protected)
float4 PS_GlowH(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (!GL_Enable || GL_Strength <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    bool isTate = GetTateState(); float2 pad = GetPillarboxPadding(isTate);
    if (uv.x < pad.x || uv.x > (1.0 - pad.x) || uv.y < pad.y || uv.y > (1.0 - pad.y)) return float4(0.0, 0.0, 0.0, 1.0);

    float spread = max(GL_Radius, 0.1) * CRT_RES_SCALE;
    float2 stepVec = float2(BUFFER_RCP_WIDTH * 4.0 * spread, 0.0);

    float3 r = tex2Dlod(SamplerGlowA, float4(uv, 0.0, 0.0)).rgb * 0.175;
    r += (tex2Dlod(SamplerGlowA, float4(clamp(uv + stepVec * 1.45, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerGlowA, float4(clamp(uv - stepVec * 1.45, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.165;
    r += (tex2Dlod(SamplerGlowA, float4(clamp(uv + stepVec * 3.40, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerGlowA, float4(clamp(uv - stepVec * 3.40, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.140;
    r += (tex2Dlod(SamplerGlowA, float4(clamp(uv + stepVec * 5.35, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerGlowA, float4(clamp(uv - stepVec * 5.35, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.085;
    r += (tex2Dlod(SamplerGlowA, float4(clamp(uv + stepVec * 7.30, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerGlowA, float4(clamp(uv - stepVec * 7.30, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.0225;

    return float4(r, 1.0);
}

// Pass 9: Wide-Dispersion Glow Blur V (Tube-Bounds Protected)
float4 PS_GlowV(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (!GL_Enable || GL_Strength <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    bool isTate = GetTateState(); float2 pad = GetPillarboxPadding(isTate);
    if (uv.x < pad.x || uv.x > (1.0 - pad.x) || uv.y < pad.y || uv.y > (1.0 - pad.y)) return float4(0.0, 0.0, 0.0, 1.0);

    float spread = max(GL_Radius, 0.1) * CRT_RES_SCALE;
    float2 stepVec = float2(0.0, BUFFER_RCP_HEIGHT * 4.0 * spread);

    float3 r = tex2Dlod(SamplerGlowB, float4(uv, 0.0, 0.0)).rgb * 0.175;
    r += (tex2Dlod(SamplerGlowB, float4(clamp(uv + stepVec * 1.45, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerGlowB, float4(clamp(uv - stepVec * 1.45, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.165;
    r += (tex2Dlod(SamplerGlowB, float4(clamp(uv + stepVec * 3.40, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerGlowB, float4(clamp(uv - stepVec * 3.40, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.140;
    r += (tex2Dlod(SamplerGlowB, float4(clamp(uv + stepVec * 5.35, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerGlowB, float4(clamp(uv - stepVec * 5.35, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.085;
    r += (tex2Dlod(SamplerGlowB, float4(clamp(uv + stepVec * 7.30, pad, 1.0 - pad), 0.0, 0.0)).rgb + tex2Dlod(SamplerGlowB, float4(clamp(uv - stepVec * 7.30, pad, 1.0 - pad), 0.0, 0.0)).rgb) * 0.0225;

    return float4(r, 1.0);
}

// Pass 10: Main Rasterizer & Tube Compositor
float4 PS_Raster_Composite(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 tateState = tex2Dlod(SamplerTateStateCur, float4(0.5, 0.5, 0.0, 0.0)).rg;
    bool isTate = (C_OrientationMode == 0) ? false : ((C_OrientationMode == 1 || BUFFER_WIDTH < BUFFER_HEIGHT) ? true : (tateState.r > 0.5));
    float flashLuma = tateState.g;

    float2 pad = GetPillarboxPadding(isTate);
    float2 activeSize = 1.0 - 2.0 * pad;

    // Fast-path early exit for display padding (color-space matched for HDR/SDR)
    if (uv.x < pad.x || uv.x > (1.0 - pad.x) || uv.y < pad.y || uv.y > (1.0 - pad.y))
        return float4(GetBorderBG(uv), 1.0);

    float2 unwarpedLocalUV = (uv - pad) / max(activeSize, 0.0001);

    // Fixed physical glass bezel SDF (kept stationary under HV anode sag)
    float2 bezelUV = WarpCoords(unwarpedLocalUV, G_Warp);
    float r = max(G_CornerSize, 0.0001);
    float2 cd = abs(bezelUV - 0.5) - 0.5 + r;
    float cornerDist = length(max(cd, 0.0)) + min(max(cd.x, cd.y), 0.0) - r;
    float aaWidth = max(length(BUFFER_PIXEL_SIZE / max(activeSize, 0.0001)) * 1.5, 0.002);
    float maskClip = (G_EnableCurvature || G_CornerSize > 0.0001) ? (1.0 - smoothstep(0.0, aaWidth, cornerDist)) : 1.0;

    // Early-out outside rounded tube corners
    if (maskClip <= 0.0)
        return float4(GetBorderBG(uv), 1.0);

    float2 localUV = unwarpedLocalUV;
    float2 activeWarp = G_Warp;
    float activeMaxBeam = B_MaxBeam;

    if (HV_Enable)
    {
        float sag = 1.0 + flashLuma * (HV_SagAmount * 0.015);
        localUV = (localUV - 0.5) / sag + 0.5;
        activeWarp *= (1.0 + flashLuma * (HV_SagAmount * 0.04));
        activeMaxBeam /= (1.0 + flashLuma * (HV_SagAmount * 0.08));
    }

    float2 warpedLocalUV = WarpCoords(localUV, activeWarp);
    float2 clampedWarpedUV = clamp(warpedLocalUV, 0.0005, 0.9995);

    bool hasDecon = (dot(D_StaticShift, D_StaticShift) + D_RadialYoke > 0.00001);
    float2 centerDist = clampedWarpedUV - 0.5;
    float radialFactor = dot(centerDist, centerDist) * D_RadialYoke * 4.0;
    float2 staticShiftRotated = isTate ? D_StaticShift.yx : D_StaticShift.xy;
    float2 shift = (staticShiftRotated + centerDist * radialFactor) * BUFFER_PIXEL_SIZE * CRT_RES_SCALE;

    // Edge Focus Decay (normalized to 1.0 at corners & clamped so sharpness never inverts)
    float2 centerDistUV = abs(clampedWarpedUV - 0.5);
    float edgeSoften = dot(centerDistUV, centerDistUV) * 2.0;
    float activeSharpness = B_Sharpness * lerp(1.0, 0.4, saturate(edgeSoften * B_EdgeDefocus));

    float targetLines = GetTargetLines();
    float rasterPos = isTate ? (clampedWarpedUV.x * targetLines) : (clampedWarpedUV.y * targetLines);

    if (I_Enable && I_Mode == 1) rasterPos += 0.5 * (float)(framecount % 2);

    float lineBase = floor(rasterPos);
    float dist = rasterPos - lineBase - 0.5;
    float3 color = float3(0.0, 0.0, 0.0);

    if (CRT_QualityTier == 0)
    {
        int kAdj = (dist < 0.0) ? -1 : 1;

        float center0 = clamp((lineBase + 0.5) / targetLines, 0.0005, 0.9995);
        float2 uv0 = isTate ? float2(center0, clampedWarpedUV.y) : float2(clampedWarpedUV.x, center0);
        float3 c0 = SampleCRT(pad + uv0 * activeSize, pad, hasDecon, shift);
        float beam0 = BeamWeight(dist, c0, activeMaxBeam, activeSharpness);
        if (I_Enable && I_Mode == 0) beam0 *= lerp(1.0, 1.0 - I_Strength, step(0.25, frac((lineBase + (float)(framecount % 2)) * 0.5)));
        color += c0 * beam0;

        float center1 = clamp((lineBase + (float)kAdj + 0.5) / targetLines, 0.0005, 0.9995);
        float2 uv1 = isTate ? float2(center1, clampedWarpedUV.y) : float2(clampedWarpedUV.x, center1);
        float3 c1 = SampleCRT(pad + uv1 * activeSize, pad, hasDecon, shift);
        float beam1 = BeamWeight(dist - (float)kAdj, c1, activeMaxBeam, activeSharpness);
        if (I_Enable && I_Mode == 0) beam1 *= lerp(1.0, 1.0 - I_Strength, step(0.25, frac((lineBase + (float)kAdj + (float)(framecount % 2)) * 0.5)));
        color += c1 * beam1;
    }
    else
    {
        int kReach = (CRT_QualityTier == 2) ? 2 : 1;
        [unroll]
        for (int k = -2; k <= 2; k++)
        {
            if (abs(k) <= kReach)
            {
                float centerLocal = clamp((lineBase + (float)k + 0.5) / targetLines, 0.0005, 0.9995);
                float2 lineCenterLocalUV = isTate ? float2(centerLocal, clampedWarpedUV.y) : float2(clampedWarpedUV.x, centerLocal);
                float3 c = SampleCRT(pad + lineCenterLocalUV * activeSize, pad, hasDecon, shift);

                float beam = BeamWeight(dist - (float)k, c, activeMaxBeam, activeSharpness);
                if (I_Enable && I_Mode == 0) beam *= lerp(1.0, 1.0 - I_Strength, step(0.25, frac((lineBase + (float)k + (float)(framecount % 2)) * 0.5)));
                color += c * beam;
            }
        }
    }

    float rawLuma = max(max(color.r, color.g), color.b);
    color *= lerp(B_Gain, 1.0, saturate(rawLuma) * sqrt(saturate(rawLuma)));

    if (Tube_Age > 0.0)
    {
        float3 agedPhosphor = float3(1.0 - (Tube_Age * 0.15), 1.0, 1.0 - (Tube_Age * 0.25));
        color *= agedPhosphor;
        color = SafePow(color, 1.0 + (Tube_Age * 0.15));
    }

    // Phosphor Mask Generation
    float3 mask = float3(1.0, 1.0, 1.0);
    float resolutionFactor = M_ResolutionScale ? max(floor(BUFFER_HEIGHT / 1080.0 + 0.1), 1.0) : 1.0;
    float effectiveMaskSize = max(M_Size * resolutionFactor, 1.0);
    float2 screenCoord = uv * BUFFER_SCREEN_SIZE / effectiveMaskSize;
    if (isTate) screenCoord = screenCoord.yx;

    int px = int(floor(screenCoord.x));
    int py = int(floor(screenCoord.y));

    if (M_Type == 1) // Aperture Grille
    {
        if (M_SubpixelMode == 2)
        {
            int x = px % 4;
            if (x == 0) mask = float3(1.0, 1.0 - M_Strength, 1.0 - M_Strength);
            else if (x == 1) mask = float3(1.0 - M_Strength, 1.0, 1.0 - M_Strength);
            else if (x == 2) mask = float3(1.0 - M_Strength, 1.0 - M_Strength, 1.0);
            else mask = (1.0 - M_Strength * 0.35).xxx;
        }
        else
        {
            int x = px % 3;
            if (x == 0) mask = float3(1.0, 1.0 - M_Strength, 1.0 - M_Strength);
            else if (x == 1) mask = float3(1.0 - M_Strength, 1.0, 1.0 - M_Strength);
            else mask = float3(1.0 - M_Strength, 1.0 - M_Strength, 1.0);
        }
    }
    else if (M_Type == 2) // Arcade Slot Mask
    {
        int x = px % 3; int y = py % 4;
        float3 triad = (1.0 - M_Strength).xxx;
        if (x == 0) triad.r = 1.0; else if (x == 1) triad.g = 1.0; else triad.b = 1.0;

        int x6 = px % 6;
        float slot = ((x6 < 3 && y == 0) || (x6 >= 3 && y == 2)) ? (1.0 - M_Strength * 0.75) : 1.0;
        mask = triad * slot;
        if (M_SubpixelMode == 2 && (px % 4 == 3)) mask *= (1.0 - M_Strength * 0.35);
    }
    else if (M_Type == 3) // Shadow Mask Dot Triad
    {
        int x = px % 3;
        int rowShift = ((px / 3) % 2) * 2;
        int y = (py + rowShift) % 3;
        mask = (1.0 - M_Strength).xxx;
        if (x == 0 && y != 0) mask.r = 1.0; else if (x == 1 && y != 1) mask.g = 1.0; else if (x == 2 && y != 2) mask.b = 1.0;
        if (M_SubpixelMode == 2 && (px % 4 == 3)) mask *= (1.0 - M_Strength * 0.35);
    }

    if (M_SubpixelMode == 1) mask = mask.bgr;
    else if (M_SubpixelMode == 3) mask = lerp(mask, dot(mask, 1.0 / 3.0).xxx, 0.20);

    color *= lerp(1.0, min(1.0 / max(MaskMeanTransmission(), 0.25), 2.5), M_AutoComp);
    float lumaMask = max(max(color.r, color.g), color.b);
    mask = lerp(mask, float3(1.0, 1.0, 1.0), (saturate(lumaMask) * sqrt(saturate(lumaMask))) * M_Bloom);
    color *= mask * M_BrightBoost;

    // Framerate-independent Single-Wave Refresh Sweep
    if (Sync_Phase > 0.0)
    {
        float sweepCoord = isTate ? clampedWarpedUV.x : clampedWarpedUV.y;
        float cycleTime = frac(timer * 0.0009);
        float sweep = 0.5 + 0.5 * sin(6.2831853 * frac(sweepCoord - cycleTime));
        color *= lerp(1.0, 1.0 - Sync_Phase, sweep);
    }

    // Framerate-independent AC Hum Bar
    if (HB_Enable)
    {
        float humCoord = isTate ? clampedWarpedUV.x : clampedWarpedUV.y;
        float humTime = frac(timer * (0.0003 * HB_Speed));
        float humWave = sin(frac(humTime + humCoord * HB_Frequency) * 6.2831853);
        color += (humWave * HB_Strength * 0.025) + color * (humWave * HB_Strength);
    }

    float2 sampleUV = pad + clampedWarpedUV * activeSize;
    if (H_Enable && H_Strength > 0.0)
        color += tex2Dlod(SamplerHalationV, float4(sampleUV, 0.0, 0.0)).rgb * H_Strength;
    if (GL_Enable && GL_Strength > 0.0)
        color += tex2Dlod(SamplerGlowA, float4(sampleUV, 0.0, 0.0)).rgb * GL_Strength;

    // =========================================================================
    // Display Output Mapping & Single-Pass Border Blend
    // =========================================================================
    int hdrMode = GetEffectiveHDRProfile();
    float blackOffsetLinear = (COL_BlackLevel >= 0.0)
        ? SafePow1(COL_BlackLevel, COL_OutputGamma)
        : -SafePow1(-COL_BlackLevel, COL_OutputGamma);

    float3 mappedColor;

    if (hdrMode == 1) // HDR10 (Rec.2020 / SMPTE ST 2084 PQ)
    {
        float maxHeadroom = max(HDR_PeakNits / max(HDR_PaperWhite, 1.0), 1.0);
        float3 hdrLinear = lerp(1.0 + (maxHeadroom - 1.0) * tanh((color - 1.0) / max(maxHeadroom - 1.0, 0.001)), color, step(color, float3(1.0, 1.0, 1.0)));
        float3 physicalNits = mul(Mat_Rec709_to_Rec2020, max(hdrLinear * HDR_PaperWhite, 0.0)) + (blackOffsetLinear * HDR_PaperWhite).xxx;
        mappedColor = EncodePQ(max(physicalNits, 0.0));
    }
    else if (hdrMode == 2) // scRGB (Linear FP16)
    {
        mappedColor = max((color + blackOffsetLinear.xxx) * (HDR_PaperWhite / 80.0), 0.0);
    }
    else // SDR (Standard)
    {
        mappedColor = max(SafePow(color, 1.0 / COL_OutputGamma) + COL_BlackLevel.xxx, 0.0);
    }

    if (maskClip < 1.0)
        mappedColor = lerp(GetBorderBG(uv), mappedColor, maskClip);

    return float4(mappedColor, 1.0);
}

// =========================================================================
// Technique Definition
// =========================================================================
technique CRT_Mame_Advance_Four
{
    pass TateDetect { VertexShader = PostProcessVS; PixelShader = PS_TateDetect; RenderTarget = TexTateStateCur; }
    pass TateCopy { VertexShader = PostProcessVS; PixelShader = PS_TateCopy; RenderTarget = TexTateStatePrev; }
    pass Linearize { VertexShader = PostProcessVS; PixelShader = PS_Linearize; RenderTarget = TexLinear; }
    pass SignalBlur { VertexShader = PostProcessVS; PixelShader = PS_SignalBlur; RenderTarget = TexSignal; }
#if CRT_ENABLE_PERSISTENCE
    pass PersistUpdate { VertexShader = PostProcessVS; PixelShader = PS_PersistUpdate; RenderTarget = TexPersistCur; }
    pass PersistCopy { VertexShader = PostProcessVS; PixelShader = PS_PersistCopy; RenderTarget = TexPersistPrev; }
#endif
    pass Halation_Horizontal { VertexShader = PostProcessVS; PixelShader = PS_Halation_H; RenderTarget = TexHalationH; }
    pass Halation_Vertical { VertexShader = PostProcessVS; PixelShader = PS_Halation_V; RenderTarget = TexHalationV; }
    pass GlowDown { VertexShader = PostProcessVS; PixelShader = PS_GlowDown; RenderTarget = TexGlowA; }
    pass GlowBlurH { VertexShader = PostProcessVS; PixelShader = PS_GlowH; RenderTarget = TexGlowB; }
    pass GlowBlurV { VertexShader = PostProcessVS; PixelShader = PS_GlowV; RenderTarget = TexGlowA; }
    pass Raster_Composite { VertexShader = PostProcessVS; PixelShader = PS_Raster_Composite; }
}