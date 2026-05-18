<div align="center">

<img src="docs/screenshots/icon.png" width="120" alt="iCamera icon"/>

# iCamera

### Professional Camera App · Leica-Inspired Aesthetics · Full Manual Control

*Available for Android · iOS coming soon*

</div>

---

## What is iCamera?

iCamera is a professional-grade camera application built for photographers who demand more than a point-and-shoot experience. Inspired by the minimalist design language and optical heritage of Leica rangefinder cameras, iCamera combines full manual exposure control with a native C++ image pipeline that applies real film emulation, lens simulation, and AI-assisted depth effects — all processed on-device, with no cloud upload required.

Whether you are a hobbyist wanting to recreate the warmth of analog film, or a serious photographer who needs direct access to ISO, shutter speed, and aperture, iCamera gives you the tools to craft images intentionally.

---

## Screenshots

<table>
<tr>
<td align="center" width="50%">

**Portrait Mode — PRO**

<img src="docs/screenshots/portrait_pro.jpg" width="320" alt="Portrait PRO mode"/>

Full-screen viewfinder with Film look selector,<br/>White Balance row, and manual exposure wheels.

</td>
<td align="center" width="50%">

**Landscape Mode — AUTO**

<img src="docs/screenshots/landscape_auto.jpg" width="480" alt="Landscape AUTO mode"/>

Full-screen landscape preview with HUD and<br/>mode controls along the right edge.

</td>
</tr>
</table>

### Film Look Samples

These two shots were taken of the same subject using the iCamera app, demonstrating the difference between the **CLASSIC** and **B&W** film emulations.

<table>
<tr>
<td align="center" width="50%">

**CLASSIC Film Look**

<img src="docs/screenshots/sample_classic.jpg" width="300" alt="CLASSIC film look — warm analog tones"/>

Warm amber tones, lifted shadows, slight halation —<br/>evokes Kodak Portra / Leica M film aesthetics.

</td>
<td align="center" width="50%">

**B&W Film Look**

<img src="docs/screenshots/sample_bw.jpg" width="300" alt="B&W film look — high-contrast monochrome"/>

High-contrast monochrome with deep blacks —<br/>classic Ilford HP5 / Tri-X character.

</td>
</tr>
</table>

---

## Key Features

| Feature | Details |
|---|---|
| **Shooting Modes** | AUTO · PRO (full manual) · APT (aperture-priority) |
| **Film Looks** | CLASSIC · CONTEMPORARY · B&W · VIVID · ARTISTIC — 3D LUT, 33×33×33 |
| **White Balance** | BULB · INDOOR · FLUORESCENT · DAYLIGHT · CLOUDY · SHADE |
| **Virtual Lenses** | Summilux 28mm · Summilux 35mm · Noctilux 50mm |
| **Lens Simulation** | Cosine⁴ vignette · Chromatic aberration · Barrel distortion |
| **Bokeh** | AI portrait background blur via ML Kit segmentation |
| **Manual ISO** | 50 → 6400 via scroll wheel (Camera2 hardware path) |
| **Manual Shutter** | 1/8000 → 1s via scroll wheel |
| **Zoom** | Pinch-to-zoom + lens snap (28mm=1.0×, 35mm=1.3×, 50mm=1.8×) |
| **Quality** | STD (~8MP) · HQ (full 13MP sensor) |
| **RAW Capture** | DNG output saved to Pictures/iCamera |
| **Orientation** | Full-screen portrait and landscape |

---

## Interface Guide

### Top HUD (Heads-Up Display)

```
1/2000          ISO 400        iCamera         5500K        f/5.6
  SS              ISO         NOCTILUX-M 50     WB           APT
```

The top bar always shows your current exposure triangle at a glance:
- **SS** — Shutter speed (e.g. 1/2000)
- **ISO** — Sensor sensitivity (e.g. ISO 400)
- **Lens name** — Active virtual lens profile (center)
- **WB** — White balance color temperature in Kelvin
- **APT** — Aperture (simulated, affects bokeh depth)

### Top-Right: Film Look Badge

The active film look name (e.g. **CLASSIC**) is displayed as a badge in the top-right corner of the viewfinder, so you always know which emulation is active while shooting.

### Bottom Controls

The bottom panel is organized into rows from top to bottom:

#### Row 1 — Film Look + Lens Selector

```
Film:  CLASSIC   CONTEMPORARY   B&W   VIVID   ARTISTIC      28mm  35mm  50mm
                                                            f/1.4 f/1.4 f/0.95
```

- **Film:** — Scroll horizontally to select the film emulation. The selected look is applied to every captured photo via a full 3D LUT.
- **Lens buttons** (right side) — Tap to switch virtual lens. Each lens has a different default focal length zoom, vignette strength, chromatic aberration, and barrel distortion profile.

#### Row 2 — White Balance

```
WB:   BULB   INDOOR   FLUORESCENT   DAYLIGHT   CLOUDY   SHADE
```

Tap any preset to shift the color temperature of the captured image. **DAYLIGHT** is neutral (5500K). **BULB** warms toward tungsten (3200K). **SHADE** adds a cool-blue correction for open shade.

#### Exposure Wheels (PRO Mode Only)

```
        SHUTTER                          ISO
   500   1000   2000   4000           200   400   800
              |                                |
           1/2000                            400
```

In PRO mode, two horizontal scroll wheels appear:
- **SHUTTER wheel** — Scroll left/right to adjust shutter speed. The red tick marks the active value.
- **ISO wheel** — Scroll left/right to adjust sensor sensitivity. The red tick marks the active value.

Both the label and the selected value are displayed in **bold** above each wheel. The selected item is always centered above the red tick mark regardless of screen width.

#### Mode Bar

```
[ RAW ]   [ AUTO ]   [ PRO ]   [ APT ]   [ FLASH ]   [ FLIP ]   [ STD ]
```

- **RAW** — Toggle DNG capture. When active, the app saves the unprocessed sensor data as a .dng file instead of applying the image pipeline.
- **AUTO** — Fully automatic exposure. The camera selects ISO and shutter speed. Film looks and lens simulation still apply.
- **PRO** — Full manual mode. Exposes the SHUTTER and ISO scroll wheels. Use this for precise creative control.
- **APT** — Aperture-priority mode. Set the virtual aperture (f-stop); the camera selects shutter speed to achieve correct exposure. Higher aperture values produce stronger bokeh.
- **FLASH** — Enable/disable the camera flash.
- **FLIP** — Switch between rear and front camera.
- **STD / HQ** — Toggle image quality. STD uses ~8MP (faster processing). HQ uses full 13MP sensor resolution.

#### Shutter Button + Thumbnail

The large circle at the bottom center is the **shutter button**. Tap it once to capture. The shutter releases immediately — image processing (LUT, lens effects, bokeh) runs in the background so you are ready for the next shot without waiting.

The small square in the bottom-left corner shows a **thumbnail** of the last captured photo. Tap it to open the system gallery.

---

## Shooting Modes Explained

### AUTO Mode
The camera manages everything automatically. You select the Film look, White Balance, and lens profile — the app handles exposure. Ideal for quick shots, family events, or situations where lighting changes rapidly.

### PRO Mode
Full manual control over shutter speed and ISO. Use this when:
- Shooting in low light and you want to push ISO deliberately without the camera hunting
- Freezing fast motion (set shutter to 1/1000 or faster)
- Introducing intentional motion blur (set shutter to 1/30 or slower)
- Shooting under artificial or mixed lighting where auto-exposure gets confused

**Tip:** Set ISO to 100–200 and shutter to 1/250 in bright daylight. In a dim interior, try ISO 800 and shutter 1/60.

### APT (Aperture-Priority) Mode
Set the virtual aperture (f-stop); the camera selects the shutter speed automatically. Lower f-stop values (f/1.4, f/0.95) produce stronger background blur. Higher values (f/5.6, f/16) keep more of the scene in focus. APT mode combines creative depth-of-field control with the convenience of auto-exposure.

---

## Film Looks — Detailed Guide

Film looks are processed using full 3D Look-Up Tables (LUTs) applied in C++ at capture time. They are not Instagram-style filters — each LUT was designed to reproduce the tonal response, color shift, and shadow rendering of a specific film stock or photographic style.

| Look | Character | Best For |
|---|---|---|
| **CLASSIC** | Warm amber midtones, lifted shadows, gentle halation | Portraits, everyday life, golden-hour scenes |
| **CONTEMPORARY** | Neutral-warm, clean, slightly desaturated | Street photography, architecture, modern subjects |
| **B&W** | High-contrast monochrome, deep blacks | Dramatic portraits, texture-rich subjects, fine art |
| **VIVID** | Punchy color, high saturation, rich contrast | Travel, landscapes, product shots in good light |
| **ARTISTIC** | Cross-processed color shift, cinematic grade | Creative / experimental — emulates bleach-bypass film |

**How to choose:** Start with CLASSIC for most situations. Switch to B&W when you want to emphasize shape, shadow, and texture over color. Use VIVID for scenes with strong, saturated colors. ARTISTIC is best used intentionally for a specific mood.

---

## Virtual Lenses — Detailed Guide

Each lens profile applies four optical effects during image processing:

| Lens | Focal Length | Aperture | Vignette | CA Fringe | Distortion |
|---|---|---|---|---|---|
| **Summilux 28mm** | Wide | f/1.4 | Mild | Low | Mild barrel |
| **Summilux 35mm** | Standard | f/1.4 | Moderate | Moderate | Slight barrel |
| **Noctilux 50mm** | Portrait | f/0.95 | Strong | Higher | Minimal |

- **Summilux 28mm** — Wide-angle perspective. Shows more of the environment. Good for street photography, architecture, and environmental portraits. Tapping this lens snaps zoom to 1.0×.
- **Summilux 35mm** — The "standard" lens. Closest to what the human eye sees naturally. Versatile all-rounder for everyday shooting. Snaps to 1.3×.
- **Noctilux 50mm** — Portrait lens with the fastest virtual aperture (f/0.95). Produces the strongest vignette and background separation. Ideal for close-up portraits and isolating subjects. Snaps to 1.8×.

**Tip:** After tapping a lens, you can fine-tune zoom by pinching the viewfinder. A zoom pill indicator shows the current magnification level and fades after 2 seconds.

---

## White Balance Guide

| Preset | Color Temp | Recommended Use |
|---|---|---|
| **BULB** | ~3200K | Incandescent / warm tungsten bulbs indoors |
| **INDOOR** | ~4000K | LED or mixed indoor lighting |
| **FLUORESCENT** | ~4500K | Office fluorescent tubes |
| **DAYLIGHT** | ~5500K | Outdoor midday, neutral reference |
| **CLOUDY** | ~6500K | Overcast sky — warms up the image |
| **SHADE** | ~7500K | Open shade — counteracts blue cast from sky |

White balance affects the recorded image color. If colors look too orange or yellow, switch to a cooler preset (DAYLIGHT, CLOUDY). If the scene looks too blue, switch to warmer (BULB, INDOOR).

---

## Saving & Accessing Photos

All photos are automatically saved to **Pictures/iCamera** on your device's internal storage. To view them:

1. Tap the **thumbnail** in the bottom-left corner of the camera screen to open your device's gallery directly.
2. Or open your device's **Files** or **Gallery** app and navigate to `Pictures → iCamera`.

**RAW files** (when RAW mode is active) are saved as `.dng` files and can be opened in Adobe Lightroom, Snapseed, or any DNG-compatible editor for full non-destructive post-processing.

---

## Tips for Better Shots

1. **Use PRO mode in low light.** Set ISO 800–1600 and shutter 1/60 to avoid blur while keeping noise under control. The CLASSIC film look's lifted shadows hide high-ISO grain naturally.

2. **Match your film look to the light.** CLASSIC works beautifully in warm afternoon light. B&W excels in harsh midday sun where the high contrast becomes a feature, not a flaw.

3. **Use Noctilux 50mm for portraits.** The strong vignette naturally draws the eye to the center of the frame. The bokeh effect separates your subject from distracting backgrounds.

4. **Shoot HQ for anything you might print.** STD is fine for social media. Switch to HQ when shooting something you might want to enlarge or crop.

5. **Lock exposure in PRO mode before the shot.** Find the exposure settings that work for your lighting, then shoot multiple frames without letting auto-exposure hunt. Consistent exposure across a series of shots makes editing easier.

6. **Use shade WB on overcast days.** Without correction, overcast light photographs cold and grey. The SHADE preset warms it back to a more natural, pleasing tone.

---

## Technical Specifications

| Specification | Details |
|---|---|
| Platform | Android 8.0+ (API 26+) |
| Image Pipeline | Native C++17 via Dart FFI |
| Color Science | 3D LUT — 33×33×33 trilinear interpolation |
| Lens Simulation | Cosine⁴ vignette · Radial CA · k1 barrel distortion |
| AI Bokeh | Google ML Kit Selfie Segmentation |
| Depth Estimation | TFLite MiDaS v2.1 |
| Camera Engine | CameraX + Camera2 interop |
| RAW Format | DNG (Digital Negative) |
| Output Formats | JPEG (STD / HQ) · DNG (RAW) |
| Save Location | Pictures/iCamera (MediaStore) |
| iOS | In development |

---

## Privacy

iCamera processes all images entirely on-device. No photos, metadata, or camera data are uploaded to any server. The app requires camera and storage permissions only — no network access is needed to use any feature.

---

<div align="center">

*iCamera — Shoot with intention.*

</div>
