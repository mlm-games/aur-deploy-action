FROM archlinux:base

RUN pacman -Syu --noconfirm
RUN pacman -S --noconfirm --needed --overwrite '*' \
      openssh sudo base-devel git fakeroot binutils gcc awk xz \
      libarchive bzip2 coreutils file findutils gettext grep gzip sed ncurses util-linux \
      pacman-contrib debugedit rsync

COPY entrypoint.sh /entrypoint.sh
COPY build.sh /build.sh
COPY ssh_config /ssh_config

ENTRYPOINT ["/entrypoint.sh"]
