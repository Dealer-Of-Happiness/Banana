AI Goodbye Desktop - Icon Files Required

Please add the following icon files to this directory before building:

REQUIRED FILES:
===============

1. icon.ico (Windows)
   - Multi-resolution ICO file
   - Sizes: 16x16, 32x32, 48x48, 64x64, 128x128, 256x256

2. icon.icns (macOS)
   - Apple ICNS format
   - Sizes: 16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024

3. 32x32.png
   - PNG format, 32x32 pixels

4. 128x128.png
   - PNG format, 128x128 pixels

5. 128x128@2x.png
   - PNG format, 256x256 pixels (for Retina displays)


OPTIONAL (for Windows NSIS installer):
=====================================

6. header.bmp
   - 150x57 pixels, 24-bit BMP
   - Shown at top of installer wizard

7. sidebar.bmp
   - 164x314 pixels, 24-bit BMP
   - Shown on left side of installer welcome/finish pages


HOW TO CREATE ICONS:
====================

Option 1: Online Tools
- https://icon.kitchen/ (Free, great for app icons)
- https://realfavicongenerator.net/ (Free)
- https://makeappicon.com/ (Free)

Option 2: Design Tools
- Figma (Free)
- Sketch (Mac only)
- Adobe Illustrator

Option 3: Command Line (macOS)
  # From a 1024x1024 PNG source:
  iconutil -c icns icon.iconset

Option 4: Command Line (ImageMagick)
  # Create ICO from PNG:
  convert icon-256.png icon-128.png icon-64.png icon-32.png icon-16.png icon.ico


RECOMMENDED DESIGN:
==================

Your AI Goodbye icon should be:
- Simple and recognizable at small sizes
- Work on both light and dark backgrounds
- Use the brand colors
- Consider an AI-themed design

Example concept:
- A waving hand with AI elements
- A friendly goodbye gesture
- Abstract AI/circuit pattern


TIPS:
=====
- Test icons at 16x16 - they should still be recognizable
- Avoid fine details that disappear at small sizes
- Use solid colors rather than gradients for clarity
- Consider adding a subtle shadow for depth
