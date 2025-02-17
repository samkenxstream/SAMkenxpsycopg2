#!/bin/bash

# Build a modern version of libpq and depending libs from source on Centos 5

set -euo pipefail
set -x

# Last release: https://www.postgresql.org/ftp/source/
# IMPORTANT! Change the cache key in packages.yml when upgrading libraries
postgres_version="${LIBPQ_VERSION}"

# last release: https://www.openssl.org/source/
openssl_version="${OPENSSL_VERSION}"

# last release: https://openldap.org/software/download/
ldap_version="2.6.3"

# last release: https://github.com/cyrusimap/cyrus-sasl/releases
sasl_version="2.1.28"

export LIBPQ_BUILD_PREFIX=${LIBPQ_BUILD_PREFIX:-/tmp/libpq.build}

if [[ -f "${LIBPQ_BUILD_PREFIX}/lib/libpq.so" ]]; then
    echo "libpq already available: build skipped" >&2
    exit 0
fi

source /etc/os-release

case "$ID" in
    centos)
        yum update -y
        yum install -y zlib-devel krb5-devel pam-devel
        ;;

    alpine)
        apk upgrade
        apk add --no-cache zlib-dev krb5-dev linux-pam-dev openldap-dev
        ;;

    *)
        echo "$0: unexpected Linux distribution: '$ID'" >&2
        exit 1
        ;;
esac

if [ "$ID" == "centos" ]; then

    # Build openssl if needed
    openssl_tag="OpenSSL_${openssl_version//./_}"
    openssl_dir="openssl-${openssl_tag}"
    if [ ! -d "${openssl_dir}" ]; then curl -sL \
            https://github.com/openssl/openssl/archive/${openssl_tag}.tar.gz \
            | tar xzf -

        cd "${openssl_dir}"

        ./config --prefix=${LIBPQ_BUILD_PREFIX} --openssldir=${LIBPQ_BUILD_PREFIX} \
            zlib -fPIC shared
        make depend
        make
    else
        cd "${openssl_dir}"
    fi

    # Install openssl
    make install_sw
    cd ..

fi


if [ "$ID" == "centos" ]; then

    # Build libsasl2 if needed
    # The system package (cyrus-sasl-devel) causes an amazing error on i686:
    # "unsupported version 0 of Verneed record"
    # https://github.com/pypa/manylinux/issues/376
    sasl_tag="cyrus-sasl-${sasl_version}"
    sasl_dir="cyrus-sasl-${sasl_tag}"
    if [ ! -d "${sasl_dir}" ]; then
        curl -sL \
            https://github.com/cyrusimap/cyrus-sasl/archive/${sasl_tag}.tar.gz \
            | tar xzf -

        cd "${sasl_dir}"

        autoreconf -i
        ./configure --prefix=${LIBPQ_BUILD_PREFIX} \
            CPPFLAGS=-I${LIBPQ_BUILD_PREFIX}/include/ LDFLAGS=-L${LIBPQ_BUILD_PREFIX}/lib
        make
    else
        cd "${sasl_dir}"
    fi

    # Install libsasl2
    # requires missing nroff to build
    touch saslauthd/saslauthd.8
    make install
    cd ..

fi


if [ "$ID" == "centos" ]; then

    # Build openldap if needed
    ldap_tag="${ldap_version}"
    ldap_dir="openldap-${ldap_tag}"
    if [ ! -d "${ldap_dir}" ]; then
        curl -sL \
            https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-${ldap_tag}.tgz \
            | tar xzf -

        cd "${ldap_dir}"

        ./configure --prefix=${LIBPQ_BUILD_PREFIX} --enable-backends=no --enable-null \
            CPPFLAGS=-I${LIBPQ_BUILD_PREFIX}/include/ LDFLAGS=-L${LIBPQ_BUILD_PREFIX}/lib

        make depend
        make -C libraries/liblutil/
        make -C libraries/liblber/
        make -C libraries/libldap/
    else
        cd "${ldap_dir}"
    fi

    # Install openldap
    make -C libraries/liblber/ install
    make -C libraries/libldap/ install
    make -C include/ install
    chmod +x ${LIBPQ_BUILD_PREFIX}/lib/{libldap,liblber}*.so*
    cd ..

fi


# Build libpq if needed
postgres_tag="REL_${postgres_version//./_}"
postgres_dir="postgres-${postgres_tag}"
if [ ! -d "${postgres_dir}" ]; then
    curl -sL \
        https://github.com/postgres/postgres/archive/${postgres_tag}.tar.gz \
        | tar xzf -

    cd "${postgres_dir}"

    # Match the default unix socket dir default with what defined on Ubuntu and
    # Red Hat, which seems the most common location
    sed -i 's|#define DEFAULT_PGSOCKET_DIR .*'\
'|#define DEFAULT_PGSOCKET_DIR "/var/run/postgresql"|' \
        src/include/pg_config_manual.h

    # Often needed, but currently set by the workflow
    # export LD_LIBRARY_PATH="${LIBPQ_BUILD_PREFIX}/lib"

    ./configure --prefix=${LIBPQ_BUILD_PREFIX} --sysconfdir=/etc/postgresql-common \
        --without-readline --with-gssapi --with-openssl --with-pam --with-ldap \
        CPPFLAGS=-I${LIBPQ_BUILD_PREFIX}/include/ LDFLAGS=-L${LIBPQ_BUILD_PREFIX}/lib
    make -C src/interfaces/libpq
    make -C src/bin/pg_config
    make -C src/include
else
    cd "${postgres_dir}"
fi

# Install libpq
make -C src/interfaces/libpq install
make -C src/bin/pg_config install
make -C src/include install
cd ..

find ${LIBPQ_BUILD_PREFIX} -name \*.so.\* -type f -exec strip --strip-unneeded {} \;
