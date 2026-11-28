# Sitak 2.0.1 — Mobile-Ready TIFF Export

Sitak 2.0.1 adds a convenient, ready-to-view TIFF option for people who process astrophotography without needing a computer or specialist desktop software. Existing FITS and standard TIFF exports remain available for users who want to keep the unstretched stack.

## What's new

- Use `--mobile-tiff` to create a permanently stretched, SDR-style image for viewing, sharing, and basic editing on a phone.
- The mobile TIFF uses Siril's linked auto-stretch with its standard auto-stretch defaults, helping preserve the relative color balance between channels.
- The output is 16-bit TIFF with lossless Deflate compression, intended to balance phone compatibility, basic editing room, and file size.
- The default mobile output name is `finalstacked_mobile.tif`. You can select a different `.tif` or `.tiff` path with `-o`.
- Existing standard 32-bit TIFF, 32-bit Deflate TIFF, and FITS export paths are retained.

## Important note about mobile output

The mobile TIFF is a rendered image: the stretch permanently changes the output pixel values. It is designed for appearance, social sharing, and modest brightness or color adjustments. It does not preserve the full linear processing latitude of standard FITS or TIFF output. File size depends on image dimensions and content, so a specific size cannot be guaranteed.

## Usage

```bash
chmod +x Sitak-x86_64.AppImage
./Sitak-x86_64.AppImage --help
./Sitak-x86_64.AppImage my-session --mobile-tiff
```

To specify an output filename:

```bash
./Sitak-x86_64.AppImage my-session --mobile-tiff -o phone-edit.tif
```

## Downloads

- **Linux x86_64 AppImage:** `Sitak-x86_64.AppImage`
- **Source code:** `Sitak-2.0.1-Source.zip`
- **SHA-256 checksums:** `SHA256SUMS.txt`

Sitak is an independent project and is not an official Siril release or endorsed by the Siril project. Sitak's own source is declared under GPL-3.0-only. Siril states that its software is licensed under GPL version 3 or later; bundled components retain their respective copyright notices and license terms. See the included `LICENSE`, README, corresponding-source archive, and dependency notice before redistributing the AppImage.

**Sitak author:** chivl.
**Siril credit:** originally written by Francois Meyer; current maintainers listed by Siril are Vincent Hourdin, Cyril Richard, and Cecile Melis. Siril's other contributors are credited in the upstream `AUTHORS` file.
