#!/usr/bin/env python3
"""
Generate app icons from the source icon for desktop builds.

Uses the AIGoodbye iPhone app icon as the source and creates all required
icon formats for Tauri (macOS, Windows, Linux).
"""

import os
import struct
import sys
import zlib

# Path to source icon (relative to this script)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_ICON = os.path.join(SCRIPT_DIR, '..', '..', 'AIGoodbye', 'AIGoodbye',
                           'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon.png')

def resize_image_with_pil(source_path, sizes, icons_dir):
    """Use PIL to resize source image and create all icon formats."""
    from PIL import Image

    print(f"Using source icon: {source_path}")
    img = Image.open(source_path).convert('RGBA')

    # Create PNG files
    for size, filename in [(32, '32x32.png'), (128, '128x128.png'), (256, '128x128@2x.png')]:
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        output_path = os.path.join(icons_dir, filename)
        resized.save(output_path, 'PNG')
        print(f"Created: {output_path}")

    # Create Windows ICO with high-resolution images
    # Include 256x256 PNG for modern Windows (Vista+) for crisp taskbar display
    # Windows taskbar typically uses 48x48 or 64x64, but scales from larger sizes
    # Order from largest to smallest for best quality selection
    ico_sizes = [256, 128, 64, 48, 40, 32, 24, 20, 16]
    ico_images = []
    for s in ico_sizes:
        resized = img.resize((s, s), Image.Resampling.LANCZOS)
        ico_images.append(resized)

    ico_path = os.path.join(icons_dir, 'icon.ico')
    # PIL's ICO save: save 256x256 first (stored as PNG inside ICO for quality)
    # then append smaller sizes
    ico_images[0].save(
        ico_path,
        format='ICO',
        append_images=ico_images[1:]
    )
    print(f"Created: {ico_path} with sizes: {ico_sizes}")

    # Also create a separate high-res icon for additional uses
    icon_png_256 = os.path.join(icons_dir, 'icon-256.png')
    img.resize((256, 256), Image.Resampling.LANCZOS).save(icon_png_256, 'PNG')
    print(f"Created: {icon_png_256}")

    # Create macOS ICNS
    icns_path = os.path.join(icons_dir, 'icon.icns')
    create_icns_from_pil(img, icns_path)
    print(f"Created: {icns_path}")

    # Create Windows installer images (header.bmp and sidebar.bmp)
    # These need to be 24-bit BMP files
    header = img.resize((150, 57), Image.Resampling.LANCZOS).convert('RGB')
    header_path = os.path.join(icons_dir, 'header.bmp')
    header.save(header_path, 'BMP')
    print(f"Created: {header_path}")

    sidebar = img.resize((164, 314), Image.Resampling.LANCZOS).convert('RGB')
    sidebar_path = os.path.join(icons_dir, 'sidebar.bmp')
    sidebar.save(sidebar_path, 'BMP')
    print(f"Created: {sidebar_path}")


def create_icns_from_pil(img, output_path):
    """Create macOS ICNS file from PIL Image."""
    from PIL import Image
    import io

    # ICNS type codes for different sizes (PNG-based for modern macOS)
    type_codes = {
        16: b'icp4',
        32: b'icp5',
        64: b'icp6',
        128: b'ic07',
        256: b'ic08',
        512: b'ic09',
        1024: b'ic10',
    }

    icons_data = b''

    for size, type_code in type_codes.items():
        resized = img.resize((size, size), Image.Resampling.LANCZOS)

        # Save as PNG to bytes
        png_buffer = io.BytesIO()
        resized.save(png_buffer, format='PNG')
        png_data = png_buffer.getvalue()

        # Add to ICNS data
        chunk_size = len(png_data) + 8
        icons_data += type_code + struct.pack('>I', chunk_size) + png_data

    # ICNS header
    total_size = len(icons_data) + 8
    icns_header = b'icns' + struct.pack('>I', total_size)

    with open(output_path, 'wb') as f:
        f.write(icns_header + icons_data)


# Fallback: Create placeholder icons without PIL
# (keeping the original fallback code for environments without PIL)

FALLBACK_COLOR = (147, 112, 219)  # Purple-ish color as fallback

def create_png_fallback(width, height, color, output_path):
    """Create a simple solid-color PNG file without external dependencies."""
    def write_chunk(chunk_type, data):
        chunk = chunk_type + data
        return struct.pack('>I', len(data)) + chunk + struct.pack('>I', zlib.crc32(chunk) & 0xffffffff)

    signature = b'\x89PNG\r\n\x1a\n'
    ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    ihdr = write_chunk(b'IHDR', ihdr_data)

    raw_data = b''
    for y in range(height):
        raw_data += b'\x00'
        for x in range(width):
            raw_data += bytes(color) + b'\xff'

    compressed = zlib.compress(raw_data, 9)
    idat = write_chunk(b'IDAT', compressed)
    iend = write_chunk(b'IEND', b'')

    with open(output_path, 'wb') as f:
        f.write(signature + ihdr + idat + iend)
    print(f"Created (fallback): {output_path}")


def create_ico_fallback(sizes, color, output_path):
    """Create a Windows ICO file with multiple sizes (fallback)."""
    def create_bmp_data(width, height, color):
        header = struct.pack('<IiiHHIIiiII', 40, width, height * 2, 1, 32, 0, 0, 0, 0, 0, 0)
        pixels = b''
        for y in range(height):
            for x in range(width):
                pixels += bytes([color[2], color[1], color[0], 255])
        mask_row_size = ((width + 31) // 32) * 4
        mask = b'\x00' * (mask_row_size * height)
        return header + pixels + mask

    ico_header = struct.pack('<HHH', 0, 1, len(sizes))
    offset = 6 + len(sizes) * 16
    entries = []
    images = []

    for size in sizes:
        bmp_data = create_bmp_data(size, size, color)
        entry = struct.pack('<BBBBHHII',
            size if size < 256 else 0, size if size < 256 else 0,
            0, 0, 1, 32, len(bmp_data), offset)
        entries.append(entry)
        images.append(bmp_data)
        offset += len(bmp_data)

    with open(output_path, 'wb') as f:
        f.write(ico_header)
        for entry in entries:
            f.write(entry)
        for image in images:
            f.write(image)
    print(f"Created (fallback): {output_path}")


def create_icns_fallback(sizes, color, output_path):
    """Create a macOS ICNS file (fallback)."""
    type_codes = {16: b'icp4', 32: b'icp5', 64: b'icp6', 128: b'ic07', 256: b'ic08', 512: b'ic09', 1024: b'ic10'}

    def create_png_data(width, height, color):
        def write_chunk(chunk_type, data):
            chunk = chunk_type + data
            return struct.pack('>I', len(data)) + chunk + struct.pack('>I', zlib.crc32(chunk) & 0xffffffff)

        signature = b'\x89PNG\r\n\x1a\n'
        ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
        ihdr = write_chunk(b'IHDR', ihdr_data)

        raw_data = b''
        for y in range(height):
            raw_data += b'\x00'
            for x in range(width):
                raw_data += bytes(color) + b'\xff'

        compressed = zlib.compress(raw_data, 9)
        idat = write_chunk(b'IDAT', compressed)
        iend = write_chunk(b'IEND', b'')
        return signature + ihdr + idat + iend

    icons_data = b''
    for size in sizes:
        if size in type_codes:
            png_data = create_png_data(size, size, color)
            chunk_size = len(png_data) + 8
            icons_data += type_codes[size] + struct.pack('>I', chunk_size) + png_data

    total_size = len(icons_data) + 8
    with open(output_path, 'wb') as f:
        f.write(b'icns' + struct.pack('>I', total_size) + icons_data)
    print(f"Created (fallback): {output_path}")


def create_bmp_fallback(width, height, color, output_path):
    """Create a simple 24-bit BMP file (fallback)."""
    row_size = ((width * 3 + 3) // 4) * 4
    pixel_data_size = row_size * height
    file_size = 54 + pixel_data_size

    bmp_header = struct.pack('<2sIHHI', b'BM', file_size, 0, 0, 54)
    dib_header = struct.pack('<IiiHHIIiiII', 40, width, height, 1, 24, 0, pixel_data_size, 2835, 2835, 0, 0)

    pixels = b''
    padding = b'\x00' * (row_size - width * 3)
    for y in range(height):
        for x in range(width):
            pixels += bytes([color[2], color[1], color[0]])
        pixels += padding

    with open(output_path, 'wb') as f:
        f.write(bmp_header + dib_header + pixels)
    print(f"Created (fallback): {output_path}")


def generate_fallback_icons(icons_dir):
    """Generate placeholder icons without PIL."""
    print("WARNING: PIL not available. Generating placeholder icons.")
    print("Install Pillow for proper icons: pip install Pillow")
    print()

    create_png_fallback(32, 32, FALLBACK_COLOR, os.path.join(icons_dir, '32x32.png'))
    create_png_fallback(128, 128, FALLBACK_COLOR, os.path.join(icons_dir, '128x128.png'))
    create_png_fallback(256, 256, FALLBACK_COLOR, os.path.join(icons_dir, '128x128@2x.png'))
    create_ico_fallback([16, 32, 48, 64, 128, 256], FALLBACK_COLOR, os.path.join(icons_dir, 'icon.ico'))
    create_icns_fallback([16, 32, 64, 128, 256, 512], FALLBACK_COLOR, os.path.join(icons_dir, 'icon.icns'))
    create_bmp_fallback(150, 57, FALLBACK_COLOR, os.path.join(icons_dir, 'header.bmp'))
    create_bmp_fallback(164, 314, FALLBACK_COLOR, os.path.join(icons_dir, 'sidebar.bmp'))


def main():
    icons_dir = os.path.join(SCRIPT_DIR, '..', 'src-tauri', 'icons')
    os.makedirs(icons_dir, exist_ok=True)

    print("Generating AIGoodbye desktop icons...")
    print(f"Output directory: {icons_dir}")
    print()

    # Check if source icon exists
    source_exists = os.path.exists(SOURCE_ICON)

    if source_exists:
        try:
            from PIL import Image
            resize_image_with_pil(SOURCE_ICON, None, icons_dir)
            print()
            print("All icons generated successfully from source!")
        except ImportError:
            print("PIL not available, using fallback...")
            generate_fallback_icons(icons_dir)
    else:
        print(f"Source icon not found: {SOURCE_ICON}")
        generate_fallback_icons(icons_dir)

    print()
    print("Icon generation complete!")


if __name__ == '__main__':
    main()
