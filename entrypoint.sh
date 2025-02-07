#!/bin/bash
set -e

# Function to set output variables
set_output() {
    echo "$1=$2" >> $GITHUB_OUTPUT
}

# Install necessary packages
echo "Installing necessary packages..."
sudo add-apt-repository universe
sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get install -y gperf gcc-multilib gcc-10-multilib g++-multilib g++-10-multilib libc6-dev lib32ncurses5-dev x11proto-core-dev libx11-dev tree lib32z-dev libgl1-mesa-dev libxml2-utils xsltproc bc ccache lib32readline-dev lib32z1-dev liblz4-tool libncurses5-dev libsdl1.2-dev libwxgtk3.0-gtk3-dev libxml2 lzop pngcrush schedtool squashfs-tools imagemagick libbz2-dev lzma ncftp qemu-user-static libstdc++-10-dev libtinfo5 libgflags-dev libncurses5 python3 curl unzip

# Install OpenJDK 8
echo "Installing OpenJDK 8..."
sudo apt-get install -y openjdk-8-jdk

# Install repo tool
echo "Installing repo tool..."
mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo -o ~/bin/repo
chmod a+x ~/bin/repo
sudo ln -sf ~/bin/repo /usr/bin/repo

# Set up the build environment
echo "Setting up build environment..."
MANIFEST_DIR="$GITHUB_WORKSPACE/android-recovery"
mkdir -p "$MANIFEST_DIR"
cd "$MANIFEST_DIR"

# Configure git
git config --global user.name "$GITHUB_ACTOR"
git config --global user.email "$GITHUB_ACTOR_ID+$GITHUB_ACTOR@users.noreply.github.com"

# Initialize the repo
echo "Initializing PBRP repo..."
repo init --depth=1 -u https://github.com/vados-dev/manifest_pb.git -b "$MANIFEST_BRANCH"

# Sync the repo
echo "Syncing PBRP repo..."
repo sync -j$(nproc --all) --force-sync

# If DEVICE_TREE is not provided, default to the current repository
if [ -z "$DEVICE_TREE" ]; then
    DEVICE_TREE="https://github.com/${GITHUB_REPOSITORY}"
    echo "DEVICE_TREE not specified. Using current repository: ${DEVICE_TREE}"
    echo "DEVICE_TREE=${DEVICE_TREE}" >> $GITHUB_ENV
fi

# Clone device tree into a temporary directory
echo "Cloning device tree..."
if [ -n "$DEVICE_TREE_BRANCH" ]; then
    echo "Cloning device tree with branch: $DEVICE_TREE_BRANCH"
    git clone "$DEVICE_TREE" -b "$DEVICE_TREE_BRANCH" tmp_device_tree
else
    echo "Cloning device tree without specifying a branch (default branch will be used)"
    git clone "$DEVICE_TREE" tmp_device_tree
fi

# Check if DEVICE_NAME or DEVICE_PATH are default or not provided
if [ -z "$DEVICE_NAME" ] || [ -z "$DEVICE_PATH" ]; then
    echo "Extracting variables from .mk files..."
    cd tmp_device_tree

    # Initialize variables
    DEVICE_MAKEFILE=""
    DEVICE_DIRECTORY=""
    DEVICE_NAME=""
    BRAND=""

    # Search for .mk files recursively in the device tree
    mk_files=$(find . -type f -name '*.mk')

    # Loop through each .mk file found
    for file in $mk_files; do
        # Extract variables using sed
        makefile=$(sed -n 's/^[[:space:]]*PRODUCT_NAME[[:space:]]*:=\s*\(.*\)/\1/p' "$file")
        brand=$(sed -n 's/^[[:space:]]*PRODUCT_BRAND[[:space:]]*:=\s*\(.*\)/\1/p' "$file")
        codename=$(sed -n 's/^[[:space:]]*PRODUCT_DEVICE[[:space:]]*:=\s*\(.*\)/\1/p' "$file")
        if [[ -n "$makefile" && -n "$brand" && -n "$codename" ]]; then
            DEVICE_MAKEFILE="$makefile"
            BRAND="$brand"
            DEVICE_NAME="$codename"
            DEVICE_PATH="device/$brand/$codename"
            echo "DEVICE_MAKEFILE=${DEVICE_MAKEFILE}" >> $GITHUB_ENV
            echo "DEVICE_NAME=${DEVICE_NAME}" >> $GITHUB_ENV
            echo "BRAND=${BRAND}" >> $GITHUB_ENV
            echo "DEVICE_PATH=${DEVICE_PATH}" >> $GITHUB_ENV
            break
        fi
    done

    # Verify that DEVICE_NAME was found
    if [ -z "$DEVICE_NAME" ]; then
        echo "::error::Failed to extract DEVICE_NAME from .mk files."
        exit 1
    fi

    # Navigate back to the MANIFEST_DIR
    cd "$MANIFEST_DIR"

    # Move the device tree into the correct directory
    echo "Moving device tree to $DEVICE_PATH"
    mkdir -p "$DEVICE_PATH"
    mv tmp_device_tree/* "$DEVICE_PATH/"
    rm -rf tmp_device_tree
else
    echo "Using provided DEVICE_NAME and DEVICE_PATH"
    # Move device tree to the specified DEVICE_PATH
    mkdir -p "$DEVICE_PATH"
    mv tmp_device_tree/* "$DEVICE_PATH/"
    rm -rf tmp_device_tree
fi

# Check for DEVICE_MAKEFILE if not set
if [ -z "$DEVICE_MAKEFILE" ]; then
    echo "Checking for recovery makefile..."
    if [ -f "$DEVICE_PATH/twrp_${DEVICE_NAME}.mk" ]; then
        DEVICE_MAKEFILE="twrp_${DEVICE_NAME}"
    elif [ -f "$DEVICE_PATH/omni_${DEVICE_NAME}.mk" ]; then
        DEVICE_MAKEFILE="omni_${DEVICE_NAME}"
    elif [ -f "$DEVICE_PATH/pb_${DEVICE_NAME}.mk" ]; then
        DEVICE_MAKEFILE="pb_${DEVICE_NAME}"
    else
        echo "::error::No recovery makefile found!"
        exit 1
    fi
    echo "DEVICE_MAKEFILE=${DEVICE_MAKEFILE}" >> $GITHUB_ENV
fi

# Set OUTPUT_DIR
OUTPUT_DIR="$MANIFEST_DIR/out/target/product/$DEVICE_NAME"
echo "OUTPUT_DIR=${OUTPUT_DIR}" >> $GITHUB_ENV

# Install additional dependencies for legacy branches
if [[ "$MANIFEST_BRANCH" != "android-11.0" && "$MANIFEST_BRANCH" != "android-12.1" ]]; then
    echo "Installing Python 2 for legacy branches..."
 #   sudo apt-get install -y python2
 #   sudo ln -sf /usr/bin/python2 /usr/bin/python
     sudo apt-get install python2 python-is-python2
else
    echo "No need to install Python 2 for this branch."
fi

# Fix missing fonts
#echo "Fixing missing fonts..."
#mkdir -p external/noto-fonts/other
#cd external/noto-fonts/other
#wget https://github.com/cd-Crypton/custom-recovery-extras/raw/main/missing-font.zip
#unzip -o missing-font.zip
cd "$MANIFEST_DIR"

# Build PBRP
echo "Building PBRP..."
source build/envsetup.sh
export ALLOW_MISSING_DEPENDENCIES=true

if [ "$BUILD_TARGET" != "pbrp" ]; then
    lunch "${DEVICE_MAKEFILE}-eng"
    make clean
    mka -j$(nproc) "${BUILD_TARGET}image"
else
    lunch "${DEVICE_MAKEFILE}-eng"
    make clean
    mka -j$(nproc) "$BUILD_TARGET"
fi

# Set build date
echo "BUILD_DATE=$(TZ=UTC date +%Y%m%d)" >> $GITHUB_ENV

# Check if the recovery image exists
echo "Checking if the recovery image exists..."
img_file=$(find "$OUTPUT_DIR" -name "*.img" -print -quit)
zip_file=$(find "$OUTPUT_DIR" -name "PBRP*.zip" -print -quit)

if [ -f "$img_file" ]; then
    echo "CHECK_IMG_IS_OK=true" >> $GITHUB_ENV
    set_output "out_img" "$img_file"
    echo "MD5_IMG=$(md5sum "$img_file" | cut -d ' ' -f 1)" >> $GITHUB_ENV
else
    echo "::warning::Recovery image not found."
fi

if [ -f "$zip_file" ]; then
    echo "CHECK_ZIP_IS_OK=true" >> $GITHUB_ENV
    set_output "out_zip" "$zip_file"
    echo "MD5_ZIP=$(md5sum "$zip_file" | cut -d ' ' -f 1)" >> $GITHUB_ENV
else
    echo "::warning::Recovery ZIP not found."
fi
