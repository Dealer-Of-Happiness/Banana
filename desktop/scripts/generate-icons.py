#!/usr/bin/env python3
"""
Generate placeholder icons for CI builds.

Creates the minimum required icon files for Tauri and PyInstaller builds.
These are simple yellow banana-colored squares as placeholders.
"""

import os
import struct
import sys

# Banana yellow color: #f7d716 -> RGB(247, 215, 22)
BANANA_YELLOW = (247, 215, 22)

def create_png(width, height, color, output_path):
    """Create a simple solid-color PNG file without external dependencies."""
    import zlib

    def write_chunk(chunk_type, data):
        chunk = chunk_type + data
        return struct.pack('>I', len(data)) + chunk + struct.pack('>I', zlib.crc32(chunk) & 0xffffffff)

    # PNG signature
    signature = b'\x89PNG\r\n\x1a\n'

    # IHDR chunk - color type 6 = RGBA (truecolor with alpha)
    ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    ihdr = write_chunk(b'IHDR', ihdr_data)

    # IDAT chunk (image data)
    raw_data = b''
    for y in range(height):
        raw_data += b'\x00'  # Filter byte
        for x in range(width):
            raw_data += bytes(color) + b'\xff'  # RGBA (with full alpha)

    compressed = zlib.compress(raw_data, 9)
    idat = write_chunk(b'IDAT', compressed)

    # IEND chunk
    iend = write_chunk(b'IEND', b'')

    with open(output_path, 'wb') as f:
        f.write(signature + ihdr + idat + iend)

    print(f"Created: {output_path}")


def create_ico(sizes, color, output_path):
    """Create a Windows ICO file with multiple sizes."""
    import zlib

    def create_bmp_data(width, height, color):
        """Create BMP image data for ICO (no file header, 32-bit BGRA)."""
        # BITMAPINFOHEADER (40 bytes)
        header = struct.pack('<IiiHHIIiiII',
            40,           # biSize
            width,        # biWidth
            height * 2,   # biHeight (doubled for ICO format with mask)
            1,            # biPlanes
            32,           # biBitCount (32-bit BGRA)
            0,            # biCompression
            0,            # biSizeImage
            0,            # biXPelsPerMeter
            0,            # biYPelsPerMeter
            0,            # biClrUsed
            0             # biClrImportant
        )

        # Pixel data (BGRA, bottom-up)
        pixels = b''
        for y in range(height):
            for x in range(width):
                # BGRA format
                pixels += bytes([color[2], color[1], color[0], 255])

        # AND mask (1 bit per pixel, all zeros = fully opaque)
        mask_row_size = ((width + 31) // 32) * 4
        mask = b'\x00' * (mask_row_size * height)

        return header + pixels + mask

    # ICO header
    ico_header = struct.pack('<HHH', 0, 1, len(sizes))

    # Calculate offsets
    offset = 6 + len(sizes) * 16  # Header + directory entries

    entries = []
    images = []

    for size in sizes:
        bmp_data = create_bmp_data(size, size, color)

        # Directory entry
        entry = struct.pack('<BBBBHHII',
            size if size < 256 else 0,  # Width (0 = 256)
            size if size < 256 else 0,  # Height (0 = 256)
            0,                           # Color palette
            0,                           # Reserved
            1,                           # Color planes
            32,                          # Bits per pixel
            len(bmp_data),              # Size of image data
            offset                       # Offset to image data
        )
        entries.append(entry)
        images.append(bmp_data)
        offset += len(bmp_data)

    with open(output_path, 'wb') as f:
        f.write(ico_header)
        for entry in entries:
            f.write(entry)
        for image in images:
            f.write(image)

    print(f"Created: {output_path}")


def create_icns(sizes, color, output_path):
    """Create a macOS ICNS file."""
    # ICNS type codes for different sizes
    type_codes = {
        16: b'icp4',   # 16x16
        32: b'icp5',   # 32x32
        64: b'icp6',   # 64x64
        128: b'ic07',  # 128x128
        256: b'ic08',  # 256x256
        512: b'ic09',  # 512x512
        1024: b'ic10', # 1024x1024
    }

    import zlib

    def create_png_data(width, height, color):
        """Create PNG data in memory with RGBA format."""
        def write_chunk(chunk_type, data):
            chunk = chunk_type + data
            return struct.pack('>I', len(data)) + chunk + struct.pack('>I', zlib.crc32(chunk) & 0xffffffff)

        signature = b'\x89PNG\r\n\x1a\n'
        # Color type 6 = RGBA (truecolor with alpha)
        ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
        ihdr = write_chunk(b'IHDR', ihdr_data)

        raw_data = b''
        for y in range(height):
            raw_data += b'\x00'
            for x in range(width):
                raw_data += bytes(color) + b'\xff'  # RGBA with full alpha

        compressed = zlib.compress(raw_data, 9)
        idat = write_chunk(b'IDAT', compressed)
        iend = write_chunk(b'IEND', b'')

        return signature + ihdr + idat + iend

    # Build ICNS file
    icons_data = b''

    for size in sizes:
        if size in type_codes:
            png_data = create_png_data(size, size, color)
            type_code = type_codes[size]
            chunk_size = len(png_data) + 8
            icons_data += type_code + struct.pack('>I', chunk_size) + png_data

    # ICNS header
    total_size = len(icons_data) + 8
    icns_header = b'icns' + struct.pack('>I', total_size)

    with open(output_path, 'wb') as f:
        f.write(icns_header + icons_data)

    print(f"Created: {output_path}")


def create_bmp(width, height, color, output_path):
    """Create a simple 24-bit BMP file."""
    # BMP header (14 bytes)
    row_size = ((width * 3 + 3) // 4) * 4  # Rows must be 4-byte aligned
    pixel_data_size = row_size * height
    file_size = 54 + pixel_data_size

    bmp_header = struct.pack('<2sIHHI',
        b'BM',          # Signature
        file_size,      # File size
        0,              # Reserved 1
        0,              # Reserved 2
        54              # Offset to pixel data
    )

    # DIB header (40 bytes)
    dib_header = struct.pack('<IiiHHIIiiII',
        40,             # Header size
        width,          # Width
        height,         # Height (positive = bottom-up)
        1,              # Color planes
        24,             # Bits per pixel
        0,              # Compression (none)
        pixel_data_size,# Image size
        2835,           # Horizontal resolution (72 DPI)
        2835,           # Vertical resolution (72 DPI)
        0,              # Colors in palette
        0               # Important colors
    )

    # Pixel data (BGR, bottom-up, padded to 4-byte boundary)
    pixels = b''
    padding = b'\x00' * (row_size - width * 3)
    for y in range(height):
        for x in range(width):
            pixels += bytes([color[2], color[1], color[0]])  # BGR
        pixels += padding

    with open(output_path, 'wb') as f:
        f.write(bmp_header + dib_header + pixels)

    print(f"Created: {output_path}")


def main():
    # Determine icons directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    icons_dir = os.path.join(script_dir, '..', 'src-tauri', 'icons')
    os.makedirs(icons_dir, exist_ok=True)

    print("Generating placeholder icons...")
    print(f"Output directory: {icons_dir}")
    print()

    # Create PNG files
    create_png(32, 32, BANANA_YELLOW, os.path.join(icons_dir, '32x32.png'))
    create_png(128, 128, BANANA_YELLOW, os.path.join(icons_dir, '128x128.png'))
    create_png(256, 256, BANANA_YELLOW, os.path.join(icons_dir, '128x128@2x.png'))

    # Create Windows ICO (multiple sizes)
    create_ico([16, 32, 48, 64, 128, 256], BANANA_YELLOW, os.path.join(icons_dir, 'icon.ico'))

    # Create macOS ICNS
    create_icns([16, 32, 64, 128, 256, 512], BANANA_YELLOW, os.path.join(icons_dir, 'icon.icns'))

    # Create Windows NSIS installer images
    create_bmp(150, 57, BANANA_YELLOW, os.path.join(icons_dir, 'header.bmp'))
    create_bmp(164, 314, BANANA_YELLOW, os.path.join(icons_dir, 'sidebar.bmp'))

    print()
    print("All icons generated successfully!")
    print("Note: These are placeholder icons. Replace with proper branding before release.")


if __name__ == '__main__':
    main()
