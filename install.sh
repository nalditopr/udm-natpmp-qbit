#!/bin/sh
# Install natpmp-qbit on a Unifi Dream Machine (UDM/UDR)
#
# This script:
#   1. Copies the service files to /data/scripts/
#   2. Creates the on_boot.d hook (survives firmware updates)
#   3. Enables and starts the service
#
# Run this from the repo directory on the UDM:
#   ssh root@<udm-ip>
#   cd /data/scripts/udm-natpmp-qbit   # or wherever you cloned/copied
#   sh install.sh
set -eu

SCRIPTS_DIR="/data/scripts"
BOOT_DIR="/data/on_boot.d"

echo "Installing natpmp-qbit..."

# Create directories
mkdir -p "$SCRIPTS_DIR" "$BOOT_DIR"

# Copy files
cp natpmp-qbit.sh "$SCRIPTS_DIR/natpmp-qbit.sh"
cp natpmp-qbit.service "$SCRIPTS_DIR/natpmp-qbit.service"
chmod +x "$SCRIPTS_DIR/natpmp-qbit.sh"

# Create env file from example if it doesn't exist
if [ ! -f "$SCRIPTS_DIR/natpmp-qbit.env" ]; then
    cp natpmp-qbit.env.example "$SCRIPTS_DIR/natpmp-qbit.env"
    echo ""
    echo ">>> IMPORTANT: Edit $SCRIPTS_DIR/natpmp-qbit.env with your values <<<"
    echo ""
fi

# Create on_boot.d hook (reinstalls service after firmware updates)
cat > "$BOOT_DIR/10-natpmp-qbit.sh" << 'EOF'
#!/bin/sh
cp /data/scripts/natpmp-qbit.service /etc/systemd/system/natpmp-qbit.service
systemctl daemon-reload
systemctl enable --now natpmp-qbit
EOF
chmod +x "$BOOT_DIR/10-natpmp-qbit.sh"

# Install and start now
cp "$SCRIPTS_DIR/natpmp-qbit.service" /etc/systemd/system/natpmp-qbit.service
systemctl daemon-reload
systemctl enable --now natpmp-qbit

echo "Done. Check status with: journalctl -u natpmp-qbit -f"
