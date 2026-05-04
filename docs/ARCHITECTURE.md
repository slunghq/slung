# Slung Architecture

## What it is

Slung is an ontology-driven compute engine that executes work based on real-time facts about relationships between components in a system. Instead of writing steps in a workflow, you define entities, their components, and rules that fire when facts change. The engine handles orchestration implicitly.

## The Problem

Workflow engines are rigid. They model work as a sequence of steps - if A then B, handle failure, retry. This works for predictable, linear processes but breaks down in moving systems where facts change asynchronously and decisions need to adapt in real time. Adding edge cases means adding more steps, forever. The complexity never converges.

## The Solution

Slung replaces steps with relationships. Data sources - Postgres tables, NATS subjects, WebSocket streams, message brokers - become first-class entities in an ECS (Entity Component System) model. Components are typed algebraic fact payloads attached to those entities. Rules are functions that fire only when the components they watch become dirty. The engine maintains global state awareness: a fact change anywhere in the system automatically propagates to every rule that cares about it.

This is not a new idea in AI - CLIPS and Drools solved this decades ago. Slung brings it to the infrastructure level.

## Systems Design

### Graph Connector

Normalises heterogeneous external sources into the ECS model. The host ships built-in connectors for common sources - NATS, Kafka, Postgres, WebSocket, HTTP, TCP, UDP. When a module is loaded, source descriptors declare which connector to use and supply connection config. The host opens and manages the actual connections; the module never does I/O directly.

For sources not covered by built-ins, the host exposes raw TCP and UDP primitives as an escape hatch. The SDK can build any protocol on top of these within the module.

The entity mapper translates incoming data from each source into EntityId + ComponentId pairs. The capability graph tracks which rules watch which components across the entire system - it is the precomputed index that makes the inference loop efficient. It is built once at module registration time and never scanned at runtime.

### Module System and ABI

Modules are Wasm binaries. The host discovers everything it needs to know about a module by scanning its exports at load time - no init function, no manual registration. Three export namespaces:

**Source descriptors** (`__slung_source_<Name>_descriptor`) declare a data source: which built-in connector to use (or `custom` for raw primitives), the connection config, and the component fields attached to that source. Each component field carries its logical field name, referenced component type name, mapper export, and dynamic-entity flag. The host reads this, opens the connection, and registers the source as an entity.

**Component descriptors** (`__slung_component_<Name>_descriptor`) declare a typed fact payload - an algebraic type that carries arbitrary data (e.g. `OrderStatus::Backlogged { reason, since }`). Descriptors include a `kind` discriminator (`struct` or `enum`) plus either named `fields` or enum `variants`. The host attaches that type metadata to the already-registered component entry and uses the serialize/deserialize boundary when reading from and writing to Wasm linear memory.

**Rule descriptors** (`__slung_rule_<Name>_descriptor`) declare a rule: its watch list of ComponentIds, its priority, and a callable entrypoint (`__slung_rule_<Name>`) the host invokes when dispatching. The host populates the capability graph from the watch list and registers the rule in the rule registry.

The host ABI exposes two tiers:

*Built-in connectors:*
```
slung_nats_connect, slung_nats_subscribe, slung_nats_next, slung_nats_publish
slung_kafka_connect, slung_kafka_subscribe, slung_kafka_next
slung_pg_connect, slung_pg_query
slung_ws_connect, slung_ws_next, slung_ws_send
slung_http_get, slung_http_post
```

*Raw escape hatch:*
```
slung_tcp_connect, slung_tcp_read, slung_tcp_write, slung_tcp_close
slung_udp_bind, slung_udp_recv, slung_udp_send
```

*Active memory and runtime:*
```
slung_get, slung_set, slung_emit, slung_notify
slung_now, slung_yield
```

SDKs wrap this ABI with ergonomic macros. The Rust SDK provides `#[source]`, `#[component]`, and `#[rule]` which expand to the descriptor exports and entrypoint glue. Rule authors never see the ABI.

Descriptor JSON currently looks like:

```json
{
  "name": "SensorData",
  "kind": "builtin",
  "builtin": "ws",
  "config": "{}",
  "components": [
    {
      "name": "temperature",
      "type_name": "Temperature",
      "mapper": "__slung_map_SensorData_temperature",
      "dynamic": false
    }
  ]
}
```

```json
{
  "name": "Temperature",
  "kind": "struct",
  "fields": ["value", "unit", "ts"]
}
```

```json
{
  "name": "SensorStatus",
  "kind": "enum",
  "fields": [],
  "variants": ["Ok", "Alert"]
}
```

### Active Memory

The current truth of the world. Backed by a distributed CRDT store (LWW-first) with a local columnar cache per node for fast reads. Every write carries a causal tag recording what triggered the change - which component changed, on which node, at what time. A shared dirty tracker signals component changes to the inference loop.

Components are typed algebraic payloads, not scalars. A fact carries its full context - `OrderStatus::Backlogged { reason, since }` rather than just a status code. This allows facts to propagate rich data down the rule chain without the downstream rule needing to re-query the source.

### State Machine (Inference Loop)

Forward chaining with dirty-driven agenda building. On each cycle:

1. A dirty entry arrives: `(EntityId, ComponentId)`
2. The capability graph maps it to affected `[RuleId]`
3. Rules are filtered by claim availability and ordered by priority
4. Causal tags are checked - inhibition prevents conflicting rules from firing based on what caused the change
5. The agenda is dispatched to the Wasm runtime worker by worker
6. Rule writes flow back through active memory, re-entering the dirty tracker and potentially extending the agenda
7. Cycle terminates at stable state or max depth

### Worker Model

A namespace is the unit of isolation - one deployed rule system, one fact space, one set of sources. Multiple namespaces can share a node.

Within a node, N workers share one namespace state: the CRDT store, dirty tracker, and capability graph are shared via `Arc<>`. Workers are concurrent executors drawing from the same pool of dirty work. Claims are atomic CAS operations on a per `(RuleId, EntityId)` register - cheap within a node, preventing duplicate execution across workers.

Across nodes, CRDT state replicates per namespace. Wasm modules are portable - any node can execute any module. Nodes do not permanently own the work running on them. Fact propagation between nodes flows through the distributed dirty signal; cross-node claims use distributed CAS.

## Key Properties

+ **Implicit orchestration** - no explicit wiring between rules; fact propagation handles it
+ **Global state awareness** - a fact change triggers every affected rule across the entire capability graph automatically
+ **Language agnostic** - rules compile to Wasm; C ABI means any language can write a rule
+ **Self-describing modules** - a module declares its sources, components, and rules entirely through Wasm exports; the host registers everything at load time with no manual wiring
+ **Edge-native** - designed as a lightweight single binary deployable where data lives
+ **Ontological inference** - causal tagging and priority-based inhibition prevent conflicting rule execution
+ **Tiered source model** - built-in connectors for common sources; raw TCP/UDP escape hatch for anything custom
