# Slung Architecture

## What it is

Slung is an ontology-driven compute engine that executes work based on real-time facts about relationships between components in a system. Instead of writing steps in a workflow, you define entities, their components, and rules that fire when facts change. The engine handles orchestration implicitly.

## The Problem

Workflow engines are rigid. They model work as a sequence of steps - if A then B, handle failure, retry. This works for predictable, linear processes but breaks down in moving systems where facts change asynchronously and decisions need to adapt in real time. Adding edge cases means adding more steps, forever. The complexity never converges.

## The Solution

Slung replaces steps with relationships. Data sources - Postgres tables, NATS subjects, WebSocket streams, message brokers - become first-class entities in an ECS (Entity Component System) model. Components are typed algebraic fact payloads attached to those entities. Rules are functions that fire only when the components they watch become dirty. The engine maintains global state awareness: a fact change anywhere in the system automatically propagates to every rule that cares about it.

This is not a new idea in AI - CLIPS and Drools solved this decades ago. Slung brings it to the infrastructure level.

## Systems Design

**Graph Connector**
Normalises heterogeneous external sources into the ECS model. Source adapters manage live connections. An entity mapper translates external subjects into EntityId + ComponentId pairs. The capability graph tracks which rules watch which components across the entire system.

**Active Memory**
The current truth of the world. Backed by a distributed CRDT store (LWW-first) with a local columnar cache per node for fast reads. Every write carries a causal tag recording what triggered the change. A shared dirty tracker signals component changes to the inference loop.

**Wasm Runtime**
Rules are written in any language and compiled to Wasm. The host exposes a minimal C ABI. SDKs should provide macros that auto-register modules at load time. The runtime is invisible to rule authors.

**State Machine (Inference Loop)**
Forward chaining with dirty-driven agenda building. On each cycle: dirty components are mapped to affected rules via the capability graph, rules are ordered by priority, causal tags are checked for conflict inhibition, and the agenda is dispatched to the Wasm runtime. Rule writes re-enter active memory and may extend the agenda. The cycle runs until stable state or max depth.

**Multi-Node / Worker Model**
Each node runs N workers sharing one namespace state. Workers are concurrent executors - they share the CRDT store, dirty tracker, and capability graph via Arc<>. Work is claimed via atomic CAS on a per (rule_id, entity_id) claim register, preventing duplicate execution. Across nodes, CRDT state is replicated per namespace. Wasm modules are portable and can execute on any node in the network - nodes do not permanently own the work running off them.

## Key Properties

+ **Implicit orchestration** - no explicit wiring between rules; fact propagation handles it
+ **Global state awareness** - a fact change triggers every affected rule across the entire capability graph automatically
+ **Language agnostic** - rules compile to Wasm; C ABI means any language can write a rule
+ **Edge-native** - designed as a lightweight single binary deployable where data lives
+ **Ontological inference** - causal tagging and priority-based inhibition prevent conflicting rule execution
