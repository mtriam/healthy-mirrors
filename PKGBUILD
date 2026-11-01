# Maintainer: mtriam <265996944+mtriam@users.noreply.github.com>

pkgname=healthy-mirrors
pkgver=1.1.0
pkgrel=1
pkgdesc='Keeps only healthy mirrors active in the CachyOS/Arch Linux mirrorlists, with an optional pacman guard daemon'
arch=('any')
url='https://github.com/mtriam/healthy-mirrors'
license=('GPL-3.0-or-later')
depends=(
    'bash' 'coreutils' 'curl' 'diffutils' 'findutils' 'gawk' 'grep' 'jq'
    'python' 'sed' 'sudo' 'systemd' 'util-linux'
)
optdepends=('libnotify: desktop notifications on errors')
install="$pkgname.install"
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('ae07ad043c2e44af5ca0e4b5bfdf6a5759321a5a9770737de8b48916a4661c14')

check() {
    cd "$pkgname-$pkgver"
    local f
    for f in hm hm-setup install.sh; do bash -n "$f"; done
    python -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' hm-daemon
}

package() {
    cd "$pkgname-$pkgver"
    install -Dm755 hm        "$pkgdir/usr/bin/hm"
    install -Dm755 hm-daemon "$pkgdir/usr/bin/hm-daemon"
    install -Dm755 hm-setup  "$pkgdir/usr/bin/hm-setup"
    install -Dm644 hm-daemon.service "$pkgdir/usr/lib/systemd/system/hm-daemon.service"
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
}
