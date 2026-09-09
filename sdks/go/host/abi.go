// Package host exposes the low-level Slung guest ABI.
//
// This package intentionally mirrors the host function signatures directly.
// Higher-level component and rule APIs can be built on top of it later.
package host

import (
	"fmt"
	"runtime"
	"sync"
	"unsafe"
)

// Timestamp is the HLC value returned by Now.
type Timestamp struct {
	WallHi  uint32
	WallLo  uint32
	Logical uint32
}

// WallMS returns the wall-clock portion as milliseconds since the Unix epoch.
func (t Timestamp) WallMS() uint64 {
	return uint64(t.WallHi)<<32 | uint64(t.WallLo)
}

// StatusError reports a non-zero Slung ABI status.
type StatusError struct {
	Operation string
	Status    uint32
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("%s failed with status %d", e.Operation, e.Status)
}

//go:wasmimport env slung_set
func abiSet(entityID, componentID, valuePtr, valueLen uint32) uint32

//go:wasmimport env slung_get
func abiGet(entityID, componentID, outPtr, outLen uint32) uint32

//go:wasmimport env slung_now
func abiNow(wallHiPtr, wallLoPtr, logicalPtr uint32) uint32

//go:wasmimport env slung_yield
func abiYield() uint32

var allocations = struct {
	sync.Mutex
	buffers map[uint32][]byte
}{buffers: make(map[uint32][]byte)}

func allocBuffer(length uint32) uint32 {
	if length == 0 {
		return 0
	}
	buffer := make([]byte, length)
	ptr := uint32(uintptr(unsafe.Pointer(&buffer[0])))
	allocations.Lock()
	allocations.buffers[ptr] = buffer
	allocations.Unlock()
	return ptr
}

func freeBuffer(ptr, length uint32) {
	if ptr == 0 || length == 0 {
		return
	}
	allocations.Lock()
	delete(allocations.buffers, ptr)
	allocations.Unlock()
}

// Set writes a JSON-encoded component value to the LWW store.
func Set(entityID, componentID uint32, value []byte) error {
	if len(value) == 0 {
		return &StatusError{Operation: "slung_set", Status: 1}
	}
	status := abiSet(entityID, componentID, pointer(value), uint32(len(value)))
	runtime.KeepAlive(value)
	if status != 0 {
		return &StatusError{Operation: "slung_set", Status: status}
	}
	return nil
}

// Get reads the JSON-encoded component value from the LWW store.
// The returned bytes are owned by the caller.
func Get(entityID, componentID uint32) ([]byte, error) {
	var outPtr uint32
	var outLen uint32
	status := abiGet(entityID, componentID, pointerOf(&outPtr), pointerOf(&outLen))
	if status != 0 || outPtr == 0 || outLen == 0 {
		return nil, &StatusError{Operation: "slung_get", Status: status}
	}
	return copyAndFree(outPtr, outLen), nil
}

// Now returns the current host HLC timestamp.
func Now() (Timestamp, error) {
	var timestamp Timestamp
	status := abiNow(
		pointerOf(&timestamp.WallHi),
		pointerOf(&timestamp.WallLo),
		pointerOf(&timestamp.Logical),
	)
	if status != 0 {
		return Timestamp{}, &StatusError{Operation: "slung_now", Status: status}
	}
	return timestamp, nil
}

// Yield cooperatively returns execution to the host scheduler.
func Yield() error {
	status := abiYield()
	if status != 0 {
		return &StatusError{Operation: "slung_yield", Status: status}
	}
	return nil
}

func pointer(bytes []byte) uint32 {
	if len(bytes) == 0 {
		return 0
	}
	return uint32(uintptr(unsafe.Pointer(&bytes[0])))
}

func pointerOf(value *uint32) uint32 {
	return uint32(uintptr(unsafe.Pointer(value)))
}

func copyAndFree(ptr, length uint32) []byte {
	value := unsafe.Slice((*byte)(unsafe.Pointer(uintptr(ptr))), int(length))
	result := append([]byte(nil), value...)
	SlungDealloc(ptr, length)
	return result
}
