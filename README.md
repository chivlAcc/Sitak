# Sitak

**Astrophotography preprocessing from the command line.** Sitak organizes your light and calibration frames, then uses Siril's command-line engine to calibrate, align, and stack them. Export the final image as FITS or 32-bit TIFF, with optional lossless TIFF Deflate compression.

**Current version:** 2.0.0  
**Author:** chivl  
**Platform:** Linux x86_64 AppImage  
**Sitak license:** GNU GPL version 3 only (`GPL-3.0-only`). See [`LICENSE`](LICENSE).

Sitak is an independent command-line wrapper. It is not the Siril application, and it is not affiliated with or endorsed by the Siril project. Siril is a separate upstream project; its official command reference describes Siril as GPL version 3 or later. See the [Siril project](https://gitlab.com/free-astro/siril) and [Siril's official man page](https://siril.org/docs/man/).

## What Sitak does

Sitak accepts an astrophotography session folder or a `.7z` archive. It looks for light frames and optional calibration frames, stages the originals without changing them, and runs Siril in headless mode. Depending on the frames you provide, Siril can build calibration masters, calibrate the lights, register them, and stack them into a 32-bit image.

The default output is `finalstacked.fit.fz` in the folder where you start Sitak. You can choose uncompressed FITS, TIFF, or TIFF with Deflate compression instead. Sitak does not overwrite an existing output.

## Quick start

When a release has been published, download `Sitak-x86_64.AppImage` from the project's GitHub Releases page. If no release is available yet, follow [Build from source](#build-from-source). In a Terminal, go to the folder containing the download, make it executable, and run it:

```bash
chmod +x Sitak-x86_64.AppImage
./Sitak-x86_64.AppImage --help
```

To process a session folder called `my-session`:

```bash
./Sitak-x86_64.AppImage my-session
```

To process the folder you are currently in, leave out the input folder:

```bash
./Sitak-x86_64.AppImage
```

## Prepare your image files

Put your light frames directly in a `lights/` or `light/` folder. Calibration folders are optional:

```text
my-session/
├── lights/     # target exposures (required)
├── darks/      # dark frames (optional)
├── flats/      # flat frames (optional)
└── biases/     # bias or offset frames (optional)
```

You may also use the folder names `dark/`, `flat/`, `bias/`, or `offsets/`. Put images directly inside the matching folders rather than in more nested folders. If there are no named exposure folders, Sitak treats supported images in the session root as light frames.

A `.7z` archive can contain the same folder structure. Sitak checks the archive before extraction, rejects encrypted archives and unsafe paths, and leaves the original archive untouched. Extraction needs extra disk space for the uncompressed images.

Input formats include FITS (`.fit`, `.fits`, `.fts`) and camera RAW formats supported by Siril and LibRaw. These commonly include `.dng`, `.cr2`, `.cr3`, `.nef`, `.arw`, `.raf`, and `.rw2`. Support depends on the Siril/LibRaw build and the camera format. Frames in one sequence should have compatible dimensions and sensor area; do not mix unrelated cameras or image sizes.

## Choose an output format

### FITS

Compressed FITS is the default. For example:

```bash
./Sitak-x86_64.AppImage my-session -o finalstacked.fit.fz
```

Sitak writes 32-bit floating-point FITS using Rice compression at quantization 16. That setting may slightly change pixel values; it is not bit-for-bit lossless. For uncompressed FITS, use a `.fit` or `.fits` filename with `--no-compress`:

```bash
./Sitak-x86_64.AppImage my-session -o finalstacked.fits --no-compress
```

### TIFF without compression

Use `--tiff` to write `finalstacked.tif` by default:

```bash
./Sitak-x86_64.AppImage my-session --tiff
```

A `.tif` or `.tiff` filename also selects TIFF automatically:

```bash
./Sitak-x86_64.AppImage my-session -o my-result.tiff
```

TIFF files are written as 32-bit images. Unless you request Deflate, TIFF compression is off.

### TIFF with Deflate compression

Use `--tiff-deflate` to write a TIFF using Adobe Deflate compression. Deflate is lossless: it compresses the TIFF data without changing the stored pixel values.

```bash
./Sitak-x86_64.AppImage my-session --tiff-deflate
./Sitak-x86_64.AppImage my-session -o my-result.tif --tiff-deflate
```

Use `.tif` or `.tiff` for TIFF output. Do not combine TIFF output with `--no-compress`; that option is for uncompressed FITS. Sitak creates the output folder if necessary but will stop rather than overwrite an existing file.

### Default filenames

- No format option: `finalstacked.fit.fz`
- `--no-compress`: `finalstacked.fits`
- `--tiff`: `finalstacked.tif`
- `--tiff-deflate`: `finalstacked.tif`

Relative output paths are based on the folder where you launched Sitak.

## Process multiple projects

Use `--batch` to search a parent folder for project folders and `.7z` archives. Sitak prefixes each output with its project name, so results do not overwrite one another. Add `--recursive` to search nested folders too.

```bash
# Process projects in the current folder
./Sitak-x86_64.AppImage --batch

# Search ./projects and put compressed TIFF outputs in ./results/
./Sitak-x86_64.AppImage --batch ./projects --tiff-deflate -o results/finalstacked.tif

# Search nested folders and write compressed FITS results
./Sitak-x86_64.AppImage --batch ./projects --recursive -o results/finalstacked.fit.fz
```

For a project named `Orion`, the TIFF batch result is named `Orion_finalstacked.tif`. Use `--recursive` only with `--batch`.

## Common options

```text
-o, --output FILE   Set the output filename and folder
--tiff              Write uncompressed 32-bit TIFF
--tiff-deflate      Write 32-bit TIFF with lossless Deflate compression
--no-compress       Write uncompressed FITS
--batch             Process projects in a parent folder
--recursive         Search nested folders in batch mode
--sigma FLOAT       Set the stack's sigma threshold (default: 3.0)
--clean-temp        Remove temporary files after a successful run
--json              Print machine-readable progress messages
--version           Print the Sitak version
-h, --help          Show help
```

Sitak keeps Siril logs and intermediate files in `.sitak_work/` by default, which can help diagnose a failed run. `--clean-temp` removes a run's intermediate files only after success. The original images and archives are not renamed, edited, or deleted.

Exit codes: `0` means success; `1` means invalid or missing input; `2` means registration failed; and `3` means processing or disk I/O failed. On error, Sitak keeps its work folder and prints the log location.

## Processing notes and limitations

Sitak uses the Siril 1.4.5 command-line engine. It does not reimplement Siril's image-processing algorithms. The exact processing result depends on your camera, input frames, calibration data, and Siril/LibRaw format support. Registration can fail when the frames do not contain enough matching stars or do not overlap sufficiently. Test with copies of your own data before using Sitak in an important workflow.

Sitak is a CLI tool, not a graphical editor. This release provides a Linux x86_64 AppImage; it does not include a Windows `.exe`.

## Build from source

The build script compiles the Sitak launcher and Siril 1.4.5 command-line engine, then packages them into `Sitak-x86_64.AppImage`. It downloads Siril's tagged 1.4.5 source archive and pinned Siril subprojects when needed, so a clean checkout needs internet access. Build dependencies are listed in the workflow at [`.github/workflows/build.yml`](.github/workflows/build.yml).

On Ubuntu, install the build tools and libraries:

```bash
sudo apt update
sudo apt install build-essential meson ninja-build cmake git curl unzip pkg-config 7zip \
  libglib2.0-dev libgtk-3-dev libgtksourceview-4-dev libjson-glib-dev \
  libgsl-dev liblcms2-dev libfftw3-dev libcfitsio-dev libraw-dev \
  libopencv-dev libtiff-dev libjpeg-dev libpng-dev libexiv2-dev python3
```

From the project folder, run:

```bash
./packaging/build-appimage.sh
```

The build can take several minutes. No graphical display is required. The AppImage includes a corresponding-source archive and dependency notes under `usr/share/sitak/source/`. To inspect its contents, run:

```bash
./Sitak-x86_64.AppImage --appimage-extract
```

## Licensing, Siril, and redistribution

Sitak's own source files are declared under **GPL-3.0-only**. The full GNU GPL version 3 text is in [`LICENSE`](LICENSE). The Sitak project does not claim copyright over Siril or third-party components.

Siril's official command reference states that Siril is licensed under **GPL version 3 or later**. This is distinct from Sitak's `GPL-3.0-only` declaration. The AppImage bundles the Siril 1.4.5 command-line program and other software components. Each component keeps its own copyright notices and license terms. See the [Siril upstream project](https://gitlab.com/free-astro/siril), its [official license statement](https://siril.org/docs/man/), and the notices included with the source archive.

If you modify Siril or another GPL-covered component and distribute that modified program, keep its existing copyright and license notices, clearly mark your changes and the date, and follow the applicable GPL terms. If you distribute a binary, make the complete source corresponding to that exact binary available under the required terms. The GNU project explains these requirements in the [GPL version 3 text](https://www.gnu.org/licenses/gpl-3.0.en.html) and its [GPL FAQ](https://www.gnu.org/licenses/gpl-faq.en.html). Keep the matching source archive, build scripts, license texts, and third-party notices available with each release. Do not present Sitak as an official Siril release or imply Siril endorses it.

The AppImage build includes a source archive for Sitak, Siril 1.4.5, and the pinned Siril subprojects, along with a dependency notice. Some bundled libraries are separate projects with their own licenses. Review the included notices and each dependency's terms before redistributing an AppImage or making other legal claims about a distribution. This README is practical project information, not legal advice; licensing requirements can depend on the exact files distributed and the applicable law.

## Contributing

Bug reports and code contributions are welcome. Before a larger change, open an issue to discuss the proposed direction. For a code change, explain what you changed, how you checked it, and whether it touches Sitak, Siril, or another dependency. Contributions to Sitak should be submitted under GPL-3.0-only, and any copied or modified third-party code must retain its required notices and license terms.

At minimum, check shell syntax before submitting a launcher change:

```bash
bash -n src/sitak.sh packaging/build-appimage.sh
```

For a packaging change, also run `./packaging/build-appimage.sh` and make sure the resulting AppImage starts with `--version` and `--help`.

## Help and bug reports

For a useful bug report, include the Sitak version (`./Sitak-x86_64.AppImage --version`), your Linux distribution, the command you ran, and the relevant `siril.log` from `.sitak_work/`. Do not post private images, personal data, or large raw datasets unless you have checked that you are allowed to share them.

**Maintainer and author:** chivl
