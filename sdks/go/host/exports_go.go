//go:build !tinygo

package host

//go:wasmexport slung_alloc
func SlungAlloc(length uint32) uint32 {
	return allocBuffer(length)
}

//go:wasmexport slung_dealloc
func SlungDealloc(ptr, length uint32) {
	freeBuffer(ptr, length)
}
