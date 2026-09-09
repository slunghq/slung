package host

import "runtime"

//go:wasmimport env slung_store_get
func abiStoreGet(keyPtr, keyLen, outPtr, outLen uint32) uint32

//go:wasmimport env slung_store_set
func abiStoreSet(keyPtr, keyLen, valuePtr, valueLen uint32) uint32

//go:wasmimport env slung_store_delete
func abiStoreDelete(keyPtr, keyLen uint32) uint32

// StoreGet reads an opaque module-owned value.
// Status 1 means the key is missing; other non-zero statuses are errors.
func StoreGet(key []byte) ([]byte, error) {
	var outPtr uint32
	var outLen uint32
	status := abiStoreGet(pointer(key), uint32(len(key)), pointerOf(&outPtr), pointerOf(&outLen))
	runtime.KeepAlive(key)
	if status == 1 {
		return nil, nil
	}
	if status != 0 {
		return nil, &StatusError{Operation: "slung_store_get", Status: status}
	}
	if outPtr == 0 || outLen == 0 {
		return []byte{}, nil
	}
	return copyAndFree(outPtr, outLen), nil
}

// StoreSet writes an opaque module-owned value.
func StoreSet(key, value []byte) error {
	status := abiStoreSet(
		pointer(key), uint32(len(key)),
		pointer(value), uint32(len(value)),
	)
	runtime.KeepAlive(key)
	runtime.KeepAlive(value)
	if status != 0 {
		return &StatusError{Operation: "slung_store_set", Status: status}
	}
	return nil
}

// StoreDelete removes an opaque module-owned value.
// The returned bool is false when the key did not exist.
func StoreDelete(key []byte) (bool, error) {
	status := abiStoreDelete(pointer(key), uint32(len(key)))
	runtime.KeepAlive(key)
	switch status {
	case 0:
		return true, nil
	case 1:
		return false, nil
	default:
		return false, &StatusError{Operation: "slung_store_delete", Status: status}
	}
}
