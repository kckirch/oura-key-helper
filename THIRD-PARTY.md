# Bundled USB component

The native Swift helper is MIT-licensed. `Scripts/filtered_backup.py` and its separately executed USB component are GPL-3.0-or-later. Its Python dependency tree contains GPL/LGPL and permissively licensed projects. The GPL text is in `LICENSE-GPL-3.0`; exact runtime versions are in `Scripts/requirements-usb.lock`. PyInstaller 6.16.0 packages the executable under its distribution exception.

The app's View source folder includes the helper/adapter source, build scripts, version lock, and `GPL-dependency-sources.tar.gz`, containing the exact PyPI source distributions of the GPL/LGPL runtime dependencies and packager. No proprietary Oura code/models are included. These components carry their original notices inside their source distributions. The archive is generated during release packaging by `Scripts/runtime-sources.py`.

To rebuild: explicitly install the locked Python dependencies, install PyInstaller 6.16.0, run `Scripts/build-usb.sh`, generate the runtime-source archive, then run `build.sh`. Python 3.12.14 was used for this Apple Silicon build. CPython is available at https://www.python.org/downloads/release/python-31214/ under the PSF license. The runtime also uses its libraries' upstream permissive licenses; their dist-info notices are retained by the frozen build where collected.

The GUI communicates with this component through local process arguments and pipes. It is not a network server. No analytics or cloud-upload feature is invoked by the adapter. Its normal operation connects to Apple's local USB device services.
