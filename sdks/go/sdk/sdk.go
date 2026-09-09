// Package sdk provides the author-facing TinyGo API for Slung modules.
//
// The host package contains direct ABI bindings. This package removes the
// pointer/length and status-code boilerplate component authors should not need
// to repeat in every mapper and rule.
package sdk

import (
	"encoding/binary"
	"encoding/json"
	"log"
	"unsafe"

	"github.com/slunghq/slung/sdks/go/host"
)

// Descriptor packs a static JSON descriptor into Slung's pointer/length ABI.
// Keep the JSON literal alive for the lifetime of the module.
func Descriptor(value string) uint64 {
	return uint64(uintptr(unsafe.Pointer(unsafe.StringData(value))))<<32 | uint64(len(value))
}

// Mapper adapts typed JSON parsing to a Slung mapper export.
func Mapper[T any](parse func([]byte) (T, error)) func(rawPtr, rawLen, outPtr, outLenPtr uint32) int32 {
	return func(rawPtr, rawLen, outPtr, outLenPtr uint32) int32 {
		raw := unsafe.Slice((*byte)(unsafe.Pointer(uintptr(rawPtr))), int(rawLen))

		value, err := parse(raw)
		if err != nil {
			return 1
		}

		encoded, err := json.Marshal(value)
		if err != nil || uint64(len(encoded)) > uint64(^uint32(0)) {
			return 2
		}

		copy(unsafe.Slice((*byte)(unsafe.Pointer(uintptr(outPtr))), len(encoded)), encoded)
		binary.LittleEndian.PutUint32(
			unsafe.Slice((*byte)(unsafe.Pointer(uintptr(outLenPtr))), 4),
			uint32(len(encoded)),
		)
		return 0
	}
}

// Rule adapts a normal Go error-returning rule to Slung's int32 ABI.
func Rule(fn func(*RuleContext) error) func() int32 {
	return func() int32 {
		if err := fn(&RuleContext{}); err != nil {
			log.Print(err)
			return 1
		}
		return 0
	}
}

// ComponentKey identifies a typed component in the host store.
type ComponentKey[T any] struct {
	SourceID    uint32
	ComponentID uint32
}

// NewComponentKey creates a typed component selector.
func NewComponentKey[T any](sourceID, componentID uint32) ComponentKey[T] {
	return ComponentKey[T]{SourceID: sourceID, ComponentID: componentID}
}

// RuleContext is passed to rule handlers. It is intentionally small for now;
// execution-scoped capabilities can be added without changing rule signatures.
type RuleContext struct{}

// Get reads and decodes a typed component value.
func Get[T any](_ *RuleContext, key ComponentKey[T]) (T, error) {
	var value T
	raw, err := host.Get(key.SourceID, key.ComponentID)
	if err != nil {
		return value, err
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return value, err
	}
	return value, nil
}

// Set serializes and writes a typed component value.
func Set[T any](_ *RuleContext, key ComponentKey[T], value T) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return host.Set(key.SourceID, key.ComponentID, encoded)
}

// StoreGet reads an opaque module-store value.
func StoreGet(key []byte) ([]byte, error) { return host.StoreGet(key) }

// StoreSet writes an opaque module-store value.
func StoreSet(key, value []byte) error { return host.StoreSet(key, value) }

// StoreDelete removes an opaque module-store value.
func StoreDelete(key []byte) (bool, error) { return host.StoreDelete(key) }

type Timestamp = host.Timestamp

// Now returns the current host HLC timestamp.
func Now() (Timestamp, error) { return host.Now() }

// Yield cooperatively returns execution to the host scheduler.
func Yield() error { return host.Yield() }
