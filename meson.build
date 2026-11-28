project('sitak', version: '2.0.1', license: 'GPL-3.0-only', meson_version: '>=1.0.0')

# The processing engine is built from the supplied Siril 1.4.5 source archive
# by packaging/build-appimage.sh. This project installs Sitak's CLI front-end.
fs = import('fs')
fs.copyfile('src/sitak.sh', 'sitak')
install_data(
  'src/sitak.sh',
  install_dir: get_option('bindir'),
  rename: 'sitak',
  install_mode: 'rwxr-xr-x',
)
