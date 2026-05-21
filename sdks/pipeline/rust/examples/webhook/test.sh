#!/bin/bash
# Webhook example test script
# Tests the HTTP webhook receiver with inventory and order events

set -e

echo "=== Slung HTTP Webhook Example ==="
echo ""
echo "This script sends test webhooks to the Slung runtime."
echo "Make sure Slung is running first:"
echo ""
echo "  cd slung"
echo "  zig build run -- run --module ../target/wasm32-unknown-unknown/debug/webhook.wasm --namespace inventory --node-id node-1"
echo ""
echo "Then run this script to send test webhooks."
echo ""

SLUNG_HOST="${SLUNG_HOST:-localhost}"
SLUNG_PORT="${SLUNG_PORT:-2074}"
ENDPOINT="http://${SLUNG_HOST}:${SLUNG_PORT}/test_ns/api/inventory"

echo "Testing webhook endpoint: $ENDPOINT"
echo ""

# Test 1: Send inventory update (good stock)
echo "Test 1: Sending inventory update - normal stock levels"
curl -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "sku": "WIDGET-001",
    "quantity": 150
  }' \
  -w "\nStatus: %{http_code}\n" \
  -s
echo ""

# Test 2: Send inventory update (low stock)
echo "Test 2: Sending inventory update - low stock (should trigger alert)"
curl -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "sku": "GADGET-002",
    "quantity": 30
  }' \
  -w "\nStatus: %{http_code}\n" \
  -s
echo ""

# Test 3: Send order event
echo "Test 3: Sending order event"
curl -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "order_id": "ORD-2024-001",
    "sku": "WIDGET-001",
    "quantity": 25
  }' \
  -w "\nStatus: %{http_code}\n" \
  -s
echo ""

# Test 4: Send inventory update (critical stock)
echo "Test 4: Sending inventory update - critical stock (should trigger emergency alert)"
curl -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "sku": "CRITICAL-003",
    "quantity": 10
  }' \
  -w "\nStatus: %{http_code}\n" \
  -s
echo ""

# Test 5: Send another order
echo "Test 5: Sending another order"
curl -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "order_id": "ORD-2024-002",
    "sku": "GADGET-002",
    "quantity": 5
  }' \
  -w "\nStatus: %{http_code}\n" \
  -s
echo ""

# Test 6: Invalid payload (should be rejected)
echo "Test 6: Sending invalid payload (should get error)"
curl -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "invalid": "payload"
  }' \
  -w "\nStatus: %{http_code}\n" \
  -s
echo ""

# Test 7: Unregistered endpoint (should 404)
echo "Test 7: Sending to unregistered endpoint (should get 404)"
curl -X POST "http://${SLUNG_HOST}:${SLUNG_PORT}/test_ns/api/unknown" \
  -H "Content-Type: application/json" \
  -d '{}' \
  -w "\nStatus: %{http_code}\n" \
  -s
echo ""

echo "=== Tests Complete ==="
echo ""
echo "Check the Slung runtime logs for rule execution output:"
echo "  - LOW STOCK ALERT for GADGET-002 (30 units)"
echo "  - Order processing for ORD-2024-001 and ORD-2024-002"
echo "  - EMERGENCY alert for CRITICAL-003 (10 units)"
