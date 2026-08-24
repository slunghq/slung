# HTTP Webhook Example

This example demonstrates how to receive HTTP POST webhooks using Slung's HTTP connector.

## Overview

The webhook example implements a simple inventory management system that:
1. **Receives** inventory updates and order events via HTTP POST webhooks
2. **Processes** incoming data through mappers that parse JSON into typed components
3. **Executes** rules that check stock levels and trigger alerts
4. **Demonstrates** how rules chain together based on priority

## Architecture

```
External System (Shopify, Database, etc)
         │
         │ POST /api/inventory
         │ {"sku": "X", "quantity": 100}
         ↓
    HTTP Server (Port 2074)
         │
         │ Queues request body
         ↓
    HTTP Connector
         │
         │ Polls queue
         ↓
    Mappers (parse_inventory_update, parse_order_event)
         │
         │ Deserialize JSON
         ↓
    Components (InventoryLevel, Order)
         │
         │ Mark as dirty
         ↓
    Inference Loop
         │
         │ Triggers rules in priority order
         ├──> check_stock_level (priority 20)
         ├──> process_order (priority 15)
         └──> escalate_alert (priority 10)
```

## Building

```bash
# The repository includes a ready-to-run Wasm fixture at:
# src/testdata/webhook.wasm
```

## Running

### Terminal 1: Start the Slung Runtime

```bash
# Build Slung
cd slung
zig build

# Run the webhook example with the HTTP connector
zig build run -- run \
  --module src/testdata/webhook.wasm \
  --namespace test_ns \
  --node-id node-1 \
  --ws-port 2073 \
  --http-port 2074
```

You should see:
```
HTTP webhook listener on http://0.0.0.0:2074
WebSocket gateway listening on http://0.0.0.0:2073
```

### Terminal 2: Send Test Webhooks

```bash
# Run the test script from the example directory
cd sdks/pipeline/rust/examples/webhook
chmod +x test.sh

# Run the test script
./test.sh
```

Or send individual webhooks manually:

```bash
# Inventory update (normal stock)
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{
    "sku": "WIDGET-001",
    "quantity": 150
  }'

# Inventory update (low stock - triggers alert)
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{
    "sku": "GADGET-002",
    "quantity": 30
  }'

# Order event
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{
    "order_id": "ORD-2024-001",
    "sku": "WIDGET-001",
    "quantity": 25
  }'

# Critical stock (< 20 units - triggers emergency alert)
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{
    "sku": "CRITICAL-003",
    "quantity": 10
  }'
```

## Components

### `InventoryLevel`
Represents current inventory for a SKU.
- `sku`: Product SKU identifier
- `quantity`: Number of units in stock

### `Order`
Represents an incoming customer order.
- `order_id`: Unique order identifier
- `sku`: Product SKU being ordered
- `quantity`: Number of units ordered

### `StockAlert`
Triggered when stock levels fall below threshold.
- `sku`: Product SKU
- `level`: Current quantity
- `message`: Alert message

## Rules

### Rule 1: `check_stock_level` (Priority 20)
**Trigger**: When `InventoryLevel` component is updated
**Action**: Check if quantity < 50 units
**Result**: Emit `StockAlert` component if stock is low

**Logic**:
```
If inventory.quantity < 50:
  Emit StockAlert with warning message
Else:
  Log that stock is well-stocked
```

### Rule 2: `process_order` (Priority 15)
**Trigger**: When `Order` component is received
**Action**: Process the order
**Result**: Log order details (in real system: update inventory, trigger fulfillment)

**Logic**:
```
Log: "Order {order_id}: {quantity} units of {sku} reserved"
```

### Rule 3: `escalate_alert` (Priority 10)
**Trigger**: When `InventoryLevel` component is updated
**Action**: Check if quantity < 20 units (critical threshold)
**Result**: Emit emergency reorder notification

**Logic**:
```
If inventory.quantity < 20:
  Log: "EMERGENCY: {sku} critically low - initiating emergency reorder"
  In real system: Call supplier API, create purchase order
```

## Rule Execution Order

Rules execute in **priority order** (highest first). This example demonstrates the principle:

1. **Priority 20** - `check_stock_level`: Evaluates stock levels
2. **Priority 15** - `process_order`: Processes orders
3. **Priority 10** - `escalate_alert`: Checks for critical thresholds

This ensures that lower-priority escalation rules only execute after higher-priority checks have been performed.

## Expected Output

When you send the test webhooks, you should see output in the Slung terminal like:

```
Order ORD-2024-001: 25 units of WIDGET-001 reserved
Order ORD-2024-002: 5 units of GADGET-002 reserved
EMERGENCY: CRITICAL-003 is critically low at 10 units - initiating emergency reorder
```

The exact messages come from `eprintln!` calls in the rules, which log to stderr.

## Testing Scenarios

### Scenario 1: Normal Stock
```bash
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{"sku": "NORMAL", "quantity": 500}'
```
**Expected**: Silent (no alerts triggered)

### Scenario 2: Low Stock Alert
```bash
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{"sku": "LOW", "quantity": 30}'
```
**Expected**: `check_stock_level` rule fires, emits StockAlert

### Scenario 3: Critical Stock
```bash
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{"sku": "CRITICAL", "quantity": 10}'
```
**Expected**: Both `check_stock_level` AND `escalate_alert` rules fire

### Scenario 4: Order Processing
```bash
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{"order_id": "ORD-123", "sku": "X", "quantity": 10}'
```
**Expected**: `process_order` rule logs the order

### Scenario 5: Invalid Payload
```bash
curl -X POST http://localhost:2074/test_ns/api/inventory \
  -H "Content-Type: application/json" \
  -d '{"invalid": "data"}'
```
**Expected**: Mappers reject it (no component emitted, no rules fire)

### Scenario 6: Wrong Endpoint
```bash
curl -X POST http://localhost:2074/test_ns/api/unknown \
  -H "Content-Type: application/json" \
  -d '{}'
```
**Expected**: `404 Not Found` - endpoint not registered

## Key Learnings

1. **HTTP Connector** receives POST webhooks on registered paths
2. **Mappers** validate and parse incoming JSON into typed components
3. **Rules** are triggered by component changes via dirty signal
4. **Priority** determines execution order of rules
5. **Component emission** triggers downstream rules (inference chain)

## Extending This Example

To extend this example:

1. **Add KV store**: Track demand velocity and rolling averages
2. **Add HTTP client calls**: Use `slung_http_post` to call supplier APIs
3. **Add multiple sources**: Register other webhook paths for different data types
4. **Add WebSocket output**: Emit alerts to connected clients via port 2073
5. **Add authentication**: Validate HMAC signatures on incoming webhooks
6. **Add monitoring**: Log metrics like processing latency, alert frequency

## Troubleshooting

### No output from rules
- Check that the Slung runtime is listening on port 2074
- Verify the JSON payload matches the expected schema
- Check for mapper errors in the Slung logs
- Ensure the component field names match the rule watch declarations

### 404 on webhook endpoint
- Verify the path in `#[config(path = "/api/inventory")]` matches your curl URL
- Check that the Slung runtime has loaded the module with this source

### Rules not executing in expected order
- Verify rule priorities (higher number = higher priority)
- Check that watched components are being emitted
- Review the dirty tracker - components must be marked dirty to trigger rules

## References

- [Slung Architecture](../../docs/ARCHITECTURE.md)
- [HTTP Architecture](../../../aria/HTTP_ARCHITECTURE.md)
- [Slung SDK Documentation](../README.md)
