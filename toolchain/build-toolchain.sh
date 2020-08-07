#!/bin/bash

#############################################################################
#
# Copyright 2020 Thales
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://solderpad.org/licenses/
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#############################################################################
#
# Original Author: Zbigniew Chamski (zbigniew.chamski@invia.fr)
#
#############################################################################

# Assumptions:
# - the required binutils source is in src/binutils-gdb
# - the required GCC source is in src/gcc
# - the required newlib is in src/newlib
# - the user invoking this script has sufficient permissions
#   to create/populate the installation directory.
# - there are no restrictions on the parallelism of the build process
#   ("make -j" without an explicit job limit causes no significant harm)
#
# Builds of individual tools are performed under the matching
# build/... subdirectories

# Helper function to print usage information.
function print_usage()
{
    echo Usage:
    echo "  $SHELL $0 [-f|--force] [CONFIG_NAME] INSTALL_PREFIX"
    echo ""
    echo "  -f,--force       Rebuild toolchain from scratch (remove build dirs,"
    echo "                     configure and build again.)"
    echo "  CONFIG_NAME      Use configuration from file config/CONFIG_NAME.sh"
    echo "                     (default: '$CONFIG_NAME')"
    echo "  INSTALL_PREFIX   Path where the toolchain should be installed"
    echo "                     (relative paths will be converted to absolute ones,"
    echo "                     missing parent directories will be created as needed.)"
}   

# Helper function to parse the cmdline args
# Takes the complete list of positional args, drops them as they get parsed.
function parse_cmdline()
{
    # "Force rebuild" mode: try before any file/directory names.
    # Valid only with 2+ cmdline args.
    if [ $# -ge 2 ]; then
	if [ $1 = "-f" -o $1 = "--force" ]; then
	    FORCE_REBUILD=yes
	    shift
	fi
    fi

    # Check for the config name.  Valid only with 2+ cmdline args left.
    if [ $# -ge 2 ]; then
	CONFIG_NAME=$1
	shift
    fi

    # Check for the installation prefix.  Must exist after dropping previous args.
    if [ $# -eq 1 ]; then
	# Resolve the path to an absolute one (it needs NOT to exist yet.)
	PREFIX=`readlink -m "$1"`
	shift
    fi

    # Any remaining arg past the prefix means an error.
    if [ $# -gt 0 ]; then
	echo "*** Excess arguments past INSTALL_PREFIX: please correct the command line!"
	echo ""
	print_usage
	exit 12
    fi
}

# ======== Default settings: GCC 10 baremetal, no forced rebuild ========
# - toolchain configuration.
#   NOTE: config/$CONFIG_NAME.sh can be a symbolic link.
CONFIG_NAME="gcc10-baremetal"

# - rebuild mode
FORCE_REBUILD=no

# The INSTALL_PREFIX argument is required
if [ $# -lt 1 ]; then
    echo "*** Please specify the installation prefix of the toolchain!"
    echo ""
    print_usage;
    exit 11
fi

# ======== Parse the command line.  Drop each successfully parsed arg. ========
echo "### Parsing the cmdline..."
parse_cmdline $@

# ======== Check if config file exists, and load it if it does ========
# Check for the presence of source code and build configuration.
CONFIG_FILE="config/$CONFIG_NAME.sh"

if [ -f $CONFIG_FILE ]; then
    # File present: read the settings.
    . $CONFIG_FILE
else
    echo "*** Configuration file '$CONFIG_FILE' missing!"
    echo ""
    print_usage
    exit 13
fi

# ======== Actual build process ========

# Force rebuilding if asked to: remove all build directories.
[ $FORCE_REBUILD = "yes" ] && rm -rf build/{binutils-gdb,gcc,newlib}

# Overall build policy: try to be as push-button as possible...
# - If a Makefile already exists, do not configure again - just build+install.
# - If there is no Makefile, run configure, then build and install.
# - If the first configure attempt failed try making 'clean' and 'distclean'
#   targets.
# - In case of build error in GCC once configured, remove the target-specific
#   build subdirectories and try making again.
# - binutils and GCC are built with CFLAGS and CXXFLAGS set to "-O2"
#   ("production" mode: no debug, stripping disabled = 10x smaller binaries).
# - CFLAGS and CXXFLAGS are left unset for newlib.

# Disable debug support to reduce size of executables and speed up their launching.
export CFLAGS="-O2"
export CXXFLAGS="-O2"

# Configure and build binutils (required by GCC).
[ -d build/binutils-gdb ] || mkdir -p build/binutils-gdb
cd build/binutils-gdb
[ -f Makefile ] || \
    ../../$BINUTILS_DIR/configure $BINUTILS_CONFIGURE_OPTS || \
    { [ -f Makefile ] && make clean && make distclean && \
	  ../../$BINUTILS_DIR/configure $BINUTILS_CONFIGURE_OPTS || \
	      { echo "Could not configure binutils-gdb, bailing out!" ; \
		exit 2 ; } ; } && \
    make -j all && make install || \
	{ echo "*** Could not build binutils, bailing out!" ; exit 2; }
cd -
									
# Configure and build GCC (required by newlib).
# If an initial configure failed (e.g., due to a change in PREFIX),
# try making 'distclean' target and configuring again.
# The target-specific subdirectories configured during *build*
# are simply removed in case of build error, and 'make all' is
# then restarted.
[ -d build/gcc ] || mkdir -p build/gcc
cd build/gcc
[ -f Makefile ] || \
    ../../$GCC_DIR/configure $GCC_CONFIGURE_OPTS || \
    { [ -f Makefile ] && make clean && make distclean && \
	  make -C libcc1 distclean && \
	  ../../$GCC_DIR/configure $GCC_CONFIGURE_OPTS || \
	      { echo "Could not configure GCC, bailing out!" ; \
		exit 2 ; } ; } && \
	make -j all || { rm -rf $TARGET && \
			     make -j all ; } && make install || \
	{ echo "*** Could not build GCC (even after removing target dirs), bailing out!" ; exit 2; }
cd -

# Unset the variables forced for binutils and GCC builds.
unset CFLAGS CXXFLAGS

# Configure and build newlib.
# We need the path to the newly installed tools
# when running 'configure' and building newlib.

# If an initial configure failed, try making 'distclean' target
# and configuring again.
[ -d build/newlib ] || mkdir -p build/newlib
cd build/newlib
export PATH="$PREFIX/bin:$PATH"
[ -f Makefile ] || \
    ../../$NEWLIB_DIR/configure $NEWLIB_CONFIGURE_OPTS || \
    { [ -f Makefile ] && make clean && make distclean && \
	  ../../$NEWLIB_DIR/configure $NEWLIB_CONFIGURE_OPTS || \
	      { echo "Could not configure newlib, bailing out!" ; \
		exit 2 ; } ; } && \
    make -j all && make install || \
	{ echo "*** Could not build newlib, bailing out!" ; exit 2; }
cd -
								       
# Exit happily.
exit 0
