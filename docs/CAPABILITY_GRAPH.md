# Capability Graph Generation

The capability graph is built once when a module is loaded. It is the engine's precomputed index of what watches what - mapping every (EntityId, ComponentId) pair to the rules that care about it, and every rule to the components it watches. The inference loop never scans at runtime; it only consults this graph.

## What the graph contains

```
(EntityId, ComponentId) -> [RuleId]     // forward: fact change -> affected rules
RuleId -> [(EntityId, ComponentId)]     // reverse: rule -> what it watches

RuleId -> {
    watch:      [(EntityId, ComponentId)],
    priority:   u8,
    entrypoint: &str,                  // __slung_rule_<Name>
    module:     WasmModuleRef,
    namespace:  NamespaceId,
}

(EntityId, ComponentId) -> {
    watchers:       [RuleId],
    source:         SourceRef,
    component_type: &str,
    mapper:         &str,              // __slung_map_<Source>_<Component>
    dynamic:        bool,              // true if mapper returns EntityKey
}
```

## How the host builds it

When a module is loaded the host does one sweep of its exports. Three descriptor namespaces are scanned in order - sources first, then components, then rules. Order matters because components must be bound to entities before rules can reference them.

### Step 1 - Source descriptors

The host scans for exports matching `__slung_source_*_descriptor`. For each one found:

+ Calls `__slung_source_<Name>_descriptor_len` to get byte length
+ Calls `__slung_source_<Name>_descriptor` to get a pointer into Wasm linear memory
+ Reads and parses the descriptor JSON

The source descriptor carries the entity name, the connector kind (builtin or custom), connection config, and the list of components attached to this entity. Each component entry names its mapper function - the Wasm export the host calls to translate raw source bytes into a typed component value:

```json
{
    "name": "<Source>",
    "kind": "builtin",
    "builtin": "<connector>",
    "config": { ... },
    "components": [
        {
            "name":    "<component>",
            "type":    "<ComponentType>",
            "mapper":  "__slung_map_<Source>_<component>",
            "dynamic": true
        }
    ]
}
```

`dynamic: true` signals that the mapper returns an `EntityKey` alongside the component value. The host mints or looks up a distinct `EntityId` per key - so two different instances of the same source entity become separate entities, each with their own component state, dirty entries, and rule invocations. When `dynamic` is false the host writes all incoming data to the single static `EntityId` minted for the source.

From this the host:
+ Mints a static `EntityId` for the source
+ Opens the source connection using the config
+ For each component entry: mints a `ComponentId`, binds it to the `EntityId`, registers the mapper export name, registers the `(EntityId, ComponentId)` pair in the graph with an empty watcher list

At this point the graph knows every entity and every component, and knows which entity each component belongs to. No rules are wired yet.

### Step 2 - Component descriptors

The host scans for exports matching `__slung_component_*_descriptor`. For each one found:

+ Reads the descriptor to get the type name and its fields or variants
+ Looks up the already-registered `ComponentId` by type name
+ Attaches the serialize/deserialize boundary - the host now knows how to read and write this type across the Wasm linear memory boundary

```json
{
    "name":   "<ComponentType>",
    "fields": ["<field_a>", "<field_b>", "<field_c>"]
}
```

This step does not create new graph entries. It enriches the component entries registered in Step 1 with type information. A component that appears in a source descriptor but has no matching component descriptor is still valid - the host treats it as opaque bytes.

### Step 3 - Rule descriptors

The host scans for exports matching `__slung_rule_*_descriptor`. For each one found:

+ Reads the descriptor to get the rule name, watch list, and priority
+ Mints a `RuleId`
+ Resolves each watch entry - `"<Source>::<component>"` resolves to `(EntityId, ComponentId)` using the registrations from Step 1
+ Registers the rule in the rule registry
+ For each resolved `(EntityId, ComponentId)` pair: appends `RuleId` to the watcher list of that pair in the graph
+ Records the reverse mapping: `RuleId -> [(EntityId, ComponentId)]`

```json
{
    "name":     "<rule_name>",
    "watch":    ["<Source>::<component>", "<Source>::<component>"],
    "priority": 10
}
```

After this step the graph is fully wired. Every `(EntityId, ComponentId)` pair that has watchers points to the exact rules that need to fire when that component becomes dirty.

### Step 4 - Module is live

```
load .wasm binary
  -> sweep __slung_source_*_descriptor
      -> mint static EntityId per source
      -> open source connection
      -> mint ComponentId per component field
      -> bind ComponentId to EntityId
      -> register mapper export name on component entry
      -> register dynamic flag on component entry
      -> register (EntityId, ComponentId) -> [] in graph
  -> sweep __slung_component_*_descriptor
      -> attach serialize/deserialize boundary to ComponentId
  -> sweep __slung_rule_*_descriptor
      -> mint RuleId
      -> resolve watch list to (EntityId, ComponentId) pairs
      -> append RuleId to watcher list of each pair
      -> register reverse mapping RuleId -> [(EntityId, ComponentId)]
  -> module is live, graph is queryable
```

No init function. No manual registration. The module is fully self-describing from its exports.

## How data flows from source to active memory

When raw bytes arrive on a source connection the host runs the mapping pipeline before anything enters active memory or the dirty tracker. The mapper is the precise boundary between raw source data and the typed component value the engine reasons about - the host never interprets source bytes directly.

```
raw bytes arrive on source connection
  -> host looks up the source entity
  -> host looks up the component and its mapper export
  -> calls __slung_map_<Source>_<component>(raw_ptr, raw_len, out_ptr, out_len) -> i32
      -> mapper deserializes raw bytes into the component type
      -> serializes the value back into the out buffer
      -> returns 0 (success) or 1 (parse failure - host discards)
  -> if dynamic: mapper also returns an EntityKey
      -> host mints or looks up a concrete EntityId for that key
  -> host writes the serialized component value into active memory
      under the resolved (EntityId, ComponentId)
  -> stamps CausalTag { cause: ComponentId, entity: EntityId, node, ts }
  -> signals dirty entry: (EntityId, ComponentId)
  -> inference loop wakes, consults capability graph
  -> affected rules fire for that entity only
```

For dynamic sources, distinct incoming keys produce distinct entities. Rules watching a dynamic source's component fire independently per entity - one key's fact change never wakes another key's rule invocations.

## Mapper exports

Each component field on a source declaration that specifies a mapper causes the SDK macro to emit a mapper export. The host calls this export whenever new data arrives on the source, passing in the raw bytes and a buffer for the serialized output:

```
__slung_map_<Source>_<component>(
    raw_ptr: *const u8,    // pointer to raw source bytes in Wasm linear memory
    raw_len: u32,          // length of raw bytes
    out_ptr: *mut u8,      // pointer to output buffer
    out_len: *mut u32,     // host writes serialized length here
) -> i32                   // 0 = success, 1 = failure
```

For dynamic entity mappers the export writes an additional `EntityKey` into a separate out buffer. The host reads both the component value and the key before writing to active memory.

## How the inference loop uses the graph

When a component becomes dirty the loop performs a single lookup:

```
dirty: (EntityId, ComponentId)
  -> graph.watchers(EntityId, ComponentId)
  -> [RuleId]
  -> filter by claim availability
  -> sort by priority
  -> dispatch
```

The forward direction - `(EntityId, ComponentId) -> [RuleId]` - is a hash map keyed on the pair. Lookup is O(1). The result is a small vec of RuleIds that goes directly into the agenda.

For dynamic entities the lookup resolves the concrete `EntityId` first, then looks up its watchers. Rules watching a dynamic source's component are registered against the static `EntityId` of the source at graph build time but fanned out to each concrete entity at dispatch time, so each entity's rules fire independently with the correct entity context.

## Lifecycle

**Module unload** - the reverse mapping `RuleId -> [(EntityId, ComponentId)]` is used to find and remove every watcher entry the rule added. Source connections are closed. Static EntityIds, dynamic EntityIds, and ComponentIds minted by this module are all retired.

**Cycle detection** - before the module goes live the host walks the graph looking for rules that watch components they also write to. Such a rule is a potential infinite loop. The host flags this at registration time rather than discovering it at runtime.

**Cross-namespace isolation** - every graph entry carries a `NamespaceId`. Lookups are always scoped to a namespace. A dirty component in one namespace never wakes rules in another even if they share a node.
