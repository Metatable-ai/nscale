#!/bin/bash
# Build script for creating release binaries

set -e

VERSION=${1:-"dev"}
OUTPUT_DIR="release"

echo "Building Nomad Scale-to-Zero binaries..."
echo "Version: ${VERSION}"
echo ""

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Build idle-scaler for multiple platforms
cd idle-scaler

echo "Building idle-scaler binaries..."

# Linux AMD64
echo "  → Linux AMD64"
GOOS=linux GOARCH=amd64 go build -ldflags="-s -w -X main.version=${VERSION}" -o "../${OUTPUT_DIR}/idle-scaler-linux-amd64" .

# Linux ARM64
echo "  → Linux ARM64"
GOOS=linux GOARCH=arm64 go build -ldflags="-s -w -X main.version=${VERSION}" -o "../${OUTPUT_DIR}/idle-scaler-linux-arm64" .

# macOS AMD64 (Intel)
echo "  → macOS AMD64 (Intel)"
GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w -X main.version=${VERSION}" -o "../${OUTPUT_DIR}/idle-scaler-darwin-amd64" .

# macOS ARM64 (Apple Silicon)
echo "  → macOS ARM64 (Apple Silicon)"
GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w -X main.version=${VERSION}" -o "../${OUTPUT_DIR}/idle-scaler-darwin-arm64" .

# Windows AMD64
echo "  → Windows AMD64"
GOOS=windows GOARCH=amd64 go build -ldflags="-s -w -X main.version=${VERSION}" -o "../${OUTPUT_DIR}/idle-scaler-windows-amd64.exe" .

cd ..

# Generate checksums
echo ""
echo "Generating checksums..."
cd "${OUTPUT_DIR}"

# Use appropriate checksum command based on OS
if command -v sha256sum &> /dev/null; then
    sha256sum idle-scaler-* > checksums.txt
elif command -v shasum &> /dev/null; then
    shasum -a 256 idle-scaler-* > checksums.txt
else
    echo "Warning: Neither sha256sum nor shasum found. Skipping checksum generation."
fi

cd ..

echo ""
echo "✓ Build complete!"
echo ""
echo "Binaries are in the ${OUTPUT_DIR}/ directory:"
ls -lh "${OUTPUT_DIR}/"

if [ -f "${OUTPUT_DIR}/checksums.txt" ]; then
    echo ""
    echo "Checksums:"
    cat "${OUTPUT_DIR}/checksums.txt"
fi
