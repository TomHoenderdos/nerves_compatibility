#!/bin/bash
set -e

echo "Building Nerves Compatibility Orchestrator for production..."

# Build the escript
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix escript.build

echo "Orchestrator built successfully: ncc_orchestrator"
echo ""
echo "To deploy:"
echo "  1. Copy ncc_orchestrator to /opt/nerves_compatibility/orchestrator/"
echo "  2. Copy config/config.exs (customize as needed)"
echo "  3. Install systemd service: sudo cp ncc-orchestrator.service /etc/systemd/system/"
echo "  4. Enable and start: sudo systemctl enable --now ncc-orchestrator"
echo ""
echo "To monitor:"
echo "  sudo journalctl -u ncc-orchestrator -f"
