"""Patches gen_manual.py: updates section 12 (QUAL) and adds section 16 (iOS PRO mode exposure)."""
import sys
sys.stdout.reconfigure(encoding='utf-8')

with open(r'C:\Users\tomcw\App_tcw3\iCamera\iPhoneApp\gen_manual.py', 'r', encoding='utf-8') as f:
    content = f.read()

# ── Replace section 12 ──────────────────────────────────────────────────────
start12 = content.find('# 12. PHOTO QUALITY')
end12   = content.find('# 13. SAVING')
assert start12 > 0 and end12 > start12, "Section 12 markers not found"

new_section12 = r"""# 12. PHOTO QUALITY
# ════════════════════════════════════════════════════════════════════════════
heading1(doc, "12.  Photo Quality — STD / HQ / HEIF")
body(doc,
     "The QUAL button in the Gear panel cycles through three capture quality levels. "
     "Each tap moves to the next option: STD → HQ → HEIF → STD.")

heading2(doc, "What is a Megapixel?")
body(doc,
     "A digital photo is made up of millions of tiny coloured dots called pixels. A megapixel (MP) "
     "is simply one million of those dots. More dots = more fine detail — but also a larger file "
     "and longer processing time.")

two_col_table(doc,
    ["Setting", "Format", "Quality", "Typical File Size", "Best For"],
    [
        ["STD",  "JPEG", "85%",        "~2–3 MB", "Everyday use — fast, small, sharp"],
        ["HQ",   "JPEG", "97%",        "~5–7 MB", "Large prints, heavy cropping"],
        ["HEIF", "HEIC", "H.265 ~90%", "~2–4 MB", "Maximum quality, smallest file (Apple ecosystem)"],
    ],
    col_widths=[2, 2, 2.5, 2.5, 6.5]
)
add_spacer(doc, 10)

heading2(doc, "STD — Standard JPEG")
body(doc, "JPEG at quality 85 — the default for all everyday shooting.")
bullet(doc, "Fast processing — thumbnail appears within about one second.")
bullet(doc, "File sizes around 2–3 MB — easy to share by message or email.")
bullet(doc, "Fine for any screen or A3 print.")
tip_box(doc, "Use STD for everyday shooting. You will not see any quality difference on a phone or TV screen.")

heading2(doc, "HQ — High Quality JPEG")
body(doc, "JPEG at quality 97 — maximum detail with minimal compression artefacts.")
bullet(doc, "More fine detail — useful for very large prints or significant cropping.")
bullet(doc, "Processing takes 2–4 seconds after the shutter click.")
bullet(doc, "File sizes noticeably larger (~5–7 MB).")
tip_box(doc, "Use HQ when you plan to print larger than A3, or need to crop deeply into the photo.")

heading2(doc, "HEIF — Apple High Efficiency Image Format")
body(doc,
     "HEIF (pronounced ‘HEEF’, file extension .heic) is Apple’s native photo format — the same "
     "format the built-in iPhone Camera app uses when you select ‘High Efficiency’ in "
     "iOS Settings → Camera → Formats. It uses H.265 (HEVC) compression, which is roughly "
     "twice as efficient as JPEG at the same visual quality.")
bullet(doc,
       "Same visual quality as HQ JPEG but the file is roughly 50% smaller. "
       "A photo that would be 6 MB as HQ JPEG is typically 2–3 MB as HEIF.",
       bold_prefix="Smaller files, same quality:  ")
bullet(doc,
       "iCamera encodes your processed pixels directly into HEIF using iOS native ImageIO "
       "(CGImageDestinationCreateWithData). There is no intermediate JPEG step. "
       "The Leica Look pipeline runs on the raw pixels first, then those pixels go straight "
       "into the HEIF encoder. One encode step = maximum quality for the format.",
       bold_prefix="Direct pixel encoding:  ")
bullet(doc,
       "HEIF files open natively in Photos.app, iCloud, Safari, and Mac Preview. "
       "Windows 11 with the HEIF codec from the Microsoft Store also supports them. "
       "Some older apps may not recognise .heic files — use HQ JPEG for maximum compatibility.",
       bold_prefix="Compatibility:  ")
tip_box(doc,
        "HEIF is recommended for iPhone users who want maximum quality with the smallest possible "
        "file. Use HQ JPEG if you need to share with apps or services that do not support .heic.")

heading2(doc, "HEIF vs Leica Look — Not the Same Thing")
body(doc,
     "These are two completely separate controls:")
bullet(doc,
       "A file compression format. Controls how image data is stored on disk — not what the "
       "image looks like. Choosing HEIF vs JPEG does not change colours, vignette, or any "
       "creative effect in your photo.",
       bold_prefix="HEIF (QUAL button):  ")
bullet(doc,
       "A creative processing pipeline (colour grade, vignette, chromatic aberration, distortion) "
       "applied to the captured pixels. Controlled by the LEICA button. Runs independently of "
       "the output format. If Leica Look is OFF, the photo is saved clean in whichever format "
       "is selected.",
       bold_prefix="Leica Look (LEICA button):  ")

heading2(doc, "How to Switch Quality")
body(doc,
     "Open the Gear panel (⚙ button, bottom right) and tap QUAL. "
     "The label cycles: STD → HQ → HEIF → STD. "
     "HQ and HEIF both use full sensor resolution; a brief camera reinitialisation occurs "
     "when switching between resolution levels.")
add_spacer(doc)

"""

content = content[:start12] + new_section12 + content[end12:]

# ── Add section 16 before the footer ────────────────────────────────────────
footer_marker = '# FOOTER PAGE'
assert footer_marker in content, "Footer marker not found"

new_section16 = r"""# ════════════════════════════════════════════════════════════════════════════
# 16. HOW iCAMERA APPLIES MANUAL EXPOSURE ON iPHONE
# ════════════════════════════════════════════════════════════════════════════
heading1(doc, "16.  How iCamera Applies Manual Exposure on iPhone")
body(doc,
     "When you select PRO mode and set a specific ISO and shutter speed, iCamera sends those exact "
     "values directly to the iPhone camera sensor using Apple’s AVFoundation framework. "
     "This section explains how that works and why it matters.")

heading2(doc, "What Happens When You Enter PRO Mode")
body(doc, "The moment you tap PRO, iCamera does three things in sequence:")
bullet(doc,
       "Locks the autofocus so the focus point stays fixed. "
       "The camera will not hunt or refocus while you compose your shot.",
       bold_prefix="1. Locks focus  ")
bullet(doc,
       "Sends your selected ISO and shutter speed directly to the sensor "
       "using AVCaptureDevice.setExposureModeCustom. This is the same low-level API "
       "that Apple’s own Camera app uses for its manual controls. "
       "The camera’s automatic exposure brain is switched off entirely.",
       bold_prefix="2. Sets hardware exposure  ")
bullet(doc,
       "Waits for the sensor to confirm that the new settings have been applied "
       "(via a completion callback from iOS) before allowing a capture. "
       "This ensures the photo is taken with your exact values, not with a stale "
       "auto-exposure reading.",
       bold_prefix="3. Waits for confirmation  ")

heading2(doc, "What the Live HUD Shows in AUTO vs PRO")
body(doc,
     "In AUTO mode, the SS and ISO values shown in the top bar are live readings from the sensor "
     "— the camera’s automatic exposure system updates them up to twice per second as lighting "
     "changes. What you see is what the sensor is actually using right now.")
body(doc,
     "In PRO mode, the SS and ISO values shown are the values you have chosen. "
     "The sensor has been locked to those exact values and will not change them until "
     "you scroll the wheel or switch back to AUTO.")

heading2(doc, "Why Manual Exposure Matters")
two_col_table(doc,
    ["Situation", "What to do in PRO"],
    [
        ["Photograph a candle flame",
         "ISO 400, SS 1/125 — freezes the flame without overexposing"],
        ["Night city street",
         "ISO 1600, SS 1/30 — rest phone on surface to avoid blur"],
        ["Bright beach in noon sun",
         "ISO 100, SS 1/2000 — clean sky, no blown-out whites"],
        ["Consistent series for editing",
         "Lock any ISO/SS that gives correct brightness — every shot identical"],
        ["Motion blur (intentional)",
         "ISO 100, SS 1/15 or slower — cars blur, static elements stay sharp"],
    ],
    col_widths=[5.5, 10]
)
add_spacer(doc)

heading2(doc, "The iPhone Aperture Limitation")
body(doc,
     "Unlike a traditional camera, the iPhone lens has a fixed, non-variable aperture. "
     "The iPhone 13 wide camera is always f/1.6 — you cannot change it. "
     "iCamera’s APT mode and the f-stop value displayed in the HUD simulate aperture "
     "for bokeh rendering purposes, but the physical lens opening is always the same. "
     "This is why the EXIF data on saved photos always shows f/1.6 regardless of the "
     "APT setting you chose in iCamera.")
tip_box(doc,
        "The APT value in iCamera controls the strength of the software bokeh blur applied "
        "at capture time, not the physical lens opening. Lower f-number = stronger blur.")
add_spacer(doc)

"""

content = content.replace('# ' + footer_marker, new_section16 + '\n# ' + footer_marker)

with open(r'C:\Users\tomcw\App_tcw3\iCamera\iPhoneApp\gen_manual.py', 'w', encoding='utf-8') as f:
    f.write(content)

print("gen_manual.py patched successfully.")
