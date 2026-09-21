# Arch Linux base image for package-builder builds.
# The actual build steps are driven by build-package.sh at runtime;
# this image only pre-installs the tooling that every build needs.
FROM archlinux:latest

# Keep the image lean: install only what build-package.sh requires.
# appimagetool is downloaded at runtime to always get the latest version.
RUN pacman -Sy --noconfirm \
      base-devel \
      wget \
      fuse2 \
      libfuse2 \
      patchelf \
      file \
      binutils \
    && pacman -Scc --noconfirm

# build-package.sh is bind-mounted at /builder at runtime (read-only).
# /work is bind-mounted as the per-build work directory.
WORKDIR /work
