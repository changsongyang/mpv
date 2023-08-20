#!/bin/bash -e

prefix_dir=$PWD/mingw_prefix
mkdir -p "$prefix_dir"
ln -snf . "$prefix_dir/usr"
ln -snf . "$prefix_dir/local"

wget="wget -nc --progress=bar:force"
gitclone="git clone --depth=1 --recursive"

# -posix is Ubuntu's variant with pthreads support
export CC=$TARGET-gcc-posix
export CXX=$TARGET-g++-posix
export AR=$TARGET-ar
export NM=$TARGET-nm
export RANLIB=$TARGET-ranlib

export CFLAGS="-O2 -pipe -Wall -D_FORTIFY_SOURCE=2"
export LDFLAGS="-fstack-protector-strong"

# anything that uses pkg-config
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

# autotools(-like)
commonflags="--disable-static --enable-shared"

# meson
fam=x86_64
[[ "$TARGET" == "i686-"* ]] && fam=x86
cat >"$prefix_dir/crossfile" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'nodownload'
[binaries]
c = ['ccache', '${CC}']
cpp = ['ccache', '${CXX}']
ar = '${AR}'
strip = '${TARGET}-strip'
pkgconfig = 'pkg-config'
windres = '${TARGET}-windres'
dlltool = '${TARGET}-dlltool'
[host_machine]
system = 'windows'
cpu_family = '${fam}'
cpu = '${TARGET%%-*}'
endian = 'little'
EOF

# CMake
cmake_args=(
    -Wno-dev
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_FIND_ROOT_PATH="$PKG_CONFIG_SYSROOT_DIR"
    -DCMAKE_RC_COMPILER="${TARGET}-windres"
    -DCMAKE_BUILD_TYPE=Release
)

export CC="ccache $CC"
export CXX="ccache $CXX"

function builddir () {
    [ -d "$1/builddir" ] && rm -rf "$1/builddir"
    mkdir -p "$1/builddir"
    pushd "$1/builddir"
}

function makeplusinstall () {
    if [ -f build.ninja ]; then
        ninja
        DESTDIR="$prefix_dir" ninja install
    else
        make -j$(nproc)
        make DESTDIR="$prefix_dir" install
    fi
}

function gettar () {
    name="${1##*/}"
    [ -d "${name%%.*}" ] && return 0
    $wget "$1"
    tar -xaf "$name"
}

## iconv
if [ ! -e "$prefix_dir/lib/libiconv.dll.a" ]; then
    ver=1.17
    gettar "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${ver}.tar.gz"
    builddir libiconv-${ver}
    ../configure --host=$TARGET $commonflags
    makeplusinstall
    popd
fi

## zlib
if [ ! -e "$prefix_dir/lib/libz.dll.a" ]; then
    ver=1.3
    gettar "https://zlib.net/fossils/zlib-${ver}.tar.gz"
    pushd zlib-${ver}
    make -fwin32/Makefile.gcc clean
    make -fwin32/Makefile.gcc PREFIX=$TARGET- CC="$CC" SHARED_MODE=1 \
        DESTDIR="$prefix_dir" install \
        BINARY_PATH=/bin INCLUDE_PATH=/include LIBRARY_PATH=/lib
    popd
fi

## ffmpeg
if [ ! -e "$prefix_dir/lib/libavcodec.dll.a" ]; then
    [ -d ffmpeg ] || $gitclone https://github.com/FFmpeg/FFmpeg.git ffmpeg
    builddir ffmpeg
    ../configure --pkg-config=pkg-config --target-os=mingw32 \
        --enable-cross-compile --cross-prefix=$TARGET- --arch=${TARGET%%-*} \
        --cc="$CC" --cxx="$CXX" $commonflags \
        --disable-{doc,programs,muxers,encoders} \
        --enable-encoder=mjpeg,png
    makeplusinstall
    popd
fi

## shaderc
if [ ! -e "$prefix_dir/lib/libshaderc_shared.dll.a" ]; then
    if [ ! -d shaderc ]; then
        $gitclone https://github.com/google/shaderc.git
        (cd shaderc && ./utils/git-sync-deps)
    fi
    builddir shaderc
    cmake .. "${cmake_args[@]}" \
        -DBUILD_SHARED_LIBS=OFF -DSHADERC_SKIP_TESTS=ON
    makeplusinstall
    popd
fi

## spirv-cross
if [ ! -e "$prefix_dir/lib/libspirv-cross-c-shared.dll.a" ]; then
    [ -d SPIRV-Cross ] || $gitclone https://github.com/KhronosGroup/SPIRV-Cross
    builddir SPIRV-Cross
    cmake .. "${cmake_args[@]}" \
        -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_{CLI,STATIC}=OFF
    makeplusinstall
    popd
fi

## vulkan-headers
if [ ! -e "$prefix_dir/include/vulkan/vulkan.h" ]; then
    [ -d Vulkan-Headers ] || $gitclone https://github.com/KhronosGroup/Vulkan-Headers
    builddir Vulkan-Headers
    cmake .. "${cmake_args[@]}"
    makeplusinstall
    popd
fi

## vulkan-loader
if [ ! -e "$prefix_dir/lib/libvulkan-1.dll.a" ]; then
    [ -d Vulkan-Loader ] || $gitclone https://github.com/KhronosGroup/Vulkan-Loader
    builddir Vulkan-Loader
    cmake .. "${cmake_args[@]}" \
        -DENABLE_WERROR=OFF -DUSE_MASM=OFF
    makeplusinstall
    popd
    sed -re '/libdir=/s|Lib(32)?|lib|' -i "$prefix_dir/lib/pkgconfig/vulkan.pc" # wat?
fi

## libplacebo
if [ ! -e "$prefix_dir/lib/libplacebo.dll.a" ]; then
    [ -d libplacebo ] || $gitclone https://code.videolan.org/videolan/libplacebo.git
    builddir libplacebo
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddemos=false -D{opengl,d3d11,vulkan}=enabled
    makeplusinstall
    popd
fi

## freetype2
if [ ! -e "$prefix_dir/lib/libfreetype.dll.a" ]; then
    ver=2.13.1
    gettar "https://mirror.netcologne.de/savannah/freetype/freetype-${ver}.tar.xz"
    builddir freetype-${ver}
    meson .. --cross-file "$prefix_dir/crossfile"
    makeplusinstall
    popd
fi

## fribidi
if [ ! -e "$prefix_dir/lib/libfribidi.dll.a" ]; then
    ver=1.0.13
    gettar "https://github.com/fribidi/fribidi/releases/download/v${ver}/fribidi-${ver}.tar.xz"
    builddir fribidi-${ver}
    meson .. --cross-file "$prefix_dir/crossfile" \
        -D{tests,docs}=false
    makeplusinstall
    popd
fi

## harfbuzz
if [ ! -e "$prefix_dir/lib/libharfbuzz.dll.a" ]; then
    ver=8.1.1
    gettar "https://github.com/harfbuzz/harfbuzz/releases/download/${ver}/harfbuzz-${ver}.tar.xz"
    builddir harfbuzz-${ver}
    meson .. --cross-file "$prefix_dir/crossfile" \
        -Dtests=disabled
    makeplusinstall
    popd
fi

## libass
if [ ! -e "$prefix_dir/lib/libass.dll.a" ]; then
    [ -d libass ] || $gitclone https://github.com/libass/libass.git
    builddir libass
    [ -f ../configure ] || (cd .. && ./autogen.sh)
    ../configure --host=$TARGET $commonflags
    makeplusinstall
    popd
fi

## luajit
if [ ! -e "$prefix_dir/lib/libluajit-5.1.a" ]; then
    $gitclone https://github.com/LuaJIT/LuaJIT.git
    pushd LuaJIT
    hostcc="ccache cc"
    flags=
    [[ "$TARGET" == "i686-"* ]] && { hostcc="$hostcc -m32"; flags=XCFLAGS=-DLUAJIT_NO_UNWIND; }
    make TARGET_SYS=Windows clean
    make TARGET_SYS=Windows HOST_CC="$hostcc" CROSS="ccache $TARGET-" \
        BUILDMODE=static $flags amalg
    make DESTDIR="$prefix_dir" INSTALL_DEP= FILE_T=luajit.exe install
    popd
fi

## mpv

[ -z "$1" ] && exit 0

CFLAGS+=" -I'$prefix_dir/include'"
LDFLAGS+=" -L'$prefix_dir/lib'"
export CFLAGS LDFLAGS
build=mingw_build
rm -rf $build

meson setup $build --cross-file "$prefix_dir/crossfile" \
    --buildtype debugoptimized \
    -Dlibmpv=true -Dlua=luajit \
    -D{shaderc,spirv-cross,d3d11,vulkan,libplacebo}=enabled

meson compile -C $build

if [ "$2" = pack ]; then
    mkdir -p artifact
    echo "Copying:"
    cp -pv $build/player/mpv.com $build/mpv.exe "$prefix_dir/bin/"*.dll artifact/
    # ship everything and the kitchen sink
    shopt -s nullglob
    for file in /usr/lib/gcc/$TARGET/*-posix/*.dll /usr/$TARGET/lib/*.dll; do
        cp -pv "$file" artifact/
    done
    echo "Archiving:"
    pushd artifact
    zip -9r "../mpv-git-$(date +%F)-$(git rev-parse --short HEAD)-${TARGET%%-*}.zip" -- *
    popd
fi
