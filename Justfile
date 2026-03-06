# Justfile for mic-lock
BIN_DIR := home_directory() / ".local/bin"

default:
    @just --list

# Build the project in release mode
build:
    swift build -c release
    @echo "Binary: {{justfile_directory()}}/.build/release/miclock"

# Run the project using swift run, forwarding all arguments
run *args:
    swift run miclock {{args}}

# Remove build artifacts
clean:
    swift package clean

# Install the binary to ~/.local/bin
install: build
    @mkdir -p {{BIN_DIR}}
    ln -sf $(pwd)/.build/release/miclock {{BIN_DIR}}/miclock
    @echo "Installed miclock to {{BIN_DIR}}/miclock"

# Uninstall the binary from ~/.local/bin
uninstall:
    rm -f {{BIN_DIR}}/miclock
    @echo "Removed miclock from {{BIN_DIR}}/miclock"
