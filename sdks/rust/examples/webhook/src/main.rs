use slung::prelude::*;
use slung_macros::{component, rule, source};

// Component types representing inventory state
#[component]
struct InventoryLevel {
    sku: String,
    quantity: u32,
}

#[component]
struct Order {
    order_id: String,
    sku: String,
    quantity: u32,
}

// HTTP Webhook Source
//
// Receives POST requests on /api/inventory path with JSON payloads:
// - Inventory updates: {"sku": "X", "quantity": 100}
// - Order events: {"order_id": "123", "sku": "X", "quantity": 10}
#[source(builtin = "http")]
struct WebhookSource {
    #[config(value = "/api/inventory")]
    endpoint: &'static str,

    #[component(map = parse_inventory_update)]
    inventory: InventoryLevel,

    #[component(map = parse_order_event)]
    order: Order,
}

// Mappers — translate raw HTTP POST body into typed components
fn parse_inventory_update(raw: &[u8]) -> Result<InventoryLevel> {
    Ok(serde_json::from_slice(raw)?)
}

fn parse_order_event(raw: &[u8]) -> Result<Order> {
    Ok(serde_json::from_slice(raw)?)
}

// Rule 1: Detect low stock levels
//
// Whenever inventory is updated, check if stock is low.
// If quantity < 50 units, log an alert.
#[rule(
    watch = [WebhookSource::inventory],
    priority = 20,
)]
fn check_stock_level(ctx: &RuleContext) -> Result<()> {
    let inventory = ctx.get::<InventoryLevel>(WebhookSource::inventory)?;

    if inventory.quantity < 50 {
        eprintln!(
            "LOW STOCK ALERT: {} now at {} units",
            inventory.sku, inventory.quantity
        );
    }

    Ok(())
}

// Rule 2: Process incoming orders
//
// When an order arrives, log it for processing.
#[rule(
    watch = [WebhookSource::order],
    priority = 15,
)]
fn process_order(ctx: &RuleContext) -> Result<()> {
    let order = ctx.get::<Order>(WebhookSource::order)?;

    eprintln!(
        "Order {}: {} units of {} reserved",
        order.order_id, order.quantity, order.sku
    );

    Ok(())
}

// Rule 3: Alert escalation
//
// If stock falls below critical threshold, trigger emergency.
#[rule(
    watch = [WebhookSource::inventory],
    priority = 10,
)]
fn escalate_alert(ctx: &RuleContext) -> Result<()> {
    let inventory = ctx.get::<InventoryLevel>(WebhookSource::inventory)?;

    // Emergency reorder threshold: < 20 units
    if inventory.quantity < 20 {
        std::eprintln!(
            "EMERGENCY: {} is critically low at {} units - initiating emergency reorder",
            inventory.sku,
            inventory.quantity
        );
    }

    Ok(())
}

fn main() {}
